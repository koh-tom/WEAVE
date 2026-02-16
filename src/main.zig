const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const host_api = @import("host_api.zig");
const TwitchAdapter = @import("adapters/twitch.zig").TwitchAdapter;
const Core = @import("core.zig").Core;
const LogTransport = @import("transports/log_transport.zig").LogTransport;
const WsGateway = @import("transports/ws_gateway.zig").WsGateway;
const NodeWsTransport = @import("transports/node_ws.zig").NodeWsTransport;

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
    std.debug.print("========================================\n", .{});
    std.debug.print("   WEAVE: Streaming Event OS Core Daemon\n", .{});
    std.debug.print("========================================\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

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

    var ws_gateway = try WsGateway.init(allocator, &core.bus, 8080);
    defer ws_gateway.deinit();
    try core.tm.register(ws_gateway.transport());

    var node_ws = try NodeWsTransport.init(allocator, &core.bus, 8081, "weave-secret-2026");
    defer node_ws.deinit();
    try core.tm.register(node_ws.transport());

    try core.setupGateway();

    const dispatcher_thread = try std.Thread.spawn(.{}, @import("event_bus.zig").EventBus.runDispatcher, .{&core.bus});
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
    var twitch = TwitchAdapter.init(allocator, &core.bus, 1, "SqLA");
    const twitch_thread = try std.Thread.spawn(.{}, runTwitch, .{&twitch});
    defer twitch.deinit();

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
