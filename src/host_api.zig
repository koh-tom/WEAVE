const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const event_bus = @import("event_bus.zig");
const plugin_manager = @import("plugin_manager.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;

/// グローバル参照（Wasm callbackからアクセスするため）
pub var global_bus: ?*event_bus.EventBus = null;
pub var global_plugin_manager: ?*plugin_manager.PluginManager = null;
/// ログ出力を有効にするかどうか
pub var enable_log: bool = true;

/// WEAVE API 戻り値定義 (Wasm側と共通)
pub const WEAVE_RESULT = enum(i32) {
    SUCCESS = 0,
    ERROR_UNKNOWN = 1,
    ERROR_PERMISSION_DENIED = 2,
    ERROR_INVALID_PARAMETER = 3,
    ERROR_QUEUE_FULL = 4,
    ERROR_NOT_FOUND = 5,

    pub fn toI32(self: WEAVE_RESULT) i32 {
        return @intFromEnum(self);
    }
};

/// Wasm側から呼び出される publish API
/// Wasm側シグネチャ: os_api_publish(topic_ptr: i32, payload_ptr: i32, payload_len: i32) -> i32
export fn os_api_publish(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
    payload_ptr: u32,
    payload_len: u32,
) i32 {
    const bus = global_bus orelse return WEAVE_RESULT.ERROR_UNKNOWN.toI32();
    const pm = global_plugin_manager orelse return WEAVE_RESULT.ERROR_UNKNOWN.toI32();

    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);

    const meta = pm.getMetadata(module_inst) orelse {
        if (enable_log) std.debug.print("Error: Unknown plugin attempted to publish\n", .{});
        return WEAVE_RESULT.ERROR_NOT_FOUND.toI32();
    };

    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    const p_native = wamr.wasm_runtime_addr_app_to_native(module_inst, payload_ptr);
    if (t_native == null or p_native == null) return WEAVE_RESULT.ERROR_INVALID_PARAMETER.toI32();

    // topic_ptr は null-terminated 文字列としてスパンを取得
    const topic = std.mem.span(@as([*c]const u8, @ptrCast(t_native)));
    const payload = @as([*]const u8, @ptrCast(p_native))[0..payload_len];

    // 権限チェック (ACL)
    if (!meta.manifest_parsed.value.canPublish(topic)) {
        if (enable_log) std.debug.print("Security Error: Plugin '{s}' (Node {}) attempted to publish to unauthorized topic '{s}'\n", .{
            meta.manifest_parsed.value.name,
            meta.node_id,
            topic,
        });
        return WEAVE_RESULT.ERROR_PERMISSION_DENIED.toI32();
    }

    bus.publish(topic, payload, .BestEffort, meta.node_id) catch |err| {
        if (err == error.QueueFull) return WEAVE_RESULT.ERROR_QUEUE_FULL.toI32();
        return WEAVE_RESULT.ERROR_UNKNOWN.toI32();
    };
    return WEAVE_RESULT.SUCCESS.toI32();
}

/// Wasm側から呼び出される subscribe API
/// Wasm側シグネチャ: os_api_subscribe(topic_ptr: i32) -> i32
export fn os_api_subscribe(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
) i32 {
    const bus = global_bus orelse return WEAVE_RESULT.ERROR_UNKNOWN.toI32();
    const pm = global_plugin_manager orelse return WEAVE_RESULT.ERROR_UNKNOWN.toI32();
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);

    const meta = pm.getMetadata(module_inst) orelse return WEAVE_RESULT.ERROR_NOT_FOUND.toI32();
    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    if (t_native == null) return WEAVE_RESULT.ERROR_INVALID_PARAMETER.toI32();

    // null-terminated 文字列としてスパンを取得
    const topic = std.mem.span(@as([*c]const u8, @ptrCast(t_native)));

    // 権限チェック (ACL)
    if (!meta.manifest_parsed.value.canSubscribe(topic)) {
        if (enable_log) std.debug.print("Security Error: Plugin '{s}' (Node {}) attempted to subscribe to unauthorized topic '{s}'\n", .{
            meta.manifest_parsed.value.name,
            meta.node_id,
            topic,
        });
        return WEAVE_RESULT.ERROR_PERMISSION_DENIED.toI32();
    }

    // 購読登録
    if (meta.subscriber) |*sub| {
        bus.subscribe(topic, meta.node_id, WasmSubscriber.callback, sub) catch return WEAVE_RESULT.ERROR_UNKNOWN.toI32();
    } else return WEAVE_RESULT.ERROR_UNKNOWN.toI32();

    if (enable_log) std.debug.print("Node {} subscribed to topic '{s}'\n", .{ meta.node_id, topic });
    return WEAVE_RESULT.SUCCESS.toI32();
}

/// Wasm側から呼び出される log API
/// Wasm側シグネチャ: os_api_log(level: i32, msg_ptr: i32, msg_len: i32) -> void
export fn os_api_log(
    exec_env: wamr.wasm_exec_env_t,
    level: u32,
    msg_ptr: u32,
    msg_len: u32,
) void {
    if (!enable_log) return;

    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const native_ptr = wamr.wasm_runtime_addr_app_to_native(module_inst, msg_ptr);
    if (native_ptr) |ptr| {
        const msg = @as([*]const u8, @ptrCast(ptr))[0..msg_len];
        std.debug.print("[WASM LOG LVL:{}] {s}\n", .{ level, msg });
    }
}

/// WAMRに登録するネイティブ関数のリスト
/// シグネチャはWasm側から見た型（exec_envは含めない）
///   publish:   (topic_ptr: i32, payload_ptr: i32, payload_len: i32) -> i32  = "(iii)i"
///   subscribe: (topic_ptr: i32) -> i32                                      = "(i)i"
///   log:       (level: i32, msg_ptr: i32, msg_len: i32) -> void             = "(iii)"
pub fn getNativeSymbols() [3]wamr.NativeSymbol {
    return [_]wamr.NativeSymbol{
        .{ .symbol = "os_api_publish", .func_ptr = @constCast(@ptrCast(&os_api_publish)), .signature = "(iii)i", .attachment = null },
        .{ .symbol = "os_api_subscribe", .func_ptr = @constCast(@ptrCast(&os_api_subscribe)), .signature = "(i)i", .attachment = null },
        .{ .symbol = "os_api_log", .func_ptr = @constCast(@ptrCast(&os_api_log)), .signature = "(iii)", .attachment = null },
    };
}
