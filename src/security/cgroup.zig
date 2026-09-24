//! 別プロセスのセルに cgroup v2 で資源の上限を掛ける (ADR-010 段階 3)。
//!
//! systemd がユーザーに委譲している `user@<uid>.service` の下に `weave.slice` を作り、子プロセスごとに
//! `cell-<node_id>-<pid>` を切って cpu.max / memory.max / pids.max を書き、子を移す。スレッドの nice 値と違い、
//! CPU 時間とメモリの上限を OS が保証する (A3 の「保証」)。root 権限は要らない。
//! 委譲が無い環境 (コンテナ・systemd 以外) では使えないので、呼ぶ側は警告を出して続ける。
//! 場所は WEAVE_CGROUP_ROOT で明示もできる (weave.slice にあたるディレクトリ)。
const std = @import("std");

pub const Limits = struct {
    /// CPU: period あたりの上限 (µs)。50000/100000 = 1 コアの 50%
    cpu_quota_us: u32 = 50_000,
    cpu_period_us: u32 = 100_000,
    memory_bytes: u64 = 256 * 1024 * 1024,
    pids: u32 = 32,
};

pub const Cgroups = struct {
    allocator: std.mem.Allocator,
    root: []u8,

    /// 委譲された場所を見つけて weave.slice を用意する。使えなければ error
    pub fn init(allocator: std.mem.Allocator) !Cgroups {
        const root = if (std.process.getEnvVarOwned(allocator, "WEAVE_CGROUP_ROOT")) |r| r else |_| try findDelegated(allocator);
        errdefer allocator.free(root);
        std.fs.cwd().makePath(root) catch return error.CgroupUnavailable;
        // weave.slice 自体にはプロセスを置かないので、子に cpu / memory / pids を配れる
        writeFile(root, "cgroup.subtree_control", "+cpu +memory +pids") catch return error.CgroupControllersUnavailable;
        var self: Cgroups = .{ .allocator = allocator, .root = root };
        self.removeStale();
        return self;
    }

    /// 前の Core が kill -9 などで片付けられなかった、プロセスのいない cell-* を消す (空の cgroup は rmdir できる)
    fn removeStale(self: *Cgroups) void {
        var dir = std.fs.cwd().openDir(self.root, .{ .iterate = true }) catch return;
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |e| {
            if (e.kind != .directory or !std.mem.startsWith(u8, e.name, "cell-")) continue;
            dir.deleteDir(e.name) catch {}; // プロセスが残っていれば EBUSY で消えない (それでよい)
        }
    }

    pub fn deinit(self: *Cgroups) void {
        self.removeStale();
        self.allocator.free(self.root);
    }

    fn findDelegated(allocator: std.mem.Allocator) ![]u8 {
        const data = try std.fs.cwd().readFileAlloc(allocator, "/proc/self/cgroup", 4096);
        defer allocator.free(data);
        // cgroup v2: "0::/user.slice/user-1000.slice/user@1000.service/app.slice/..."
        const line = std.mem.trim(u8, data, " \n");
        if (!std.mem.startsWith(u8, line, "0::")) return error.CgroupUnavailable;
        const path = line[3..];
        const at = std.mem.indexOf(u8, path, ".service") orelse return error.CgroupUnavailable;
        const svc_start = std.mem.lastIndexOf(u8, path[0..at], "/user@") orelse return error.CgroupUnavailable;
        _ = svc_start;
        return std.fmt.allocPrint(allocator, "/sys/fs/cgroup{s}/weave.slice", .{path[0 .. at + ".service".len]});
    }

    /// 子プロセス pid を新しい cgroup に入れて上限を掛ける。作った cgroup のパスを返す (後で remove する)
    pub fn place(self: *Cgroups, name: []const u8, pid: std.posix.pid_t, limits: Limits) ![]u8 {
        const dir = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.root, name });
        errdefer self.allocator.free(dir);
        std.fs.cwd().makeDir(dir) catch |err| if (err != error.PathAlreadyExists) return err;
        var buf: [64]u8 = undefined;
        try writeFile(dir, "cpu.max", try std.fmt.bufPrint(&buf, "{d} {d}", .{ limits.cpu_quota_us, limits.cpu_period_us }));
        try writeFile(dir, "memory.max", try std.fmt.bufPrint(&buf, "{d}", .{limits.memory_bytes}));
        try writeFile(dir, "pids.max", try std.fmt.bufPrint(&buf, "{d}", .{limits.pids}));
        try writeFile(dir, "cgroup.procs", try std.fmt.bufPrint(&buf, "{d}", .{pid}));
        return dir;
    }

    /// プロセスがいなくなった cgroup を消す
    pub fn remove(self: *Cgroups, dir: []u8) void {
        std.fs.cwd().deleteDir(dir) catch {};
        self.allocator.free(dir);
    }
};

fn writeFile(dir: []const u8, file: []const u8, value: []const u8) !void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, file });
    const f = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer f.close();
    try f.writeAll(value);
}
