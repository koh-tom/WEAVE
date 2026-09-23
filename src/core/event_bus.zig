//! EventBus — コントロールプレーン (購読表・ACL の最終関門・ルーティング) と、
//! セル (Cell) ごとの実行器 (executor) からなる。
//!
//! 設計の要点 (docs/v1_plan_2026-09.md §4, §12):
//! - **セル = 障害ドメイン = スケジューリング単位**。各セルが専用のキューとスレッドを持つ。
//!   あるセルのノードが遅い / 再起動中 / 無限ループしても、他セルの配送は待たされない。
//! - **購読は同期コールバックを呼ばない**。Transient の再配送も含め、配送は必ず
//!   宛先セルのキュー経由で行う。旧実装はロック保持中に同期コールバックしており、
//!   再起動中のプラグインへ毒メッセージを再配送してデッドロックした (P0-6)。
//! - **メッセージは参照カウント**で、宛先セルの数だけ共有される (コピーしない)。
//! - **トピックのインターンを廃止**。任意トピックを publish され続けてもホストの
//!   メモリが単調増加しない (P1-2)。Transient の保持数にも上限を設ける。
//! - **因果の深さ (hops)**: プラグインが処理中のメッセージに反応して publish すると
//!   hops+1 になる。上限を超えた連鎖はハウリング (無限反響) とみなして止める。

const std = @import("std");
const common = @import("../common/types.zig");
const pattern = @import("pattern.zig");
const topics = @import("topics.zig");
const RateLimiter = @import("rate_limiter.zig").RateLimiter;

pub const QoS = common.QoS;
pub const IntrospectionLevel = common.IntrospectionLevel;

/// ホスト内で管理されるメッセージのエンベロープ
pub const EventMessage = struct {
    id: u64,
    topic: []const u8,
    timestamp: i64,
    source_node_id: u32,
    qos: QoS,
    payload: []const u8,
    /// このメッセージを発行する契機になったメッセージの id (因果トレース)
    parent_id: u64 = 0,
    /// 因果の深さ。外部入力 = 0
    hops: u8 = 0,
};

/// 購読コールバック
pub const SubscribeCallback = *const fn (context: ?*anyopaque, msg: *const EventMessage) void;

pub const Subscriber = struct {
    node_id: u32,
    cell: *Cell,
    context: ?*anyopaque,
    callback: SubscribeCallback,
    /// 自分が発行したメッセージも受け取るか (Inspector などのタップ用)
    receive_own: bool = false,
};

/// 参照カウント付きの共有メッセージ。topic と payload は 1 つのバッファに入る。
pub const SharedMsg = struct {
    msg: EventMessage,
    refs: std.atomic.Value(u32),
    buf: []u8,

    fn create(allocator: std.mem.Allocator, base: EventMessage, initial_refs: u32) !*SharedMsg {
        const buf = try allocator.alloc(u8, base.topic.len + base.payload.len);
        errdefer allocator.free(buf);
        @memcpy(buf[0..base.topic.len], base.topic);
        @memcpy(buf[base.topic.len..], base.payload);
        const self = try allocator.create(SharedMsg);
        self.* = .{
            .msg = base,
            .refs = std.atomic.Value(u32).init(initial_refs),
            .buf = buf,
        };
        self.msg.topic = buf[0..base.topic.len];
        self.msg.payload = buf[base.topic.len..];
        return self;
    }

    pub fn retain(self: *SharedMsg) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    pub fn release(self: *SharedMsg, allocator: std.mem.Allocator) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            allocator.free(self.buf);
            allocator.destroy(self);
        }
    }
};

pub const ControlFn = *const fn (ctx: *anyopaque) void;

const Item = struct {
    msg: ?*SharedMsg = null,
    subs: []Subscriber = &.{},
    control: ?ControlFn = null,
    control_ctx: ?*anyopaque = null,
    enq_ns: i128 = 0,
};

/// セルの信頼レベル
pub const Trust = enum {
    core,
    trusted,
    untrusted,
    remote,

    pub fn fromString(s: []const u8) ?Trust {
        return std.meta.stringToEnum(Trust, s);
    }
};

pub const CellOptions = struct {
    trust: Trust = .core,
    capacity: usize = 1024,
    /// 他セルから入ってよいトピック (購読できる範囲の上限)
    bridges_in: []const []const u8 = &.{"#"},
    /// 他セルへ出してよいトピック (publish できる範囲の上限)
    bridges_out: []const []const u8 = &.{"#"},
    /// セル全体の publish 予算 (events/sec, 0 = 無制限)。所属する全ノードで共有する
    budget_eps: f64 = 0,
};

/// セルの保守タスク (再起動のスケジューリングなど)。executor スレッド上で呼ばれ、
/// 次に呼んでほしい時刻 (ms, std.math.maxInt(i64) = 不要) を返す。
pub const Task = struct {
    ctx: *anyopaque,
    run: *const fn (ctx: *anyopaque, now_ms: i64) i64,
};

/// 未処理アイテム数の追跡 (waitIdle 用)
const Tracker = struct {
    pending: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// 近い将来に実行予定の再起動など
    scheduled: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    fn inc(self: *Tracker) void {
        _ = self.pending.fetchAdd(1, .acq_rel);
    }

    fn dec(self: *Tracker) void {
        if (self.pending.fetchSub(1, .acq_rel) == 1) self.notify();
    }

    fn notify(self: *Tracker) void {
        self.mutex.lock();
        self.cond.broadcast();
        self.mutex.unlock();
    }

    fn idle(self: *Tracker) bool {
        return self.pending.load(.acquire) == 0 and self.scheduled.load(.acquire) == 0;
    }
};

threadlocal var tl_current_cell: ?*Cell = null;

