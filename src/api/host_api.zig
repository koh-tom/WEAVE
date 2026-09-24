const std = @import("std");
const common = @import("../common/types.zig");
const log = @import("../common/log.zig");
const wamr = @import("../core/wamr_libs.zig").wamr;
const event_bus = @import("../core/event_bus.zig");
const topics = @import("../core/topics.zig");
const plugin_manager = @import("../core/plugin_manager.zig");
const WasmSubscriber = @import("../core/wasm_subscriber.zig").WasmSubscriber;

/// グローバル参照（Wasm callbackからアクセスするため）
pub var global_bus: ?*event_bus.EventBus = null;
pub var global_plugin_manager: ?*plugin_manager.PluginManager = null;
/// ログ出力を有効にするかどうか
pub var enable_log: bool = true;

/// ゲストから受け取る文字列の上限
const MAX_TOPIC_BYTES: u32 = 256;
const MAX_PAYLOAD_BYTES: u32 = 1024 * 1024;
const MAX_LOG_BYTES: u32 = 4096;

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
    topic_len: u32,
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

    // ゲストが渡した (ptr, len) が自分の線形メモリに収まっているか検証する (P0-7)。
    // 検証しないと len を巨大にしてホスト側のメモリを読ませ、publish で外へ持ち出せてしまう。
    if (topic_len > MAX_TOPIC_BYTES or payload_len > MAX_PAYLOAD_BYTES) return toI32(.ERROR_INVALID_PARAMETER);
    if (!wamr.wasm_runtime_validate_app_addr(module_inst, topic_ptr, topic_len)) return toI32(.ERROR_INVALID_PARAMETER);
    if (!wamr.wasm_runtime_validate_app_addr(module_inst, payload_ptr, payload_len)) return toI32(.ERROR_INVALID_PARAMETER);
    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    const p_native = wamr.wasm_runtime_addr_app_to_native(module_inst, payload_ptr);
    if (t_native == null or p_native == null) return toI32(.ERROR_INVALID_PARAMETER);

    // topic_ptr から topic_len の範囲で安全にスライスを取得 (null-terminated 前提を排除)
    const topic = @as([*]const u8, @ptrCast(t_native))[0..topic_len];
    const payload = @as([*]const u8, @ptrCast(p_native))[0..payload_len];

    // 権限チェック (ACL)
    if (!meta.manifest_parsed.value.canPublish(topic)) {
        if (enable_log) std.debug.print("Security Error: Plugin '{s}' (Node {}) attempted to publish to unauthorized topic '{s}'\n", .{
            meta.manifest_parsed.value.name,
            meta.node_id,
            topic,
        });
        emitSecurity(bus, "acl_denied", meta.node_id, meta.manifest_parsed.value.name, "publish", topic);
        return toI32(.ERROR_PERMISSION_DENIED);
    }

    // レート制限 (Token Bucket / ノード単位)。Bot 暴走がバスを埋め尽くすのを防ぐ。
    if (!meta.rate_limiter.tryConsume(std.time.milliTimestamp())) {
        if (enable_log) std.debug.print("Rate limit: Plugin '{s}' (Node {}) exceeded {d:.0} eps on '{s}' -> dropped\n", .{ meta.manifest_parsed.value.name, meta.node_id, meta.manifest_parsed.value.rate_limit_eps, topic });
        // 暴走 Bot は 1 秒に数百回ここに来るので、監査イベントは 1 秒に 1 件へ集約する
        const now = std.time.milliTimestamp();
        if (now - meta.rl_last_emit_ms >= 1000) {
            var dbuf: [320]u8 = undefined;
            const detail = std.fmt.bufPrint(&dbuf, "{s} (+{d} dropped in the last second)", .{ topic, meta.rl_suppressed }) catch topic;
            emitSecurity(bus, "rate_limited", meta.node_id, meta.manifest_parsed.value.name, "publish", detail);
            meta.rl_last_emit_ms = now;
            meta.rl_suppressed = 0;
        } else {
            meta.rl_suppressed += 1;
        }
        return toI32(.ERROR_RATE_LIMITED);
    }

    // 異なるトピックの数の上限 (A5)。ワイルドカード権限で topic を無限に作られると、Core の
    // 購読照合・グラフ・Inspector の負荷が増え続けるので、ノードごとに数を抑える
    {
        const max_topics = meta.manifest_parsed.value.limits.max_topics;
        meta.topics_mutex.lock();
        defer meta.topics_mutex.unlock();
        if (!meta.published_topics.contains(topic)) {
            if (max_topics > 0 and meta.published_topics.count() >= max_topics) {
                meta.emitLimitAggregated(bus, "max_topics", topic);
                return toI32(.ERROR_LIMIT_EXCEEDED);
            }
            const key = pm.allocator.dupe(u8, topic) catch return toI32(.ERROR_UNKNOWN);
            meta.published_topics.put(pm.allocator, key, {}) catch {
                pm.allocator.free(key);
                return toI32(.ERROR_UNKNOWN);
            };
        }
    }

    // セル単位の予算 (同じセルに属する全ノードの合計)。運用者が weave.json / --cell-budget で決める
    if (meta.subscriber) |*sub| if (sub.cell) |cell| {
        const now = std.time.milliTimestamp();
        if (!cell.tryBudget(now)) {
            if (now - meta.rl_last_emit_ms >= 1000) {
                var dbuf: [320]u8 = undefined;
                const detail = std.fmt.bufPrint(&dbuf, "{s} (cell '{s}' budget {d:.0} eps exhausted, +{d} dropped in the last second)", .{ topic, cell.name, cell.budgetEps(), meta.rl_suppressed }) catch topic;
                emitSecurity(bus, "rate_limited", meta.node_id, meta.manifest_parsed.value.name, "publish", detail);
                meta.rl_last_emit_ms = now;
                meta.rl_suppressed = 0;
            } else {
                meta.rl_suppressed += 1;
            }
            return toI32(.ERROR_RATE_LIMITED);
        }
    };

    var qos_val = if (qos >= 3) event_bus.QoS.BestEffort else @as(event_bus.QoS, @enumFromInt(@as(u32, @intCast(qos))));
    // 保持 (Transient) は state 種別のトピックだけ。event を保持すると古いイベントが新しい購読者に
    // 再配送され (P0-6 の型)、任意トピックを保持すれば保持表 (上限 4096) を埋めて Core の状態を押し出せる。
    // リモートノードと同じ規則。配送はそのまま行い、保持だけしない。
    if (qos_val == .Transient and topics.classify(topic) != .state) qos_val = .BestEffort;

    // 因果トレース: 処理中のメッセージに反応した publish は parent を持ち、深さが 1 増える。
    // 深さが上限を超えた連鎖はハウリング (ツール同士の無限反響) とみなしてバスが止める。
    const parent = current_message_id;
    const hops: u8 = if (parent != 0) current_message_hops +| 1 else 0;
    bus.publishEx(topic, payload, .{ .qos = qos_val, .source = meta.node_id, .parent_id = parent, .hops = hops }) catch |err| {
        if (err == error.QueueFull) return toI32(.ERROR_QUEUE_FULL);
        if (err == error.InvalidTopic) return toI32(.ERROR_INVALID_TOPIC);
        if (err == error.HopLimitExceeded) {
            emitSecurity(bus, "loop_detected", meta.node_id, meta.manifest_parsed.value.name, "publish", topic);
            return toI32(.ERROR_LIMIT_EXCEEDED);
        }
        return toI32(.ERROR_UNKNOWN);
    };
    return toI32(.SUCCESS);
}

