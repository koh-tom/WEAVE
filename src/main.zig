const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const EventBus = @import("event_bus.zig").EventBus;
const host_api = @import("host_api.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;
const WasmRuntime = @import("wasm_runtime.zig").WasmRuntime;
const PluginManager = @import("plugin_manager.zig").PluginManager;
const TwitchAdapter = @import("adapters/twitch.zig").TwitchAdapter;

fn runTwitch(t: *TwitchAdapter) void {
    t.run() catch |err| {
        std.debug.print("TwitchAdapter Error: {any}\n", .{err});
    };
}

pub fn main() !void {
    std.debug.print("========================================\n", .{});
    std.debug.print("   WEAVE: Streaming Event OS Core Daemon\n", .{});
    std.debug.print("========================================\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Wasmランタイムの初期化
    var runtime = try WasmRuntime.init();
    defer runtime.deinit();

    // 2. 基盤の初期化 (EventBus, PluginManager)
    std.debug.print("Status: Initializing EventBus & PluginManager...\n", .{});
    var bus = EventBus.init(allocator, 1000);
    defer bus.deinit();
    var pm = PluginManager.init(allocator);
    defer pm.deinit();

    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;

    const dispatcher_thread = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});

    // Twitchアダプタの起動
    var twitch = TwitchAdapter.init(allocator, &bus, 1, "xqc");
    const twitch_thread = try std.Thread.spawn(.{}, runTwitch, .{&twitch});
    defer twitch.deinit();

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    // 3. プラグインのロードとインスタンス化
    std.debug.print("Status: Loading and Instantiating Wasm modules...\n", .{});
    const wasm_path = "wasm-apps/chat_node.wasm";
    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);
    defer allocator.free(wasm_buffer);

    const module = try runtime.loadModule(wasm_buffer);
    defer wamr.wasm_runtime_unload(module);

    const module_inst = try runtime.instantiate(module, 64 * 1024, 64 * 1024);
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    // Wasmパスからマニフェストパスを生成 (.wasm -> .json)
    var manifest_path_buf: [256]u8 = undefined;
    const manifest_path = if (std.mem.endsWith(u8, wasm_path, ".wasm"))
        try std.fmt.bufPrint(&manifest_path_buf, "{s}.json", .{wasm_path[0 .. wasm_path.len - 5]})
    else
        "wasm-apps/manifest.json"; // fallback

    // マニフェストの登録
    const meta = try pm.registerPlugin(module_inst, manifest_path);
    std.debug.print("Status: Registered plugin '{s}' (Version: {s}) from {s} as Node {}\n", .{
        meta.manifest_parsed.value.name,
        meta.manifest_parsed.value.version,
        manifest_path,
        meta.node_id,
    });

    // 4. プラグインの有効化 (マニフェスト登録後に行う)
    std.debug.print("Status: Activating plugins...\n", .{});
    if (wamr.wasm_runtime_lookup_function(module_inst, "on_init")) |func| {
        const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
        defer wamr.wasm_runtime_destroy_exec_env(env);
        var argv = [_]u32{0};
        if (!wamr.wasm_runtime_call_wasm(env, func, 0, &argv)) {
            return error.PluginInitCallFailed;
        }
        const result = @as(i32, @bitCast(argv[0]));
        if (result != 0) {
            std.debug.print("Error: Plugin on_init failed with code {}\n", .{result});
            return error.PluginInitFailed;
        }
    }

    // マニフェストに基づいた購読の自動登録
    try pm.applyManifestSubscriptions(module_inst, &bus);

    // 5. デーモンモード — Twitchアダプタが終了するまで待機
    std.debug.print("Status: Running... (Press Ctrl+C to stop)\n", .{});
    twitch_thread.join();

    // 6. シャットダウン
    std.debug.print("Status: Shutting down...\n", .{});
    bus.stop();
    dispatcher_thread.join();
}