/// 現在のスレッドがセルの executor ならそのセルを返す
pub fn currentCell() ?*Cell {
    return tl_current_cell;
}

pub const LatencyStats = struct {
    p50_us: u32 = 0,
    p99_us: u32 = 0,
    max_us: u32 = 0,
    samples: usize = 0,
};

pub const Cell = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    trust: Trust,
    bridges_in: [][]const u8,
    bridges_out: [][]const u8,
    tracker: *Tracker,

    mutex: std.Thread.Mutex = .{},
    not_empty: std.Thread.Condition = .{},
    not_full: std.Thread.Condition = .{},
    items: []Item,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    capacity: usize,
    shutdown: bool = false,
    thread: ?std.Thread = null,

    task_mutex: std.Thread.Mutex = .{},
    tasks: std.ArrayListUnmanaged(Task) = .{},

    delivered: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    dropped: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    /// セル単位の publish 予算。ノード単位の rate limit に加えて、同じセルの全ノードの合計を抑える
    budget_mutex: std.Thread.Mutex = .{},
    budget: RateLimiter = .{},
    budget_denied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    lat_mutex: std.Thread.Mutex = .{},
    lat_ring: [512]u32 = undefined,
    lat_len: usize = 0,
    lat_pos: usize = 0,

    fn create(allocator: std.mem.Allocator, name: []const u8, opts: CellOptions, tracker: *Tracker) !*Cell {
        const self = try allocator.create(Cell);
        errdefer allocator.destroy(self);
        const items = try allocator.alloc(Item, opts.capacity);
        errdefer allocator.free(items);
        self.* = .{
            .allocator = allocator,
            .name = try allocator.dupe(u8, name),
            .trust = opts.trust,
            .bridges_in = try dupeList(allocator, opts.bridges_in),
            .bridges_out = try dupeList(allocator, opts.bridges_out),
            .tracker = tracker,
            .items = items,
            .capacity = opts.capacity,
            .budget = RateLimiter.init(opts.budget_eps),
        };
        return self;
    }

    /// セルの予算から 1 件分を消費する。予算切れなら false
    pub fn tryBudget(self: *Cell, now_ms: i64) bool {
        self.budget_mutex.lock();
        defer self.budget_mutex.unlock();
        if (self.budget.tryConsume(now_ms)) return true;
        _ = self.budget_denied.fetchAdd(1, .monotonic);
        return false;
    }

    pub fn budgetEps(self: *Cell) f64 {
        self.budget_mutex.lock();
        defer self.budget_mutex.unlock();
        return self.budget.rate_eps;
    }

    fn dupeList(allocator: std.mem.Allocator, src: []const []const u8) ![][]const u8 {
        const out = try allocator.alloc([]const u8, src.len);
        for (src, 0..) |s, i| out[i] = try allocator.dupe(u8, s);
        return out;
    }

    fn freeList(allocator: std.mem.Allocator, list: [][]const u8) void {
        for (list) |s| allocator.free(s);
        allocator.free(list);
    }

    fn destroy(self: *Cell) void {
        // 残っているアイテムを解放
        while (self.count > 0) {
            const it = self.items[self.head];
            self.head = (self.head + 1) % self.capacity;
            self.count -= 1;
            if (it.msg) |m| m.release(self.allocator);
            if (it.subs.len > 0) self.allocator.free(it.subs);
        }
        self.allocator.free(self.items);
        self.allocator.free(self.name);
        freeList(self.allocator, self.bridges_in);
        freeList(self.allocator, self.bridges_out);
        self.tasks.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    /// このセルのノードが topic を受け取ってよいか
    pub fn allowsIn(self: *const Cell, topic: []const u8) bool {
        for (self.bridges_in) |b| if (pattern.isMatch(b, topic)) return true;
        return false;
    }

    /// このセルのノードが topic を publish してよいか
    pub fn allowsOut(self: *const Cell, topic: []const u8) bool {
        for (self.bridges_out) |b| if (pattern.isMatch(b, topic)) return true;
        return false;
    }

    /// パターン p (manifest の publish 宣言) が bridges_out に収まっているか
    pub fn coversOut(self: *const Cell, p: []const u8) bool {
        for (self.bridges_out) |b| if (pattern.covers(b, p)) return true;
        return false;
    }

    /// パターン p (購読) が bridges_in と交差するか
    pub fn intersectsIn(self: *const Cell, p: []const u8) bool {
        for (self.bridges_in) |b| if (pattern.intersect(b, p)) return true;
        return false;
    }

    const PushError = error{ QueueFull, QueueShutdown };

    fn push(self: *Cell, item: Item, block: bool) PushError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.shutdown) return error.QueueShutdown;
        while (self.count >= self.capacity) {
            if (!block) return error.QueueFull;
            self.not_full.wait(&self.mutex);
            if (self.shutdown) return error.QueueShutdown;
        }
        var it = item;
        it.enq_ns = std.time.nanoTimestamp();
        self.items[self.tail] = it;
        self.tail = (self.tail + 1) % self.capacity;
        self.count += 1;
        self.not_empty.signal();
    }

    const Pop = union(enum) { item: Item, timeout, closed };

    fn pop(self: *Cell, timeout_ns: ?u64) Pop {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count == 0) {
            if (self.shutdown) return .closed;
            if (timeout_ns) |t| {
                self.not_empty.timedWait(&self.mutex, t) catch {
                    if (self.count == 0) return if (self.shutdown) .closed else .timeout;
                };
            } else {
                self.not_empty.wait(&self.mutex);
            }
        }
        const it = self.items[self.head];
        self.head = (self.head + 1) % self.capacity;
        self.count -= 1;
        self.not_full.signal();
        return .{ .item = it };
    }

    /// executor スレッド上で任意の処理を実行させる (プラグインの on_init など)。
    /// キューの順序が保たれるので、それ以前に積まれた配送の後に実行される。
    pub fn post(self: *Cell, f: ControlFn, ctx: *anyopaque) !void {
        self.tracker.inc();
        self.push(.{ .control = f, .control_ctx = ctx }, currentCell() == null) catch |e| {
            self.tracker.dec();
            return e;
        };
    }

    pub fn addTask(self: *Cell, task: Task) !void {
        self.task_mutex.lock();
        defer self.task_mutex.unlock();
        try self.tasks.append(self.allocator, task);
    }

    pub fn removeTask(self: *Cell, ctx: *anyopaque) void {
        self.task_mutex.lock();
        defer self.task_mutex.unlock();
        var i: usize = 0;
        while (i < self.tasks.items.len) {
            if (self.tasks.items[i].ctx == ctx) {
                _ = self.tasks.swapRemove(i);
            } else i += 1;
        }
    }

    /// タスクを起こす (再起動の予約直後などに、待機中の executor を即座に回す)
    pub fn wake(self: *Cell) void {
        self.mutex.lock();
        self.not_empty.signal();
        self.mutex.unlock();
    }

    fn runTasks(self: *Cell) i64 {
        const now = std.time.milliTimestamp();
        var next: i64 = std.math.maxInt(i64);
        self.task_mutex.lock();
        // タスク実行中に addTask されてもよいようにコピーしてから回す
        var buf: [64]Task = undefined;
        const n = @min(self.tasks.items.len, buf.len);
        @memcpy(buf[0..n], self.tasks.items[0..n]);
        self.task_mutex.unlock();
        for (buf[0..n]) |t| {
            const due = t.run(t.ctx, now);
            if (due < next) next = due;
        }
        return next;
    }

    fn recordLatency(self: *Cell, enq_ns: i128) void {
        const d = std.time.nanoTimestamp() - enq_ns;
        const us: u32 = if (d <= 0) 0 else @intCast(@min(@divTrunc(d, 1000), std.math.maxInt(u32)));
        self.lat_mutex.lock();
        defer self.lat_mutex.unlock();
        self.lat_ring[self.lat_pos] = us;
        self.lat_pos = (self.lat_pos + 1) % self.lat_ring.len;
        if (self.lat_len < self.lat_ring.len) self.lat_len += 1;
    }

    /// 直近の配送レイテンシ (キュー投入 → コールバック完了) の分位点
    pub fn latency(self: *Cell) LatencyStats {
        var tmp: [512]u32 = undefined;
        self.lat_mutex.lock();
        const n = self.lat_len;
        @memcpy(tmp[0..n], self.lat_ring[0..n]);
        self.lat_mutex.unlock();
        if (n == 0) return .{};
        std.mem.sort(u32, tmp[0..n], {}, std.sort.asc(u32));
        return .{
            .p50_us = tmp[(n - 1) / 2],
            .p99_us = tmp[@min(n - 1, (n * 99) / 100)],
            .max_us = tmp[n - 1],
            .samples = n,
        };
    }

    pub fn queueDepth(self: *Cell) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.count;
    }

    fn dispatch(self: *Cell, item: Item) void {
        if (item.control) |f| {
            f(item.control_ctx.?);
            return;
        }
        const sm = item.msg orelse return;
        defer sm.release(self.allocator);
        defer if (item.subs.len > 0) self.allocator.free(item.subs);
        for (item.subs) |sub| {
            if (sub.receive_own or sub.node_id != sm.msg.source_node_id) {
                sub.callback(sub.context, &sm.msg);
            }
        }
        _ = self.delivered.fetchAdd(1, .monotonic);
        self.recordLatency(item.enq_ns);
    }

    fn run(self: *Cell) void {
        tl_current_cell = self;
        defer tl_current_cell = null;
        var next_due: i64 = std.math.maxInt(i64);
        while (true) {
            var timeout: ?u64 = null;
            if (next_due != std.math.maxInt(i64)) {
                const now = std.time.milliTimestamp();
                const wait_ms: i64 = @max(0, next_due - now);
                timeout = @as(u64, @intCast(wait_ms)) * std.time.ns_per_ms + 1;
            } else {
                // タスクが追加されうるので、無期限ではなく定期的に起きる
                timeout = 200 * std.time.ns_per_ms;
            }
            switch (self.pop(timeout)) {
                .item => |it| {
                    self.dispatch(it);
                    next_due = self.runTasks();
                    self.tracker.dec();
                },
                .timeout => next_due = self.runTasks(),
                .closed => break,
            }
        }
    }

    fn close(self: *Cell) void {
        self.mutex.lock();
        self.shutdown = true;
        self.not_empty.broadcast();
        self.not_full.broadcast();
        self.mutex.unlock();
    }
};

