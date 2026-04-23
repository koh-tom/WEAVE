const std = @import("std");
const common = @import("../common/types.zig");
const log = @import("../common/log.zig");
const wamr = @import("../core/wamr_libs.zig").wamr;
const event_bus = @import("../core/event_bus.zig");
const plugin_manager = @import("../core/plugin_manager.zig");
const WasmSubscriber = @import("../core/wasm_subscriber.zig").WasmSubscriber;

/// グローバル参照（Wasm callbackからアクセスするため）
pub var global_bus: ?*event_bus.EventBus = null;
pub var global_plugin_manager: ?*plugin_manager.PluginManager = null;
/// ログ出力を有効にするかどうか
pub var enable_log: bool = true;

/// WEAVE API 戻り値定義 (Wasm側と共通)
pub const ResultCode = common.ResultCode;

fn toI32(code: ResultCode) i32 {
    return @intFromEnum(code);
}

/// Wasm側から呼び出される publish API
/// Wasm側シグネチャ: os_api_publish(topic_ptr: i32, payload_ptr: i32, payload_len: i32) -> i32
export fn os_api_publish(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
    payload_ptr: u32,
    payload_len: u32,
    qos: u32,
) i32 {
    const bus = global_bus orelse return toI32(.ERROR_UNKNOWN);
    const pm = global_plugin_manager orelse return toI32(.ERROR_UNKNOWN);

    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);

    const meta = pm.getMetadata(module_inst) orelse {
        if (enable_log) std.debug.print("Error: Unknown plugin attempted to publish\n", .{});
        return toI32(.ERROR_NOT_FOUND);
    };

    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    const p_native = wamr.wasm_runtime_addr_app_to_native(module_inst, payload_ptr);
    if (t_native == null or p_native == null) return toI32(.ERROR_INVALID_PARAMETER);

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
        return toI32(.ERROR_PERMISSION_DENIED);
    }

    const qos_val = if (qos >= 3) event_bus.QoS.BestEffort else @as(event_bus.QoS, @enumFromInt(@as(u32, @intCast(qos))));

    bus.publish(topic, payload, qos_val, meta.node_id) catch |err| {
        if (err == error.QueueFull) return toI32(.ERROR_QUEUE_FULL);
        return toI32(.ERROR_UNKNOWN);
    };
    return toI32(.SUCCESS);
}

/// Wasm側から呼び出される subscribe API
/// Wasm側シグネチャ: os_api_subscribe(topic_ptr: i32) -> i32
export fn os_api_subscribe(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
) i32 {
    const bus = global_bus orelse return toI32(.ERROR_UNKNOWN);
    const pm = global_plugin_manager orelse return toI32(.ERROR_UNKNOWN);
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);

    const meta = pm.getMetadata(module_inst) orelse return toI32(.ERROR_NOT_FOUND);
    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    if (t_native == null) return toI32(.ERROR_INVALID_PARAMETER);

    // null-terminated 文字列としてスパンを取得
    const topic = std.mem.span(@as([*c]const u8, @ptrCast(t_native)));

    // 権限チェック (ACL)
    if (!meta.manifest_parsed.value.canSubscribe(topic)) {
        log.err("Security Error: Plugin '{s}' (Node {}) attempted to subscribe to unauthorized topic '{s}'", .{
            meta.manifest_parsed.value.name,
            meta.node_id,
            topic,
        });
        return toI32(.ERROR_PERMISSION_DENIED);
    }

    // 購読登録
    if (meta.subscriber) |*sub| {
        bus.subscribe(topic, meta.node_id, WasmSubscriber.callback, sub) catch return toI32(.ERROR_UNKNOWN);
    } else return toI32(.ERROR_UNKNOWN);

    log.debug("Node {} subscribed to topic '{s}'", .{ meta.node_id, topic });
    return toI32(.SUCCESS);
}

/// Wasm側から呼び出される log API
/// Wasm側シグネチャ: os_api_log(level: i32, msg_ptr: i32, msg_len: i32) -> void
export fn os_api_log(
    exec_env: wamr.wasm_exec_env_t,
    level: u32,
    msg_ptr: u32,
    msg_len: u32,
) void {
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const pm = global_plugin_manager orelse return;
    const meta = pm.getMetadata(module_inst);
    const name = if (meta) |m| m.manifest_parsed.value.name else "unknown-wasm";

    const native_ptr = wamr.wasm_runtime_addr_app_to_native(module_inst, msg_ptr);
    if (native_ptr) |ptr| {
        const msg = @as([*]const u8, @ptrCast(ptr))[0..msg_len];
        switch (level) {
            0 => log.debug("[{s}] {s}", .{ name, msg }),
            1 => log.info("[{s}] {s}", .{ name, msg }),
            2 => log.warn("[{s}] {s}", .{ name, msg }),
            3 => log.err("[{s}] {s}", .{ name, msg }),
            else => log.info("[{s}] {s}", .{ name, msg }),
        }
    }
}

/// WAMRに登録するネイティブ関数のリスト
/// シグネチャはWasm側から見た型（exec_envは含めない）
///   publish:   (topic_ptr: i32, payload_ptr: i32, payload_len: i32) -> i32  = "(iiii)i"
///   subscribe: (topic_ptr: i32) -> i32                                      = "(i)i"
///   log:       (level: i32, msg_ptr: i32, msg_len: i32) -> void             = "(iii)"
pub fn getNativeSymbols() [3]wamr.NativeSymbol {
    return [_]wamr.NativeSymbol{
        .{ .symbol = "os_api_publish", .func_ptr = @constCast(@ptrCast(&os_api_publish)), .signature = "(iiii)i", .attachment = null },
        .{ .symbol = "os_api_subscribe", .func_ptr = @constCast(@ptrCast(&os_api_subscribe)), .signature = "(i)i", .attachment = null },
        .{ .symbol = "os_api_log", .func_ptr = @constCast(@ptrCast(&os_api_log)), .signature = "(iii)", .attachment = null },
    };
}
