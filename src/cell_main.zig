//! weave-cell — セルを別の OS プロセスで動かす (ADR-010 Level 2, 段階 1: egress セル)。
//!
//! Core (weave) が子プロセスとして起動する。自分の中に小さなバスを持ち、そこで既存の ObsEgress
//! (または mock) をそのまま動かす。Core とは UNIX ドメインソケットでつながり、フレームは ws_proto を使う。
//!   Core → cell : {"t":"core.obs.request.<Type>","p":"<payload JSON>"}   OBS への要求
//!   cell → Core : {"t":"core.obs.event.*" | "core.obs.link" | "core.obs.problem" | "core.obs.latency","p":"..."}  OBS からの状態・断られた要求・遅延
//! 何を受け取り何を出してよいかの判定は Core 側で行う (このプロセスは信頼されない)。
//! ObsEgress がパーサのバグなどで落ちても、落ちるのはこのプロセスだけで、Core は再起動して
//! 意図した OBS の状態を送り直す。
//!
//! 使い方 (Core が起動する。手で起動するものではない):
//!   weave-cell egress --socket <path> [--mock-obs-file <file>] [--obs-host H --obs-port P]
//!   weave-cell plugin --socket <path>     (段階 2: Wasm プラグインのセル。wasm と manifest は Core からソケットで受け取る)
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
        if (std.mem.startsWith(u8, msg.topic, "core.obs.event.") or std.mem.eql(u8, msg.topic, "core.obs.link") or std.mem.eql(u8, msg.topic, "core.obs.problem") or std.mem.eql(u8, msg.topic, "core.obs.latency")) {
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

    if (args.len >= 2 and std.mem.eql(u8, args[1], "plugin")) return pluginMain(allocator, args);
    if (args.len >= 2 and std.mem.eql(u8, args[1], "selftest-seccomp")) return selftestSeccomp();
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
        const Msg = struct { t: []const u8, p: []const u8, s: u32 = 0, o: i64 = 0, h: u8 = 0 };
        const m = std.json.parseFromSlice(Msg, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer m.deinit();
        if (!std.mem.startsWith(u8, m.value.t, "core.obs.request.")) continue;
        // 送り主は Core のノード ID のまま渡す (子のバスにそのノードはいないが、ObsEgress は記録に使うだけ)
        bus.publishEx(m.value.t, m.value.p, .{ .qos = .Reliable, .source = m.value.s, .origin_us = m.value.o, .hops = m.value.h }) catch {};
    }
    bus.waitIdle();
    log.info("weave-cell: Core closed the link; exiting", .{});
}

// ======================================================================
// 段階 2: Wasm プラグインのセル (ADR-010 §7)
// 子の中では今の部品 (バス・PluginManager・WasmSubscriber) をそのまま使う。違うのは Host API で、
// publish / subscribe / unsubscribe は判定せずに Core に問い合わせる (host_api.forwarder)。
// ======================================================================

const host_api = @import("api/host_api.zig");
const sandbox = @import("security/sandbox.zig");

/// seccomp が効いていることを確かめる: フィルタを掛けてからファイルを開こうとする。
/// 正しく効いていれば SIGSYS で終わり、ここには戻らない
fn selftestSeccomp() !void {
    try sandbox.applySeccomp();
    const f = std.fs.cwd().openFile("/etc/hostname", .{}) catch |err| {
        std.debug.print("open failed without being killed: {any}\n", .{err});
        std.process.exit(3);
    };
    f.close();
    std.debug.print("NOT BLOCKED: opened a file after seccomp\n", .{});
    std.process.exit(1);
}
const PluginManager = @import("core/plugin_manager.zig").PluginManager;
const WasmRuntime = @import("core/wasm_runtime.zig").WasmRuntime;

