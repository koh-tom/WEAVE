const std = @import("std");
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
        std.debug.print("TwitchAdapter Error: {any}\n", .{err});
    };
}

fn runWsGateway(w: *WsGateway) void {
    w.run() catch |err| {
        std.debug.print("WsGateway Error: {any}\n", .{err});
    };
}

fn runNodeWs(n: *NodeWsTransport) void {
    n.run() catch |err| {
        std.debug.print("NodeWsTransport Error: {any}\n", .{err});
    };
}

fn runGraphPublisher(core: *Core, running_ptr: *std.atomic.Value(bool)) void {
    while (running_ptr.load(.acquire)) {
        const json = core.graph.toJson(core.allocator) catch |err| {
            std.debug.print("GraphPublisher Error (JSON): {any}\n", .{err});
            continue;
        };
        defer core.allocator.free(json);
        
        core.bus.publish("core.system.graph.full", json, .Transient, 0) catch |err| {
            std.debug.print("GraphPublisher Error (Publish): {any}\n", .{err});
        };
        
        // 1秒ごとにフラグチェック、60秒ごとにパブリッシュ
        var i: u32 = 0;
        while (i < 60 and running_ptr.load(.acquire)) : (i += 1) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }
}

var running = std.atomic.Value(bool).init(true);

fn sigHandler(sig: i32) callconv(.C) void {
    _ = sig;
    running.store(false, .release);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // シグナルハンドラの設定
    const act = std.os.linux.Sigaction{
        .handler = .{ .handler = sigHandler },
        .mask = std.os.linux.empty_sigset,
        .flags = 0,
    };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &act, null);

    var config = try Config.parse(allocator);
    defer config.deinit(allocator);

    std.debug.print("========================================\n", .{});
    std.debug.print("   WEAVE: Streaming Event OS Core Daemon\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("Config: Dashboard: http://localhost:{d}\n", .{config.dashboard_port});
    std.debug.print("Config: WS Gateway: ws://localhost:{d}\n", .{config.ws_gateway_port});
    std.debug.print("Config: Node WS: ws://localhost:{d}\n", .{config.node_ws_port});
    std.debug.print("Config: Twitch: {s}, OBS: {s}:{d}\n", .{config.twitch_channel, config.obs_host, config.obs_port});
    std.debug.print("----------------------------------------\n", .{});

    // 1. Coreの初期化 (EventBus, PluginManager, TransportManager, WasmRuntime)
    var core = try Core.init(allocator);
    defer core.deinit();

    core.bus.graph = &core.graph;
    core.graph.bus = &core.bus;

    host_api.global_bus = &core.bus;
    host_api.global_plugin_manager = &core.pm;
    core.pm.runtime = &core.runtime;

    // 2. トランスポートの設定
    var log_transport = LogTransport.init("DebugLogger");
    try core.tm.register(log_transport.asTransport());

    var ws_gateway = try WsGateway.init(allocator, &core.bus, config.ws_gateway_port);
    defer ws_gateway.deinit();
    try core.tm.register(ws_gateway.transport());

    var node_ws = try NodeWsTransport.init(allocator, &core.bus, config.node_ws_port, "weave-secret-2026");
    defer node_ws.deinit();
    try core.tm.register(node_ws.transport());

    try core.setupGateway();

    const dispatcher_thread = try std.Thread.spawn(.{}, @import("core/event_bus.zig").EventBus.runDispatcher, .{&core.bus});
    
    // スレッド管理用に保持
    const ws_thread = try std.Thread.spawn(.{}, runWsGateway, .{ws_gateway});
    const node_ws_thread = try std.Thread.spawn(.{}, runNodeWs, .{node_ws});
    
    const graph_thread = try std.Thread.spawn(.{}, runGraphPublisher, .{&core, &running});

    // ネイティブノードの登録と起動
    try core.graph.registerNode(1, "TwitchAdapter", .native);
    try core.bus.publish("core.node.registered", "{\"node_id\":1,\"name\":\"TwitchAdapter\",\"type\":\"native\"}", .Transient, 0);

    var twitch = TwitchAdapter.init(allocator, &core.bus, 1, config.twitch_channel);
    const twitch_thread = try std.Thread.spawn(.{}, runTwitch, .{&twitch});
    defer twitch.deinit();

    var obs = try ObsEgressNode.init(allocator, &core.bus, 2, config.obs_password);
    defer obs.deinit();
    obs.connect(config.obs_host, config.obs_port) catch |err| {
        std.debug.print("Main: OBS connect failed (optional): {any}\n", .{err});
    };

    // Dashboardの起動
    var dashboard = try DashboardNode.init(allocator, &core.bus, 100, config.dashboard_port);
    defer dashboard.deinit();
    try dashboard.start();

    // Wasmプラグインのロード
    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);

    for (config.plugins.items) |path| {
        core.loadPlugin(path) catch |err| {
            std.debug.print("Error: Failed to load plugin '{s}': {any}\n", .{path, err});
        };
    }

    // 5. 実行
    std.debug.print("Status: Running... (Press Ctrl+C to stop)\n", .{});
    
    // 終了フラグを監視
    while (running.load(.acquire)) {
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    std.debug.print("\nStatus: Shutdown signal received. Cleaning up...\n", .{});

    // 6. シャットダウンシーケンス
    twitch.stop(); // Twitchスレッドを停止
    twitch_thread.join();

    ws_gateway.stop(); // facil.io を停止
    ws_thread.join();
    
    node_ws.stop();
    node_ws_thread.join();

    graph_thread.join();

    core.bus.stop(); // Dispatcherを停止
    dispatcher_thread.join();

    std.debug.print("Status: Shutdown complete.\n", .{});
}
