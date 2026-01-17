const std = @import("std");
const event_bus = @import("event_bus.zig");
const EventBus = event_bus.EventBus;
const QoS = event_bus.QoS;

fn my_callback(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
    _ = context;
    std.debug.print(">>> Callback received message! ID: {}, Topic: {s}, Payload: {s}\n", .{ msg.id, msg.topic, msg.payload });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Testing Event Bus (Pure Zig)...\n", .{});

    // 容量10のバスを初期化
    var bus = EventBus.init(allocator, 10);
    defer bus.deinit();

    // ディスパッチャスレッドは立てずに、手動でテストするか、
    // あるいはスレッドを立ててテストする。ここではスレッドを立てる。
    const dispatcher_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *EventBus) void {
            b.registerDispatcherThread();
            while (true) {
                if (b.queue.pop()) |msg| {
                    b.dispatch(&msg);
                    msg.deinit(b.allocator);
                    b.notifyPotentialIdle();
                } else {
                    b.notifyPotentialIdle();
                    break;
                }
            }
        }
    }.run, .{&bus});

    // Node 2 が購読 (contextはnull)
    try bus.subscribe("ext.twitch.chat", 2, my_callback, null);

    // Node 1 が発行
    std.debug.print("Publishing from Node 1...\n", .{});
    try bus.publish("ext.twitch.chat", "{\"user\": \"koh\", \"msg\": \"hello!\"}", .BestEffort, 1);

    // 全ての配送が終わるのを待つ
    bus.waitIdle();

    // Node 2 が発行 (自分自身には届かないはずなので、ログは出ないはず)
    std.debug.print("Publishing from Node 2 (Self-loop check)...\n", .{});
    try bus.publish("ext.twitch.chat", "{\"user\": \"bot\", \"msg\": \"hi koh\"}", .BestEffort, 2);

    bus.waitIdle();

    std.debug.print("Test Finished. Shutting down...\n", .{});
    bus.stop();
    dispatcher_thread.join();
}
