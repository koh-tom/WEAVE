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


const Config = struct {
    ws_gateway_port: u16 = 8080,
    node_ws_port: u16 = 8081,
    dashboard_port: u16 = 3030,
    twitch_channel: []const u8 = "SqLA",
    obs_host: []const u8 = "127.0.0.1",
    obs_port: u16 = 4455,
    obs_password: []const u8 = "obs-password",

    pub fn parse(allocator: std.mem.Allocator) !Config {
        var self = Config{};
        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--ws-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.ws_gateway_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--node-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.node_ws_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--dash-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.dashboard_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--twitch")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.twitch_channel = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--obs-host")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_host = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--obs-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--obs-pass")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_password = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--help")) {
                std.debug.print(
                    \\Usage: WEAVE [options]
                    \\Options:
                    \\  --ws-port <port>     Port for WebSocket Gateway (default: 8080)
                    \\  --node-port <port>   Port for Node WebSocket Transport (default: 8081)
                    \\  --dash-port <port>   Port for Dashboard HTTP Server (default: 3030)
                    \\  --twitch <channel>   Twitch channel to join (default: SqLA)
                    \\  --obs-host <host>    OBS WebSocket host (default: 127.0.0.1)
                    \\  --obs-port <port>    OBS WebSocket port (default: 4455)
                    \\  --obs-pass <pass>    OBS WebSocket password (default: obs-password)
                    \\  --help               Show this help
                    \\
                , .{});
                std.process.exit(0);
            } else {
                std.debug.print("Warning: Unknown argument '{s}'\n", .{arg});
            }
        }
        return self;
    }
};

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

fn runGraphPublisher(core: *Core) void {
    while (true) {
        const json = core.graph.toJson(core.allocator) catch |err| {
            std.debug.print("GraphPublisher Error (JSON): {any}\n", .{err});
            continue;
        };
        defer core.allocator.free(json);
        
        core.bus.publish("core.system.graph.full", json, .Transient, 0) catch |err| {
            std.debug.print("GraphPublisher Error (Publish): {any}\n", .{err});
        };
        std.Thread.sleep(60 * std.time.ns_per_s);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = try Config.parse(allocator);

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
    core.graph.bus = &core.bus; // 追加: 差分発行用

    host_api.global_bus = &core.bus;
    host_api.global_plugin_manager = &core.pm;
    core.pm.runtime = &core.runtime; // 追加: 再起動用

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
    const ws_thread = try std.Thread.spawn(.{}, runWsGateway, .{ws_gateway});
    ws_thread.detach();

    const node_ws_thread = try std.Thread.spawn(.{}, runNodeWs, .{node_ws});
    node_ws_thread.detach();

    const graph_thread = try std.Thread.spawn(.{}, runGraphPublisher, .{&core});
    graph_thread.detach();

    // ノードの登録
    try core.graph.registerNode(1, "TwitchAdapter", .native);
    try core.bus.publish("core.node.registered", "{\"node_id\":1,\"name\":\"TwitchAdapter\",\"type\":\"native\"}", .Transient, 0);

    try core.graph.registerNode(100, "chat_node", .wasm);
    try core.bus.publish("core.node.registered", "{\"node_id\":100,\"name\":\"chat_node\",\"type\":\"wasm\"}", .Transient, 0);

    // Twitchアダプタの起動 (Native Node)
    var twitch = TwitchAdapter.init(allocator, &core.bus, 1, config.twitch_channel);
    const twitch_thread = try std.Thread.spawn(.{}, runTwitch, .{&twitch});
    defer twitch.deinit();

    // OBSアダプタの起動
    var obs = try ObsEgressNode.init(allocator, &core.bus, 2, config.obs_password);
    defer obs.deinit();
    obs.connect(config.obs_host, config.obs_port) catch |err| {
        std.debug.print("Main: OBS connect failed (optional): {any}\n", .{err});
    };

    // Dashboardの起動
    var dashboard = try DashboardNode.init(allocator, &core.bus, 100, config.dashboard_port);
    defer dashboard.deinit();
    try dashboard.start();

    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);

    // 3. プラグインのロード
    const wasm_path = "wasm-apps/chat_node.wasm";
    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);
    defer allocator.free(wasm_buffer);

    const module = try core.runtime.loadModule(wasm_buffer);
    defer wamr.wasm_runtime_unload(module);

    const module_inst = try core.runtime.instantiate(module, 64 * 1024, 64 * 1024);
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    var manifest_path_buf: [256]u8 = undefined;
    const manifest_path = if (std.mem.endsWith(u8, wasm_path, ".wasm"))
        try std.fmt.bufPrint(&manifest_path_buf, "{s}.json", .{wasm_path[0 .. wasm_path.len - 5]})
    else
        "wasm-apps/manifest.json";

    const meta = try core.pm.registerPlugin(module_inst, wasm_path, manifest_path, &core.bus);
    std.debug.print("Status: Registered plugin '{s}' as Node {}\n", .{
        meta.manifest_parsed.value.name,
        meta.node_id,
    });

    // 4. 有効化
    if (wamr.wasm_runtime_lookup_function(module_inst, "on_init")) |func| {
        const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
        defer wamr.wasm_runtime_destroy_exec_env(env);
        var argv = [_]u32{0};
        _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
    }

    try core.pm.applyManifestSubscriptions(module_inst, &core.bus);

    // 5. 実行
    std.debug.print("Status: Running... (Press Ctrl+C to stop)\n", .{});
    twitch_thread.join();

    // 6. シャットダウン
    core.bus.stop();
    dispatcher_thread.join();
}
