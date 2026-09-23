const std = @import("std");
const log = @import("common/log.zig");
const wamr = @import("core/wamr_libs.zig").wamr;
const host_api = @import("api/host_api.zig");
const TwitchAdapter = @import("builtin/twitch.zig").TwitchAdapter;
const Core = @import("core/core.zig").Core;
const LogTransport = @import("transport/log_transport.zig").LogTransport;
const NodeWsTransport = @import("transport/node_ws.zig").NodeWsTransport;
const ObsEgressNode = @import("builtin/obs.zig").ObsEgressNode;
const MockObsEgressNode = @import("builtin/mock_obs.zig").MockObsEgressNode;
const MockTwitchAdapter = @import("builtin/mock_twitch.zig").MockTwitchAdapter;
const DashboardNode = @import("builtin/dashboard.zig").DashboardNode;
const StreamElementsAdapter = @import("builtin/streamelements.zig").StreamElementsAdapter;
const streamlabs = @import("builtin/streamlabs.zig");

const Config = @import("common/config.zig").Config;
const Snapshot = @import("core/snapshot.zig").Snapshot;

fn runTwitch(t: *TwitchAdapter) void {
    t.run() catch |err| {
        log.err("TwitchAdapter Error: {any}", .{err});
    };
}

fn runMockTwitch(t: *MockTwitchAdapter) void {
    t.run() catch |err| {
        log.err("MockTwitchAdapter Error: {any}", .{err});
    };
}

fn runNodeWs(n: *NodeWsTransport) void {
    n.run() catch |err| {
        log.err("NodeWsTransport Error: {any}", .{err});
    };
}

var run_mutex = std.Thread.Mutex{};
var run_cond = std.Thread.Condition{};
var running = std.atomic.Value(bool).init(true);

/// 500ms 間隔で core.system.tick を publish する。
/// Wasm プラグイン等が"時間の経過"を検知するために使う (例: kusa_node の auto-hide)。
fn runTicker(core: *Core) void {
    const interval_ns: u64 = 500 * std.time.ns_per_ms;
    while (running.load(.acquire)) {
        run_mutex.lock();
        if (!running.load(.acquire)) {
            run_mutex.unlock();
            break;
        }
        run_cond.timedWait(&run_mutex, interval_ns) catch |err| {
            if (err != error.Timeout) {
                log.err("Ticker timedWait Error: {any}", .{err});
            }
        };
        run_mutex.unlock();
        if (!running.load(.acquire)) break;

        core.bus.publish("core.system.tick", "{}", .BestEffort, 0) catch |err| {
            log.err("Ticker publish error: {any}", .{err});
        };
    }
}

fn runGraphPublisher(core: *Core, config: *const Config) void {
    const interval_ns = @as(u64, config.graph_full_interval_secs) * std.time.ns_per_s;

    while (running.load(.acquire)) {
        const json = core.graph.toJsonAlloc(core.allocator) catch |err| {
            log.err("GraphPublisher Error (JSON): {any}", .{err});
            continue;
        };
        defer core.allocator.free(json);

        core.bus.publish("core.system.graph.full", json, .Transient, 0) catch |err| {
            log.err("GraphPublisher Error (Publish): {any}", .{err});
        };

        run_mutex.lock();
        if (!running.load(.acquire)) {
            run_mutex.unlock();
            break;
        }
        run_cond.timedWait(&run_mutex, interval_ns) catch |err| {
            if (err != error.Timeout) {
                log.err("GraphPublisher timedWait Error: {any}", .{err});
            }
        };
        run_mutex.unlock();
    }
}

fn sigHandler(sig: i32) callconv(.c) void {
    _ = sig;
    // 標準エラー出力に直接書く（シグナルハンドラ内での安全性を考慮。write は非同期シグナル安全）
    _ = std.fs.File.stderr().write("\nStatus: Shutdown signal received. Graceful exiting...\n") catch {};

    running.store(false, .release);
}

fn restoreSnapshot(sn: *Snapshot, republish: bool) void {
    const r = sn.restore(republish) catch |err| {
        log.warn("Snapshot: restore failed: {any}", .{err});
        return;
    };
    if (r.desired + r.retained > 0) {
        log.info("Snapshot: restored {d} OBS desired state(s) and {d} retained event(s) (saved {d} ms ago)", .{ r.desired, r.retained, r.age_ms });
    }
}

