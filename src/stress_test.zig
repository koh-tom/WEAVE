const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const EventBus = @import("event_bus.zig").EventBus;
const host_api = @import("host_api.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;
const WasmRuntime = @import("wasm_runtime.zig").WasmRuntime;
const PluginManager = @import("plugin_manager.zig").PluginManager;

pub fn main() !void {
    std.debug.print(">>> WEAVE Stress Test: Memory Management (Phase 2.2 Async) <<<\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. Wasmランタイムの初期化
    var runtime = try WasmRuntime.init();
    defer runtime.deinit();

    var bus = EventBus.init(allocator, 1000);
    bus.verbose = false;
    var pm = PluginManager.init(allocator);
    defer pm.deinit();

    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    host_api.enable_log = false; // パフォーマンスのためログを無効化

    // ディスパッチャスレッドを起動
    const dispatcher_thread = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});
    


    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

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
    _ = try pm.registerPlugin(module_inst, manifest_path);

    // マニフェストに基づいた購読の自動登録
    try pm.applyManifestSubscriptions(module_inst, &bus);

    const iterations = 100000;
    std.debug.print("Running {} iterations with Async Queue (Capacity: 1000)...\n", .{iterations});
    
    const start_time = std.time.milliTimestamp();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        try bus.publish("test.stress", "STRESS_TEST_PAYLOAD", .Reliable, 0);
        if (i % 10000 == 0) std.debug.print("Progress: {}/100000 (Queue: {})\n", .{i, bus.queue.count});
    }

    bus.waitIdle();
    const end_time = std.time.milliTimestamp();

    std.debug.print("Test Finished Successfully in {}ms!\n", .{end_time - start_time});

    bus.stop();
    dispatcher_thread.join();
}
