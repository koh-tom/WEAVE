const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const event_bus = @import("event_bus.zig");

pub const WasmSubscriber = struct {
    instance: wamr.wasm_module_inst_t,
    node_id: u32,
    bus: *event_bus.EventBus,
    manager: *@import("plugin_manager.zig").PluginManager, // 追加
    mutex: std.Thread.Mutex = .{},

    // リスタートスロットリング用
    consecutive_failures: u32 = 0,
    last_failure_time: i64 = 0,

    const MAX_RESTART_ATTEMPTS: u32 = 5;
    const BASE_BACKOFF_MS: i64 = 1000; // 1秒

    // WASM exec_env のスタックサイズ (Zig std.json の再帰に対応)
    const EXEC_ENV_STACK_SIZE: u32 = 128 * 1024;

    pub fn init(instance: wamr.wasm_module_inst_t, node_id: u32, bus: *event_bus.EventBus, manager: *@import("plugin_manager.zig").PluginManager) !WasmSubscriber {
        return WasmSubscriber{
            .instance = instance,
            .node_id = node_id,
            .bus = bus,
            .manager = manager,
            .mutex = .{},
            .consecutive_failures = 0,
            .last_failure_time = 0,
        };
    }

    pub fn deinit(self: *WasmSubscriber) void {
        _ = self;
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
        
        const alloc_func = wamr.wasm_runtime_lookup_function(self.instance, "os_alloc");
        if (alloc_func == null) return;

        // Topicコピー
        var argv_t = [_]u32{@intCast(msg.topic.len)};
        if (!wamr.wasm_runtime_call_wasm(env, alloc_func, 1, &argv_t)) return;
        const t_ptr = argv_t[0];
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, t_ptr).?))[0..msg.topic.len], msg.topic);

        // Payloadコピー
        var argv_p = [_]u32{@intCast(msg.payload.len)};
        if (!wamr.wasm_runtime_call_wasm(env, alloc_func, 1, &argv_p)) return;
        const p_ptr = argv_p[0];
        @memcpy(@as([*]u8, @ptrCast(wamr.wasm_runtime_addr_app_to_native(self.instance, p_ptr).?))[0..msg.payload.len], msg.payload);

        // 計測開始
        const start_time = std.time.nanoTimestamp();

        // on_message実行
        if (wamr.wasm_runtime_lookup_function(self.instance, "on_message")) |func| {
            var msg_argv = [_]u32{ t_ptr, @intCast(msg.topic.len), p_ptr, @intCast(msg.payload.len) };
            if (!wamr.wasm_runtime_call_wasm(env, func, 4, &msg_argv)) {
                if (wamr.wasm_runtime_get_exception(self.instance)) |exc| {
                    std.debug.print("WasmSubscriber: Execution TRAPPED! Exception: {s}\n", .{exc});
                } else {
                    std.debug.print("WasmSubscriber: Execution failed without exception.\n", .{});
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
                    std.debug.print("WasmSubscriber: Node {} has failed {} times. Giving up on automatic restart.\n", .{self.node_id, self.consecutive_failures});
                    return;
                }
                
                // 指数バックオフチェック
                const backoff_ms = BASE_BACKOFF_MS * (@as(i64, 1) << @intCast(@min(self.consecutive_failures - 1, 10)));
                const elapsed_retry = now - self.last_failure_time;
                if (self.last_failure_time > 0 and elapsed_retry < backoff_ms) {
                    std.debug.print("WasmSubscriber: Node {} restart throttled (attempt {}/{}, backoff {}ms, elapsed {}ms)\n", 
                        .{self.node_id, self.consecutive_failures, MAX_RESTART_ATTEMPTS, backoff_ms, elapsed_retry});
                    return;
                }
                self.last_failure_time = now;
                
                // 自動復旧 (Restart) のトリガー
                std.debug.print("WasmSubscriber: Triggering automatic restart for Node {} (attempt {}/{})\n", .{self.node_id, self.consecutive_failures, MAX_RESTART_ATTEMPTS});
                self.manager.restartPlugin(self.node_id, self.bus) catch |err| {
                    std.debug.print("WasmSubscriber: Auto-restart failed for Node {}: {any}\n", .{self.node_id, err});
                };
                return; // ← インスタンスが再生成されたため、旧インスタンスのメモリリセットに進まない
            }

            // 計測終了とパブリッシュ
            const end_time = std.time.nanoTimestamp();
            const exec_time_ns = end_time - start_time;
            
            // メモリサイズ取得 (WAMR API)
            // wasm_runtime_get_app_addr_range を使用してリニアメモリの範囲を取得
            var start_offset: u64 = 0;
            var end_offset: u64 = 0;
            const success = wamr.wasm_runtime_get_app_addr_range(self.instance, @as(u64, 0), &start_offset, &end_offset);
            const mem_size = if (success)
                end_offset - start_offset
            else
                0;

            var metric_buf: [256]u8 = undefined;
            const metric_payload = std.fmt.bufPrint(&metric_buf, 
                "{{\"node_id\":{},\"exec_time_ns\":{},\"memory_bytes\":{}}}", 
                .{self.node_id, exec_time_ns, mem_size}
            ) catch "";
            
            if (metric_payload.len > 0) {
                _ = self.bus.publish("core.node.metrics", metric_payload, .BestEffort, self.node_id) catch {};
            }
        }

        // 成功した場合は連続失敗カウンタをリセット
        self.consecutive_failures = 0;

        // メモリリセット
        if (wamr.wasm_runtime_lookup_function(self.instance, "os_reset_heap")) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, reset_func, 0, &reset_argv);
        }
    }
};
