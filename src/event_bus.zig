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
            .topic = self.topic, // topic はインターン化されている前提
            .timestamp = self.timestamp,
            .source_node_id = self.source_node_id,
            .qos = self.qos,
            .payload = try allocator.dupe(u8, self.payload),
        };
    }

    pub fn deinit(self: EventMessage, allocator: std.mem.Allocator) void {
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

pub const WildcardSubscription = struct {
    pattern: []const u8,
    subscriber: Subscriber,
};

/// MPSC イベントキュー
pub const EventQueue = struct {
    allocator: std.mem.Allocator,
    messages: []EventMessage,
    mutex: std.Thread.Mutex,
    cond_not_full: std.Thread.Condition,
    cond_not_empty: std.Thread.Condition,
    is_shutdown: bool,
    capacity: usize,
    count: usize,
    head: usize = 0,
    tail: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !EventQueue {
        const messages = try allocator.alloc(EventMessage, capacity);
        return EventQueue{
            .allocator = allocator,
            .messages = messages,
            .mutex = .{},
            .cond_not_full = .{},
            .cond_not_empty = .{},
            .is_shutdown = false,
            .capacity = capacity,
            .count = 0,
            .head = 0,
            .tail = 0,
        };
    }

    pub fn deinit(self: *EventQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        
        while (self.count > 0) {
            self.messages[self.head].deinit(self.allocator);
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
        }
        self.allocator.free(self.messages);
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

        self.messages[self.tail] = msg;
        self.tail = (self.tail + 1) % self.capacity;
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

        const msg = self.messages[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        self.cond_not_full.signal();
        return msg;
    }
};

pub const IntrospectionLevel = enum {
    off,
    metadata,
    contents,
};

/// Event Bus コア実装 (スレッドセーフ)
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    subscribers: std.StringHashMap(std.ArrayListUnmanaged(Subscriber)),
    wildcard_subs: std.ArrayListUnmanaged(WildcardSubscription),
    topic_cache: std.StringHashMap([]const u8), // 追加: トピック名のインターン化用
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
    
    /// 全イベントの配送時に呼ばれるグローバル・オブザーバー（トランスポート等で使用）
    global_observer: ?struct {
        ctx: *anyopaque,
        callback: *const fn (ctx: *anyopaque, msg: *const EventMessage) void,
    } = null,
    graph: ?*@import("graph.zig").SystemGraph = null,
    introspection_level: IntrospectionLevel = .metadata,

    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize) !EventBus {
        return EventBus{
            .allocator = allocator,
            .subscribers = std.StringHashMap(std.ArrayListUnmanaged(Subscriber)).init(allocator),
            .wildcard_subs = .{},
            .topic_cache = std.StringHashMap([]const u8).init(allocator),
            .queue = try EventQueue.init(allocator, queue_capacity),
            .last_messages = std.StringHashMap(EventMessage).init(allocator),
            .next_msg_id = 1,
            .verbose = true,
            .mutex = .{},
            .cond_idle = .{},
            .dispatcher_thread_id = std.atomic.Value(usize).init(0),
            .busy_count = std.atomic.Value(usize).init(0),
            .graph = null,
            .introspection_level = .metadata,
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

        for (self.wildcard_subs.items) |ws| {
            self.allocator.free(ws.pattern);
        }
        self.wildcard_subs.deinit(self.allocator);

        // トピックキャッシュの解放
        var tc_it = self.topic_cache.iterator();
        while (tc_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.topic_cache.deinit();

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

    // ワイルドカードマッチングロジック (MQTT-like)
    // + : single level
    // # : multi level (must be at the end)
    pub fn isMatch(pattern: []const u8, topic: []const u8) bool {
        var p_it = std.mem.splitScalar(u8, pattern, '.');
        var t_it = std.mem.splitScalar(u8, topic, '.');

        while (true) {
            const p_part = p_it.next();
            const t_part = t_it.next();

            if (p_part == null) return t_part == null;

            if (std.mem.eql(u8, p_part.?, "#")) return true;

            if (t_part == null) return false;

            if (std.mem.eql(u8, p_part.?, "+") or std.mem.eql(u8, p_part.?, "*")) {
                continue;
            }

            if (!std.mem.eql(u8, p_part.?, t_part.?)) return false;
        }
    }

    fn traceMessage(self: *EventBus, msg: *const EventMessage) void {
        if (self.introspection_level == .off) return;
        // 自己再帰（トレースのトレース）を防止
        if (std.mem.eql(u8, msg.topic, "core.system.event_traced")) return;
        // グラフ更新は頻繁すぎるため、デバッグが煩雑になる場合は除外することも検討できるが、
        // 現状は全件トレースを基本とする。

        // ペイロードの処理（現在の観測レベルに従う）
        const payload_json = if (self.introspection_level == .contents) 
            msg.payload 
        else 
            "{\"hidden\":true}";

        var buf: [2048]u8 = undefined;
        const trace_json = std.fmt.bufPrint(&buf,
            "{{\"id\":{},\"topic\":\"{s}\",\"source\":{},\"timestamp\":{},\"qos\":{},\"payload\":{s}}}",
            .{ msg.id, msg.topic, msg.source_node_id, msg.timestamp, @intFromEnum(msg.qos), payload_json }
        ) catch |err| {
            if (self.verbose) std.debug.print("Tracing: Payload too large for trace buffer: {any}\n", .{err});
            return;
        };

        // トレースメッセージ自体を再発行
        // 配送ループに入らないように publish を呼び出すが、
        // publish内でのトピックチェックにより安全。
        _ = self.publish("core.system.event_traced", trace_json, .BestEffort, 0) catch {};
    }
    pub fn registerDispatcherThread(self: *EventBus) void {
        const tid = @as(usize, @intCast(std.Thread.getCurrentId()));
        self.dispatcher_thread_id.store(tid, .monotonic);
    }

    fn getInternedTopic(self: *EventBus, topic: []const u8) ![]const u8 {
        if (self.topic_cache.get(topic)) |cached| {
            return cached;
        }
        const duped = try self.allocator.dupe(u8, topic);
        try self.topic_cache.put(duped, duped);
        return duped;
    }

    pub fn subscribe(self: *EventBus, topic: []const u8, node_id: u32, callback: SubscribeCallback, context: ?*anyopaque) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // ワイルドカードが含まれているかチェック
        const is_wildcard = std.mem.indexOfScalar(u8, topic, '*') != null or 
                           std.mem.indexOfScalar(u8, topic, '+') != null or 
                           std.mem.indexOfScalar(u8, topic, '#') != null;

        if (is_wildcard) {
            try self.wildcard_subs.append(self.allocator, .{
                .pattern = try self.allocator.dupe(u8, topic),
                .subscriber = .{
                    .node_id = node_id,
                    .context = context,
                    .callback = callback,
                },
            });
        } else {
            const result = try self.subscribers.getOrPut(topic);
            if (!result.found_existing) {
                result.key_ptr.* = try self.allocator.dupe(u8, topic);
                result.value_ptr.* = std.ArrayListUnmanaged(Subscriber){};
            }
            try result.value_ptr.append(self.allocator, Subscriber{
                .node_id = node_id,
                .context = context,
                .callback = callback,
            });
        }
        if (self.verbose) std.debug.print("Node {} subscribed to topic pattern '{s}'\n", .{ node_id, topic });

        if (self.graph) |g| {
            g.updateSubscription(node_id, topic) catch |err| {
                std.debug.print("EventBus: Failed to update graph subscription: {any}\n", .{err});
            };
        }

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
    ) anyerror!void {
        // システム制御トピックの処理
        if (std.mem.eql(u8, topic, "core.system.introspection")) {
            if (std.mem.eql(u8, payload, "\"OFF\"") or std.mem.eql(u8, payload, "OFF")) {
                self.introspection_level = .off;
                std.debug.print("Introspection: Level changed to OFF\n", .{});
            } else if (std.mem.eql(u8, payload, "\"METADATA\"") or std.mem.eql(u8, payload, "METADATA")) {
                self.introspection_level = .metadata;
                std.debug.print("Introspection: Level changed to METADATA\n", .{});
            } else if (std.mem.eql(u8, payload, "\"CONTENTS\"") or std.mem.eql(u8, payload, "CONTENTS")) {
                self.introspection_level = .contents;
                std.debug.print("Introspection: Level changed to CONTENTS\n", .{});
            }
        }

        self.mutex.lock();
        const msg_id = self.next_msg_id;
        self.next_msg_id += 1;
        const interned_topic = try self.getInternedTopic(topic);
        self.mutex.unlock();

        if (self.graph) |g| {
            g.recordPublish(source_node_id, interned_topic) catch |err| {
                std.debug.print("EventBus: Failed to record graph publish: {any}\n", .{err});
            };
        }

        const msg = EventMessage{
            .id = msg_id,
            .topic = interned_topic,
            .timestamp = std.time.milliTimestamp(),
            .source_node_id = source_node_id,
            .qos = qos,
            .payload = try self.allocator.dupe(u8, payload),
        };

        // Transient QoS の場合は最新メッセージとして保存
        if (qos == .Transient) {
            self.mutex.lock();
            const gop = try self.last_messages.getOrPut(interned_topic);
            if (!gop.found_existing) {
                gop.key_ptr.* = interned_topic;
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
        // 1. 完全一致の購読者
        const subs_snapshot = if (self.subscribers.getPtr(msg.topic)) |list|
            self.allocator.dupe(Subscriber, list.items) catch null
        else
            null;
        
        // 2. ワイルドカード一致の購読者
        var wildcard_matches: std.ArrayListUnmanaged(Subscriber) = .{};
        defer wildcard_matches.deinit(self.allocator);
        for (self.wildcard_subs.items) |ws| {
            if (EventBus.isMatch(ws.pattern, msg.topic)) {
                wildcard_matches.append(self.allocator, ws.subscriber) catch {};
            }
        }
        self.mutex.unlock();

        // 配送実行
        if (subs_snapshot) |snapshot| {
            defer self.allocator.free(snapshot);
            for (snapshot) |sub| {
                if (sub.node_id != msg.source_node_id) {
                    sub.callback(sub.context, msg);
                }
            }
        }
        
        for (wildcard_matches.items) |sub| {
            if (sub.node_id != msg.source_node_id) {
                sub.callback(sub.context, msg);
            }
        }

        // グローバル・オブザーバーへの通知
        if (self.global_observer) |obs| {
            obs.callback(obs.ctx, msg);
        }

        // イベント追跡トピックの発行
        self.traceMessage(msg);
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
    var bus = try EventBus.init(allocator, 2);
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
    var bus = try EventBus.init(allocator, 1);
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
    var bus = try EventBus.init(allocator, 10);
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

test "EventBus: Wildcard Matching" {
    const isMatch = EventBus.isMatch;
    
    // Exact match
    try std.testing.expect(isMatch("a.b.c", "a.b.c"));
    try std.testing.expect(!isMatch("a.b.c", "a.b.d"));
    
    // + : Single level
    try std.testing.expect(isMatch("a.+.c", "a.b.c"));
    try std.testing.expect(isMatch("a.+", "a.b"));
    try std.testing.expect(!isMatch("a.+", "a.b.c"));
    
    // * : Single level (WEAVE compatibility)
    try std.testing.expect(isMatch("a.*.c", "a.b.c"));
    
    // # : Multi level
    try std.testing.expect(isMatch("a.#", "a.b"));
    try std.testing.expect(isMatch("a.#", "a.b.c"));
    try std.testing.expect(isMatch("#", "a.b.c"));
}

test "EventBus: Wildcard Dispatch" {
    const allocator = std.testing.allocator;
    var bus = try EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var count: u32 = 0;
    const S = struct {
        fn cb(ctx: ?*anyopaque, _: *const EventMessage) void {
            const c_ptr = @as(*u32, @ptrCast(@alignCast(ctx)));
            c_ptr.* += 1;
        }
    };

    try bus.subscribe("ext.twitch.#", 2, S.cb, &count);
    try bus.subscribe("ext.+.chat.*", 3, S.cb, &count);
    
    const thread = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});
    
    // Match 1 (Pattern 1 only)
    try bus.publish("ext.twitch.connected", "{}", .BestEffort, 1);
    // Match 2 (Both patterns)
    try bus.publish("ext.twitch.chat.message", "{}", .BestEffort, 1);
    // No match
    try bus.publish("other.topic", "{}", .BestEffort, 1);

    bus.waitIdle();
    bus.stop();
    thread.join();
    
    try std.testing.expectEqual(@as(u32, 3), count);
}