const SubEntry = struct {
    pattern: []const u8,
    sub: Subscriber,
};

pub const PublishOptions = struct {
    qos: QoS = .BestEffort,
    source: u32 = 0,
    timestamp: ?i64 = null,
    parent_id: u64 = 0,
    hops: u8 = 0,
};

pub const PublishError = error{ InvalidTopic, QueueFull, QueueShutdown, OutOfMemory, HopLimitExceeded };

/// Event Bus コア実装 (スレッドセーフ)
pub const EventBus = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// 完全一致の購読 (トピック → 購読者)
    exact: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(Subscriber)) = .{},
    /// ワイルドカード購読
    wildcard: std.ArrayListUnmanaged(SubEntry) = .{},
    /// Transient の最新値 (キーは保持している SharedMsg の topic)
    retained: std.StringHashMapUnmanaged(*SharedMsg) = .{},

    next_msg_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    cells: std.ArrayListUnmanaged(*Cell) = .{},
    core_cell: *Cell,
    tracker: *Tracker,
    running: bool = false,
    stop_event: std.Thread.ResetEvent = .{},
    join_mutex: std.Thread.Mutex = .{},

    graph: ?*@import("graph.zig").SystemGraph = null,
    introspection_level: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(IntrospectionLevel.metadata)),
    verbose: bool = true,

    max_retained: usize = 4096,
    max_hops: u8 = 16,
    queue_capacity: usize,

    dropped_total: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    loops_detected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize) !EventBus {
        const tracker = try allocator.create(Tracker);
        tracker.* = .{};
        errdefer allocator.destroy(tracker);
        const core = try Cell.create(allocator, "core", .{ .trust = .core, .capacity = queue_capacity }, tracker);
        var self = EventBus{
            .allocator = allocator,
            .core_cell = core,
            .tracker = tracker,
            .queue_capacity = queue_capacity,
        };
        try self.cells.append(allocator, core);
        return self;
    }

    pub fn deinit(self: *EventBus) void {
        self.stop();
        self.join();
        var it = self.exact.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(self.allocator);
        }
        self.exact.deinit(self.allocator);
        for (self.wildcard.items) |w| self.allocator.free(w.pattern);
        self.wildcard.deinit(self.allocator);
        var rit = self.retained.valueIterator();
        while (rit.next()) |m| m.*.release(self.allocator);
        self.retained.deinit(self.allocator);
        for (self.cells.items) |c| c.destroy();
        self.cells.deinit(self.allocator);
        self.allocator.destroy(self.tracker);
    }

    // ------------------------------------------------------------------
    // セル
    // ------------------------------------------------------------------

    pub fn createCell(self: *EventBus, name: []const u8, opts: CellOptions) !*Cell {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.cells.items) |c| if (std.mem.eql(u8, c.name, name)) return error.CellExists;
        var o = opts;
        if (o.capacity == 0) o.capacity = self.queue_capacity;
        const cell = try Cell.create(self.allocator, name, o, self.tracker);
        errdefer cell.destroy();
        try self.cells.append(self.allocator, cell);
        if (self.running) cell.thread = try std.Thread.spawn(.{}, Cell.run, .{cell});
        return cell;
    }

    pub fn getCell(self: *EventBus, name: []const u8) ?*Cell {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.cells.items) |c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    pub fn defaultCell(self: *EventBus) *Cell {
        return self.core_cell;
    }

    /// 全セルの executor スレッドを起動する
    pub fn start(self: *EventBus) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.running) return;
        self.running = true;
        for (self.cells.items) |c| {
            if (c.thread == null) c.thread = try std.Thread.spawn(.{}, Cell.run, .{c});
        }
    }

    /// 互換 API: executor 群を起動し、stop() されるまでブロックし、全スレッドを join する。
    pub fn runDispatcher(self: *EventBus) void {
        self.start() catch |err| {
            std.debug.print("EventBus: failed to start executors: {any}\n", .{err});
            return;
        };
        self.stop_event.wait();
        self.join();
    }

    pub fn stop(self: *EventBus) void {
        self.mutex.lock();
        const cells = self.cells.items;
        self.mutex.unlock();
        for (cells) |c| c.close();
        self.stop_event.set();
        self.tracker.notify();
    }

    /// 全 executor の終了を待つ (stop 後に呼ぶ)。複数スレッドから呼ばれても安全
    /// (runDispatcher のスレッドと deinit が同時に呼ぶことがある)。
    pub fn join(self: *EventBus) void {
        self.join_mutex.lock();
        defer self.join_mutex.unlock();
        self.mutex.lock();
        const cells = self.cells.items;
        self.mutex.unlock();
        for (cells) |c| {
            if (c.thread) |t| {
                t.join();
                c.thread = null;
            }
        }
    }

    /// 全キューが空で、実行中の配送も予定された再起動も無い状態になるまで待つ
    pub fn waitIdle(self: *EventBus) void {
        self.tracker.mutex.lock();
        defer self.tracker.mutex.unlock();
        while (!self.tracker.idle() and !self.stop_event.isSet()) {
            self.tracker.cond.timedWait(&self.tracker.mutex, 5 * std.time.ns_per_ms) catch {};
        }
    }

    /// 近い将来に実行予定の処理を登録/解除する (waitIdle がそれを待つ)
    pub fn scheduleBegin(self: *EventBus) void {
        _ = self.tracker.scheduled.fetchAdd(1, .acq_rel);
    }
    pub fn scheduleEnd(self: *EventBus) void {
        if (self.tracker.scheduled.fetchSub(1, .acq_rel) == 1) self.tracker.notify();
    }

    // ------------------------------------------------------------------
    // 購読
    // ------------------------------------------------------------------

    pub const SubscribeOptions = struct {
        cell: ?*Cell = null,
        receive_own: bool = false,
        /// SystemGraph に購読として記録するか (Inspector / ゲートウェイ等のタップは記録しない)
        record_graph: bool = true,
    };

    /// 互換 API: core セルで購読する
    pub fn subscribe(self: *EventBus, topic: []const u8, node_id: u32, callback: SubscribeCallback, context: ?*anyopaque) !void {
        return self.subscribeEx(topic, node_id, callback, context, .{});
    }

    /// 購読を登録する。同じ (node_id, パターン) の二重登録は無視する (冪等)。
    /// Transient の最新値があれば、宛先セルのキュー経由で配送する (同期呼び出しはしない)。
    pub fn subscribeEx(self: *EventBus, topic: []const u8, node_id: u32, callback: SubscribeCallback, context: ?*anyopaque, opts: SubscribeOptions) !void {
        if (!pattern.validPattern(topic)) return error.InvalidTopic;
        const cell = opts.cell orelse self.core_cell;
        const sub = Subscriber{ .node_id = node_id, .cell = cell, .context = context, .callback = callback, .receive_own = opts.receive_own };

        var replay = std.ArrayListUnmanaged(*SharedMsg){};
        defer replay.deinit(self.allocator);

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (pattern.hasWildcard(topic)) {
                for (self.wildcard.items) |w| {
                    if (w.sub.node_id == node_id and w.sub.context == context and std.mem.eql(u8, w.pattern, topic)) return;
                }
                const owned = try self.allocator.dupe(u8, topic);
                errdefer self.allocator.free(owned);
                try self.wildcard.append(self.allocator, .{ .pattern = owned, .sub = sub });
                var it = self.retained.iterator();
                while (it.next()) |e| {
                    if (pattern.isMatch(topic, e.key_ptr.*) and cell.allowsIn(e.key_ptr.*)) {
                        e.value_ptr.*.retain();
                        replay.append(self.allocator, e.value_ptr.*) catch e.value_ptr.*.release(self.allocator);
                    }
                }
            } else {
                const gop = try self.exact.getOrPut(self.allocator, topic);
                if (!gop.found_existing) {
                    gop.key_ptr.* = self.allocator.dupe(u8, topic) catch |err| {
                        _ = self.exact.remove(topic);
                        return err;
                    };
                    gop.value_ptr.* = .{};
                }
                for (gop.value_ptr.items) |s| {
                    if (s.node_id == node_id and s.context == context) return;
                }
                try gop.value_ptr.append(self.allocator, sub);
                if (self.retained.get(topic)) |m| {
                    if (cell.allowsIn(topic)) {
                        m.retain();
                        replay.append(self.allocator, m) catch m.release(self.allocator);
                    }
                }
            }
        }

        if (self.verbose) std.debug.print("Node {} subscribed to topic pattern '{s}' (cell {s})\n", .{ node_id, topic, cell.name });

        if (opts.record_graph) {
            if (self.graph) |g| g.updateSubscription(node_id, topic) catch {};
        }

        for (replay.items) |m| {
            if (m.msg.source_node_id == node_id and !opts.receive_own) {
                m.release(self.allocator);
                continue;
            }
            const subs = self.allocator.alloc(Subscriber, 1) catch {
                m.release(self.allocator);
                continue;
            };
            subs[0] = sub;
            self.tracker.inc();
            cell.push(.{ .msg = m, .subs = subs }, false) catch {
                self.tracker.dec();
                self.allocator.free(subs);
                m.release(self.allocator);
                _ = cell.dropped.fetchAdd(1, .monotonic);
            };
        }
    }

    /// (node_id, パターン) の購読を解除する
    pub fn unsubscribe(self: *EventBus, node_id: u32, topic: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (pattern.hasWildcard(topic)) {
            var i: usize = 0;
            while (i < self.wildcard.items.len) {
                const w = self.wildcard.items[i];
                if (w.sub.node_id == node_id and std.mem.eql(u8, w.pattern, topic)) {
                    self.allocator.free(w.pattern);
                    _ = self.wildcard.orderedRemove(i);
                } else i += 1;
            }
        } else if (self.exact.getPtr(topic)) |list| {
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].node_id == node_id) {
                    _ = list.orderedRemove(i);
                } else i += 1;
            }
        }
    }

    /// ノードの全購読を解除する
    pub fn unsubscribeAll(self: *EventBus, node_id: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var i: usize = 0;
        while (i < self.wildcard.items.len) {
            const w = self.wildcard.items[i];
            if (w.sub.node_id == node_id) {
                self.allocator.free(w.pattern);
                _ = self.wildcard.orderedRemove(i);
            } else i += 1;
        }
        var it = self.exact.valueIterator();
        while (it.next()) |list| {
            var j: usize = 0;
            while (j < list.items.len) {
                if (list.items[j].node_id == node_id) {
                    _ = list.orderedRemove(j);
                } else j += 1;
            }
        }
    }

    /// ノードの購読数
    pub fn subscriptionCount(self: *EventBus, node_id: u32) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        for (self.wildcard.items) |w| {
            if (w.sub.node_id == node_id) n += 1;
        }
        var it = self.exact.valueIterator();
        while (it.next()) |list| {
            for (list.items) |s| if (s.node_id == node_id) {
                n += 1;
            };
        }
        return n;
    }

    // ------------------------------------------------------------------
    // 発行
    // ------------------------------------------------------------------

    /// ワイルドカードマッチ (互換 API)
    pub fn isMatch(p: []const u8, topic: []const u8) bool {
        return pattern.isMatch(p, topic);
    }

    pub fn publish(self: *EventBus, topic: []const u8, payload: []const u8, qos: QoS, source_node_id: u32) PublishError!void {
        return self.publishEx(topic, payload, .{ .qos = qos, .source = source_node_id });
    }

    pub fn publishWithMessageTimestamp(self: *EventBus, topic: []const u8, payload: []const u8, qos: QoS, source_node_id: u32, timestamp: i64) PublishError!void {
        return self.publishEx(topic, payload, .{ .qos = qos, .source = source_node_id, .timestamp = timestamp });
    }

    pub fn publishEx(self: *EventBus, topic: []const u8, payload: []const u8, opts: PublishOptions) PublishError!void {
        if (!pattern.validTopic(topic)) return error.InvalidTopic;

        if (std.mem.eql(u8, topic, "core.system.introspection")) {
            self.handleIntrospection(payload);
            return;
        }

        if (opts.hops > self.max_hops) {
            _ = self.loops_detected.fetchAdd(1, .monotonic);
            if (self.verbose) std.debug.print("EventBus: hop limit exceeded on '{s}' (source {})\n", .{ topic, opts.source });
            return error.HopLimitExceeded;
        }

        const id = self.next_msg_id.fetchAdd(1, .monotonic);
        const base = EventMessage{
            .id = id,
            .topic = topic,
            .timestamp = opts.timestamp orelse std.time.milliTimestamp(),
            .source_node_id = opts.source,
            .qos = opts.qos,
            .payload = payload,
            .parent_id = opts.parent_id,
            .hops = opts.hops,
        };

        // 宛先の収集 (セルごとにまとめる)。1 プラグイン = 1 セルなのでセル数に上限は置かない。
        // 32 セルまではスタック上で済ませ、それを超えたらヒープに広げる
        var sfa = std.heap.stackFallback(32 * @sizeOf(Group), self.allocator);
        const ga = sfa.get();
        var groups: std.ArrayListUnmanaged(Group) = .{};
        defer {
            for (groups.items) |*g| g.subs.deinit(self.allocator);
            groups.deinit(ga);
        }

        // 宛先も保持も無ければメッセージ本体を確保しない
        var sm_opt: ?*SharedMsg = null;
        defer if (sm_opt) |sm| sm.release(self.allocator);
        {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.exact.get(topic)) |list| {
                for (list.items) |s| try addToGroup(self.allocator, ga, &groups, s, topic, opts.source);
            }
            for (self.wildcard.items) |w| {
                if (pattern.isMatch(w.pattern, topic)) try addToGroup(self.allocator, ga, &groups, w.sub, topic, opts.source);
            }
            if (groups.items.len > 0 or opts.qos == .Transient) {
                // 1 参照 = 発行処理自身 (defer で解放)
                const sm = try SharedMsg.create(self.allocator, base, 1);
                sm_opt = sm;
                if (opts.qos == .Transient) self.retainLocked(sm);
            }
        }

        if (self.graph) |g| g.recordPublish(opts.source, topic) catch {};

        const sm = sm_opt orelse return;
        const block = opts.qos == .Reliable and currentCell() == null;
        for (groups.items) |*g| {
            const subs = g.subs.toOwnedSlice(self.allocator) catch continue;
            sm.retain();
            self.tracker.inc();
            g.cell.push(.{ .msg = sm, .subs = subs }, block) catch |err| {
                self.tracker.dec();
                self.allocator.free(subs);
                sm.release(self.allocator);
                _ = g.cell.dropped.fetchAdd(1, .monotonic);
                _ = self.dropped_total.fetchAdd(1, .monotonic);
                if (err == error.QueueShutdown) return err;
                if (self.verbose) std.debug.print("QoS: drop '{s}' for cell '{s}' (queue full)\n", .{ topic, g.cell.name });
            };
        }
    }

    const Group = struct { cell: *Cell, subs: std.ArrayListUnmanaged(Subscriber) };

    fn addToGroup(allocator: std.mem.Allocator, ga: std.mem.Allocator, groups: *std.ArrayListUnmanaged(Group), s: Subscriber, topic: []const u8, source: u32) !void {
        // 発行元自身には届けない (タップを除く)。ここで除外しておけば自己宛てでキューが詰まらない
        if (s.node_id == source and !s.receive_own) return;
        if (!s.cell.allowsIn(topic)) return;
        for (groups.items) |*g| {
            if (g.cell == s.cell) {
                try g.subs.append(allocator, s);
                return;
            }
        }
        const g = try groups.addOne(ga);
        g.* = .{ .cell = s.cell, .subs = .{} };
        try g.subs.append(allocator, s);
    }

    fn retainLocked(self: *EventBus, sm: *SharedMsg) void {
        if (self.retained.getEntry(sm.msg.topic)) |e| {
            e.value_ptr.*.release(self.allocator);
            sm.retain();
            e.key_ptr.* = sm.msg.topic;
            e.value_ptr.* = sm;
            return;
        }
        if (self.retained.count() >= self.max_retained) return;
        sm.retain();
        self.retained.put(self.allocator, sm.msg.topic, sm) catch sm.release(self.allocator);
    }

    pub const RetainedEntry = struct { topic: []u8, payload: []u8, ts: i64 = 0 };

    /// Transient の最新値のコピーを返す (スナップショット用)。呼び出し側が free する。
    pub fn snapshotRetained(self: *EventBus, allocator: std.mem.Allocator, filter: ?*const fn ([]const u8) bool) !std.ArrayListUnmanaged(RetainedEntry) {
        var out: std.ArrayListUnmanaged(RetainedEntry) = .{};
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.retained.valueIterator();
        while (it.next()) |m| {
            if (filter) |f| if (!f(m.*.msg.topic)) continue;
            try out.append(allocator, .{ .topic = try allocator.dupe(u8, m.*.msg.topic), .payload = try allocator.dupe(u8, m.*.msg.payload), .ts = m.*.msg.timestamp });
        }
        return out;
    }

    /// 保持中の最新値の payload をコピーして返す
    pub fn retainedPayload(self: *EventBus, allocator: std.mem.Allocator, topic: []const u8) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const m = self.retained.get(topic) orelse return null;
        return allocator.dupe(u8, m.msg.payload) catch null;
    }

    fn handleIntrospection(self: *EventBus, payload: []const u8) void {
        var level_str: []const u8 = std.mem.trim(u8, payload, " \t\r\n\"");
        var parsed: ?std.json.Parsed(std.json.Value) = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch null;
        defer if (parsed) |*p| p.deinit();
        if (parsed) |p| switch (p.value) {
            .string => |s| level_str = s,
            .object => |o| if (o.get("level")) |v| {
                if (v == .string) level_str = v.string;
            },
            else => {},
        };
        var buf: [32]u8 = undefined;
        if (level_str.len >= buf.len) return;
        const lower = std.ascii.lowerString(&buf, level_str);
        const level = std.meta.stringToEnum(IntrospectionLevel, lower) orelse return;
        const old: IntrospectionLevel = @enumFromInt(self.introspection_level.swap(@intFromEnum(level), .acq_rel));
        if (old == level) return;
        if (self.verbose) std.debug.print("Introspection: Level changed to {s}\n", .{@tagName(level)});
        var evt_buf: [128]u8 = undefined;
        const evt = std.fmt.bufPrint(&evt_buf, "{{\"from\":\"{s}\",\"to\":\"{s}\"}}", .{ @tagName(old), @tagName(level) }) catch return;
        self.publish("core.system.introspection.changed", evt, .Transient, 0) catch {};
    }
};

