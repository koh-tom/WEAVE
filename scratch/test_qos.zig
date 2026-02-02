const std = @import("std");
const event_bus = @import("../src/event_bus.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // 容量 2 の小さいキューで作成
    var bus = event_bus.EventBus.init(allocator, 2);
    defer bus.deinit();

    std.debug.print("\n--- Starting QoS Reliability Test ---\n", .{});

    // 1. BestEffort でキューを埋める
    try bus.publish("test.topic", "msg1", .BestEffort, 1);
    try bus.publish("test.topic", "msg2", .BestEffort, 1);
    
    // 3つ目は BestEffort なのでドロップされるはず
    std.debug.print("Publishing 3rd message (BestEffort)... should drop\n", .{});
    try bus.publish("test.topic", "msg3", .BestEffort, 1);

    // 2. Reliable で Publish してみる。別スレッドでやらないとここでブロックして終わる
    const thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *event_bus.EventBus) void {
            std.debug.print("Thread: Publishing 4th message (Reliable)... should block\n", .{});
            b.publish("test.topic", "msg4", .Reliable, 1) catch |err| {
                std.debug.print("Thread error: {}\n", .{err});
            };
            std.debug.print("Thread: Publish (Reliable) unblocked!\n", .{});
        }
    }.run, .{&bus});

    std.time.sleep(1 * std.time.ns_per_s);
    std.debug.print("Main: Popping one message to unblock thread...\n", .{});
    if (bus.queue.pop()) |msg| {
        std.debug.print("Main: Popped '{s}'\n", .{msg.payload});
        msg.deinit(allocator);
    }

    thread.join();
    
    // 3. Transient のテスト
    std.debug.print("\n--- Starting QoS Transient Test ---\n", .{});
    try bus.publish("transient.topic", "last_value", .Transient, 1);
    
    std.debug.print("Subscribing to transient.topic...\n", .{});
    try bus.subscribe("transient.topic", 2, struct {
        fn callback(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            _ = ctx;
            std.debug.print("Subscriber: Received Transient message: {s}\n", .{msg.payload});
        }
    }.callback, null);

    std.debug.print("Test completed.\n", .{});
}
