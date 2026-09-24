//! weave-cell — セルを別の OS プロセスで動かす (ADR-010 Level 2, 段階 1: egress セル)。
//!
//! Core (weave) が子プロセスとして起動する。自分の中に小さなバスを持ち、そこで既存の ObsEgress
//! (または mock) をそのまま動かす。Core とは UNIX ドメインソケットでつながり、フレームは ws_proto を使う。
//!   Core → cell : {"t":"core.obs.request.<Type>","p":"<payload JSON>"}   OBS への要求
//!   cell → Core : {"t":"core.obs.event.*" | "core.obs.link","p":"..."}  OBS からの状態
//! 何を受け取り何を出してよいかの判定は Core 側で行う (このプロセスは信頼されない)。
//! ObsEgress がパーサのバグなどで落ちても、落ちるのはこのプロセスだけで、Core は再起動して
//! 意図した OBS の状態を送り直す。
//!
//! 使い方 (Core が起動する。手で起動するものではない):
//!   weave-cell egress --socket <path> [--mock-obs-file <file>] [--obs-host H --obs-port P]
//!   環境変数: WEAVE_CELL_TOKEN (Core との認証), WEAVE_OBS_PASSWORD
const std = @import("std");
const event_bus = @import("core/event_bus.zig");
const ws = @import("transport/ws_proto.zig");
const ObsEgressNode = @import("builtin/obs.zig").ObsEgressNode;
const MockObsEgressNode = @import("builtin/mock_obs.zig").MockObsEgressNode;
const log = @import("common/log.zig");

const Link = struct {
    stream: std.net.Stream,
    mutex: std.Thread.Mutex = .{},
    allocator: std.mem.Allocator,

    fn send(self: *Link, topic: []const u8, payload: []const u8) void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        out.writer(self.allocator).print("{f}", .{std.json.fmt(.{ .t = topic, .p = payload }, .{})}) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        ws.writeFrame(self.stream, .text, out.items, false) catch {};
    }

    /// ローカルバスで ObsEgress が出したもののうち、Core に返すものだけを送る
    fn tap(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *Link = @ptrCast(@alignCast(ctx.?));
        if (std.mem.startsWith(u8, msg.topic, "core.obs.event.") or std.mem.eql(u8, msg.topic, "core.obs.link")) {
            self.send(msg.topic, msg.payload);
        }
    }
};

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2 or !std.mem.eql(u8, args[1], "egress")) {
        std.debug.print("usage: weave-cell egress --socket <path> [--mock-obs-file F] [--obs-host H --obs-port P]\n", .{});
        std.process.exit(2);
    }
    var socket_path: ?[]const u8 = null;
    var mock_file: ?[]const u8 = null;
    var obs_host: []const u8 = "127.0.0.1";
    var obs_port: u16 = 4455;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--socket")) socket_path = args[i + 1];
        if (std.mem.eql(u8, args[i], "--mock-obs-file")) mock_file = args[i + 1];
        if (std.mem.eql(u8, args[i], "--obs-host")) obs_host = args[i + 1];
        if (std.mem.eql(u8, args[i], "--obs-port")) obs_port = std.fmt.parseInt(u16, args[i + 1], 10) catch 4455;
    }
    const path = socket_path orelse return error.SocketRequired;
    const token = std.process.getEnvVarOwned(allocator, "WEAVE_CELL_TOKEN") catch return error.TokenRequired;
    defer allocator.free(token);
    const password = std.process.getEnvVarOwned(allocator, "WEAVE_OBS_PASSWORD") catch null;
    defer if (password) |p| allocator.free(p);

    // Core につなぎ、トークンで名乗る
    const stream = try std.net.connectUnixSocket(path);
    var link = Link{ .stream = stream, .allocator = allocator };
    defer stream.close();
    {
        var hello: std.ArrayListUnmanaged(u8) = .{};
        defer hello.deinit(allocator);
        try hello.writer(allocator).print("{f}", .{std.json.fmt(.{ .hello = "egress", .token = token }, .{})});
        try ws.writeFrame(stream, .text, hello.items, false);
    }

    // セルの中のバス。ObsEgress はここに購読・発行する (Core のバスとは別物)
    var bus = try event_bus.EventBus.init(allocator, 1024);
    defer bus.deinit();
    bus.verbose = false;
    try bus.subscribeEx("#", 99, Link.tap, &link, .{ .receive_own = true, .record_graph = false });
    try bus.start();
    defer bus.stop();

    var real: ?*ObsEgressNode = null;
    var mock: ?*MockObsEgressNode = null;
    if (mock_file) |f| {
        mock = try MockObsEgressNode.init(allocator, &bus, 2, password, f);
        mock.?.truncate_on_connect = false;
        try mock.?.connect(obs_host, obs_port);
    } else {
        real = try ObsEgressNode.init(allocator, &bus, 2, password);
        try real.?.connect(obs_host, obs_port);
    }
    defer {
        if (mock) |m| m.deinit();
        if (real) |r| {
            r.stop();
            r.deinit();
        }
    }
    log.info("weave-cell: egress cell running (pid {d})", .{std.os.linux.getpid()});

    // Core からの要求をローカルバスに流す。Core が切れたら終わる
    while (true) {
        const f = ws.readMessage(stream, allocator, 1 << 20) catch break;
        defer allocator.free(f.payload);
        if (f.opcode == .close) break;
        if (f.opcode != .text) continue;
        const Msg = struct { t: []const u8, p: []const u8 };
        const m = std.json.parseFromSlice(Msg, allocator, f.payload, .{}) catch continue;
        defer m.deinit();
        if (!std.mem.startsWith(u8, m.value.t, "core.obs.request.")) continue;
        bus.publish(m.value.t, m.value.p, .Reliable, 0) catch {};
    }
    bus.waitIdle();
    log.info("weave-cell: Core closed the link; exiting", .{});
}
