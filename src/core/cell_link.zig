//! CellLink — 別プロセスのセル (weave-cell) と Core をつなぐ (ADR-010 Level 2, 段階 1: egress)。
//!
//! - Core は UNIX ドメインソケットで待ち受け、子プロセス `weave-cell egress` を起動して監視する。
//!   子が落ちたら (kill -9 を含む) すぐ起動し直す。Core と他のセルは止まらない。
//! - `core.obs.request.*` を Core のバスで購読し (egress セル)、子に転送する。
//! - 「WEAVE が意図した OBS の状態」は Core 側で持つ。子が (再) 接続したら全部送り直すので、
//!   子のメモリが消えても OBS の表示は戻る。スナップショット (R7) もこれを使う。
//! - 子から来てよいのは `core.obs.event.*` と `core.obs.link` だけ。それ以外は拒否して監査に残す
//!   (強制点は Core。子プロセスは信頼しない)。子はソケットのパーミッション (0600) とトークンで確かめる。
const std = @import("std");
const event_bus = @import("event_bus.zig");
const ws = @import("../transport/ws_proto.zig");
const DesiredState = @import("../builtin/obs.zig").DesiredState;
const log = @import("../common/log.zig");

pub const CellLink = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    socket_path: []const u8,
    /// 子プロセスの argv (argv[0] は weave-cell の絶対パス)
    child_argv: []const []const u8,
    /// 子に渡す追加の環境変数 (OBS のパスワード)
    obs_password: ?[]const u8,
    token: [32]u8 = undefined,

    desired: DesiredState,
    server: ?std.net.Server = null,
    stream: ?std.net.Stream = null,
    stream_mutex: std.Thread.Mutex = .{},
    child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    restarts: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    denied: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub fn create(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, socket_path: []const u8, child_argv: []const []const u8, obs_password: ?[]const u8) !*CellLink {
        const self = try allocator.create(CellLink);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .socket_path = try allocator.dupe(u8, socket_path),
            .child_argv = child_argv,
            .obs_password = obs_password,
            .desired = DesiredState.init(allocator),
        };
        var raw: [16]u8 = undefined;
        std.crypto.random.bytes(&raw);
        _ = std.fmt.bufPrint(&self.token, "{x}", .{&raw}) catch unreachable;
        return self;
    }

    pub fn destroy(self: *CellLink) void {
        self.stop();
        self.desired.deinit();
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    pub fn start(self: *CellLink) !void {
        if (std.fs.path.dirname(self.socket_path)) |d| try std.fs.cwd().makePath(d);
        std.fs.cwd().deleteFile(self.socket_path) catch {};
        const addr = try std.net.Address.initUnix(self.socket_path);
        self.server = try addr.listen(.{});
        // ソケットファイルは自分だけが開ける
        std.posix.fchmodat(std.fs.cwd().fd, self.socket_path, 0o600, 0) catch {};

        const cell = self.bus.getCell("egress") orelse try self.bus.createCell("egress", .{ .trust = .core });
        if (self.bus.graph) |g| try g.registerNodeIn(self.node_id, "ObsEgress", .native, cell.name);
        try self.bus.subscribeEx("core.obs.request.*", self.node_id, onRequest, self, .{ .cell = cell });

        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, supervise, .{self});
        log.info("CellLink: egress runs in a separate process (ADR-010), socket {s}", .{self.socket_path});
    }

    pub fn stop(self: *CellLink) void {
        if (!self.running.swap(false, .acq_rel)) return;
        const pid = self.child_pid.load(.acquire);
        if (pid > 0) std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        {
            self.stream_mutex.lock();
            defer self.stream_mutex.unlock();
            if (self.stream) |s| {
                ws.writeFrame(s, .close, "", false) catch {};
                std.posix.shutdown(s.handle, .both) catch {};
            }
        }
        // accept で待っていれば起こす
        if (std.net.connectUnixSocket(self.socket_path)) |c| c.close() else |_| {}
        if (self.thread) |t| t.join();
        self.thread = null;
        if (self.server) |*s| s.deinit();
        self.server = null;
        std.fs.cwd().deleteFile(self.socket_path) catch {};
    }

    /// Core のバスの要求 → 意図した状態に記録し、子に送る (子がいなければ再接続時にまとめて送る)
    fn onRequest(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *CellLink = @ptrCast(@alignCast(ctx.?));
        const prefix = "core.obs.request.";
        if (!std.mem.startsWith(u8, msg.topic, prefix)) return;
        _ = self.desired.record(msg.topic[prefix.len..], msg.payload) catch false;
        self.sendToChild(msg.topic, msg.payload);
    }

    fn sendToChild(self: *CellLink, topic: []const u8, payload: []const u8) void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        out.writer(self.allocator).print("{f}", .{std.json.fmt(.{ .t = topic, .p = payload }, .{})}) catch return;
        self.stream_mutex.lock();
        defer self.stream_mutex.unlock();
        const s = self.stream orelse return;
        ws.writeFrame(s, .text, out.items, false) catch {};
    }

    fn spawnChild(self: *CellLink) !std.process.Child {
        var env = try std.process.getEnvMap(self.allocator);
        defer env.deinit();
        try env.put("WEAVE_CELL_TOKEN", &self.token);
        if (self.obs_password) |p| try env.put("WEAVE_OBS_PASSWORD", p);
        var child = std.process.Child.init(self.child_argv, self.allocator);
        child.env_map = &env;
        child.stdin_behavior = .Ignore;
        try child.spawn();
        self.child_pid.store(child.id, .release);
        return child;
    }

    fn setStatus(self: *CellLink, status: @import("../common/types.zig").NodeStatus) void {
        if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, status);
    }

    /// 子を起動 → 接続を受ける → 名乗りを確かめる → 意図した状態を送り直す → 子からのイベントを流す。
    /// 子が切れたら (落ちた・kill された) 最初からやり直す
    fn supervise(self: *CellLink) void {
        var backoff_ms: u64 = 0;
        while (self.running.load(.acquire)) {
            if (backoff_ms > 0) std.Thread.sleep(backoff_ms * std.time.ns_per_ms);
            var child = self.spawnChild() catch |err| {
                log.err("CellLink: cannot start weave-cell: {any}", .{err});
                backoff_ms = @min(@max(backoff_ms * 2, 250), 5000);
                continue;
            };
            self.serveChild();
            // 子の終了を待つ (kill -9 なら即座)。まだ生きていれば止める
            const pid = self.child_pid.swap(0, .acq_rel);
            if (pid > 0) std.posix.kill(pid, std.posix.SIG.KILL) catch {};
            _ = child.wait() catch {};
            if (!self.running.load(.acquire)) break;
            _ = self.restarts.fetchAdd(1, .monotonic);
            self.setStatus(.restarting);
            log.warn("CellLink: egress cell process exited; restarting it (Core and the other cells keep running)", .{});
            backoff_ms = 50;
        }
    }

    fn serveChild(self: *CellLink) void {
        var server = &(self.server orelse return);
        const conn = server.accept() catch return;
        if (!self.running.load(.acquire)) {
            conn.stream.close();
            return;
        }
        // 最初のフレームで名乗る: {"hello":"egress","token":"..."}
        const hello = ws.readMessage(conn.stream, self.allocator, 4096) catch {
            conn.stream.close();
            return;
        };
        defer self.allocator.free(hello.payload);
        const H = struct { hello: []const u8 = "", token: []const u8 = "" };
        const h = std.json.parseFromSlice(H, self.allocator, hello.payload, .{ .ignore_unknown_fields = true }) catch {
            conn.stream.close();
            return;
        };
        defer h.deinit();
        if (!std.mem.eql(u8, h.value.hello, "egress") or !ws.constantTimeEql(h.value.token, &self.token)) {
            log.err("CellLink: rejected a connection with a wrong token", .{});
            conn.stream.close();
            return;
        }
        {
            self.stream_mutex.lock();
            defer self.stream_mutex.unlock();
            self.stream = conn.stream;
        }
        defer {
            self.stream_mutex.lock();
            self.stream = null;
            self.stream_mutex.unlock();
            conn.stream.close();
        }

        // 意図した OBS の状態を送り直す (子のメモリは消えているので)
        if (self.desired.copies(self.allocator)) |entries| {
            defer DesiredState.freeCopies(self.allocator, entries);
            var tbuf: [128]u8 = undefined;
            for (entries) |e| {
                const t = std.fmt.bufPrint(&tbuf, "core.obs.request.{s}", .{e.request_type}) catch continue;
                self.sendToChild(t, e.data);
            }
            if (entries.len > 0 and self.restarts.load(.monotonic) > 0) log.info("CellLink: re-sent {d} desired OBS state(s) to the restarted egress cell", .{entries.len});
        } else |_| {}
        self.setStatus(.active);

        while (self.running.load(.acquire)) {
            const f = ws.readMessage(conn.stream, self.allocator, 1 << 20) catch return;
            defer self.allocator.free(f.payload);
            if (f.opcode == .close) return;
            if (f.opcode != .text) continue;
            const M = struct { t: []const u8, p: []const u8 };
            const m = std.json.parseFromSlice(M, self.allocator, f.payload, .{}) catch continue;
            defer m.deinit();
            if (!allowedFromChild(m.value.t)) {
                _ = self.denied.fetchAdd(1, .monotonic);
                var buf: [256]u8 = undefined;
                var w = std.io.Writer.fixed(&buf);
                w.print("{f}", .{std.json.fmt(.{ .node_id = self.node_id, .name = "ObsEgress", .action = "publish", .topic = m.value.t }, .{})}) catch continue;
                self.bus.publish("core.security.acl_denied", w.buffered(), .Transient, 0) catch {};
                continue;
            }
            self.bus.publish(m.value.t, m.value.p, .Transient, self.node_id) catch {};
        }
    }

    pub fn allowedFromChild(topic: []const u8) bool {
        return std.mem.startsWith(u8, topic, "core.obs.event.") or std.mem.eql(u8, topic, "core.obs.link");
    }
};

test "CellLink: only OBS state topics may come back from the egress cell" {
    try std.testing.expect(CellLink.allowedFromChild("core.obs.event.SceneItemEnableStateChanged"));
    try std.testing.expect(CellLink.allowedFromChild("core.obs.link"));
    try std.testing.expect(!CellLink.allowedFromChild("core.obs.request.StopStream"));
    try std.testing.expect(!CellLink.allowedFromChild("core.node.fault"));
    try std.testing.expect(!CellLink.allowedFromChild("ext.twitch.chat.message"));
}