/// Wasm側から呼び出される subscribe API
/// Wasm側シグネチャ: os_api_subscribe(topic_ptr: i32) -> i32
export fn os_api_subscribe(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
    topic_len: u32,
) i32 {
    const bus = global_bus orelse return toI32(.ERROR_UNKNOWN);
    const pm = global_plugin_manager orelse return toI32(.ERROR_UNKNOWN);
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);

    const meta = pm.getMetadata(module_inst) orelse return toI32(.ERROR_NOT_FOUND);
    if (topic_len > MAX_TOPIC_BYTES) return toI32(.ERROR_INVALID_PARAMETER);
    if (!wamr.wasm_runtime_validate_app_addr(module_inst, topic_ptr, topic_len)) return toI32(.ERROR_INVALID_PARAMETER);
    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr);
    if (t_native == null) return toI32(.ERROR_INVALID_PARAMETER);

    // topic_ptr から topic_len の範囲で安全にスライスを取得 (null-terminated 前提を排除)
    const topic = @as([*]const u8, @ptrCast(t_native))[0..topic_len];

    // 権限チェック (ACL)
    if (!meta.manifest_parsed.value.canSubscribe(topic)) {
        log.err("Security Error: Plugin '{s}' (Node {}) attempted to subscribe to unauthorized topic '{s}'", .{
            meta.manifest_parsed.value.name,
            meta.node_id,
            topic,
        });
        emitSecurity(bus, "acl_denied", meta.node_id, meta.manifest_parsed.value.name, "subscribe", topic);
        return toI32(.ERROR_PERMISSION_DENIED);
    }

    // 購読数の上限 (A5)。同じパターンの張り直しは冪等なので数えない
    const max_subs = meta.manifest_parsed.value.limits.max_subscriptions;
    if (max_subs > 0 and !bus.hasSubscription(meta.node_id, topic) and bus.subscriptionCount(meta.node_id) >= max_subs) {
        meta.emitLimitAggregated(bus, "max_subscriptions", topic);
        return toI32(.ERROR_LIMIT_EXCEEDED);
    }

    // 購読登録
    if (meta.subscriber) |*sub| {
        bus.subscribeEx(topic, meta.node_id, WasmSubscriber.callback, sub, .{ .cell = sub.cell }) catch |err| {
            if (err == error.InvalidTopic) return toI32(.ERROR_INVALID_TOPIC);
            return toI32(.ERROR_UNKNOWN);
        };
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

    const len = @min(msg_len, MAX_LOG_BYTES);
    if (!wamr.wasm_runtime_validate_app_addr(module_inst, msg_ptr, len)) return;
    const native_ptr = wamr.wasm_runtime_addr_app_to_native(module_inst, msg_ptr);
    if (native_ptr) |ptr| {
        const msg = @as([*]const u8, @ptrCast(ptr))[0..len];
        if (level == 3 and (std.mem.indexOf(u8, msg, "out_of_memory") != null or std.mem.indexOf(u8, msg, "out of memory") != null)) {
            wamr.wasm_runtime_set_exception(module_inst, "out_of_memory");
        }
        switch (level) {
            0 => log.debug("[{s}] {s}", .{ name, msg }),
            1 => log.info("[{s}] {s}", .{ name, msg }),
            2 => log.warn("[{s}] {s}", .{ name, msg }),
            3 => log.err("[{s}] {s}", .{ name, msg }),
            else => log.info("[{s}] {s}", .{ name, msg }),
        }
    }
}