fn randomToken(allocator: std.mem.Allocator) ![]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    return std.fmt.allocPrint(allocator, "{x}", .{&random_bytes});
}

// ----------------------------------------------------------------------
// Supervisor (R7): Core を子プロセスとして起動し、異常終了したら即座に再起動する。
// 「落ちない」ではなく「落ちても 1 秒未満で戻る」を可用性の主張にする (ADR-006 §5)。
// ----------------------------------------------------------------------

var sup_child_pid = std.atomic.Value(i32).init(0);
var sup_stop = std.atomic.Value(bool).init(false);

fn supSignal(sig: i32) callconv(.c) void {
    sup_stop.store(true, .release);
    const pid = sup_child_pid.load(.acquire);
    if (pid > 0) _ = std.os.linux.kill(pid, @intCast(sig));
}

fn runSupervisor(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var child_args: std.ArrayListUnmanaged([]const u8) = .{};
    defer child_args.deinit(allocator);
    for (args) |a| {
        if (!std.mem.eql(u8, a, "--supervise")) try child_args.append(allocator, a);
    }

    // トークンは 1 回だけ生成し、再起動後の Core にも同じものを渡す (Inspector が同じ URL で再接続できる)
    var env = try std.process.getEnvMap(allocator);
    defer env.deinit();
    if (env.get("WEAVE_DASHBOARD_TOKEN") == null) {
        const t = try randomToken(allocator);
        defer allocator.free(t);
        try env.put("WEAVE_DASHBOARD_TOKEN", t);
    }
    if (env.get("WEAVE_NODE_WS_TOKEN") == null) {
        const t = try randomToken(allocator);
        defer allocator.free(t);
        try env.put("WEAVE_NODE_WS_TOKEN", t);
    }
    try env.put("WEAVE_SUPERVISED", "1");

    const act = std.os.linux.Sigaction{ .handler = .{ .handler = supSignal }, .mask = std.mem.zeroes(std.os.linux.sigset_t), .flags = 0 };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &act, null);

    var crash_times: [5]i64 = [_]i64{0} ** 5;
    var crash_pos: usize = 0;
    var restarts: u32 = 0;
    while (!sup_stop.load(.acquire)) {
        // 何回目の起動か。0 = 初回 (状態を復元しない)、1 以上 = クラッシュからの再起動 (スナップショットから復元)
        var rc_buf: [16]u8 = undefined;
        try env.put("WEAVE_RESTART_COUNT", try std.fmt.bufPrint(&rc_buf, "{d}", .{restarts}));
        var child = std.process.Child.init(child_args.items, allocator);
        child.env_map = &env;
        try child.spawn();
        sup_child_pid.store(child.id, .release);
        const term = child.wait() catch |err| {
            std.debug.print("\x1b[35;1m[SUPERVISOR]\x1b[0m wait failed: {any}\n", .{err});
            return err;
        };
        sup_child_pid.store(0, .release);
        if (sup_stop.load(.acquire)) break;
        switch (term) {
            .Exited => |code| if (code == 0) break,
            else => {},
        }
        const now = std.time.milliTimestamp();
        crash_times[crash_pos] = now;
        crash_pos = (crash_pos + 1) % crash_times.len;
        const oldest = crash_times[crash_pos];
        if (oldest != 0 and now - oldest < 30_000) {
            std.debug.print("\x1b[35;1m[SUPERVISOR]\x1b[0m core crashed 5 times within 30s; giving up\n", .{});
            std.process.exit(1);
        }
        restarts += 1;
        std.debug.print("\x1b[35;1m[SUPERVISOR]\x1b[0m core exited ({any}); restarting now (restart #{d})\n", .{ term, restarts });
    }
}

