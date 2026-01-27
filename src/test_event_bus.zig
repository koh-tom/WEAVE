const std = @import("std");
const EventBus = @import("event_bus.zig").EventBus;
const EventMessage = @import("event_bus.zig").EventMessage;

fn my_callback(context: ?*anyopaque, msg: *const EventMessage) void {
    _ = context;
    std.debug.print(">>> Callback received message! ID: {}, Topic: {s}, Payload: {s}\n", .{ msg.id, msg.topic, msg.payload });
}

var receive_count: u32 = 0;
fn count_callback(context: ?*anyopaque, msg: *const EventMessage) void {
    _ = context;
    _ = msg;
    receive_count += 1;
}

test "EventBus: Basic Delivery" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator, 10);
    defer bus.deinit();

    const dispatcher_thread = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});

    receive_count = 0;
    try bus.subscribe("test.topic", 100, count_callback, null);
    try bus.publish("test.topic", "hello", .Reliable, 0);
    
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), receive_count);

    bus.stop();
    dispatcher_thread.join();
}

test "EventBus: Multiple Subscribers" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator, 10);
    defer bus.deinit();

    const dispatcher_thread = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});

    receive_count = 0;
    try bus.subscribe("broadcast", 101, count_callback, null);
    try bus.subscribe("broadcast", 102, count_callback, null);
    try bus.subscribe("broadcast", 103, count_callback, null);

    try bus.publish("broadcast", "everyone see this", .Reliable, 0);
    
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 3), receive_count);

    bus.stop();
    dispatcher_thread.join();
}

test "EventBus: QoS BestEffort Drop" {
    const allocator = std.testing.allocator;
    // 小さいキューサイズで作成
    var bus = EventBus.init(allocator, 2);
    defer bus.deinit();

    // ディスパッチャを起動せずに（＝消費させずに）キューを埋める
    try bus.publish("drop.me", "1", .BestEffort, 0);
    try bus.publish("drop.me", "2", .BestEffort, 0);
    
    // 3つ目はドロップされるはず
    try bus.publish("drop.me", "3", .BestEffort, 0);
    
    try std.testing.expectEqual(@as(usize, 2), bus.queue.count);

    // ディスパッチャを起動して空にする
    const dispatcher_thread = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});
    bus.waitIdle();

    bus.stop();
    dispatcher_thread.join();
}

pub fn main() !void {
    std.debug.print("EventBus Tests completed (via main)\n", .{});
}
