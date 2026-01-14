const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const EventBus = @import("event_bus.zig").EventBus;

// グローバル状態
var global_bus: *EventBus = undefined;

// --- Host APIs (WAMR Native Functions) ---

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
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const native_ptr = wamr.wasm_runtime_addr_app_to_native(module_inst, msg_ptr);
    if (native_ptr) |ptr| {
        const msg = @as([*]const u8, @ptrCast(ptr))[0..msg_len];
        std.debug.print("[WASM LOG LVL:{}] {s}\n", .{ level, msg });
    }
    return 0;
}

// --- Daemon Logic ---

const WasmSubscriber = struct {
    instance: wamr.wasm_module_inst_t,
    exec_env: wamr.wasm_exec_env_t,

    pub fn init(instance: wamr.wasm_module_inst_t) !WasmSubscriber {
        const env = wamr.wasm_runtime_create_exec_env(instance, 16384);
        if (env == null) return error.ExecEnvCreationFailed;
        return WasmSubscriber{
            .instance = instance,
            .exec_env = env.?,
        };
    }

    pub fn deinit(self: *WasmSubscriber) void {
        wamr.wasm_runtime_destroy_exec_env(self.exec_env);
    }

    pub fn callback(ctx: ?*anyopaque, msg: *const @import("event_bus.zig").EventMessage) void {
        const self: *WasmSubscriber = @ptrCast(@alignCast(ctx orelse return));

        const alloc_func = wamr.wasm_runtime_lookup_function(self.instance, "os_alloc");
        if (alloc_func == null) return;

        // Topicコピー
        var argv_t = [_]u32{@intCast(msg.topic.len)};
        if (!wamr.wasm_runtime_call_wasm(self.exec_env, alloc_func, 1, &argv_t)) return;
        const t_ptr = argv_t[0];
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, t_ptr).?))[0..msg.topic.len], msg.topic);

        // Payloadコピー
        var argv_p = [_]u32{@intCast(msg.payload.len)};
        if (!wamr.wasm_runtime_call_wasm(self.exec_env, alloc_func, 1, &argv_p)) return;
        const p_ptr = argv_p[0];
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, p_ptr).?))[0..msg.payload.len], msg.payload);

        // on_message実行
        if (wamr.wasm_runtime_lookup_function(self.instance, "on_message")) |func| {
            var msg_argv = [_]u32{ t_ptr, @intCast(msg.topic.len), p_ptr, @intCast(msg.payload.len) };
            _ = wamr.wasm_runtime_call_wasm(self.exec_env, func, 4, &msg_argv);
        }

        // メモリリセット (フェーズ 2.1)
        if (wamr.wasm_runtime_lookup_function(self.instance, "os_reset_heap")) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(self.exec_env, reset_func, 0, &reset_argv);
        }
    }
};

/// イベントディスパッチャスレッドのメインループ
fn eventDispatcherLoop(bus: *EventBus) void {
    bus.registerDispatcherThread();
    std.debug.print("Status: Event Dispatcher Thread started\n", .{});
    while (true) {
        // イベントを待機 (ブロッキング)
        if (bus.queue.pop()) |msg| {
            bus.dispatch(&msg);
            msg.deinit(bus.allocator); // 配送完了後にヒープメモリを解放
            bus.notifyPotentialIdle(); // アイドル状態の可能性を通知
        } else {
            bus.notifyPotentialIdle();
            // popがnullを返した場合はキューがシャットダウンされたことを意味する
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

    std.debug.print("Status: Initializing EventBus...\n", .{});
    var bus = EventBus.init(allocator, 1000);
    global_bus = &bus;

    // ディスパッチャスレッドを起動
    std.debug.print("Status: Spawning Event Dispatcher Thread...\n", .{});
    const dispatcher_thread = try std.Thread.spawn(.{}, eventDispatcherLoop, .{&bus});
    // メインの最後に join する

    std.debug.print("Status: Initializing WAMR Runtime...\n", .{});
    var init_args = std.mem.zeroInit(wamr.RuntimeInitArgs, .{
        .mem_alloc_type = wamr.Alloc_With_System_Allocator,
    });
    if (!wamr.wasm_runtime_full_init(&init_args)) {
        std.debug.print("Error: wasm_runtime_full_init failed\n", .{});
        return;
    }
    defer wamr.wasm_runtime_destroy();

    std.debug.print("Status: Registering Native Symbols...\n", .{});
    var native_symbols = [_]wamr.NativeSymbol{
        .{ .symbol = "os_api_publish", .func_ptr = @constCast(&os_api_publish), .signature = "(iiiii)i", .attachment = null },
        .{ .symbol = "os_api_log", .func_ptr = @constCast(&os_api_log), .signature = "(iii)i", .attachment = null },
    };
    if (!wamr.wasm_runtime_register_natives("env", &native_symbols, native_symbols.len)) {
        std.debug.print("Error: wasm_runtime_register_natives failed\n", .{});
        return;
    }

    std.debug.print("Status: Loading Wasm binary...\n", .{});
    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, "wasm-apps/chat_node.wasm", 1024 * 1024);
    defer allocator.free(wasm_buffer);

    var error_buf: [128]u8 = undefined;
    const module = wamr.wasm_runtime_load(wasm_buffer.ptr, @intCast(wasm_buffer.len), &error_buf, @intCast(error_buf.len));
    if (module == null) {
        std.debug.print("Error: wasm_runtime_load failed: {s}\n", .{error_buf});
        return;
    }
    defer wamr.wasm_runtime_unload(module);

    std.debug.print("Status: Instantiating Wasm module...\n", .{});
    const module_inst = wamr.wasm_runtime_instantiate(module, 64 * 1024, 64 * 1024, &error_buf, @intCast(error_buf.len));
    if (module_inst == null) {
        std.debug.print("Error: wasm_runtime_instantiate failed: {s}\n", .{error_buf});
        return;
    }
    defer wamr.wasm_runtime_deinstantiate(module_inst);

    std.debug.print("Status: Calling on_init...\n", .{});
    const exec_env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
    if (exec_env) |env| {
        defer wamr.wasm_runtime_destroy_exec_env(env);
        if (wamr.wasm_runtime_lookup_function(module_inst, "on_init")) |func| {
            var argv = [_]u32{0};
            if (!wamr.wasm_runtime_call_wasm(env, func, 0, &argv)) {
                std.debug.print("Error: on_init failed!\n", .{});
                return;
            }
        }
    }

    std.debug.print("Status: Registering Wasm subscriber...\n", .{});
    global_wasm_sub = try WasmSubscriber.init(module_inst);
    try bus.subscribe("ext.twitch.chat", 1, WasmSubscriber.callback, &global_wasm_sub.?);

    std.debug.print("Status: Publishing test event...\n", .{});
    try bus.publish("ext.twitch.chat", "Hello WEAVE!", .Reliable, 0);

    // 非同期配送を待つために少し待機
    std.Thread.sleep(200 * std.time.ns_per_ms);

    std.debug.print("Status: Success\n", .{});

    // シャットダウンシーケンス: 停止通知 -> スレッド待機 -> メモリ解放
    bus.stop();
    dispatcher_thread.join();
    if (global_wasm_sub) |*sub| sub.deinit();
    bus.deinit();
}