const PluginLink = struct {
    allocator: std.mem.Allocator,
    stream: std.net.Stream,
    /// 書き込みは作業スレッドだけ (プラグインの実行・問い合わせ・通知・done) だが、念のため直列化する
    write_mutex: std.Thread.Mutex = .{},
    closed: bool = false,
    node_id: u32 = 0,

    // 読み書きは全て作業スレッド 1 本で行う (受信スレッドを置かない)。Core は done を受け取るまで次を送らず、
    // 問い合わせ (pub / sub / unsub) の間は ret しか送らないので、読む順番は決まっている。
    // スレッドの受け渡しが無いぶん、1 件あたりの往復が速い (ADR-010 2-4)

    fn sendJson(self: *PluginLink, value: anytype) void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        out.writer(self.allocator).print("{f}", .{std.json.fmt(value, .{})}) catch return;
        self.write_mutex.lock();
        defer self.write_mutex.unlock();
        ws.writeFrame(self.stream, .text, out.items, false) catch {};
    }

    /// 問い合わせを送り、Core の答え (ret) をその場で読む
    fn ask(self: *PluginLink, value: anytype) i32 {
        if (self.closed) return 1; // ERROR_UNKNOWN
        self.sendJson(value);
        while (true) {
            const f = ws.readMessage(self.stream, self.allocator, 2 << 20) catch {
                self.closed = true;
                return 1;
            };
            defer self.allocator.free(f.payload);
            if (f.opcode == .close) {
                self.closed = true;
                return 1;
            }
            if (f.opcode != .text) continue;
            const R = struct { op: []const u8 = "", code: i32 = 1 };
            const r = std.json.parseFromSlice(R, self.allocator, f.payload, .{ .ignore_unknown_fields = true }) catch continue;
            defer r.deinit();
            if (std.mem.eql(u8, r.value.op, "ret")) return r.value.code;
        }
    }

    fn fwdPublish(ctx: *anyopaque, topic: []const u8, payload: []const u8, qos: u32) i32 {
        const self: *PluginLink = @ptrCast(@alignCast(ctx));
        return self.ask(.{ .op = "pub", .t = topic, .p = payload, .qos = qos });
    }
    fn fwdSubscribe(ctx: *anyopaque, topic: []const u8) i32 {
        const self: *PluginLink = @ptrCast(@alignCast(ctx));
        return self.ask(.{ .op = "sub", .t = topic });
    }
    fn fwdUnsubscribe(ctx: *anyopaque, topic: []const u8) i32 {
        const self: *PluginLink = @ptrCast(@alignCast(ctx));
        return self.ask(.{ .op = "unsub", .t = topic });
    }

    /// 子の中で WasmSubscriber が出した障害・メトリクス・毒を、発行したその場で Core に知らせる (EventBus.sync_tap)
    fn tap(ctx: *anyopaque, topic: []const u8, payload: []const u8) void {
        const self: *PluginLink = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, topic, "core.node.metrics") or std.mem.eql(u8, topic, "core.node.fault") or std.mem.eql(u8, topic, "core.node.poison")) {
            self.sendJson(.{ .op = "tele", .t = topic, .p = payload });
        }
    }

    /// Core から次の指示 (msg / restore) を読む。Core が切れたら null
    fn nextWork(self: *PluginLink) ?[]u8 {
        while (!self.closed) {
            const f = ws.readMessage(self.stream, self.allocator, 2 << 20) catch {
                self.closed = true;
                return null;
            };
            if (f.opcode == .close) {
                self.allocator.free(f.payload);
                self.closed = true;
                return null;
            }
            if (f.opcode != .text) {
                self.allocator.free(f.payload);
                continue;
            }
            return f.payload;
        }
        return null;
    }
};

