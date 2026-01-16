const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const EventBus = @import("event_bus.zig").EventBus;
const host_api = @import("host_api.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;
const WasmRuntime = @import("wasm_runtime.zig").WasmRuntime;

/// イベントディスパッチャスレッドのメインループ
fn eventDispatcherLoop(bus: *EventBus) void {
    bus.registerDispatcherThread();
    std.debug.print("Status: Event Dispatcher Thread started\n", .{});
    while (true) {
        if (bus.queue.pop()) |msg| {
            bus.dispatch(&msg);
            msg.deinit(bus.allocator); // 配送完了後にヒープメモリを解放
            bus.notifyPotentialIdle(); // アイドル状態の可能性を通知
        } else {
            bus.notifyPotentialIdle();
            break;
        }
    }
    std.debug.print("Status: Event Dispatcher Thread stopped\n", .{});
}

var global_wasm_sub: ?WasmSubscriber = null;

pub fn main() !void {
    std.debug.print("========================================\n", .{});
    std.debug.print("   WEAVE: Streaming Event OS Core Daemon\n", .{});
    std.debug.print("========================================\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 1. 基盤の初期化 (EventBus)
    std.debug.print("Status: Initializing EventBus...\n", .{});
    var bus = EventBus.init(allocator, 1000);
    host_api.global_bus = &bus;
    const dispatcher_thread = try std.Thread.spawn(.{}, eventDispatcherLoop, .{&bus});

    // 2. Wasmランタイムの初期化
    std.debug.print("Status: Initializing Wasm Runtime...\n", .{});
    var runtime = try WasmRuntime.init();
    defer runtime.deinit();

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    // 3. プラグインのロードとインスタンス化
    std.debug.print("Status: Loading and Instantiating Wasm modules...\n", .{});
    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, "wasm-apps/chat_node.wasm", 1024 * 1024);
    defer allocator.free(wasm_buffer);

    const module = try runtime.loadModule(wasm_buffer);
    defer wamr.wasm_runtime_unload(module);

    const module_inst = try runtime.instantiate(module, 64 * 1024, 64 * 1024);
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    // 4. プラグインの有効化
    std.debug.print("Status: Activating plugins...\n", .{});
    if (wamr.wasm_runtime_lookup_function(module_inst, "on_init")) |func| {
        const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
        defer wamr.wasm_runtime_destroy_exec_env(env);
        var argv = [_]u32{0};
        _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
    }

    global_wasm_sub = try WasmSubscriber.init(module_inst);
    try bus.subscribe("ext.twitch.chat", 1, WasmSubscriber.callback, &global_wasm_sub.?);

    // 5. 実行と待機
    std.debug.print("Status: Running...\n", .{});
    try bus.publish("ext.twitch.chat", "Hello WEAVE!", .Reliable, 0);
    bus.waitIdle();

    std.debug.print("Status: Success\n", .{});

    // 6. シャットダウン
    std.debug.print("Status: Shutting down...\n", .{});
    bus.stop();
    dispatcher_thread.join();
    if (global_wasm_sub) |*sub| sub.deinit();
    bus.deinit();
}
