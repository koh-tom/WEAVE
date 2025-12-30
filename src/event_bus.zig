const std = @import("std");

/// イベントのQoSレベル
pub const QoS = enum(u8) {
    BestEffort = 0,
    Reliable = 1,
    Transient = 2,
};

/// ホスト内で管理されるメッセージのエンベロープ
/// キューイングされるため、文字列の所有権を持つ必要がある
pub const EventMessage = struct {
    id: u64,
    topic: []const u8,
    timestamp: i64,
    source_node_id: u32,
    qos: QoS,
    payload: []const u8,

    /// ヒープにデータをコピーして新しいEventMessageを作成
    pub fn clone(self: EventMessage, allocator: std.mem.Allocator) !EventMessage {
        return EventMessage{
            .id = self.id,
            .topic = try allocator.dupe(u8, self.topic),
            .timestamp = self.timestamp,
            .source_node_id = self.source_node_id,
            .qos = self.qos,
            .payload = try allocator.dupe(u8, self.payload),
        };
    }

    pub fn deinit(self: EventMessage, allocator: std.mem.Allocator) void {
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

/// MPSC イベントキュー
/// 非同期配送のために、Publishスレッドから配送スレッドへデータを渡す
pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    queue: std.TailQueue(EventMessage),
    mutex: std.Thread.Mutex,
    cond: std.Thread.Condition,
    is_shutdown: bool,

    pub fn init(allocator: std.mem.Allocator) EventQueue {
        return EventQueue{
            .allocator = allocator,
            .queue = .{},
            .mutex = .{},
            .cond = .{},
            .is_shutdown = false,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        while (self.queue.popFirst()) |node| {
            node.data.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.is_shutdown = true;
        self.cond.broadcast();
    }

    /// キューにイベントを追加
    pub fn push(self: *EventQueue, msg: EventMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return error.QueueShutdown;

        const node = try self.allocator.create(std.TailQueue(EventMessage).Node);
        node.data = try msg.clone(self.allocator);
        self.queue.append(node);
        
        self.cond.signal();
    }

    /// キューからイベントを取り出す (ブロッキング)
    pub fn pop(self: *EventQueue) ?EventMessage {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.queue.len == 0 and !self.is_shutdown) {
            self.cond.wait(&self.mutex);
        }

        if (self.queue.popFirst()) |node| {
            const msg = node.data;
            self.allocator.destroy(node);
            return msg;
        }

        return null;
    }
};

/// Event Bus コア実装 (スレッドセーフ)
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    subscribers: std.StringHashMap(std.ArrayListUnmanaged(Subscriber)),
    next_msg_id: u64,
    verbose: bool,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) EventBus {
        return EventBus{
            .allocator = allocator,
            .subscribers = std.StringHashMap(std.ArrayListUnmanaged(Subscriber)).init(allocator),
            .next_msg_id = 1,
            .verbose = true,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *EventBus) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.subscribers.iterator();
        while (it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.subscribers.deinit();
    }

    pub fn subscribe(self: *EventBus, topic: []const u8, node_id: u32, callback: SubscribeCallback, context: ?*anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

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
        self.mutex.lock();

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

        // 購読者リストのスナップショットを取得してからロック解除
        const subs = self.subscribers.get(topic);
        self.mutex.unlock();

        if (subs) |s| {
            for (s.items) |sub| {
                if (sub.node_id != source_node_id) {
                    sub.callback(sub.context, &msg);
                }
            }
        }
    }
};