// ======================================================================
// Tests
// ======================================================================

var test_count = std.atomic.Value(u32).init(0);
fn countCb(_: ?*anyopaque, _: *const EventMessage) void {
    _ = test_count.fetchAdd(1, .monotonic);
}

test "EventBus: basic delivery via executor" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    try bus.subscribe("t.a", 2, countCb, null);
    try bus.start();
    try bus.publish("t.a", "x", .Reliable, 1);
    try bus.publish("t.b", "x", .Reliable, 1);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), test_count.load(.monotonic));
}

test "EventBus: one publish reaches every cell (no fan-out cap)" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    // 以前は宛先セルが 32 を超えると 33 個目以降に黙って届かなかった
    var i: u32 = 0;
    while (i < 40) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "plugin.p{d}", .{i});
        const cell = try bus.createCell(name, .{ .trust = .untrusted });
        try bus.subscribeEx("t.fan", 100 + i, countCb, null, .{ .cell = cell });
    }
    try bus.start();
    try bus.publish("t.fan", "x", .Reliable, 1);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 40), test_count.load(.monotonic));
}

test "EventBus QoS: Reliable blocks when the target cell queue is full" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 2);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    try bus.subscribe("t", 2, countCb, null);
    try bus.publish("t", "1", .BestEffort, 1);
    try bus.publish("t", "2", .BestEffort, 1);
    const th = try std.Thread.spawn(.{}, struct {
        fn run(b: *EventBus) void {
            b.publish("t", "3", .Reliable, 1) catch {};
        }
    }.run, .{&bus});
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(usize, 2), bus.core_cell.queueDepth());
    try bus.start(); // 消費が始まると Reliable の publisher が抜ける
    th.join();
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 3), test_count.load(.monotonic));
}

