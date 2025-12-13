const std = @import("std");
const EventBus = @import("event_bus.zig").EventBus;
const EventMessage = @import("event_bus.zig").EventMessage;
const QoS = @import("event_bus.zig").QoS;

fn my_callback(msg: *const EventMessage) void {
    std.debug.print(">>> Callback received message! ID: {}, Topic: {s}, Payload: {s}\n", .{ msg.id, msg.topic, msg.payload });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var bus = EventBus.init(allocator);
    defer bus.deinit();

    std.debug.print("Testing Event Bus...\n", .{});

    // Node 2 が購読
    try bus.subscribe("ext.twitch.chat", 2, my_callback);

    // Node 1 が発行
    try bus.publish("ext.twitch.chat", "{\"user\": \"koh\", \"msg\": \"hello!\"}", QoS.BestEffort, 1);

    // Node 2 が発行 (自分自身には届かないはず)
    try bus.publish("ext.twitch.chat", "{\"user\": \"bot\", \"msg\": \"hi koh\"}", QoS.BestEffort, 2);
}