pub fn main() !void {
    const t_start = std.time.milliTimestamp();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // シグナルハンドラの設定
    const act = std.os.linux.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.mem.zeroes(std.os.linux.sigset_t),
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &act, null);

    {
        const argv = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, argv);
        for (argv[1..]) |a| {
            if (std.mem.eql(u8, a, "--supervise")) return runSupervisor(allocator, argv);
        }
    }

    var config = try Config.parse(allocator);
    defer config.deinit(allocator);

    // ログレベルの設定を反映
    log.current_level = config.log_level;

    log.info("========================================", .{});
    log.info("   WEAVE: Streaming Event OS Core Daemon", .{});
    log.info("========================================", .{});
    log.info("Config: Dashboard: http://{s}:{d}  (bind {s})", .{ config.bind, config.dashboard_port, config.bind });
    log.info("Config: Node WS: ws://localhost:{d}", .{config.node_ws_port});
    log.info("Config: Twitch: {s}, OBS: {s}:{d}", .{ config.twitch_channel, config.obs_host, config.obs_port });
    log.info("Config: Log Level: {s}", .{@tagName(config.log_level)});
    log.info("----------------------------------------", .{});

    // 1. Coreの初期化
    var core = try Core.init(allocator);
    defer core.deinit();

    core.bus.graph = &core.graph;
    core.graph.bus = &core.bus;

    // 監査ログ: core.security.* をファイルに記録 (ACL違反/レート制限/署名不正の証跡)
    var audit = @import("core/audit_log.zig").AuditLog.init(allocator, config.audit_log_path);
    audit.subscribeBus(&core.bus) catch |err| log.warn("AuditLog: subscribe failed: {any}", .{err});
    log.info("Audit: security events -> {s}", .{config.audit_log_path});

    host_api.global_bus = &core.bus;
    host_api.global_plugin_manager = &core.pm;
    core.pm.runtime = &core.runtime;
    core.pm.wasm_stack_size = config.wasm_stack_size;
    core.pm.wasm_heap_size = config.wasm_heap_size;

    // 署名検証 (トラストアンカー Stage 1) の設定
    // 設定の誤りで検証が黙って off になる (fail-open) ことを避ける:
    //   不明なモード → 起動しない / strict で信頼鍵が読めない → 起動しない / warn → 警告して続行
    core.configureSignature(config.signature_mode, config.trust_keys_path) catch |err| {
        if (err == error.InvalidSignatureMode) {
            log.err("Signature: refusing to start with an unknown --signature-mode '{s}' (off|warn|strict)", .{config.signature_mode});
            std.process.exit(2);
        }
        if (core.signature_mode == .strict) {
            log.err("Signature: strict mode but the trust store '{s}' could not be loaded: {any}", .{ config.trust_keys_path, err });
            std.process.exit(2);
        }
        log.warn("Signature: failed to load trust store: {any}", .{err});
    };

    // 観測レベル (off / metadata / contents)。metadata では ext.* の payload (PII を含みうる) を隠す
    core.bus.publish("core.system.introspection", config.introspection, .BestEffort, 0) catch {};

    // 2. トランスポートの設定。LogTransport は全イベントを標準出力に流すので debug 時だけ
    var log_transport = LogTransport.init("DebugLogger");
    if (config.log_level == .debug) try core.tm.register(log_transport.asTransport());

    // トークン: 未設定なら起動時に生成して一度だけ表示する
    var owned_tokens: [2]?[]u8 = .{ null, null };
    defer for (owned_tokens) |t| if (t) |x| allocator.free(x);
    const node_token = if (config.node_ws_token) |t| t else blk: {
        const hex = try randomToken(allocator);
        owned_tokens[0] = hex;
        std.debug.print("\x1b[33;1m[SECURITY]\x1b[0m Node WS token (generated): \x1b[32;1m{s}\x1b[0m\n", .{hex});
        break :blk hex;
    };
    const dash_token = if (config.dashboard_token) |t| t else blk: {
        const hex = try randomToken(allocator);
        owned_tokens[1] = hex;
        break :blk hex;
    };

    var node_ws = try NodeWsTransport.init(allocator, &core.bus, .{ .bind = config.bind, .port = config.node_ws_port, .token = node_token });
    defer node_ws.deinit();

    try core.setupGateway();

    const dispatcher_thread = try std.Thread.spawn(.{}, @import("core/event_bus.zig").EventBus.runDispatcher, .{&core.bus});

    const node_ws_thread = try std.Thread.spawn(.{}, runNodeWs, .{node_ws});
    const graph_thread = try std.Thread.spawn(.{}, runGraphPublisher, .{ &core, &config });
    const ticker_thread = try std.Thread.spawn(.{}, runTicker, .{&core});

    // 4. Dashboard / Inspector (自前 HTTP + WebSocket)
    var dashboard = try DashboardNode.init(allocator, &core.bus, 10, .{
        .bind = config.bind,
        .port = config.dashboard_port,
        .dist_dir = config.dashboard_dist,
        .token = dash_token,
        .allow_loopback_without_token = config.weave_env == .development,
        .simulator = config.weave_env == .development,
    });
    try dashboard.start();
    std.debug.print("\x1b[36;1m[INSPECTOR]\x1b[0m http://{s}:{d}/?token={s}\n", .{ if (std.mem.eql(u8, config.bind, "0.0.0.0")) "localhost" else config.bind, config.dashboard_port, dash_token });

    // 5. Wasmプラグイン
    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);

    for (config.plugins.items) |path| {
        core.loadPlugin(path) catch |err| {
            log.err("Failed to load plugin '{s}': {any}", .{ path, err });
        };
    }

    // 3. ネイティブノード (Twitch)
    // --no-twitch 指定時は Twitch 系スレッドを一切起動しない
    // (Dashboard の「草ラッシュ」ボタン等、外部からの pub のみで発火させたい時に使う)
    var maybe_twitch: ?TwitchAdapter = null;
    var maybe_mock_twitch: ?MockTwitchAdapter = null;
    var twitch_thread: ?std.Thread = null;

    if (!config.no_twitch) {
        try core.graph.registerNode(1, "TwitchAdapter", .native);
        try core.bus.publish("core.node.registered", "{\"node_id\":1,\"name\":\"TwitchAdapter\",\"type\":\"native\"}", .Transient, 0);

        if (config.mock_twitch_scenario) |scenario_path| {
            maybe_mock_twitch = try MockTwitchAdapter.init(allocator, &core.bus, 1, scenario_path);
            maybe_mock_twitch.?.loop = !config.mock_twitch_once;
            twitch_thread = try std.Thread.spawn(.{}, runMockTwitch, .{&maybe_mock_twitch.?});
        } else {
            maybe_twitch = TwitchAdapter.init(allocator, &core.bus, 1, config.twitch_channel);
            twitch_thread = try std.Thread.spawn(.{}, runTwitch, .{&maybe_twitch.?});
        }
    } else {
        log.info("Status: --no-twitch enabled. Chat input is button/manual only.", .{});
    }
    defer {
        if (maybe_mock_twitch) |*t| t.deinit();
        if (maybe_twitch) |*t| t.deinit();
    }

    // 3b. StreamElements Astro (互換 A)。チャンネル ID と JWT が揃ったときだけ
    var maybe_se: ?*StreamElementsAdapter = null;
    if (config.streamelements_channel) |channel| {
        if (config.streamelements_jwt) |jwt| {
            maybe_se = try StreamElementsAdapter.init(allocator, &core.bus, .{
                .url = config.streamelements_url orelse "wss://astro.streamelements.com/",
                .token = jwt,
                .channel = channel,
            });
            try core.bus.publish("core.node.registered", "{\"node_id\":4,\"name\":\"StreamElements\",\"type\":\"native\"}", .Transient, 0);
            try maybe_se.?.start();
        } else {
            log.warn("StreamElements: --streamelements-channel is set but STREAMELEMENTS_JWT is empty; not connecting", .{});
        }
    }
    defer if (maybe_se) |se| se.deinit();

    // 3c. Streamlabs Socket API (互換 A)。--streamlabs とトークンが揃ったときだけ
    var maybe_sl: ?*streamlabs.StreamlabsAdapter = null;
    if (config.streamlabs) {
        if (config.streamlabs_token) |tok| {
            if (streamlabs.StreamlabsAdapter.init(allocator, &core.bus, .{
                .url = config.streamlabs_url orelse streamlabs.DEFAULT_URL,
                .token = tok,
            })) |sl| {
                maybe_sl = sl;
                try core.bus.publish("core.node.registered", "{\"node_id\":5,\"name\":\"Streamlabs\",\"type\":\"native\"}", .Transient, 0);
                try sl.start();
            } else |err| log.err("Streamlabs: not starting: {any}", .{err});
        } else {
            log.warn("Streamlabs: --streamlabs is set but STREAMLABS_SOCKET_TOKEN is empty; not connecting", .{});
        }
    }
    defer if (maybe_sl) |sl| sl.deinit();

    var snapshot: ?Snapshot = null;
    var snap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snapshot_path = try std.fmt.bufPrint(&snap_path_buf, "{s}/snapshot.json", .{config.state_dir});
    var maybe_obs: ?*ObsEgressNode = null;
    var maybe_mock_obs: ?*MockObsEgressNode = null;
    if (config.mock_obs) {
        maybe_mock_obs = try MockObsEgressNode.init(allocator, &core.bus, 2, config.obs_password, config.mock_obs_filepath);
        try maybe_mock_obs.?.connect(config.obs_host, config.obs_port);
        snapshot = Snapshot.init(allocator, snapshot_path, &core.bus, &maybe_mock_obs.?.desired);
        if (config.snapshot and config.restore_snapshot) restoreSnapshot(&snapshot.?, true);
    } else {
        maybe_obs = try ObsEgressNode.init(allocator, &core.bus, 2, config.obs_password);
        // 意図した状態を接続前に戻しておく → 接続 (Identified) 時に OBS へ再適用される
        snapshot = Snapshot.init(allocator, snapshot_path, &core.bus, &maybe_obs.?.desired);
        if (config.snapshot and config.restore_snapshot) restoreSnapshot(&snapshot.?, false);
        maybe_obs.?.connect(config.obs_host, config.obs_port) catch |err| {
            log.warn("Main: OBS connect failed (optional): {any}", .{err});
        };
    }
    defer {
        if (maybe_mock_obs) |o| o.deinit();
        if (maybe_obs) |o| o.deinit();
    }

    if (config.snapshot) {
        if (snapshot) |*sn| sn.start() catch |err| log.warn("Snapshot: failed to start: {any}", .{err});
    }

    log.info("Status: Ready in {} ms. Running... (Press Ctrl+C to stop)", .{std.time.milliTimestamp() - t_start});

    while (running.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info("\nStatus: Shutdown signal received. Cleaning up...", .{});

    // GraphPublisher を即時にウェイクアップ
    run_mutex.lock();
    run_cond.broadcast();
    run_mutex.unlock();

    // 6. シャットダウンシーケンス (一斉に停止合図を送る)
    if (snapshot) |*sn| sn.stop();
    dashboard.stop();
    if (maybe_mock_obs) |o| o.stop();
    if (maybe_obs) |o| o.stop();
    if (maybe_mock_twitch) |*t| t.stop();
    if (maybe_twitch) |*t| t.stop();
    if (maybe_se) |se| se.stop();
    if (maybe_sl) |sl| sl.stop();
    node_ws.stop();
    core.bus.stop();

    // 7. 各スレッドの終了を待機・リソース解放
    dashboard.deinit();

    if (twitch_thread) |t| t.join();
    node_ws_thread.join();
    graph_thread.join();
    ticker_thread.join();
    dispatcher_thread.join();

    log.info("Status: Shutdown complete.", .{});
}

test {
    _ = @import("core/event_bus.zig");
    _ = @import("core/graph.zig");
    _ = @import("core/manifest.zig");
    _ = @import("core/plugin_manager.zig");
    _ = @import("core/core.zig");
    _ = @import("core/rate_limiter.zig");
    _ = @import("core/audit_log.zig");
    _ = @import("security/signing.zig");
    _ = @import("common/config.zig");
    _ = @import("tests/oom_test.zig");
    _ = @import("tests/mock_test.zig");
    _ = @import("tests/kusa_test.zig");
    _ = @import("tests/cascade_test.zig");
    _ = @import("core/pattern.zig");
    _ = @import("core/topics.zig");
    _ = @import("transport/ws_proto.zig");
    _ = @import("transport/node_ws.zig");
    _ = @import("builtin/dashboard.zig");
    _ = @import("builtin/obs.zig");
    _ = @import("builtin/streamelements.zig");
    _ = @import("builtin/streamlabs.zig");
    _ = @import("core/snapshot.zig");
}
