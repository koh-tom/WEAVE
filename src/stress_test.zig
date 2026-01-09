const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const EventBus = @import("event_bus.zig").EventBus;

// グローバル状態
var global_bus: *EventBus = undefined;

// --- Host APIs ---

export fn os_api_publish(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
    topic_len: u32,
    payload_ptr: u32,
    payload_len: u32,
    qos_raw: u32,
) u32 {
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    const p_native = wamr.wasm_runtime_addr_app_to_native(module_inst, payload_ptr);
    if (t_native == null or p_native == null) return 1;

    const topic = @as([*]const u8, @ptrCast(t_native))[0..topic_len];
    const payload = @as([*]const u8, @ptrCast(p_native))[0..payload_len];
    const qos = @as(@import("event_bus.zig").QoS, @enumFromInt(@as(u8, @intCast(qos_raw))));

    global_bus.publish(topic, payload, qos, 1) catch return 1;
    return 0;
}

export fn os_api_log(
    exec_env: wamr.wasm_exec_env_t,
    level: u32,
    msg_ptr: u32,
    msg_len: u32,
) u32 {
    _ = exec_env; _ = level; _ = msg_ptr; _ = msg_len;
    return 0;
}

const WasmSubscriber = struct {
    instance: wamr.wasm_module_inst_t,

    pub fn callback(ctx: ?*anyopaque, msg: *const @import("event_bus.zig").EventMessage) void {
        const self: *WasmSubscriber = @ptrCast(@alignCast(ctx orelse return));
        const exec_env = wamr.wasm_runtime_create_exec_env(self.instance, 16384);
        if (exec_env == null) return;
        defer wamr.wasm_runtime_destroy_exec_env(exec_env);

        const alloc_func = wamr.wasm_runtime_lookup_function(self.instance, "os_alloc");
        if (alloc_func == null) return;

        // Topicコピー
        var argv_t = [_]u32{@intCast(msg.topic.len)};
        _ = wamr.wasm_runtime_call_wasm(exec_env, alloc_func, 1, &argv_t);
        const t_ptr = argv_t[0];
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, t_ptr).?))[0..msg.topic.len], msg.topic);

        // Payloadコピー
        var argv_p = [_]u32{@intCast(msg.payload.len)};
        _ = wamr.wasm_runtime_call_wasm(exec_env, alloc_func, 1, &argv_p);
        const p_ptr = argv_p[0];
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, p_ptr).?))[0..msg.payload.len], msg.payload);

        // on_message実行
        if (wamr.wasm_runtime_lookup_function(self.instance, "on_message")) |func| {
            var msg_argv = [_]u32{ t_ptr, @intCast(msg.topic.len), p_ptr, @intCast(msg.payload.len) };
            _ = wamr.wasm_runtime_call_wasm(exec_env, func, 4, &msg_argv);
        }

        // メモリリセット
        if (wamr.wasm_runtime_lookup_function(self.instance, "os_reset_heap")) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(exec_env, reset_func, 0, &reset_argv);
        }
    }
};

fn eventDispatcherLoop(bus: *EventBus) void {
    std.debug.print("Dispatcher: Started\n", .{});
    while (true) {
        if (bus.queue.pop()) |msg| {
            // std.debug.print("Dispatcher: Popped event {}\n", .{msg.id});
            bus.dispatch(&msg);
            msg.deinit(bus.allocator);
        } else {
            std.debug.print("Dispatcher: Shutdown\n", .{});
            break;
        }
    }
}

pub fn main() !void {
    std.debug.print(">>> WEAVE Stress Test: Memory Management (Phase 2.2 Async) <<<\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = EventBus.init(allocator, 100000);
    bus.verbose = false;
    global_bus = &bus;

    // ディスパッチャスレッドを起動
    const dispatcher_thread = try std.Thread.spawn(.{}, eventDispatcherLoop, .{&bus});
    
    var init_args = std.mem.zeroInit(wamr.RuntimeInitArgs, .{ .mem_alloc_type = wamr.Alloc_With_System_Allocator });
    _ = wamr.wasm_runtime_full_init(&init_args);
    defer wamr.wasm_runtime_destroy();

    var native_symbols = [_]wamr.NativeSymbol{
        .{ .symbol = "os_api_publish", .func_ptr = @constCast(&os_api_publish), .signature = "(iiiii)i", .attachment = null },
        .{ .symbol = "os_api_log", .func_ptr = @constCast(&os_api_log), .signature = "(iii)i", .attachment = null },
    };
    _ = wamr.wasm_runtime_register_natives("env", &native_symbols, native_symbols.len);

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, "wasm-apps/chat_node.wasm", 1024 * 1024);
    defer allocator.free(wasm_buffer);

    var error_buf: [128]u8 = undefined;
    const module = wamr.wasm_runtime_load(wasm_buffer.ptr, @intCast(wasm_buffer.len), &error_buf, @intCast(error_buf.len));
    const module_inst = wamr.wasm_runtime_instantiate(module, 64*1024, 64*1024, &error_buf, @intCast(error_buf.len));
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    var wasm_sub = WasmSubscriber{ .instance = module_inst.? };
    try bus.subscribe("test.stress", 1, WasmSubscriber.callback, &wasm_sub);

    const iterations = 100000;
    std.debug.print("Running {} iterations with Async Queue (Capacity: 100000)...\n", .{iterations});
    
    const start_time = std.time.milliTimestamp();
    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        try bus.publish("test.stress", "STRESS_TEST_PAYLOAD", .Reliable, 0);
        if (i % 10000 == 0) std.debug.print("Progress: {}/100000 (Queue: {})\n", .{i, bus.queue.count});
    }

    // すべてのイベントが処理されるまで少し待機
    while (bus.queue.count > 0) {
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    const end_time = std.time.milliTimestamp();

    std.debug.print("Test Finished Successfully in {}ms!\n", .{end_time - start_time});

    // シャットダウンシーケンス: 停止通知 -> スレッド待機 -> メモリ解放
    bus.stop();
    dispatcher_thread.join();
    bus.deinit();
}
