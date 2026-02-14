const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const event_bus = @import("event_bus.zig");

pub const WasmSubscriber = struct {
    instance: wamr.wasm_module_inst_t,
    exec_env: wamr.wasm_exec_env_t,
    node_id: u32,
    bus: *event_bus.EventBus,
    mutex: std.Thread.Mutex = .{}, // 追加: 並行実行防止用

    pub fn init(instance: wamr.wasm_module_inst_t, node_id: u32, bus: *event_bus.EventBus) !WasmSubscriber {
        const env = wamr.wasm_runtime_create_exec_env(instance, 16384);
        if (env == null) return error.ExecEnvCreationFailed;
        return WasmSubscriber{
            .instance = instance,
            .exec_env = env.?,
            .node_id = node_id,
            .bus = bus,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *WasmSubscriber) void {
        wamr.wasm_runtime_destroy_exec_env(self.exec_env);
    }

    pub fn callback(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *WasmSubscriber = @ptrCast(@alignCast(ctx orelse return));
        
        // 排他制御のロック
        self.mutex.lock();
        defer self.mutex.unlock();
        
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
            if (!wamr.wasm_runtime_call_wasm(self.exec_env, func, 4, &msg_argv)) {
                std.debug.print("WasmSubscriber: on_message failed for Node {}\n", .{self.node_id});
                if (self.bus.graph) |g| {
                    g.updateNodeStatus(self.node_id, .fault);
                    var buf: [128]u8 = undefined;
                    const payload = std.fmt.bufPrint(&buf, "{{\"node_id\":{},\"status\":\"fault\"}}", .{self.node_id}) catch "";
                    _ = self.bus.publish("core.node.status_changed", payload, .Transient, 0) catch {};
                }
            }
        }

        // メモリリセット
        if (wamr.wasm_runtime_lookup_function(self.instance, "os_reset_heap")) |reset_func| {
            var reset_argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(self.exec_env, reset_func, 0, &reset_argv);
        }
    }
};
