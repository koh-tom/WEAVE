const std = @import("std");

/// イベントのQoSレベル
pub const QoS = enum(u8) {
    BestEffort = 0,
    Reliable = 1,
    Transient = 2,
};

/// ホスト内で管理されるメッセージのエンベロープ
pub const EventMessage = struct {
    id: u64,
    topic: []const u8,
    timestamp: i64,
    source_node_id: u32,
    qos: QoS,
    payload: []const u8,

    pub fn deinit(self: *EventMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload);
    }
};

/// 購読コールバック (contextポインタをサポート)
pub const SubscribeCallback = *const fn (context: ?*anyopaque, msg: *const EventMessage) void;

pub const Subscriber = struct {
    node_id: u32,
    context: ?*anyopaque,
    callback: SubscribeCallback,
};

/// Event Bus コア実装
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    subscribers: std.StringHashMap(std.ArrayListUnmanaged(Subscriber)),
    next_msg_id: u64,
    verbose: bool,

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return EventBus{
            .allocator = allocator,
            .subscribers = std.StringHashMap(std.ArrayListUnmanaged(Subscriber)).init(allocator),
            .next_msg_id = 1,
            .verbose = true,
        };
    }

    pub fn deinit(self: *EventBus) void {
        var it = self.subscribers.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscribers.deinit();
    }

    pub fn subscribe(self: *EventBus, topic: []const u8, node_id: u32, callback: SubscribeCallback, context: ?*anyopaque) !void {
        const result = try self.subscribers.getOrPut(topic);
        if (!result.found_existing) {
            result.key_ptr.* = try self.allocator.dupe(u8, topic);
            result.value_ptr.* = .{};
        }
        try result.value_ptr.append(self.allocator, Subscriber{
            .node_id = node_id,
            .context = context,
            .callback = callback,
        });
        if (self.verbose) std.debug.print("Node {} subscribed to topic '{s}'\n", .{ node_id, topic });
    }

    pub fn publish(
        self: *EventBus,
        topic: []const u8,
        payload: []const u8,
        qos: QoS,
        source_node_id: u32,
    ) !void {
        if (self.verbose) std.debug.print("Publishing to '{s}' from Node {} (QoS: {any})\n", .{ topic, source_node_id, qos });

        const msg = EventMessage{
            .id = self.next_msg_id,
            .topic = topic,
            .timestamp = std.time.milliTimestamp(),
            .source_node_id = source_node_id,
            .qos = qos,
            .payload = payload,
        };
        self.next_msg_id += 1;

        if (self.subscribers.get(topic)) |subs| {
            for (subs.items) |sub| {
                if (sub.node_id != source_node_id) {
                    sub.callback(sub.context, &msg);
                }
            }
        }
    }
};