test "EventBus QoS: BestEffort drops when full" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 1);
    defer bus.deinit();
    bus.verbose = false;
    try bus.subscribe("t", 2, countCb, null);
    try bus.publish("t", "1", .BestEffort, 1);
    try bus.publish("t", "2", .BestEffort, 1);
    try std.testing.expectEqual(@as(usize, 1), bus.core_cell.queueDepth());
    try std.testing.expectEqual(@as(u64, 1), bus.dropped_total.load(.monotonic));
}

test "EventBus: messages without subscribers are not queued" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 1);
    defer bus.deinit();
    bus.verbose = false;
    try bus.publish("nobody.listens", "x", .BestEffort, 1);
    try std.testing.expectEqual(@as(usize, 0), bus.core_cell.queueDepth());
}

test "EventBus QoS: Transient is replayed to a new subscriber through the queue" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 8);
    defer bus.deinit();
    bus.verbose = false;
    try bus.publish("state", "v1", .Transient, 1);
    try bus.publish("state", "v2", .Transient, 1);

    const S = struct {
        var got: [8]u8 = undefined;
        var len: usize = 0;
        fn cb(_: ?*anyopaque, msg: *const EventMessage) void {
            @memcpy(got[0..msg.payload.len], msg.payload);
            len = msg.payload.len;
        }
    };
    try bus.subscribe("state", 2, S.cb, null);
    // 同期では呼ばれない (ロック中のコールバックはデッドロックの原因)
    try std.testing.expectEqual(@as(usize, 0), S.len);
    try bus.start();
    bus.waitIdle();
    try std.testing.expectEqualStrings("v2", S.got[0..S.len]);
}

