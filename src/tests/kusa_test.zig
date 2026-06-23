const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const plugin_manager = @import("../core/plugin_manager.zig");
const wamr = @import("../core/wamr_libs.zig").wamr;
const PluginMetadata = plugin_manager.PluginMetadata;

test "WasmSubscriber: kusa_node logic test" {
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

    const wasm_path = "wasm-apps/kusa_node.wasm";
    const manifest_path = "wasm-apps/kusa_node.json";

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);

    const module = try runtime.loadModule(wasm_buffer);
    const module_inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);

    const meta = try pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &bus);

    const ObsContext = struct {
        visible_events: std.array_list.Managed(bool),
        pub fn init(alloc: std.mem.Allocator) @This() {
            return .{ .visible_events = std.array_list.Managed(bool).init(alloc) };
        }
        pub fn deinit(self: *@This()) void {
            self.visible_events.deinit();
        }
    };

    const S = struct {
        fn cb(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const context = @as(*ObsContext, @ptrCast(@alignCast(ctx)));
            var parsed = std.json.parseFromSlice(struct {
                sceneName: []const u8,
                itemName: []const u8,
                visible: bool,
            }, std.testing.allocator, msg.payload, .{}) catch return;
            defer parsed.deinit();

            if (std.mem.eql(u8, parsed.value.sceneName, "Overlay") and std.mem.eql(u8, parsed.value.itemName, "KusaEffect")) {
                context.visible_events.append(parsed.value.visible) catch {};
            }
        }
    };

    var obs_ctx = ObsContext.init(allocator);
    defer obs_ctx.deinit();
    try bus.subscribe("ext.obs.scene.item_control", 99, S.cb, &obs_ctx);

    const thread = try std.Thread.spawn(.{}, event_bus.EventBus.runDispatcher, .{&bus});

    // Initialize plugin
    if (meta.instance) |inst| {
        const func_init = wamr.wasm_runtime_lookup_function(inst, "on_init") orelse return error.FunctionNotFound;
        const env_init = wamr.wasm_runtime_create_exec_env(inst, 16384);
        var argv_init = [_]u32{0};
        _ = wamr.wasm_runtime_call_wasm(env_init, func_init, 0, &argv_init);
        wamr.wasm_runtime_destroy_exec_env(env_init);
    }

    // 1. Send 9 messages containing 'w' at t = 1000. Under threshold (10), so no event should be published.
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        try bus.publishWithMessageTimestamp("ext.twitch.chat.message", "{\"user\":\"user\",\"message\":\"w\"}", .BestEffort, 0, 1000);
    }
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 0), obs_ctx.visible_events.items.len);

    // 2. Send the 10th message containing '草' at t = 1500. Now threshold is reached within 3s window.
    // It should trigger visible=true.
    try bus.publishWithMessageTimestamp("ext.twitch.chat.message", "{\"user\":\"user\",\"message\":\"草\"}", .BestEffort, 0, 1500);
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), obs_ctx.visible_events.items.len);
    try std.testing.expectEqual(true, obs_ctx.visible_events.items[0]);

    // 3. Send message containing 'w' at t = 11499 (less than 10 seconds since t=1500).
    // It should not trigger hide or show event.
    try bus.publishWithMessageTimestamp("ext.twitch.chat.message", "{\"user\":\"user\",\"message\":\"w\"}", .BestEffort, 0, 11499);
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 1), obs_ctx.visible_events.items.len);

    // 4. Send message at t = 11500 (exactly 10 seconds since trigger at t=1500).
    // This should trigger auto-hide (visible=false).
    try bus.publishWithMessageTimestamp("ext.twitch.chat.message", "{\"user\":\"user\",\"message\":\"no grass message\"}", .BestEffort, 0, 11500);
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), obs_ctx.visible_events.items.len);
    try std.testing.expectEqual(false, obs_ctx.visible_events.items[1]);

    // 5. Send 10 messages containing 'w' within 3 seconds, ending at t = 16000 (within 15s cooldown since t=1500).
    // It should NOT trigger show event.
    i = 0;
    while (i < 10) : (i += 1) {
        try bus.publishWithMessageTimestamp("ext.twitch.chat.message", "{\"user\":\"user\",\"message\":\"w\"}", .BestEffort, 0, 16000);
    }
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 2), obs_ctx.visible_events.items.len);

    // 6. Send 10 messages containing 'w' within 3 seconds, ending at t = 17000 (after 15s cooldown has passed since t=1500).
    // This should trigger show event (visible=true).
    i = 0;
    while (i < 10) : (i += 1) {
        try bus.publishWithMessageTimestamp("ext.twitch.chat.message", "{\"user\":\"user\",\"message\":\"w\"}", .BestEffort, 0, 17000);
    }
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 3), obs_ctx.visible_events.items.len);
    try std.testing.expectEqual(true, obs_ctx.visible_events.items[2]);

    bus.stop();
    thread.join();
}