/// セキュリティイベントを core.security.* に発行する (監査ログが購読)。
fn emitSecurity(bus: *event_bus.EventBus, subtopic: []const u8, node_id: u32, name: []const u8, action: []const u8, topic: []const u8) void {
    var topic_buf: [96]u8 = undefined;
    const full_topic = std.fmt.bufPrint(&topic_buf, "core.security.{s}", .{subtopic}) catch return;
    // JSON は std.json で組み立てる (トピック名に引用符などが入っても監査ログが壊れない, P1-3)
    var buf: [768]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    w.print("{f}", .{std.json.fmt(.{ .node_id = node_id, .name = name, .action = action, .topic = topic }, .{})}) catch return;
    _ = bus.publish(full_topic, w.buffered(), .Transient, 0) catch {};
}

/// Wasm側から呼び出される unsubscribe API
/// Wasm側シグネチャ: os_api_unsubscribe(topic_ptr: i32, topic_len: i32) -> i32
export fn os_api_unsubscribe(
    exec_env: wamr.wasm_exec_env_t,
    topic_ptr: u32,
    topic_len: u32,
) i32 {
    const bus = global_bus orelse return toI32(.ERROR_UNKNOWN);
    const pm = global_plugin_manager orelse return toI32(.ERROR_UNKNOWN);
    const module_inst = wamr.wasm_runtime_get_module_inst(exec_env);
    const meta = pm.getMetadata(module_inst) orelse return toI32(.ERROR_NOT_FOUND);
    if (topic_len > MAX_TOPIC_BYTES) return toI32(.ERROR_INVALID_PARAMETER);
    if (!wamr.wasm_runtime_validate_app_addr(module_inst, topic_ptr, topic_len)) return toI32(.ERROR_INVALID_PARAMETER);
    const t_native = wamr.wasm_runtime_addr_app_to_native(module_inst, topic_ptr) orelse return toI32(.ERROR_INVALID_PARAMETER);
    const topic = @as([*]const u8, @ptrCast(t_native))[0..topic_len];
    bus.unsubscribe(meta.node_id, topic);
    if (bus.graph) |g| g.removeSubscription(meta.node_id, topic);
    return toI32(.SUCCESS);
}

