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
const Replayer = @import("builtin/replay.zig").Replayer;
const CellLink = @import("core/cell_link.zig").CellLink;
const DashboardNode = @import("builtin/dashboard.zig").DashboardNode;
const HealthMonitor = @import("core/health.zig").HealthMonitor;
const StreamElementsAdapter = @import("builtin/streamelements.zig").StreamElementsAdapter;
const streamlabs = @import("builtin/streamlabs.zig");

const Config = @import("common/config.zig").Config;
const Snapshot = @import("core/snapshot.zig").Snapshot;
const ObsGate = @import("builtin/obs_gate.zig").ObsGate;

fn runTwitch(t: *TwitchAdapter) void {
    t.run() catch |err| {
        log.err("TwitchAdapter Error: {any}", .{err});
    };
}

fn runReplay(r: *Replayer) void {
    r.run() catch |err| log.err("Replay: {any}", .{err});
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
/// 記録の再生中は、時刻 (tick) も記録から流すので実時間の tick を止める
var replay_active = std.atomic.Value(bool).init(false);

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

        if (replay_active.load(.acquire)) continue;
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
    if (r.desired + r.retained + r.plugin_states > 0) {
        log.info("Snapshot: restored {d} OBS desired state(s), {d} retained event(s) and {d} plugin state(s) (saved {d} ms ago)", .{ r.desired, r.retained, r.plugin_states, r.age_ms });
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
    // 待ち受けるポートが空いているかを、スレッドを作る前に確かめる。使用中 (別の WEAVE など) なら分かりやすく止める
    // (待ち受けは SO_REUSEPORT を付けないので、同じポートを別のプロセスと黙って分け合うことはない)
    for ([_]struct { name: []const u8, port: u16, flag: []const u8 }{
        .{ .name = "Dashboard / Inspector", .port = config.dashboard_port, .flag = "--dash-port" },
        .{ .name = "remote nodes", .port = config.node_ws_port, .flag = "--node-port" },
    }) |p| {
        const addr = std.net.Address.parseIp(config.bind, p.port) catch continue;
        var probe = @import("transport/ws_proto.zig").listenExclusive(addr) catch |err| {
            log.err("Port {d} ({s}) on {s} is not available: {any}. Is another WEAVE running? Choose another with {s}.", .{ p.port, p.name, config.bind, err, p.flag });
            std.process.exit(2);
        };
        probe.deinit();
    }

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
    for (config.cell_budgets.items) |cb| {
        core.setCellBudget(cb.name, cb.eps) catch {
            log.err("Config: cell budget '{s}' must be named plugin.* or plugins.*", .{cb.name});
            std.process.exit(2);
        };
        log.info("Cell budget: '{s}' = {d:.0} eps (shared by its plugins)", .{ cb.name, cb.eps });
    }
    // 毒メッセージの記録先 (R2): <state_dir>/dlq/<node_id>.jsonl
    var dlq_buf: [512]u8 = undefined;
    core.pm.dlq_dir = std.fmt.bufPrint(&dlq_buf, "{s}/dlq", .{config.state_dir}) catch null;

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

    // 利用者による承認 (トラストアンカー Stage 0)。不明なモードで黙って off にしない
    core.configureApproval(config.approval_mode, config.approvals_path) catch {
        log.err("Approval: refusing to start with an unknown --approval-mode '{s}' (off|warn|strict)", .{config.approval_mode});
        std.process.exit(2);
    };

    // 観測レベル (off / metadata / contents)。metadata では ext.* の payload (PII を含みうる) を隠す
    core.bus.publish("core.system.introspection", config.introspection, .BestEffort, 0) catch {};

    // 2. トランスポートの設定。LogTransport は全イベントを標準出力に流すので debug 時だけ
    var log_transport = LogTransport.init("DebugLogger");
    if (config.log_level == .debug) try core.tm.register(log_transport.asTransport());

    // トークン: 未設定なら起動時に生成して一度だけ表示する
    var owned_tokens: [3]?[]u8 = .{ null, null, null };
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

    // 観測専用 (/status)。これで繋いだ端末には稼働状態 (core.health.*) しか届かない
    const observer_token = if (config.observer_token) |t| t else blk: {
        const hex = try randomToken(allocator);
        owned_tokens[2] = hex;
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
        .observer_token = observer_token,
    });
    try dashboard.start();
    std.debug.print("\x1b[36;1m[INSPECTOR]\x1b[0m http://{s}:{d}/?token={s}\n", .{ if (std.mem.eql(u8, config.bind, "0.0.0.0")) "localhost" else config.bind, config.dashboard_port, dash_token });
    std.debug.print("\x1b[36;1m[STATUS]\x1b[0m    http://{s}:{d}/status?token={s}  (観測専用: 稼働状態だけ。スマホから見るには --bind 0.0.0.0 と PC の IP で)\n", .{ if (std.mem.eql(u8, config.bind, "0.0.0.0")) "localhost" else config.bind, config.dashboard_port, observer_token });

    // 4b. OBS への送信ノード。プラグインより先にバスにつなぐ (attach)。
    //     プラグインが起動時 (on_init) に出す OBS への指示 (サブ目標やスコアの初期表示など) を
    //     「意図した状態」として受け取り、接続後に送るため。以前はプラグインの後に作っていて、
    //     起動時の指示は購読者がいないまま捨てられていた
    var maybe_obs: ?*ObsEgressNode = null;
    var maybe_mock_obs: ?*MockObsEgressNode = null;
    var maybe_link: ?*CellLink = null;
    var cell_argv: std.ArrayListUnmanaged([]const u8) = .{};
    defer cell_argv.deinit(allocator);
    var exe_dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    var sock_buf: [std.fs.max_path_bytes]u8 = undefined;
    var port_buf: [8]u8 = undefined;
    if (config.isolate_egress) {
        // egress セルを別プロセスで動かす (ADR-010)。強制と意図した状態は Core に残す
        const exe_dir = try std.fs.selfExeDirPath(&exe_dir_buf);
        const cell_exe = try std.fs.path.join(allocator, &.{ exe_dir, "weave-cell" });
        defer allocator.free(cell_exe);
        const sock = try std.fmt.bufPrint(&sock_buf, "{s}/egress.sock", .{config.state_dir});
        try cell_argv.appendSlice(allocator, &.{ try allocator.dupe(u8, cell_exe), "egress", "--socket", sock });
        if (config.mock_obs) {
            // 出力ファイルは Core の起動時に 1 回だけ空にする (子の再起動では消さない)
            std.fs.cwd().deleteFile(config.mock_obs_filepath) catch {};
            (try std.fs.cwd().createFile(config.mock_obs_filepath, .{})).close();
            try cell_argv.appendSlice(allocator, &.{ "--mock-obs-file", config.mock_obs_filepath });
        } else {
            try cell_argv.appendSlice(allocator, &.{ "--obs-host", config.obs_host, "--obs-port", try std.fmt.bufPrint(&port_buf, "{d}", .{config.obs_port}) });
        }
        maybe_link = try CellLink.create(allocator, &core.bus, 2, sock, cell_argv.items, config.obs_password);
        try maybe_link.?.attach();
    } else if (config.mock_obs) {
        maybe_mock_obs = try MockObsEgressNode.init(allocator, &core.bus, 2, config.obs_password, config.mock_obs_filepath);
        try maybe_mock_obs.?.attach();
    } else {
        maybe_obs = try ObsEgressNode.init(allocator, &core.bus, 2, config.obs_password);
        try maybe_obs.?.attach();
    }
    defer {
        if (maybe_mock_obs) |o| o.deinit();
        if (maybe_obs) |o| o.deinit();
        if (maybe_link) |l| {
            l.destroy();
            allocator.free(cell_argv.items[0]);
        }
    }

    // 5. Wasmプラグイン
    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);

    var plugin_exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const plugin_cell_exe: ?[]const u8 = if (config.isolate_plugins or config.isolate_plugin_names.items.len > 0) blk: {
        const d = try std.fs.selfExeDirPath(&plugin_exe_buf);
        break :blk try std.fs.path.join(allocator, &.{ d, "weave-cell" });
    } else null;
    defer if (plugin_cell_exe) |p| allocator.free(p);
    // 承認が無い・権限が増えたために読み込まなかったプラグイン (稼働状態に「承認待ち」と出す)
    var approval_blocked = std.ArrayListUnmanaged([]const u8){};
    defer approval_blocked.deinit(allocator);
    for (config.plugins.items) |path| {
        const stem = std.fs.path.stem(path);
        const isolate_this = config.isolate_plugins or for (config.isolate_plugin_names.items) |n| {
            if (std.mem.eql(u8, n, stem)) break true;
        } else false;
        if (plugin_cell_exe != null and isolate_this) {
            const exe = plugin_cell_exe.?;
            core.loadPluginIsolated(path, exe, config.state_dir) catch |err| {
                log.err("Failed to load plugin '{s}' in its own process: {any}", .{ path, err });
                if (err == error.ApprovalRequired) approval_blocked.append(allocator, path) catch {};
            };
            continue;
        }
        core.loadPlugin(path) catch |err| {
            log.err("Failed to load plugin '{s}': {any}", .{ path, err });
            if (err == error.ApprovalRequired) approval_blocked.append(allocator, path) catch {};
        };
    }

    // 3. ネイティブノード (Twitch)
    // --no-twitch 指定時は Twitch 系スレッドを一切起動しない
    // (Dashboard の「草ラッシュ」ボタン等、外部からの pub のみで発火させたい時に使う)
    var maybe_twitch: ?TwitchAdapter = null;
    var maybe_mock_twitch: ?MockTwitchAdapter = null;
    var twitch_thread: ?std.Thread = null;
    var maybe_replay: ?Replayer = null;
    var replay_thread: ?std.Thread = null;

    if (config.replay_path) |rp| {
        // 記録の再生が入力源になる (実 Twitch には繋がない)
        try core.graph.registerNode(1, "TwitchAdapter", .native);
        try core.bus.publish("core.node.registered", "{\"node_id\":1,\"name\":\"TwitchAdapter\",\"type\":\"native\"}", .Transient, 0);
        maybe_replay = .{ .allocator = allocator, .bus = &core.bus, .path = rp };
        replay_active.store(true, .release);
        replay_thread = try std.Thread.spawn(.{}, runReplay, .{&maybe_replay.?});
        log.info("Replay: {s}", .{rp});
    } else if (!config.no_twitch) {
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

    // OBS への送信ノードはプラグインより先に attach 済み。スナップショットの復元はプラグインの状態を
    // 戻すのでここ (プラグインの後) で行い、OBS への接続もここで始める
    var snapshot: ?Snapshot = null;
    var snap_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const snapshot_path = try std.fmt.bufPrint(&snap_path_buf, "{s}/snapshot.json", .{config.state_dir});
    if (maybe_link) |l| {
        try l.start();
        snapshot = Snapshot.init(allocator, snapshot_path, &core.bus, &l.desired);
        snapshot.?.pm = &core.pm;
        snapshot.?.isolated = &core.isolated;
        // 要求としてバスに流し直す → CellLink が記録し、子に (接続後に) 送る
        if (config.snapshot and config.restore_snapshot) restoreSnapshot(&snapshot.?, true);
    } else if (maybe_mock_obs) |o| {
        try o.connect(config.obs_host, config.obs_port);
        snapshot = Snapshot.init(allocator, snapshot_path, &core.bus, &o.desired);
        snapshot.?.pm = &core.pm;
        snapshot.?.isolated = &core.isolated;
        if (config.snapshot and config.restore_snapshot) restoreSnapshot(&snapshot.?, true);
    } else if (maybe_obs) |o| {
        // 意図した状態を接続前に戻しておく → 接続 (Identified) 時に OBS へ再適用される
        snapshot = Snapshot.init(allocator, snapshot_path, &core.bus, &o.desired);
        snapshot.?.pm = &core.pm;
        snapshot.?.isolated = &core.isolated;
        if (config.snapshot and config.restore_snapshot) restoreSnapshot(&snapshot.?, false);
        o.connect(config.obs_host, config.obs_port) catch |err| {
            log.warn("Main: OBS connect failed (optional): {any}", .{err});
        };
    }

    if (config.snapshot) {
        if (snapshot) |*sn| sn.start() catch |err| log.warn("Snapshot: failed to start: {any}", .{err});
    }

    // 既存ツールのラッパー (ObsGate)。.weave/wrap/*.json があるときだけ OBS のふりをして待ち受ける
    var maybe_gate: ?*ObsGate = null;
    if (!config.no_gate) {
        maybe_gate = ObsGate.init(allocator, &core.bus, .{
            .bind = config.bind,
            .port = config.gate_port,
            .upstream_host = config.obs_host,
            .upstream_port = config.obs_port,
            .upstream_password = config.obs_password,
            .wrap_dir = config.wrap_dir,
        }) catch |err| blk: {
            log.warn("ObsGate: cannot load {s}: {any}", .{ config.wrap_dir, err });
            break :blk null;
        };
        if (maybe_gate) |g| g.start() catch |err| {
            log.err("ObsGate: cannot listen on port {d}: {any}. Choose another with --gate-port", .{ config.gate_port, err });
            g.deinit();
            maybe_gate = null;
        };
    }
    defer if (maybe_gate) |g| g.deinit();

    // 稼働状態の監視 (core.health.summary)。本来いるはずのノード = 起動時に指定したプラグイン + --expect
    const health = try HealthMonitor.create(allocator, &core.bus, &core.graph);
    {
        try health.addBuiltins();
        var cells = std.ArrayListUnmanaged([]const u8){};
        defer cells.deinit(allocator);
        for (config.cell_budgets.items) |cb| try cells.append(allocator, cb.name);
        var mbuf: [std.fs.max_path_bytes]u8 = undefined;
        for (config.plugins.items) |path| {
            const mpath = if (std.mem.endsWith(u8, path, ".wasm")) std.fmt.bufPrint(&mbuf, "{s}.json", .{path[0 .. path.len - 5]}) catch continue else continue;
            const blocked = for (approval_blocked.items) |b| {
                if (std.mem.eql(u8, b, path)) break true;
            } else false;
            (if (blocked) health.addBlockedManifest(mpath, cells.items, "approval_required") else health.addManifest(mpath, cells.items)) catch |err|
                log.warn("Health: cannot read manifest '{s}': {any}", .{ mpath, err });
        }
        for (config.expect.items) |mpath| {
            health.addManifest(mpath, cells.items) catch |err| log.warn("Health: cannot read --expect manifest '{s}': {any}", .{ mpath, err });
        }
        for (try health.runLint()) |l| {
            log.warn("Lint: '{s}' subscribes to '{s}', which no node publishes. Did you mean '{s}' (published by {s})?", .{ l.node, l.topic, l.suggestion, l.suggestion_from });
        }
        try health.start();
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
    if (maybe_link) |l| l.stop();
    core.stopIsolated();
    if (maybe_mock_twitch) |*t| t.stop();
    if (maybe_replay) |*r| r.stop();
    if (maybe_twitch) |*t| t.stop();
    if (maybe_se) |se| se.stop();
    if (maybe_sl) |sl| sl.stop();
    if (maybe_gate) |g| g.stop();
    node_ws.stop();
    core.bus.stop();

    // 7. 各スレッドの終了を待機・リソース解放
    dashboard.deinit();

    if (twitch_thread) |t| t.join();
    if (replay_thread) |t| t.join();
    node_ws_thread.join();
    graph_thread.join();
    ticker_thread.join();
    dispatcher_thread.join();
    health.destroy();

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
    _ = @import("security/approval.zig");
    _ = @import("common/config.zig");
    _ = @import("tests/oom_test.zig");
    _ = @import("tests/mock_test.zig");
    _ = @import("tests/kusa_test.zig");
    _ = @import("tests/cascade_test.zig");
    _ = @import("core/pattern.zig");
    _ = @import("core/topics.zig");
    _ = @import("transport/ws_proto.zig");
    _ = @import("tests/fuzz_test.zig");
    _ = @import("builtin/replay.zig");
    _ = @import("core/cell_link.zig");
    _ = @import("tests/audit_match_test.zig");
    _ = @import("transport/node_ws.zig");
    _ = @import("builtin/dashboard.zig");
    _ = @import("core/health.zig");
    _ = @import("builtin/obs.zig");
    _ = @import("builtin/obs_gate.zig");
    _ = @import("builtin/streamelements.zig");
    _ = @import("builtin/streamlabs.zig");
    _ = @import("core/snapshot.zig");
}
