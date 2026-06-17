const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const plugin_manager = @import("../core/plugin_manager.zig");
const wamr = @import("../core/wamr_libs.zig").wamr;
const PluginMetadata = plugin_manager.PluginMetadata;

test "WasmSubscriber: OOM auto restart" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("../core/wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = plugin_manager.PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
    }

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    const wasm_path = "wasm-apps/bad_node.wasm";
    const manifest_path = "wasm-apps/bad_node.json";

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);

    const module = try runtime.loadModule(wasm_buffer);
    const module_inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);

    const meta = try pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &bus);

    var fault_count: u32 = 0;
    var received_exception: [128]u8 = undefined;
    var received_node_id: u32 = 0;

    const TestContext = struct {
        fc: *u32,
        exc: []u8,
        nid: *u32,
    };

    const S = struct {
        fn cb(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const context = @as(*TestContext, @ptrCast(@alignCast(ctx)));
            context.fc.* += 1;

            var parsed = std.json.parseFromSlice(struct { node_id: u32, exception: []const u8 }, std.testing.allocator, msg.payload, .{}) catch return;
            defer parsed.deinit();

            context.nid.* = parsed.value.node_id;
            @memcpy(context.exc[0..parsed.value.exception.len], parsed.value.exception);
            context.exc[parsed.value.exception.len] = 0;
        }
    };

    var context_struct = TestContext{ .fc = &fault_count, .exc = &received_exception, .nid = &received_node_id };
    try bus.subscribe("core.node.fault", 99, S.cb, &context_struct);

    const thread = try std.Thread.spawn(.{}, event_bus.EventBus.runDispatcher, .{&bus});

    // 1. Initialize plugin
    if (meta.instance) |inst| {
        const func_init = wamr.wasm_runtime_lookup_function(inst, "on_init") orelse return error.FunctionNotFound;
        const env_init = wamr.wasm_runtime_create_exec_env(inst, 16384);
        var argv_init = [_]u32{0};
        _ = wamr.wasm_runtime_call_wasm(env_init, func_init, 0, &argv_init);
        wamr.wasm_runtime_destroy_exec_env(env_init);
    }

    // 2. Publish ALLOC_UNTIL_OOM to trigger OOM trap
    try bus.publish("allowed.topic", "ALLOC_UNTIL_OOM", .BestEffort, 0);
    bus.waitIdle();

    // Verify first OOM fault notification
    try std.testing.expectEqual(@as(u32, 1), fault_count);
    try std.testing.expectEqual(@as(u32, 100), received_node_id);
    const exc_str = std.mem.span(@as([*c]const u8, @ptrCast(&received_exception)));
    try std.testing.expectEqualStrings("out_of_memory", exc_str);

    // 3. Repeat OOM trigger to increment consecutive failures up to MAX_RESTART_ATTEMPTS (5)
    // Note: Restarting bad_node will execute on_init which subscribes to allowed.topic again,
    // resulting in a duplicate subscription. This means a single publish triggers multiple callbacks.

    // Publish 2nd time: triggers 2nd and 3rd faults (fault_count becomes 3)
    try bus.publish("allowed.topic", "ALLOC_UNTIL_OOM", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 3), fault_count);

    // Publish 3rd time: triggers 4th and 5th faults (fault_count becomes 5)
    try bus.publish("allowed.topic", "ALLOC_UNTIL_OOM", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 5), fault_count);

    // Check consecutive_failures value is 5
    var pm_it = pm.plugins.iterator();
    var found_meta: ?*PluginMetadata = null;
    while (pm_it.next()) |entry| {
        if (entry.value_ptr.*.node_id == 100) {
            found_meta = entry.value_ptr.*;
            break;
        }
    }
    const meta_after = found_meta orelse return error.MetaNotFound;
    if (meta_after.subscriber) |sub| {
        try std.testing.expectEqual(@as(u32, 5), sub.consecutive_failures);
    } else {
        return error.SubscriberNotFound;
    }

    // 4. Publish 4th time and verify it is ignored (no new fault event, fault_count remains 5)
    try bus.publish("allowed.topic", "ALLOC_UNTIL_OOM", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 5), fault_count);

    bus.stop();
    thread.join();
}
