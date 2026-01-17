const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const event_bus = @import("event_bus.zig");
const plugin_manager = @import("plugin_manager.zig");

/// ホスト側で共有されるEventBusへのポインタ
pub var global_bus: ?*event_bus.EventBus = null;
/// ホスト側で共有されるPluginManagerへのポインタ
pub var global_plugin_manager: ?*plugin_manager.PluginManager = null;
/// ログ出力を有効にするかどうか
pub var enable_log: bool = true;

/// Wasm側から呼び出される publish API
export fn os_api_publish(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
    topic_len: u32,
    payload_ptr: u32,
    payload_len: u32,
    qos_raw: u32,
) u32 {
    const bus = global_bus orelse return 1;
    const pm = global_plugin_manager orelse return 1;
    
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    
    // 呼び出し元のメタデータを取得
    const meta = pm.getMetadata(module_inst) orelse {
        if (enable_log) std.debug.print("Error: Unknown plugin attempted to publish\n", .{});
        return 1;
    };

    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    const p_native = wamr.wasm_runtime_addr_app_to_native(module_inst, payload_ptr);
    if (t_native == null or p_native == null) return 1;

    const topic = @as([*]const u8, @ptrCast(t_native))[0..topic_len];
    const payload = @as([*]const u8, @ptrCast(p_native))[0..payload_len];
    const qos = @as(event_bus.QoS, @enumFromInt(@as(u8, @intCast(qos_raw))));

    // 権限チェック (ACL)
    if (!meta.manifest_parsed.value.canPublish(topic)) {
        if (enable_log) std.debug.print("Security Error: Plugin '{s}' (Node {}) attempted to publish to unauthorized topic '{s}'\n", .{
            meta.manifest_parsed.value.name,
            meta.node_id,
            topic,
        });
        return 1;
    }

    // マニフェストから取得した Node ID を使用して発行
    bus.publish(topic, payload, qos, meta.node_id) catch return 1;
    return 0;
}

/// Wasm側から呼び出される log API
export fn os_api_log(
    exec_env: wamr.wasm_exec_env_t,
    level: u32,
    msg_ptr: u32,
    msg_len: u32,
) u32 {
    if (!enable_log) return 0;

    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const native_ptr = wamr.wasm_runtime_addr_app_to_native(module_inst, msg_ptr);
    if (native_ptr) |ptr| {
        const msg = @as([*]const u8, @ptrCast(ptr))[0..msg_len];
        std.debug.print("[WASM LOG LVL:{}] {s}\n", .{ level, msg });
    }
    return 0;
}

/// WAMRに登録するネイティブ関数のリスト
pub fn getNativeSymbols() [2]wamr.NativeSymbol {
    return [_]wamr.NativeSymbol{
        .{ .symbol = "os_api_publish", .func_ptr = @constCast(@ptrCast(&os_api_publish)), .signature = "(iiiii)i", .attachment = null },
        .{ .symbol = "os_api_log", .func_ptr = @constCast(@ptrCast(&os_api_log)), .signature = "(iii)i", .attachment = null },
    };
}