test "EventBus: Transient replay to wildcard subscribers" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 8);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    try bus.publish("st.a", "1", .Transient, 1);
    try bus.publish("st.b", "2", .Transient, 1);
    try bus.publish("ev.c", "3", .BestEffort, 1);
    try bus.subscribe("st.#", 2, countCb, null);
    try bus.start();
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 2), test_count.load(.monotonic));
}

test "EventBus: subscribe is idempotent per (node, pattern)" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 8);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    try bus.subscribe("t.x", 2, countCb, null);
    try bus.subscribe("t.x", 2, countCb, null);
    try bus.subscribe("t.#", 2, countCb, null);
    try bus.subscribe("t.#", 2, countCb, null);
    try std.testing.expectEqual(@as(usize, 2), bus.subscriptionCount(2));
    try bus.start();
    try bus.publish("t.x", "1", .BestEffort, 1);
    bus.waitIdle();
    // 完全一致と `#` で 2 回 (パターンが違うので別購読)
    try std.testing.expectEqual(@as(u32, 2), test_count.load(.monotonic));
    bus.unsubscribeAll(2);
    try std.testing.expectEqual(@as(usize, 0), bus.subscriptionCount(2));
}

test "EventBus: wildcard dispatch" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 10);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    try bus.subscribe("ext.twitch.#", 2, countCb, null);
    try bus.subscribe("ext.+.chat.*", 3, countCb, null);
    try bus.start();
    try bus.publish("ext.twitch.connected", "{}", .BestEffort, 1);
    try bus.publish("ext.twitch.chat.message", "{}", .BestEffort, 1);
    try bus.publish("other.topic", "{}", .BestEffort, 1);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 3), test_count.load(.monotonic));
}