fn pluginMain(debug_allocator: std.mem.Allocator, args: []const [:0]u8) !void {
    // seccomp 下では DebugAllocator が使えない (確保ごとのスタックトレース取得が process_vm_readv を呼ぶ。
    // 他プロセスのメモリを読めるシステムコールなので許可しない)。子ではスタックトレースを取らないアロケータを使う
    _ = debug_allocator;
    const allocator = std.heap.smp_allocator;
    var socket_path: ?[]const u8 = null;
    var i: usize = 2;
    while (i + 1 < args.len) : (i += 2) {
        if (std.mem.eql(u8, args[i], "--socket")) socket_path = args[i + 1];
    }
    const path = socket_path orelse return error.SocketRequired;
    const token = std.process.getEnvVarOwned(allocator, "WEAVE_CELL_TOKEN") catch return error.TokenRequired;
    defer allocator.free(token);
    const sandbox_on = !std.process.hasEnvVarConstant("WEAVE_CELL_NO_SANDBOX");

    // 段階 3: スレッドを作る前に user + network 名前空間へ (外へ出るネットワークを持たない)。
    // Core との UNIX ソケットはファイルシステムのパスでつなぐので、この後でも接続できる
    if (sandbox_on) sandbox.unshareNetwork() catch |err| log.warn("weave-cell: could not enter a network namespace ({any}); continuing without it", .{err});

    const stream = try std.net.connectUnixSocket(path);
    defer stream.close();
    var link = PluginLink{ .allocator = allocator, .stream = stream };
    link.sendJson(.{ .hello = "plugin", .token = token });

    // 読み込み: {"op":"load","node_id":N} + manifest + wasm (検証済みのバイト列。ディスクは読まない)
    const load = try ws.readMessage(stream, allocator, 4096);
    defer allocator.free(load.payload);
    const L = struct { op: []const u8, node_id: u32 };
    const l = try std.json.parseFromSlice(L, allocator, load.payload, .{ .ignore_unknown_fields = true });
    defer l.deinit();
    const manifest_frame = try ws.readMessage(stream, allocator, 1 << 20);
    defer allocator.free(manifest_frame.payload);
    const wasm_frame = try ws.readMessage(stream, allocator, 16 << 20);
    const wasm_buf = wasm_frame.payload; // PluginManager が所有する
    link.node_id = l.value.node_id;

    var bus = try event_bus.EventBus.init(allocator, 1024);
    defer bus.deinit();
    bus.verbose = false;
    var runtime = try WasmRuntime.init();
    defer runtime.deinit();
    var pm = PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    host_api.forwarder = .{ .ctx = &link, .publish = PluginLink.fwdPublish, .subscribe = PluginLink.fwdSubscribe, .unsubscribe = PluginLink.fwdUnsubscribe };
    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    bus.sync_tap = .{ .ctx = &link, .f = PluginLink.tap };
    try bus.start();
    defer bus.stop();

    // 今の部品でロードする (R2〜R5 / breaker は子の中でそのまま働く)
    const M = @import("core/manifest.zig").Manifest;
    const pre = try M.parse(allocator, manifest_frame.payload);
    const limits = pre.value.limits;
    const cell_name = try std.fmt.allocPrint(allocator, "plugin.{s}", .{pre.value.name});
    defer allocator.free(cell_name);
    pre.deinit();
    const module = try runtime.loadModule(wasm_buf);
    const inst = try runtime.instantiateLimited(module, pm.wasm_stack_size, pm.wasm_heap_size, limits.memory_pages);
    pm.next_node_id = link.node_id; // Core と同じノード ID を使う (障害通知の node_id が一致する)
    const meta = try pm.registerPluginWithManifest(module, inst, "cell.wasm", "cell.json", manifest_frame.payload, wasm_buf, &bus);
    meta.subscriber.?.cell = try bus.createCell(cell_name, .{ .trust = .untrusted });
    pm.initPlugin(meta); // on_init の subscribe は Core に問い合わせる
    // manifest の購読は Core が自分のバスで張っているので、子の中では配送先としてだけ張る
    for (meta.manifest_parsed.value.permissions.subscribe) |pat| {
        try bus.subscribeEx(pat, meta.node_id, @import("core/wasm_subscriber.zig").WasmSubscriber.callback, &meta.subscriber.?, .{ .cell = meta.subscriber.?.cell });
    }
    // 段階 3: 読み込み・スレッド作成・購読が終わったので、必要なシステムコールだけに絞る。
    // 以後 open / socket / execve などを呼ぶとこのプロセスは SIGSYS で終わり、Core はそれを障害として扱う
    if (sandbox_on) {
        if (sandbox.applySeccomp()) |_| {
            log.info("weave-cell: '{s}' sandboxed (seccomp allowlist{s})", .{ meta.manifest_parsed.value.name, "" });
        } else |err| log.warn("weave-cell: seccomp not applied ({any})", .{err});
    }
    link.sendJson(.{ .op = "ready" });

    // Core から 1 件ずつ受け取り、子の中のバスに流し、処理し終えたら done を返す。
    // コミット済みの状態 (R5) が変わっていれば done に載せて Core に預ける (プロセスごと落ちても続きから)
    var last_state: std.ArrayListUnmanaged(u8) = .{};
    defer last_state.deinit(allocator);
    const plugin_name = meta.manifest_parsed.value.name;
    while (link.nextWork()) |w| {
        defer allocator.free(w);
        const Msg = struct { op: []const u8, id: u64 = 0, t: []const u8 = "", p: []const u8 = "", ts: i64 = 0, qos: u8 = 0, state: []const u8 = "" };
        const m = std.json.parseFromSlice(Msg, allocator, w, .{ .ignore_unknown_fields = true }) catch continue;
        defer m.deinit();
        if (std.mem.eql(u8, m.value.op, "restore")) {
            if (m.value.state.len % 2 == 0) {
                const bytes = try allocator.alloc(u8, m.value.state.len / 2);
                defer allocator.free(bytes);
                if (std.fmt.hexToBytes(bytes, m.value.state)) |_| {
                    if (pm.restoreCommittedState(plugin_name, bytes)) {
                        last_state.clearRetainingCapacity();
                        try last_state.appendSlice(allocator, bytes);
                        log.info("weave-cell: restored the committed state of '{s}' from Core", .{plugin_name});
                    }
                } else |_| {}
            }
            link.sendJson(.{ .op = "restored" });
            continue;
        }
        if (!std.mem.eql(u8, m.value.op, "msg")) continue;
        const qos: event_bus.QoS = if (m.value.qos <= 2) @enumFromInt(m.value.qos) else .BestEffort;
        // 子の中のバスを経由せず、この作業スレッドから WasmSubscriber に直接渡す (スレッドの受け渡しを 2 回減らす)。
        // R2〜R5 / breaker は WasmSubscriber の中にあるので同じように働く。障害通知・メトリクスは
        // 発行したその場で Core に送られる (sync_tap) ので、待つものは無い
        const ev = event_bus.EventMessage{ .id = m.value.id, .topic = m.value.t, .timestamp = m.value.ts, .source_node_id = 0, .qos = qos, .payload = m.value.p };
        @import("core/wasm_subscriber.zig").WasmSubscriber.callback(&meta.subscriber.?, &ev);
        const changed: ?[]u8 = blk: {
            const sub = &meta.subscriber.?;
            sub.mutex.lock();
            defer sub.mutex.unlock();
            const st = sub.committedState() orelse break :blk null;
            if (std.mem.eql(u8, st, last_state.items)) break :blk null;
            last_state.clearRetainingCapacity();
            last_state.appendSlice(allocator, st) catch break :blk null;
            break :blk std.fmt.allocPrint(allocator, "{x}", .{st}) catch null;
        };
        if (changed) |hex| {
            defer allocator.free(hex);
            link.sendJson(.{ .op = "done", .state = hex });
        } else link.sendJson(.{ .op = "done" });
    }
    std.posix.shutdown(stream.handle, .both) catch {};
}
