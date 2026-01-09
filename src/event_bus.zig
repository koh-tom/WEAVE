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

/// 購読コールバック
pub const SubscribeCallback = *const fn (context: ?*anyopaque, msg: *const EventMessage) void;

pub const Subscriber = struct {
    node_id: u32,
    context: ?*anyopaque,
    callback: SubscribeCallback,
};

/// MPSC イベントキュー
pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    list: std.DoublyLinkedList = .{},
    mutex: std.Thread.Mutex,
    cond_not_full: std.Thread.Condition,
    cond_not_empty: std.Thread.Condition,
    is_shutdown: bool,
    capacity: usize,
    count: usize,

    const Node = struct {
        data: EventMessage,
        node: std.DoublyLinkedList.Node = .{},
    };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) EventQueue {
        return EventQueue{
            .allocator = allocator,
            .mutex = .{},
            .cond_not_full = .{},
            .cond_not_empty = .{},
            .is_shutdown = false,
            .capacity = capacity,
            .count = 0,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        while (self.list.popFirst()) |n| {
            const node: *Node = @fieldParentPtr("node", n);
            node.data.deinit(self.allocator);
            self.allocator.destroy(node);
        }
        self.is_shutdown = true;
        self.cond_not_empty.broadcast();
        self.cond_not_full.broadcast();
    }

    /// キューにイベントを追加
    /// block_if_full = true の場合、空きができるまで待機 (Reliable用)
    /// block_if_full = false の場合、満杯ならエラーを返す (BestEffort用)
    pub fn push(self: *EventQueue, msg: EventMessage, block_if_full: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.is_shutdown) return error.QueueShutdown;

        while (self.count >= self.capacity) {
            if (!block_if_full) return error.QueueFull;
            self.cond_not_full.wait(&self.mutex);
            if (self.is_shutdown) return error.QueueShutdown;
        }

        const node = try self.allocator.create(Node);
        node.* = .{
            .data = try msg.clone(self.allocator),
            .node = .{},
        };
        self.list.append(&node.node);
        self.count += 1;
        
        self.cond_not_empty.signal();
    }

    pub fn pop(self: *EventQueue) ?EventMessage {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.count == 0 and !self.is_shutdown) {
            self.cond_not_empty.wait(&self.mutex);
        }

        if (self.list.popFirst()) |n| {
            const node: *Node = @fieldParentPtr("node", n);
            const msg = node.data;
            self.allocator.destroy(node);
            self.count -= 1;
            self.cond_not_full.signal();
            return msg;
        }

        return null;
    }
};

/// Event Bus コア実装 (スレッドセーフ)
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    subscribers: std.StringHashMap(std.ArrayListUnmanaged(Subscriber)),
    queue: EventQueue,
    next_msg_id: u64,
    verbose: bool,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize) EventBus {
        return EventBus{
            .allocator = allocator,
            .subscribers = std.StringHashMap(std.ArrayListUnmanaged(Subscriber)).init(allocator),
            .queue = EventQueue.init(allocator, queue_capacity),
            .next_msg_id = 1,
            .verbose = true,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *EventBus) void {
        self.queue.deinit();
        
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
        const msg_id = self.next_msg_id;
        self.next_msg_id += 1;
        self.mutex.unlock();

        const msg = EventMessage{
            .id = msg_id,
            .topic = topic,
            .timestamp = std.time.milliTimestamp(),
            .source_node_id = source_node_id,
            .qos = qos,
            .payload = payload,
        };

        // QoSに基づいた投入戦略
        const block = (qos == .Reliable);
        self.queue.push(msg, block) catch |err| {
            if (err == error.QueueFull) {
                if (self.verbose) std.debug.print("QoS: BestEffort drop event '{s}' due to full queue\n", .{topic});
                return;
            }
            return err;
        };

        if (self.verbose) std.debug.print("Enqueuing event '{s}' (ID: {}, QoS: {any})\n", .{ topic, msg_id, qos });
    }

    pub fn dispatch(self: *EventBus, msg: *const EventMessage) void {
        self.mutex.lock();
        const subs_opt = self.subscribers.get(msg.topic);
        self.mutex.unlock();

        if (subs_opt) |subs| {
            for (subs.items) |sub| {
                if (sub.node_id != msg.source_node_id) {
                    sub.callback(sub.context, msg);
                }
            }
        }
    }
};
