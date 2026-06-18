const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const event_bus = @import("event_bus.zig");
const log = @import("../common/log.zig");

pub const WasmSubscriber = struct {
    instance: wamr.wasm_module_inst_t,
    node_id: u32,
    bus: *event_bus.EventBus,
    manager: *@import("plugin_manager.zig").PluginManager, // 追加
    mutex: std.Thread.Mutex = .{},

    // リスタートスロットリング用
    consecutive_failures: u32 = 0,
    last_failure_time: i64 = 0,

    // 関数ハンドルキャッシュ
    func_os_alloc: ?wamr.wasm_function_inst_t = null,
    func_on_message: ?wamr.wasm_function_inst_t = null,
    func_get_heap_usage: ?wamr.wasm_function_inst_t = null,
    func_os_reset_heap: ?wamr.wasm_function_inst_t = null,

    const MAX_RESTART_ATTEMPTS: u32 = 5;
    const BASE_BACKOFF_MS: i64 = 1000; // 1秒

    // WASM exec_env のスタックサイズ (Zig std.json の再帰に対応)
    const EXEC_ENV_STACK_SIZE: u32 = 128 * 1024;

    pub fn init(instance: wamr.wasm_module_inst_t, node_id: u32, bus: *event_bus.EventBus, manager: *@import("plugin_manager.zig").PluginManager) !WasmSubscriber {
        var sub = WasmSubscriber{
            .instance = instance,
            .node_id = node_id,
            .bus = bus,
            .manager = manager,
            .mutex = .{},
            .consecutive_failures = 0,
            .last_failure_time = 0,
            .func_os_alloc = null,
            .func_on_message = null,
            .func_get_heap_usage = null,
            .func_os_reset_heap = null,
        };
        sub.updateInstance(instance);
        return sub;
    }

    pub fn updateInstance(self: *WasmSubscriber, new_inst: wamr.wasm_module_inst_t) void {
        self.instance = new_inst;
        self.func_os_alloc = wamr.wasm_runtime_lookup_function(new_inst, "os_alloc");
        self.func_on_message = wamr.wasm_runtime_lookup_function(new_inst, "on_message");
        self.func_get_heap_usage = wamr.wasm_runtime_lookup_function(new_inst, "os_api_get_heap_usage");
        self.func_os_reset_heap = wamr.wasm_runtime_lookup_function(new_inst, "os_reset_heap");
    }

    pub fn deinit(self: *WasmSubscriber) void {
        _ = self;
    }

    fn handleFault(self: *WasmSubscriber, env: wamr.wasm_exec_env_t, exception_msg: []const u8) void {
        // 障害分離 (Fault Isolation) 時のフェイルセーフ通知
        var fault_buf: [256]u8 = undefined;
        const fault_payload = std.fmt.bufPrint(&fault_buf, "{{\"node_id\":{},\"exception\":\"{s}\"}}", .{ self.node_id, exception_msg }) catch "";
        if (fault_payload.len > 0) {
            _ = self.bus.publish("core.node.fault", fault_payload, .Transient, self.node_id) catch |err| {
                log.err("WasmSubscriber: Failed to publish fault event: {any}", .{err});
            };
        }

        if (self.bus.graph) |g| {
            g.updateNodeStatus(self.node_id, .fault);
            var buf: [128]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"node_id\":{},\"status\":\"fault\"}}", .{self.node_id}) catch "";
            _ = self.bus.publish("core.node.status_changed", payload, .Transient, 0) catch {};
        }

        // リスタートスロットリング
        self.consecutive_failures += 1;
        const now = std.time.milliTimestamp();

        if (self.consecutive_failures >= MAX_RESTART_ATTEMPTS) {
            log.err("WasmSubscriber: Node {} has failed {} times. Giving up on automatic restart.", .{ self.node_id, self.consecutive_failures });
            if (self.func_os_reset_heap) |reset_func| {
                var reset_argv = [_]u32{0};
                _ = wamr.wasm_runtime_call_wasm(env, reset_func, 0, &reset_argv);
            }
            return;
        }

        // 指数バックオフチェック
        const backoff_ms = BASE_BACKOFF_MS * (@as(i64, 1) << @intCast(@min(self.consecutive_failures - 1, 10)));
        const elapsed_retry = now - self.last_failure_time;
        if (self.last_failure_time > 0 and elapsed_retry < backoff_ms) {
            log.warn("WasmSubscriber: Node {} restart throttled (attempt {}/{}, backoff {}ms, elapsed {}ms)", .{ self.node_id, self.consecutive_failures, MAX_RESTART_ATTEMPTS, backoff_ms, elapsed_retry });
            if (self.func_os_reset_heap) |reset_func| {
                var reset_argv = [_]u32{0};
                _ = wamr.wasm_runtime_call_wasm(env, reset_func, 0, &reset_argv);
            }
            return;
        }
        self.last_failure_time = now;

        // 自動復旧 (Restart) のトリガー
        log.info("WasmSubscriber: Triggering automatic restart for Node {} (attempt {}/{})", .{ self.node_id, self.consecutive_failures, MAX_RESTART_ATTEMPTS });
        self.manager.restartPlugin(self.node_id, self.bus) catch |err| {
            log.err("WasmSubscriber: Auto-restart failed for Node {}: {any}", .{ self.node_id, err });
        };
    }

    pub fn callback(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *WasmSubscriber = @ptrCast(@alignCast(ctx orelse return));

        // 排他制御のロック
        self.mutex.lock();
        defer self.mutex.unlock();

        // リスタート上限に達している場合はコールバックを無視
        if (self.consecutive_failures >= MAX_RESTART_ATTEMPTS) {
            return;
        }

        // 呼び出しスレッドごとにexec_envを作成（WAMRスレッドセーフティ）
        const env = wamr.wasm_runtime_create_exec_env(self.instance, EXEC_ENV_STACK_SIZE);
        if (env == null) return;
        defer wamr.wasm_runtime_destroy_exec_env(env);

        const alloc_func = self.func_os_alloc orelse return;

        // Topicコピー
        var argv_t = [_]u32{@intCast(msg.topic.len)};
        if (!wamr.wasm_runtime_call_wasm(env, alloc_func, 1, &argv_t)) {
            var exception_msg: []const u8 = "unknown execution trap";
            if (wamr.wasm_runtime_get_exception(self.instance)) |exc| {
                const raw_exc = std.mem.span(exc);
                if (std.mem.indexOf(u8, raw_exc, "out of memory") != null or std.mem.indexOf(u8, raw_exc, "out_of_memory") != null) {
                    exception_msg = "out_of_memory";
                } else {
                    exception_msg = raw_exc;
                }
            }
            self.handleFault(env, exception_msg);
            return;
        }
        const t_ptr = argv_t[0];
        if (t_ptr == 0) {
            self.handleFault(env, "out_of_memory");
            return;
        }
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, t_ptr).?))[0..msg.topic.len], msg.topic);

        // Payloadコピー
        var argv_p = [_]u32{@intCast(msg.payload.len)};
        if (!wamr.wasm_runtime_call_wasm(env, alloc_func, 1, &argv_p)) {
            var exception_msg: []const u8 = "unknown execution trap";
            if (wamr.wasm_runtime_get_exception(self.instance)) |exc| {
                const raw_exc = std.mem.span(exc);
                if (std.mem.indexOf(u8, raw_exc, "out of memory") != null or std.mem.indexOf(u8, raw_exc, "out_of_memory") != null) {
                    exception_msg = "out_of_memory";
                } else {
                    exception_msg = raw_exc;
                }
            }
            self.handleFault(env, exception_msg);
            return;
        }
        const p_ptr = argv_p[0];
        if (p_ptr == 0) {
            self.handleFault(env, "out_of_memory");
            return;
        }
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, p_ptr).?))[0..msg.payload.len], msg.payload);

        // 計測開始
        const start_time = std.time.nanoTimestamp();

        // on_message実行
        if (self.func_on_message) |func| {
            @import("../api/host_api.zig").current_message_timestamp = msg.timestamp;
            var msg_argv = [_]u32{ t_ptr, @intCast(msg.topic.len), p_ptr, @intCast(msg.payload.len) };
            if (!wamr.wasm_runtime_call_wasm(env, func, 4, &msg_argv)) {
                var exception_msg: []const u8 = "unknown execution trap";
                if (wamr.wasm_runtime_get_exception(self.instance)) |exc| {
                    const raw_exc = std.mem.span(exc);
                    if (std.mem.indexOf(u8, raw_exc, "out of memory") != null or std.mem.indexOf(u8, raw_exc, "out_of_memory") != null) {
                        exception_msg = "out_of_memory";
                    } else {
                        exception_msg = raw_exc;
                    }
                    log.err("WasmSubscriber: Execution TRAPPED! Exception: {s}", .{exception_msg});
                } else {
                    log.err("WasmSubscriber: Execution failed without exception.", .{});
                }

                self.handleFault(env, exception_msg);
                return;
            }

            // 計測終了とパブリッシュ
            const end_time = std.time.nanoTimestamp();
            const exec_time_ns = end_time - start_time;

            // メモリサイズ取得 (正確な heap usage を Wasm 側から取得)
            var mem_size: u32 = 0;
            if (self.func_get_heap_usage) |usage_func| {
                var usage_argv = [_]u32{0};
                if (wamr.wasm_runtime_call_wasm(env, usage_func, 0, &usage_argv)) {
                    mem_size = usage_argv[0];
                }
            }

            var metric_buf: [256]u8 = undefined;
            const metric_payload = std.fmt.bufPrint(&metric_buf, "{{\"node_id\":{},\"exec_time_ns\":{},\"memory_bytes\":{}}}", .{ self.node_id, exec_time_ns, mem_size }) catch "";

            if (metric_payload.len > 0) {
                _ = self.bus.publish("core.node.metrics", metric_payload, .BestEffort, self.node_id) catch {};
            }
        }

        // 成功した場合は連続失敗カウンタをリセット
        self.consecutive_failures = 0;

        // メモリリセット
        if (self.func_os_reset_heap) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, reset_func, 0, &reset_argv);
        }
    }
};