/// 壁時計 (UNIX ミリ秒)
export fn os_api_now(exec_env: wamr.wasm_exec_env_t) i64 {
    _ = exec_env;
    return std.time.milliTimestamp();
}

/// 処理中のメッセージのタイムスタンプ (UNIX ミリ秒)。壁時計ではないので、
/// 記録したイベントを再生しても同じ結果になる (決定的なテストと再現に使える)。
export fn os_api_message_timestamp(exec_env: wamr.wasm_exec_env_t) i64 {
    _ = exec_env;
    return current_message_timestamp;
}

pub threadlocal var current_message_timestamp: i64 = 0;
/// 処理中のメッセージ (on_message 中だけ非 0)。ここから publish されたものの parent になる
pub threadlocal var current_message_id: u64 = 0;
pub threadlocal var current_message_hops: u8 = 0;

export fn os_api_current_timestamp(
    exec_env: wamr.wasm_exec_env_t,
) i64 {
    _ = exec_env;
    return current_message_timestamp;
}

/// WAMRに登録するネイティブ関数のリスト (Host API v1)
/// シグネチャはWasm側から見た型（exec_envは含めない）
///   publish:           (topic_ptr, topic_len, payload_ptr, payload_len, qos) -> i32 = "(iiiii)i"
///   subscribe:         (topic_ptr, topic_len) -> i32                                 = "(ii)i"
///   unsubscribe:       (topic_ptr, topic_len) -> i32                                 = "(ii)i"
///   log:               (level, msg_ptr, msg_len) -> void                             = "(iii)"
///   message_timestamp: () -> i64                                                     = "()I"
///   current_timestamp: () -> i64  (message_timestamp の旧名。1.x の間は残す)          = "()I"
///   now:               () -> i64                                                     = "()I"
pub fn getNativeSymbols() [7]wamr.NativeSymbol {
    return [_]wamr.NativeSymbol{
        .{ .symbol = "os_api_publish", .func_ptr = @ptrCast(@constCast(&os_api_publish)), .signature = "(iiiii)i", .attachment = null },
        .{ .symbol = "os_api_subscribe", .func_ptr = @ptrCast(@constCast(&os_api_subscribe)), .signature = "(ii)i", .attachment = null },
        .{ .symbol = "os_api_unsubscribe", .func_ptr = @ptrCast(@constCast(&os_api_unsubscribe)), .signature = "(ii)i", .attachment = null },
        .{ .symbol = "os_api_log", .func_ptr = @ptrCast(@constCast(&os_api_log)), .signature = "(iii)", .attachment = null },
        .{ .symbol = "os_api_message_timestamp", .func_ptr = @ptrCast(@constCast(&os_api_message_timestamp)), .signature = "()I", .attachment = null },
        .{ .symbol = "os_api_current_timestamp", .func_ptr = @ptrCast(@constCast(&os_api_current_timestamp)), .signature = "()I", .attachment = null },
        .{ .symbol = "os_api_now", .func_ptr = @ptrCast(@constCast(&os_api_now)), .signature = "()I", .attachment = null },
    };
}
