const std = @import("std");
const log = @import("common/log.zig");
const wamr = @import("core/wamr_libs.zig").wamr;
const host_api = @import("api/host_api.zig");
const TwitchAdapter = @import("builtin/twitch.zig").TwitchAdapter;
const Core = @import("core/core.zig").Core;
const LogTransport = @import("transport/log_transport.zig").LogTransport;
const WsGateway = @import("transport/ws_gateway.zig").WsGateway;
const NodeWsTransport = @import("transport/node_ws.zig").NodeWsTransport;
const ObsEgressNode = @import("builtin/obs.zig").ObsEgressNode;
const DashboardNode = @import("builtin/dashboard.zig").DashboardNode;

const Config = @import("common/config.zig").Config;

fn runTwitch(t: *TwitchAdapter) void {
    t.run() catch |err| {
        log.err("TwitchAdapter Error: {any}", .{err});
    };
}

fn runWsGateway(w: *WsGateway) void {
    w.run() catch |err| {
        log.err("WsGateway Error: {any}", .{err});
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

fn runGraphPublisher(core: *Core, config: *const Config) void {
    const interval_ns = @as(u64, config.graph_full_interval_secs) * std.time.ns_per_s;

    while (running.load(.acquire)) {
        const json = core.graph.toJson(core.allocator) catch |err| {
            log.err("GraphPublisher Error (JSON): {any}", .{err});
            continue;
        };
        defer core.allocator.free(json);
        
        core.bus.publish("core.system.graph.full", json, .Transient, 0) catch |err| {
            log.err("GraphPublisher Error (Publish): {any}", .{err});
        };
        
        run_mutex.lock();
        defer run_mutex.unlock();
        
        run_cond.timedWait(&run_mutex, interval_ns) catch |err| {
            if (err == error.Timeout) {
                continue;
            }
            log.err("GraphPublisher timedWait Error: {any}", .{err});
        };
    }
}

fn sigHandler(sig: i32) callconv(.c) void {
    _ = sig;
    // 標準エラー出力に直接書く（シグナルハンドラ内での安全性を考慮）
    _ = std.fs.File.stderr().write("\nStatus: Shutdown signal received. Exiting immediately...\n") catch {};
    
    running.store(false, .release);
    
    run_mutex.lock();
    run_cond.broadcast();
    run_mutex.unlock();
    
    // zap (dashboard) の停止を試みる（ベストエフォート）
    if (DashboardNode.getInstance()) |dash| {
        dash.stop();
    }

    std.process.exit(0);
}

pub fn main() !void {
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

    var config = try Config.parse(allocator);
    defer config.deinit(allocator);

    // ログレベルの設定を反映
    log.current_level = config.log_level;

    log.info("========================================", .{});
    log.info("   WEAVE: Streaming Event OS Core Daemon", .{});
    log.info("========================================", .{});
    log.info("Config: Dashboard: http://localhost:{d}", .{config.dashboard_port});
    log.info("Config: WS Gateway: ws://localhost:{d}", .{config.ws_gateway_port});
    log.info("Config: Node WS: ws://localhost:{d}", .{config.node_ws_port});
    log.info("Config: Twitch: {s}, OBS: {s}:{d}", .{config.twitch_channel, config.obs_host, config.obs_port});
    log.info("Config: Log Level: {s}", .{@tagName(config.log_level)});
    log.info("----------------------------------------", .{});

    // 1. Coreの初期化
    var core = try Core.init(allocator);
    defer core.deinit();

    core.bus.graph = &core.graph;
    core.graph.bus = &core.bus;

    host_api.global_bus = &core.bus;
    host_api.global_plugin_manager = &core.pm;
    core.pm.runtime = &core.runtime;
    core.pm.wasm_stack_size = config.wasm_stack_size;
    core.pm.wasm_heap_size = config.wasm_heap_size;

    // 2. トランスポートの設定
    var log_transport = LogTransport.init("DebugLogger");
    try core.tm.register(log_transport.asTransport());

    var ws_gateway = try WsGateway.init(allocator, &core.bus, config.ws_gateway_port);
    defer ws_gateway.deinit();
    try core.tm.register(ws_gateway.transport());

    const token = config.node_ws_token orelse "weave-secret-2026";
    var node_ws = try NodeWsTransport.init(allocator, &core.bus, config.node_ws_port, token);
    defer node_ws.deinit();
    try core.tm.register(node_ws.transport());

    try core.setupGateway();

    const dispatcher_thread = try std.Thread.spawn(.{}, @import("core/event_bus.zig").EventBus.runDispatcher, .{&core.bus});
    
    const ws_thread = try std.Thread.spawn(.{}, runWsGateway, .{ws_gateway});
    const node_ws_thread = try std.Thread.spawn(.{}, runNodeWs, .{node_ws});
    const graph_thread = try std.Thread.spawn(.{}, runGraphPublisher, .{ &core, &config });

    // 3. ネイティブノード
    try core.graph.registerNode(1, "TwitchAdapter", .native);
    try core.bus.publish("core.node.registered", "{\"node_id\":1,\"name\":\"TwitchAdapter\",\"type\":\"native\"}", .Transient, 0);

    var twitch = TwitchAdapter.init(allocator, &core.bus, 1, config.twitch_channel);
    const twitch_thread = try std.Thread.spawn(.{}, runTwitch, .{&twitch});
    defer twitch.deinit();

    var obs = try ObsEgressNode.init(allocator, &core.bus, 2, config.obs_password);
    defer obs.deinit();
    obs.connect(config.obs_host, config.obs_port) catch |err| {
        log.warn("Main: OBS connect failed (optional): {any}", .{err});
    };

    // 4. Dashboard (zap)
    var dashboard = try DashboardNode.init(allocator, &core.bus, 100, config.dashboard_port);
    try dashboard.start();

    // 5. Wasmプラグイン
    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);

    for (config.plugins.items) |path| {
        core.loadPlugin(path) catch |err| {
            log.err("Failed to load plugin '{s}': {any}", .{path, err});
        };
    }

    log.info("Status: Running... (Press Ctrl+C to stop)", .{});
    
    while (running.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    log.info("\nStatus: Shutdown signal received. Cleaning up...", .{});

    // 6. シャットダウンシーケンス (一斉に停止合図を送る)
    dashboard.stop();
    obs.stop();
    twitch.stop();
    ws_gateway.stop();
    node_ws.stop();
    core.bus.stop();

    // 7. 各スレッドの終了を待機・リソース解放
    dashboard.deinit(); 
    obs.deinit();

    twitch_thread.join();
    ws_thread.join();
    node_ws_thread.join();
    graph_thread.join();
    dispatcher_thread.join();

    log.info("Status: Shutdown complete.", .{});
}