test "EventBus: invalid topics are rejected" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 4);
    defer bus.deinit();
    bus.verbose = false;
    try std.testing.expectError(error.InvalidTopic, bus.publish("a.\"b", "x", .BestEffort, 1));
    try std.testing.expectError(error.InvalidTopic, bus.publish("a.#", "x", .BestEffort, 1));
    try std.testing.expectError(error.InvalidTopic, bus.subscribe("", 1, countCb, null));
}

test "EventBus: hop limit stops echo loops" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 4);
    defer bus.deinit();
    bus.verbose = false;
    try std.testing.expectError(error.HopLimitExceeded, bus.publishEx("a.b", "x", .{ .hops = 17 }));
    try std.testing.expectEqual(@as(u64, 1), bus.loops_detected.load(.monotonic));
}

test "EventBus: a stalled cell does not delay other cells (HOL isolation)" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 64);
    defer bus.deinit();
    bus.verbose = false;
    const slow = try bus.createCell("slow", .{});
    const fast = try bus.createCell("fast", .{});

    const Slow = struct {
        var gate = std.Thread.ResetEvent{};
        fn cb(_: ?*anyopaque, _: *const EventMessage) void {
            gate.wait(); // ゲートが開くまで止まり続ける (無限ループの代わり)
        }
    };
    const Fast = struct {
        var n = std.atomic.Value(u32).init(0);
        fn cb(_: ?*anyopaque, _: *const EventMessage) void {
            _ = n.fetchAdd(1, .monotonic);
        }
    };
    Slow.gate.reset();
    Fast.n.store(0, .monotonic);
    try bus.subscribeEx("x", 10, Slow.cb, null, .{ .cell = slow });
    try bus.subscribeEx("x", 11, Fast.cb, null, .{ .cell = fast });
    try bus.start();
    var i: usize = 0;
    while (i < 20) : (i += 1) try bus.publish("x", "m", .BestEffort, 1);

    var waited: usize = 0;
    while (Fast.n.load(.monotonic) < 20 and waited < 200) : (waited += 1) std.Thread.sleep(std.time.ns_per_ms);
    try std.testing.expectEqual(@as(u32, 20), Fast.n.load(.monotonic));
    Slow.gate.set();
    bus.waitIdle();
}

