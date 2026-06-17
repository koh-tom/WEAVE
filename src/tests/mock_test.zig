const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const MockTwitchAdapter = @import("../builtin/mock_twitch.zig").MockTwitchAdapter;

test "MockTwitchAdapter: replays scenario timing" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    const S = struct {
        fn cb(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const count_ptr: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
            _ = count_ptr.fetchAdd(1, .release);
            _ = msg;
        }
    };

    var count = std.atomic.Value(u32).init(0);
    try bus.subscribe("ext.twitch.chat.message", 99, S.cb, &count);

    const dispatcher_thread = try std.Thread.spawn(.{}, event_bus.EventBus.runDispatcher, .{&bus});

    var mock = try MockTwitchAdapter.init(allocator, &bus, 1, "test_fixtures/sample.jsonl");
    defer mock.deinit();

    mock.loop = false;

    const t = try std.Thread.spawn(.{}, MockTwitchAdapter.run, .{&mock});
    std.Thread.sleep(4 * std.time.ns_per_s);
    mock.stop();
    t.join();

    try std.testing.expectEqual(@as(u32, 3), count.load(.acquire));

    bus.stop();
    dispatcher_thread.join();
}
