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
    }

    pub fn shutdown(self: *EventQueue) void {
        self.mutex.lock();
        self.is_shutdown = true;
        self.mutex.unlock();
        
        self.cond_not_empty.broadcast();
        self.cond_not_full.broadcast();
    }

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

        while (self.count == 0) {
            if (self.is_shutdown) return null;
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
    cond_idle: std.Thread.Condition, // 追加: アイドル状態通知用
    
    last_messages: std.StringHashMap(EventMessage), // 追加: Transient用の最新メッセージ保持
    
    // デッドロック回避用
    dispatcher_thread_id: std.atomic.Value(usize),
    // 配送中のメッセージ数
    busy_count: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize) EventBus {
        return EventBus{
            .allocator = allocator,
            .subscribers = std.StringHashMap(std.ArrayListUnmanaged(Subscriber)).init(allocator),
            .queue = EventQueue.init(allocator, queue_capacity),
            .last_messages = std.StringHashMap(EventMessage).init(allocator),
            .next_msg_id = 1,
            .verbose = true,
            .mutex = .{},
            .cond_idle = .{},
            .dispatcher_thread_id = std.atomic.Value(usize).init(0),
            .busy_count = std.atomic.Value(usize).init(0),
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

        var last_it = self.last_messages.iterator();
        while (last_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.last_messages.deinit();

        self.queue.deinit();
    }

    pub fn stop(self: *EventBus) void {
        self.queue.shutdown();
        self.cond_idle.broadcast();
    }

    pub fn waitIdle(self: *EventBus) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (true) {
            // キューの中身を安全に確認
            self.queue.mutex.lock();
            const q_count = self.queue.count;
            const shutdown = self.queue.is_shutdown;
            self.queue.mutex.unlock();

            const b_count = self.busy_count.load(.acquire);
            
            if ((q_count == 0 and b_count == 0) or shutdown) break;
            
            // アイドル状態になるまで待機 (ポーリングなし)
            self.cond_idle.wait(&self.mutex);
        }
    }

    /// アイドル状態になった可能性を通知する
    pub fn notifyPotentialIdle(self: *EventBus) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cond_idle.signal();
    }

    pub fn registerDispatcherThread(self: *EventBus) void {
        const tid = @as(usize, @intCast(std.Thread.getCurrentId()));
        self.dispatcher_thread_id.store(tid, .monotonic);
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

        // Transient QoS の最新メッセージがあれば即座に配送
        if (self.last_messages.get(topic)) |msg| {
            if (msg.source_node_id != node_id) {
                if (self.verbose) std.debug.print("QoS: Dispatching Transient message to new subscriber (Topic: {s})\n", .{topic});
                callback(context, &msg);
            }
        }
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

        // Transient QoS の場合は最新メッセージとして保存
        if (qos == .Transient) {
            self.mutex.lock();
            const gop = try self.last_messages.getOrPut(topic);
            if (!gop.found_existing) {
                gop.key_ptr.* = try self.allocator.dupe(u8, topic);
            } else {
                gop.value_ptr.deinit(self.allocator);
            }
            gop.value_ptr.* = try msg.clone(self.allocator);
            self.mutex.unlock();
        }

        var block = (qos == .Reliable);
        const tid = self.dispatcher_thread_id.load(.monotonic);
        if (tid != 0 and tid == @as(usize, @intCast(std.Thread.getCurrentId()))) {
            // ディスパッチャスレッド自身によるPublishはデッドロック回避のためブロックしない
            block = false;
        }

        self.queue.push(msg, block) catch |err| {
            if (err == error.QueueFull) {
                if (self.verbose) std.debug.print("QoS: drop event '{s}' due to full queue (Source: {})\n", .{topic, source_node_id});
                return;
            }
            return err;
        };

        if (self.verbose) std.debug.print("Enqueuing event '{s}' (ID: {}, QoS: {any})\n", .{ topic, msg_id, qos });
    }

    pub fn dispatch(self: *EventBus, msg: *const EventMessage) void {
        _ = self.busy_count.fetchAdd(1, .acquire);
        defer _ = self.busy_count.fetchSub(1, .release);

        self.mutex.lock();
        const subs_snapshot = if (self.subscribers.getPtr(msg.topic)) |list|
            self.allocator.dupe(Subscriber, list.items) catch null
        else
            null;
        self.mutex.unlock();

        if (subs_snapshot) |snapshot| {
            defer self.allocator.free(snapshot);
            for (snapshot) |sub| {
                if (sub.node_id != msg.source_node_id) {
                    sub.callback(sub.context, msg);
                }
            }
        }
    }

    /// イベント配送ループの実行（別スレッドで呼ぶことを想定）
    pub fn runDispatcher(self: *EventBus) void {
        self.registerDispatcherThread();
        if (self.verbose) std.debug.print("Status: Event Dispatcher Thread started\n", .{});
        while (true) {
            if (self.queue.pop()) |msg| {
                self.dispatch(&msg);
                msg.deinit(self.allocator); // 配送完了後にヒープメモリを解放
                self.notifyPotentialIdle(); // アイドル状態の可能性を通知
            } else {
                self.notifyPotentialIdle();
                break;
            }
        }
        if (self.verbose) std.debug.print("Status: Event Dispatcher Thread stopped\n", .{});
    }
};

test "EventBus QoS: Reliable blocks when full" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator, 2);
    defer bus.deinit();
    bus.verbose = false;

    try bus.publish("test", "1", .BestEffort, 1);
    try bus.publish("test", "2", .BestEffort, 1);

    const thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *EventBus) void {
            b.publish("test", "3", .Reliable, 1) catch {};
        }
    }.run, .{&bus});

    // 待機
    std.Thread.sleep(100 * std.time.ns_per_ms);
    
    // まだ 2 つのはず
    bus.queue.mutex.lock();
    try std.testing.expectEqual(@as(usize, 2), bus.queue.count);
    bus.queue.mutex.unlock();

    // 1つ取り出す
    const m1 = bus.queue.pop().?;
    m1.deinit(allocator);

    thread.join();

    // 3つ目が追加されているはず
    bus.queue.mutex.lock();
    try std.testing.expectEqual(@as(usize, 2), bus.queue.count);
    bus.queue.mutex.unlock();
}

test "EventBus QoS: BestEffort drops when full" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator, 1);
    defer bus.deinit();
    bus.verbose = false;

    try bus.publish("test", "1", .BestEffort, 1);
    // これはドロップされる
    try bus.publish("test", "2", .BestEffort, 1);

    bus.queue.mutex.lock();
    try std.testing.expectEqual(@as(usize, 1), bus.queue.count);
    bus.queue.mutex.unlock();
}

test "EventBus QoS: Transient stores last message and dispatches to new subscriber" {
    const allocator = std.testing.allocator;
    var bus = EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    try bus.publish("state", "v1", .Transient, 1);
    try bus.publish("state", "v2", .Transient, 1);

    var received: bool = false;
    const S = struct {
        fn cb(ctx: ?*anyopaque, msg: *const EventMessage) void {
            const rec_ptr = @as(*bool, @ptrCast(@alignCast(ctx)));
            if (std.mem.eql(u8, msg.payload, "v2")) {
                rec_ptr.* = true;
            }
        }
    };
    try bus.subscribe("state", 2, S.cb, &received);

    try std.testing.expect(received);
}