test "EventBus: bridges_in filters what a cell can receive" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 8);
    defer bus.deinit();
    bus.verbose = false;
    test_count.store(0, .monotonic);
    const c = try bus.createCell("sandbox", .{ .trust = .untrusted, .bridges_in = &.{"ext.#"} });
    try bus.subscribeEx("#", 5, countCb, null, .{ .cell = c });
    try bus.start();
    try bus.publish("ext.chat.x", "1", .BestEffort, 1);
    try bus.publish("core.obs.request.SetX", "2", .BestEffort, 1);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), test_count.load(.monotonic));
}

test "EventBus: Introspection normalization" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 10);
    defer bus.deinit();
    bus.verbose = false;
    try bus.publish("core.system.introspection", "OFF", .BestEffort, 1);
    try std.testing.expectEqual(IntrospectionLevel.off, @as(IntrospectionLevel, @enumFromInt(bus.introspection_level.load(.monotonic))));
    try bus.publish("core.system.introspection", "\"METADATA\"", .BestEffort, 1);
    try std.testing.expectEqual(IntrospectionLevel.metadata, @as(IntrospectionLevel, @enumFromInt(bus.introspection_level.load(.monotonic))));
    try bus.publish("core.system.introspection", "{\"level\":\"CONTENTS\"}", .BestEffort, 1);
    try std.testing.expectEqual(IntrospectionLevel.contents, @as(IntrospectionLevel, @enumFromInt(bus.introspection_level.load(.monotonic))));
    try bus.publish("core.system.introspection", "off", .BestEffort, 1);
    try std.testing.expectEqual(IntrospectionLevel.off, @as(IntrospectionLevel, @enumFromInt(bus.introspection_level.load(.monotonic))));
}

test "EventBus: introspection change is announced" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 10);
    defer bus.deinit();
    bus.verbose = false;
    bus.introspection_level.store(@intFromEnum(IntrospectionLevel.metadata), .monotonic);
    const S = struct {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        fn cb(_: ?*anyopaque, msg: *const EventMessage) void {
            @memcpy(buf[0..msg.payload.len], msg.payload);
            len = msg.payload.len;
        }
    };
    try bus.subscribe("core.system.introspection.changed", 1, S.cb, null);
    try bus.start();
    try bus.publish("core.system.introspection", "contents", .BestEffort, 1);
    bus.waitIdle();
    try std.testing.expectEqualStrings("{\"from\":\"metadata\",\"to\":\"contents\"}", S.buf[0..S.len]);
}

test "EventBus: large payload reaches a tap subscriber" {
    const a = std.testing.allocator;
    var bus = try EventBus.init(a, 10);
    defer bus.deinit();
    bus.verbose = false;
    const big = try a.alloc(u8, 64 * 1024);
    defer a.free(big);
    @memset(big, 'A');
    const S = struct {
        var n: usize = 0;
        fn cb(_: ?*anyopaque, msg: *const EventMessage) void {
            n = msg.payload.len;
        }
    };
    try bus.subscribeEx("#", 1, S.cb, null, .{ .receive_own = true });
    try bus.start();
    try bus.publish("some.user.topic", big, .BestEffort, 1);
    bus.waitIdle();
    try std.testing.expectEqual(@as(usize, 64 * 1024), S.n);
}
