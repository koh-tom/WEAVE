//! OBS WebSocket v5 への送信ノード (ObsEgress)。
//!
//! `core.obs.request.<RequestType>` を購読し、OBS に要求を送る。トピックの末尾が要求種別で、
//! これが権限の単位 (manifest の publish 宣言) になる。
//!
//! v1 の変更点:
//! - **意図した状態の再適用 (R6)**: 冪等な状態設定要求 (表示切替・シーン切替など) を
//!   「WEAVE が意図した OBS の状態」として保持し、OBS に (再) 接続したら全て再適用する。
//!   OBS が落ちて戻っても、オーバーレイの表示状態が自動で元通りになる。
//!   未接続中の要求も捨てずに、状態として合流させて接続後に送る。
//! - **生フレームの素通しを廃止**: 以前は payload に "op" があれば OBS へそのまま送っており、
//!   SetSceneItemEnabled しか許可されていないプラグインが任意の要求 (配信停止など) を送れた。
//! - 自前 WebSocket (ws_proto) を使い、ランダムなキーとマスク・Accept の検証を行う。
//! - 接続状態を `core.obs.link` で通知し、切断中はノード状態を degraded にする。
//! - **OBS が断った要求を配信者に伝える**: どのプラグインの・どの名前 (ソース / シーン) への要求だったかと、
//!   OBS にある近い名前 (「もしかして」) を `core.obs.problem` で出す。同じ要求が後で通れば resolved を出す。
//!   名前違いは配信の現場でいちばん多い「動かない」の原因で、これまではログに 1 行出るだけだった。

const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const ws = @import("../transport/ws_proto.zig");
const log = @import("../common/log.zig");
const blast = @import("../audit/blast.zig");

/// 冪等な (最後の値だけが意味を持つ) 要求。再接続時に再適用する
const STATEFUL = [_]struct { request: []const u8, keys: []const []const u8 }{
    .{ .request = "SetSceneItemEnabled", .keys = &.{ "sceneName", "sceneItemId" } },
    .{ .request = "SetCurrentProgramScene", .keys = &.{} },
    .{ .request = "SetInputMute", .keys = &.{"inputName"} },
    .{ .request = "SetSourceFilterEnabled", .keys = &.{ "sourceName", "filterName" } },
    // テキストソースの内容など (countdown が使う)。入力ごとに最後の設定だけが意味を持つ
    .{ .request = "SetInputSettings", .keys = &.{"inputName"} },
};

/// 「WEAVE が意図した OBS の状態」。キー = 要求種別 + 対象を特定するフィールド
pub const DesiredState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// key -> { request_type, request_data (JSON) }
    map: std.StringArrayHashMapUnmanaged(Entry) = .{},

    /// sender = 要求を出したノード (OBS に断られたとき、どのプラグインの要求かを伝えるため)
    pub const Entry = struct { request_type: []u8, data: []u8, sender: u32 = 0 };

    pub fn init(allocator: std.mem.Allocator) DesiredState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DesiredState) void {
        var it = self.map.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.request_type);
            self.allocator.free(e.value_ptr.data);
        }
        self.map.deinit(self.allocator);
    }

    /// 要求が状態設定なら記録して true を返す
    pub fn record(self: *DesiredState, request_type: []const u8, data_json: []const u8) !bool {
        return self.recordFrom(request_type, data_json, 0);
    }

    pub fn recordFrom(self: *DesiredState, request_type: []const u8, data_json: []const u8, sender: u32) !bool {
        const spec = for (STATEFUL) |s| {
            if (std.mem.eql(u8, s.request, request_type)) break s;
        } else return false;

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;

        var key: std.ArrayListUnmanaged(u8) = .{};
        defer key.deinit(self.allocator);
        try key.appendSlice(self.allocator, request_type);
        for (spec.keys) |k| {
            try key.append(self.allocator, '|');
            const v = parsed.value.object.get(k) orelse return false;
            try key.writer(self.allocator).print("{f}", .{std.json.fmt(v, .{})});
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.map.getOrPut(self.allocator, key.items);
        if (gop.found_existing) {
            self.allocator.free(gop.value_ptr.data);
            gop.value_ptr.data = try self.allocator.dupe(u8, data_json);
            gop.value_ptr.sender = sender;
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key.items);
            gop.value_ptr.* = .{
                .request_type = try self.allocator.dupe(u8, request_type),
                .data = try self.allocator.dupe(u8, data_json),
                .sender = sender,
            };
        }
        return true;
    }

    pub fn count(self: *DesiredState) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.map.count();
    }

    /// 全エントリをコピーして返す (呼び出し側が freeCopies で解放)
    pub fn copies(self: *DesiredState, allocator: std.mem.Allocator) ![]Entry {
        self.mutex.lock();
        defer self.mutex.unlock();
        const out = try allocator.alloc(Entry, self.map.count());
        var i: usize = 0;
        var it = self.map.iterator();
        while (it.next()) |e| : (i += 1) {
            out[i] = .{ .request_type = try allocator.dupe(u8, e.value_ptr.request_type), .data = try allocator.dupe(u8, e.value_ptr.data), .sender = e.value_ptr.sender };
        }
        return out;
    }

    pub fn freeCopies(allocator: std.mem.Allocator, entries: []Entry) void {
        for (entries) |e| {
            allocator.free(e.request_type);
            allocator.free(e.data);
        }
        allocator.free(entries);
    }
};

/// OBS が断った要求を「誰の・どの名前への要求か」と結びつけ、OBS にある近い名前を探す
pub const ProblemTracker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// 送った要求 (requestId → 送り主と対象)。古いものから上書きするリング
    ring: [128]Pending = [_]Pending{.{}} ** 128,
    ring_pos: usize = 0,
    /// OBS にある入力 (ソース) とシーンの名前 (GetInputList / GetSceneList の応答)
    inputs: std.ArrayListUnmanaged([]u8) = .{},
    scenes: std.ArrayListUnmanaged([]u8) = .{},
    /// いま断られている (送り主|要求|対象)。後で通ったら resolved を出す
    failing: std.StringHashMapUnmanaged(void) = .{},

    pub const Kind = enum { input, scene, other };

    pub const Pending = struct {
        id: u64 = 0,
        sender: u32 = 0,
        request_buf: [64]u8 = undefined,
        request_len: usize = 0,
        target_buf: [128]u8 = undefined,
        target_len: usize = 0,
        kind: Kind = .other,

        pub fn request(self: *const Pending) []const u8 {
            return self.request_buf[0..self.request_len];
        }
        pub fn target(self: *const Pending) []const u8 {
            return self.target_buf[0..self.target_len];
        }
    };

    pub fn init(allocator: std.mem.Allocator) ProblemTracker {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProblemTracker) void {
        freeNames(self.allocator, &self.inputs);
        freeNames(self.allocator, &self.scenes);
        var it = self.failing.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.failing.deinit(self.allocator);
    }

    fn freeNames(a: std.mem.Allocator, list: *std.ArrayListUnmanaged([]u8)) void {
        for (list.items) |n| a.free(n);
        list.deinit(a);
    }

    /// 要求の対象 (ソース名 / シーン名) を requestData から取り出す
    pub fn targetOf(data_json: []const u8, buf: []u8) struct { name: []const u8, kind: Kind } {
        const F = struct { inputName: ?[]const u8 = null, sourceName: ?[]const u8 = null, sceneName: ?[]const u8 = null };
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const v = std.json.parseFromSliceLeaky(F, fba.allocator(), data_json, .{ .ignore_unknown_fields = true }) catch return .{ .name = "", .kind = .other };
        if (v.inputName) |n| return .{ .name = n, .kind = .input };
        if (v.sourceName) |n| return .{ .name = n, .kind = .input };
        if (v.sceneName) |n| return .{ .name = n, .kind = .scene };
        return .{ .name = "", .kind = .other };
    }

    pub fn noteRequest(self: *ProblemTracker, id: u64, sender: u32, request_type: []const u8, data_json: []const u8) void {
        var scratch: [2048]u8 = undefined;
        const t = targetOf(data_json, &scratch);
        self.mutex.lock();
        defer self.mutex.unlock();
        var p = &self.ring[self.ring_pos % self.ring.len];
        self.ring_pos += 1;
        p.* = .{ .id = id, .sender = sender, .kind = t.kind };
        p.request_len = @min(request_type.len, p.request_buf.len);
        @memcpy(p.request_buf[0..p.request_len], request_type[0..p.request_len]);
        p.target_len = @min(t.name.len, p.target_buf.len);
        @memcpy(p.target_buf[0..p.target_len], t.name[0..p.target_len]);
    }

    pub fn take(self: *ProblemTracker, id: u64) ?Pending {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.ring) |*p| {
            if (p.id == id and id != 0) {
                const out = p.*;
                p.id = 0;
                return out;
            }
        }
        return null;
    }

    pub fn setNames(self: *ProblemTracker, kind: Kind, names: []const []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = if (kind == .scene) &self.scenes else &self.inputs;
        for (list.items) |n| self.allocator.free(n);
        list.clearRetainingCapacity();
        for (names) |n| {
            const d = self.allocator.dupe(u8, n) catch continue;
            list.append(self.allocator, d) catch self.allocator.free(d);
        }
    }

    /// OBS にある近い名前 (大文字小文字・空白の違い、または 1 〜数文字の打ち間違い)。呼び出し側の buf に写して返す
    pub fn suggest(self: *ProblemTracker, kind: Kind, target: []const u8, buf: []u8) ?[]const u8 {
        if (target.len == 0) return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        const lists: []const []const []u8 = switch (kind) {
            .scene => &.{self.scenes.items},
            .input => &.{ self.inputs.items, self.scenes.items }, // sourceName はシーンも指せる
            .other => return null,
        };
        var best: ?[]const u8 = null;
        var best_d: usize = std.math.maxInt(usize);
        const max_d = @max(@as(usize, 2), target.len / 4);
        for (lists) |list| for (list) |n| {
            if (std.mem.eql(u8, n, target)) return null; // 名前は合っている (別の理由で断られた)
            const d: usize = if (looseEql(n, target)) 0 else (blast.editDistance(n, target, max_d) orelse continue);
            if (d < best_d) {
                best_d = d;
                best = n;
            }
        };
        const b = best orelse return null;
        const len = @min(b.len, buf.len);
        @memcpy(buf[0..len], b[0..len]);
        return buf[0..len];
    }

    /// 大文字小文字と空白・_ - の違いを無視して同じか
    fn looseEql(a: []const u8, b: []const u8) bool {
        var i: usize = 0;
        var j: usize = 0;
        while (true) {
            while (i < a.len and isSep(a[i])) i += 1;
            while (j < b.len and isSep(b[j])) j += 1;
            if (i == a.len or j == b.len) return i == a.len and j == b.len;
            if (std.ascii.toLower(a[i]) != std.ascii.toLower(b[j])) return false;
            i += 1;
            j += 1;
        }
    }
    fn isSep(c: u8) bool {
        return c == ' ' or c == '_' or c == '-';
    }

    /// 断られた / 通ったを記録する。状態が変わったときだけ true (問題を出す / 解消を出す)
    pub fn setFailing(self: *ProblemTracker, p: *const Pending, failing: bool) bool {
        var kbuf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d}|{s}|{s}", .{ p.sender, p.request(), p.target() }) catch return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (failing) {
            if (self.failing.contains(key)) return true; // 同じ問題でも毎回知らせる (直したつもりで直っていない)
            const owned = self.allocator.dupe(u8, key) catch return true;
            self.failing.put(self.allocator, owned, {}) catch self.allocator.free(owned);
            return true;
        }
        if (self.failing.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            return true;
        }
        return false;
    }

    /// 要求が通ったときに呼ぶ。同じプラグインの同じ種類の要求で、断られていたものを全部「解消」として取り出す
    /// (名前を直して別の名前で通った場合も、打ち間違えた名前の問題が残り続けないように)。
    /// 取り出した対象名を buf に詰めて返す (最大 8 件)
    pub fn resolveSameKind(self: *ProblemTracker, p: *const Pending, buf: *[8][128]u8, lens: *[8]usize) usize {
        var pbuf: [128]u8 = undefined;
        const prefix = std.fmt.bufPrint(&pbuf, "{d}|{s}|", .{ p.sender, p.request() }) catch return 0;
        self.mutex.lock();
        defer self.mutex.unlock();
        var n: usize = 0;
        var keys: [8][]const u8 = undefined;
        var it = self.failing.keyIterator();
        while (it.next()) |k| {
            if (n == keys.len) break;
            if (std.mem.startsWith(u8, k.*, prefix)) {
                keys[n] = k.*;
                n += 1;
            }
        }
        for (keys[0..n], 0..) |k, i| {
            const t = k[prefix.len..];
            lens[i] = @min(t.len, buf[i].len);
            @memcpy(buf[i][0..lens[i]], t[0..lens[i]]);
            _ = self.failing.remove(k);
            self.allocator.free(k);
        }
        return n;
    }
};

/// 「入力がバスに入ってから OBS に送るまで」の時間の集計。直近 2048 件から分位点を出す。
/// 入力から始まった連鎖 (hops > 0) の要求だけを数える (プラグインの起動時の初期表示などは除く)
pub const LatencyStats = struct {
    mutex: std.Thread.Mutex = .{},
    ring: [2048]u32 = undefined,
    len: usize = 0,
    pos: usize = 0,
    total: u64 = 0,
    last_pub_ms: i64 = 0,

    pub const Summary = struct { samples: u64 = 0, p50_us: u32 = 0, p95_us: u32 = 0, p99_us: u32 = 0, max_us: u32 = 0 };

    pub fn record(self: *LatencyStats, us: i64) void {
        const v: u32 = @intCast(std.math.clamp(us, 0, std.math.maxInt(u32)));
        self.mutex.lock();
        defer self.mutex.unlock();
        self.ring[self.pos] = v;
        self.pos = (self.pos + 1) % self.ring.len;
        if (self.len < self.ring.len) self.len += 1;
        self.total += 1;
    }

    pub fn summary(self: *LatencyStats) Summary {
        var buf: [2048]u32 = undefined;
        self.mutex.lock();
        const n = self.len;
        @memcpy(buf[0..n], self.ring[0..n]);
        const total = self.total;
        self.mutex.unlock();
        if (n == 0) return .{};
        std.mem.sort(u32, buf[0..n], {}, std.sort.asc(u32));
        return .{ .samples = total, .p50_us = buf[(n - 1) * 50 / 100], .p95_us = buf[(n - 1) * 95 / 100], .p99_us = buf[(n - 1) * 99 / 100], .max_us = buf[n - 1] };
    }

    /// 入力から始まった要求を OBS に送ったところで呼ぶ。前回の報告から 500 ms 以上たっていれば core.obs.latency を出す
    pub fn onSent(self: *LatencyStats, bus: *event_bus.EventBus, node_id: u32, msg: *const event_bus.EventMessage) void {
        self.onSentAt(bus, node_id, msg, std.time.microTimestamp());
    }

    pub fn onSentAt(self: *LatencyStats, bus: *event_bus.EventBus, node_id: u32, msg: *const event_bus.EventMessage, sent_us: i64) void {
        if (msg.hops == 0 or msg.origin_us == 0) return;
        self.record(sent_us - msg.origin_us);
        const now = std.time.milliTimestamp();
        if (now - self.last_pub_ms < 500) return;
        self.last_pub_ms = now;
        var buf: [192]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(self.summary(), .{})}) catch return;
        bus.publish("core.obs.latency", w.buffered(), .Transient, node_id) catch {};
    }
};

pub const ObsEgressNode = struct {
    /// バスにつないだか (attach 済み)
    attached: bool = false,
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    password: ?[]const u8,
    host: ?[]const u8 = null,
    port: u16 = 0,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    identified: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// stream と送信を守る
    mutex: std.Thread.Mutex = .{},
    stream: ?std.net.Stream = null,
    thread: ?std.Thread = null,

    desired: DesiredState,
    /// 状態でない要求 (コマンド) の送信待ち。接続後に順に送る。上限を超えたら古いものを捨てる
    outbox: std.ArrayListUnmanaged([]u8) = .{},
    outbox_max: usize = 64,
    next_request: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),
    problems: ProblemTracker,
    latency: LatencyStats = .{},
    connections: u64 = 0,
    reconnects: u64 = 0,
    reapplied_total: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, password: ?[]const u8) !*ObsEgressNode {
        const self = try allocator.create(ObsEgressNode);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .password = if (password) |p| try allocator.dupe(u8, p) else null,
            .desired = DesiredState.init(allocator),
            .problems = ProblemTracker.init(allocator),
        };
        return self;
    }

    pub fn stop(self: *ObsEgressNode) void {
        self.running.store(false, .release);
        self.mutex.lock();
        if (self.stream) |s| std.posix.shutdown(s.handle, .both) catch {};
        self.mutex.unlock();
    }

    pub fn deinit(self: *ObsEgressNode) void {
        self.stop();
        if (self.thread) |t| t.join();
        self.mutex.lock();
        if (self.stream) |s| s.close();
        self.stream = null;
        for (self.outbox.items) |o| self.allocator.free(o);
        self.outbox.deinit(self.allocator);
        self.mutex.unlock();
        self.desired.deinit();
        self.problems.deinit();
        if (self.password) |p| self.allocator.free(p);
        if (self.host) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }

    /// バスにつなぐ (グラフ登録と購読)。プラグインより先に呼ぶと、プラグインが起動時に出した要求も
    /// 「意図した状態」として受け取り、OBS に接続したあとで送れる。connect() は未実行ならこれも行う
    pub fn attach(self: *ObsEgressNode) !void {
        if (self.attached) return;
        // OBS への送信は専用セル "egress" で行う (OBS が遅くても他の配送を待たせない)
        const cell = self.bus.getCell("egress") orelse try self.bus.createCell("egress", .{ .trust = .core });
        // グラフ登録を購読より先に行う (逆順だと購読が記録されず、トポロジから OBS への辺が消える)
        if (self.bus.graph) |g| try g.registerNodeIn(self.node_id, "ObsEgress", .native, cell.name);
        try self.bus.subscribeEx("core.obs.request.*", self.node_id, ObsEgressNode.onMessage, self, .{ .cell = cell });
        self.attached = true;
    }

    /// OBS への接続をバックグラウンドで開始する (まだならバスにもつなぐ)
    pub fn connect(self: *ObsEgressNode, host: []const u8, port: u16) !void {
        self.host = try self.allocator.dupe(u8, host);
        self.port = port;
        self.running.store(true, .release);
        try self.attach();
        self.thread = try std.Thread.spawn(.{}, runRetryLoop, .{self});
    }

    fn publishLink(self: *ObsEgressNode, connected: bool) void {
        var buf: [160]u8 = undefined;
        const payload = std.fmt.bufPrint(&buf, "{{\"connected\":{},\"reconnects\":{d},\"desired\":{d}}}", .{ connected, self.reconnects, self.desired.count() }) catch return;
        self.bus.publish("core.obs.link", payload, .Transient, self.node_id) catch {};
        if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, if (connected) .active else .degraded);
    }

    fn runRetryLoop(self: *ObsEgressNode) void {
        // OBS の再起動に素早く追従するため、最初は短い間隔で再試行する
        const backoff_ms = [_]u64{ 250, 250, 250, 250, 500, 1000, 2000, 5000 };
        var attempt: usize = 0;
        while (self.running.load(.acquire)) {
            self.doConnectAndReceive() catch |err| {
                if (err != error.EndOfStream and self.running.load(.acquire)) {
                    if (attempt == 0) log.warn("ObsEgress: connection failed: {any}", .{err});
                }
            };
            const was_identified = self.identified.swap(false, .acq_rel);
            self.mutex.lock();
            if (self.stream) |s| s.close();
            self.stream = null;
            self.mutex.unlock();
            if (was_identified) {
                attempt = 0;
                self.publishLink(false);
                log.warn("ObsEgress: disconnected from OBS; will re-apply {d} desired state(s) on reconnect", .{self.desired.count()});
            }
            if (!self.running.load(.acquire)) break;
            const wait = backoff_ms[@min(attempt, backoff_ms.len - 1)];
            attempt += 1;
            var slept: u64 = 0;
            while (slept < wait and self.running.load(.acquire)) : (slept += 50) std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    fn doConnectAndReceive(self: *ObsEgressNode) !void {
        const host = self.host orelse return;
        const address = try std.net.Address.resolveIp(host, self.port);
        const stream = try std.net.tcpConnectToAddress(address);
        // フレームのヘッダと本体を別々に書くので、Nagle で送信が数十 ms 遅れないようにする
        const one: c_int = 1;
        std.posix.setsockopt(stream.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
        self.mutex.lock();
        self.stream = stream;
        self.mutex.unlock();

        try ws.clientHandshake(stream, host, self.port, "/", "");
        log.info("ObsEgress: WebSocket handshake completed ({s}:{d})", .{ host, self.port });

        while (self.running.load(.acquire)) {
            const frame = try ws.readMessage(stream, self.allocator, 16 * 1024 * 1024);
            defer self.allocator.free(frame.payload);
            switch (frame.opcode) {
                .close => return error.EndOfStream,
                .ping => {
                    self.mutex.lock();
                    ws.writeFrame(stream, .pong, frame.payload, true) catch {};
                    self.mutex.unlock();
                    continue;
                },
                .text => {},
                else => continue,
            }
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const op = parsed.value.object.get("op") orelse continue;
            if (op != .integer) continue;
            const d = parsed.value.object.get("d") orelse continue;
            if (d != .object) continue;
            switch (op.integer) {
                0 => try self.handleHello(d.object),
                2 => self.onIdentified(),
                5 => self.onEvent(d.object, frame.payload),
                7 => self.onResponse(d.object),
                else => {},
            }
        }
    }

    fn handleHello(self: *ObsEgressNode, d: std.json.ObjectMap) !void {
        var buf: [512]u8 = undefined;
        var msg: []const u8 = undefined;
        if (d.get("authentication")) |auth| {
            if (auth != .object) return error.InvalidHello;
            const challenge_v = auth.object.get("challenge") orelse return error.InvalidHello;
            const salt_v = auth.object.get("salt") orelse return error.InvalidHello;
            if (challenge_v != .string or salt_v != .string) return error.InvalidHello;
            const password = self.password orelse return error.PasswordRequired;
            const secret = authString(password, salt_v.string, challenge_v.string);
            // eventSubscriptions = 173 = General(1) | Scenes(4) | Inputs(8) | Filters(32) | SceneItems(128)。
            // SceneItems が無いと本物の OBS は SceneItemEnableStateChanged を送ってこず、Inspector の
            // 「OBS の実際の状態」が (報告なし) のままになる (mock はイベントを自前で流すので気づかなかった)
            msg = try std.fmt.bufPrint(&buf, "{{\"op\":1,\"d\":{{\"rpcVersion\":1,\"authentication\":\"{s}\",\"eventSubscriptions\":173}}}}", .{secret});
        } else {
            msg = "{\"op\":1,\"d\":{\"rpcVersion\":1,\"eventSubscriptions\":173}}";
        }
        try self.sendRaw(msg);
    }

    /// OBS WebSocket v5 認証: base64(sha256(base64(sha256(password + salt)) + challenge))
    pub fn authString(password: []const u8, salt: []const u8, challenge: []const u8) [44]u8 {
        var h1: [32]u8 = undefined;
        var s1 = std.crypto.hash.sha2.Sha256.init(.{});
        s1.update(password);
        s1.update(salt);
        s1.final(&h1);
        var b1: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&b1, &h1);
        var h2: [32]u8 = undefined;
        var s2 = std.crypto.hash.sha2.Sha256.init(.{});
        s2.update(&b1);
        s2.update(challenge);
        s2.final(&h2);
        var out: [44]u8 = undefined;
        _ = std.base64.standard.Encoder.encode(&out, &h2);
        return out;
    }

    fn onIdentified(self: *ObsEgressNode) void {
        self.identified.store(true, .release);
        self.connections += 1;
        log.info("ObsEgress: identified with OBS", .{});
        // 名前の一覧を先に取る (この後の再適用が断られたとき「もしかして」を出せるように)
        self.refreshNames();
        self.reconcile();
        // 未接続中に溜まったコマンドを順に送る
        self.mutex.lock();
        const pending = self.outbox.toOwnedSlice(self.allocator) catch &.{};
        self.mutex.unlock();
        defer {
            for (pending) |p| self.allocator.free(p);
            self.allocator.free(pending);
        }
        for (pending) |p| self.sendRaw(p) catch {};
        self.publishLink(true);
    }

    /// 意図した状態を OBS に再適用する
    fn reconcile(self: *ObsEgressNode) void {
        const entries = self.desired.copies(self.allocator) catch return;
        defer DesiredState.freeCopies(self.allocator, entries);
        if (entries.len == 0) return;
        for (entries) |e| self.sendRequestFrom(e.request_type, e.data, e.sender) catch {};
        self.reapplied_total += entries.len;
        if (self.connections > 1) {
            self.reconnects += 1;
            log.info("ObsEgress: re-applied {d} desired state(s) after reconnect", .{entries.len});
        }
    }

    fn refreshNames(self: *ObsEgressNode) void {
        self.sendRaw("{\"op\":6,\"d\":{\"requestType\":\"GetInputList\",\"requestId\":\"weave-names-inputs\",\"requestData\":{}}}") catch {};
        self.sendRaw("{\"op\":6,\"d\":{\"requestType\":\"GetSceneList\",\"requestId\":\"weave-names-scenes\",\"requestData\":{}}}") catch {};
    }

    fn onEvent(self: *ObsEgressNode, d: std.json.ObjectMap, raw: []const u8) void {
        const et = d.get("eventType") orelse return;
        if (et != .string) return;
        // 名前が変わりうるイベントで一覧を取り直す
        for ([_][]const u8{ "InputCreated", "InputRemoved", "InputNameChanged", "SceneCreated", "SceneRemoved", "SceneNameChanged" }) |n| {
            if (std.mem.eql(u8, et.string, n)) self.refreshNames();
        }
        var topic_buf: [128]u8 = undefined;
        const topic = std.fmt.bufPrint(&topic_buf, "core.obs.event.{s}", .{et.string}) catch return;
        self.bus.publish(topic, raw, .Transient, self.node_id) catch {};
    }

    fn onResponse(self: *ObsEgressNode, d: std.json.ObjectMap) void {
        const status = d.get("requestStatus") orelse return;
        if (status != .object) return;
        const result = status.object.get("result") orelse return;
        const ok = !(result == .bool and !result.bool);
        const rid_v = d.get("requestId") orelse .null;
        const rid: []const u8 = if (rid_v == .string) rid_v.string else "";

        // 名前の一覧
        if (std.mem.startsWith(u8, rid, "weave-names-")) {
            if (ok) self.storeNames(d, std.mem.eql(u8, rid, "weave-names-scenes"));
            return;
        }
        const id = if (std.mem.startsWith(u8, rid, "weave-")) std.fmt.parseInt(u64, rid[6..], 10) catch 0 else 0;
        const p = self.problems.take(id) orelse {
            if (!ok) log.err("ObsEgress: OBS rejected a request: {s}", .{rid});
            return;
        };
        if (ok) {
            var tbuf: [8][128]u8 = undefined;
            var tlens: [8]usize = undefined;
            const n = self.problems.resolveSameKind(&p, &tbuf, &tlens);
            for (0..n) |i| {
                var q = p;
                q.target_len = @min(tlens[i], q.target_buf.len);
                @memcpy(q.target_buf[0..q.target_len], tbuf[i][0..q.target_len]);
                self.publishProblem(&q, 100, "", true);
            }
            return;
        }
        const code: i64 = if (status.object.get("code")) |c| (if (c == .integer) c.integer else 0) else 0;
        const comment = if (status.object.get("comment")) |c| (if (c == .string) c.string else "") else "";
        log.err("ObsEgress: OBS rejected {s} ({s}) from node {d}: {s}", .{ p.request(), p.target(), p.sender, comment });
        _ = self.problems.setFailing(&p, true);
        self.publishProblem(&p, code, comment, false);
    }

    fn storeNames(self: *ObsEgressNode, d: std.json.ObjectMap, scenes: bool) void {
        const rd = d.get("responseData") orelse return;
        if (rd != .object) return;
        const arr = rd.object.get(if (scenes) "scenes" else "inputs") orelse return;
        if (arr != .array) return;
        var names = std.ArrayListUnmanaged([]const u8){};
        defer names.deinit(self.allocator);
        for (arr.array.items) |it| {
            if (it != .object) continue;
            const n = it.object.get(if (scenes) "sceneName" else "inputName") orelse continue;
            if (n == .string) names.append(self.allocator, n.string) catch {};
        }
        self.problems.setNames(if (scenes) .scene else .input, names.items);
    }

    fn publishProblem(self: *ObsEgressNode, p: *const ProblemTracker.Pending, code: i64, comment: []const u8, resolved: bool) void {
        var sbuf: [128]u8 = undefined;
        // 600 = ResourceNotFound (名前が見つからない)
        const suggestion: ?[]const u8 = if (!resolved and code == 600) self.problems.suggest(p.kind, p.target(), &sbuf) else null;
        var out = std.io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        out.writer.print("{f}", .{std.json.fmt(.{
            .node_id = p.sender,
            .request = p.request(),
            .target = p.target(),
            .target_kind = @tagName(p.kind),
            .code = code,
            .comment = comment,
            .suggestion = suggestion,
            .resolved = resolved,
        }, .{})}) catch return;
        self.bus.publish("core.obs.problem", out.written(), .Transient, self.node_id) catch {};
    }

    fn sendRaw(self: *ObsEgressNode, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.stream orelse return error.NotConnected;
        try ws.writeFrame(s, .text, data, true);
    }

    fn buildRequest(self: *ObsEgressNode, request_type: []const u8, data_json: []const u8, sender: u32) ![]u8 {
        const id = self.next_request.fetchAdd(1, .monotonic);
        self.problems.noteRequest(id, sender, request_type, data_json);
        return std.fmt.allocPrint(self.allocator, "{{\"op\":6,\"d\":{{\"requestType\":\"{s}\",\"requestId\":\"weave-{d}\",\"requestData\":{s}}}}}", .{ request_type, id, data_json });
    }

    fn sendRequestFrom(self: *ObsEgressNode, request_type: []const u8, data_json: []const u8, sender: u32) !void {
        const req = try self.buildRequest(request_type, data_json, sender);
        defer self.allocator.free(req);
        try self.sendRaw(req);
    }

    /// 要求を処理する (egress セルの executor 上)
    pub fn handleRequest(self: *ObsEgressNode, request_type: []const u8, payload: []const u8) void {
        self.handleRequestFrom(request_type, payload, 0);
    }

    pub fn handleRequestFrom(self: *ObsEgressNode, request_type: []const u8, payload: []const u8, sender: u32) void {
        // 要求種別はトピックの一部なので英数字のみ (validTopic 済み)。requestData は JSON オブジェクトに限る
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch {
            log.warn("ObsEgress: {s}: requestData must be a JSON object", .{request_type});
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return;

        const stateful = self.desired.recordFrom(request_type, payload, sender) catch false;
        if (self.identified.load(.acquire)) {
            self.sendRequestFrom(request_type, payload, sender) catch |err| log.warn("ObsEgress: send failed: {any}", .{err});
            return;
        }
        if (stateful) return; // 状態は接続後の reconcile で送られる
        const req = self.buildRequest(request_type, payload, sender) catch return;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.outbox.items.len >= self.outbox_max) {
            self.allocator.free(self.outbox.orderedRemove(0));
        }
        self.outbox.append(self.allocator, req) catch self.allocator.free(req);
    }

    fn onMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *ObsEgressNode = @ptrCast(@alignCast(context orelse return));
        const prefix = "core.obs.request.";
        if (!std.mem.startsWith(u8, msg.topic, prefix)) return;
        self.handleRequestFrom(msg.topic[prefix.len..], msg.payload, msg.source_node_id);
        // OBS に送れた (接続中) ものだけ数える。未接続の間に溜めたものは接続後にまとめて送るので除く
        if (self.identified.load(.acquire)) self.latency.onSent(self.bus, self.node_id, msg);
    }
};

test "OBS auth string matches the obs-websocket v5 algorithm" {
    // obs-websocket の仕様例: password="supersecretpassword", salt="lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
    // challenge="+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=" → "1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4="
    const out = ObsEgressNode.authString("supersecretpassword", "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=", "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=");
    try std.testing.expectEqualStrings("1Ct943GAT+6YQUUX47Ia/ncufilbe6+oD6lY+5kaCu4=", &out);
}

test "DesiredState keeps the last value per target" {
    const a = std.testing.allocator;
    var d = DesiredState.init(a);
    defer d.deinit();
    try std.testing.expect(try d.record("SetSceneItemEnabled", "{\"sceneName\":\"Overlay\",\"sceneItemId\":1,\"sceneItemEnabled\":true}"));
    try std.testing.expect(try d.record("SetSceneItemEnabled", "{\"sceneName\":\"Overlay\",\"sceneItemId\":1,\"sceneItemEnabled\":false}"));
    try std.testing.expect(try d.record("SetSceneItemEnabled", "{\"sceneName\":\"Overlay\",\"sceneItemId\":2,\"sceneItemEnabled\":true}"));
    try std.testing.expect(try d.record("SetCurrentProgramScene", "{\"sceneName\":\"Game\"}"));
    try std.testing.expect(!try d.record("StartStream", "{}")); // 状態ではない
    try std.testing.expectEqual(@as(usize, 3), d.count());
    const c = try d.copies(a);
    defer DesiredState.freeCopies(a, c);
    var found_false = false;
    for (c) |e| {
        if (std.mem.indexOf(u8, e.data, "\"sceneItemId\":1") != null and std.mem.indexOf(u8, e.data, "false") != null) found_false = true;
    }
    try std.testing.expect(found_false);
}

test "ProblemTracker: who sent a refused request, and the closest name OBS actually has" {
    const a = std.testing.allocator;
    var t = ProblemTracker.init(a);
    defer t.deinit();
    t.setNames(.input, &.{ "Score Board", "SubGoal", "ゲーム画面ラベル" });
    t.setNames(.scene, &.{ "Overlay", "Card1" });

    t.noteRequest(7, 105, "SetInputSettings", "{\"inputName\":\"Scoreboard\",\"inputSettings\":{\"text\":\"A 0 - 0 B\"}}");
    const p = t.take(7).?;
    try std.testing.expectEqual(@as(u32, 105), p.sender);
    try std.testing.expectEqualStrings("Scoreboard", p.target());
    try std.testing.expect(t.take(7) == null);

    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Score Board", t.suggest(.input, "Scoreboard", &buf).?); // 空白と大文字小文字
    try std.testing.expectEqualStrings("SubGoal", t.suggest(.input, "SubGaol", &buf).?); // 打ち間違い
    try std.testing.expectEqualStrings("Overlay", t.suggest(.scene, "overlay", &buf).?);
    try std.testing.expect(t.suggest(.input, "SubGoal", &buf) == null); // 名前は合っている
    try std.testing.expect(t.suggest(.input, "TotallyDifferent", &buf) == null);

    // 名前を直して別の名前で通ったら、打ち間違えた名前の問題も解消する
    var t2 = ProblemTracker.init(a);
    defer t2.deinit();
    t2.noteRequest(20, 105, "SetInputSettings", "{\"inputName\":\"timer\"}");
    const bad = t2.take(20).?;
    _ = t2.setFailing(&bad, true);
    t2.noteRequest(21, 105, "SetInputSettings", "{\"inputName\":\"Timer\"}");
    const good = t2.take(21).?;
    var tb: [8][128]u8 = undefined;
    var tl: [8]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), t2.resolveSameKind(&good, &tb, &tl));
    try std.testing.expectEqualStrings("timer", tb[0][0..tl[0]]);
    try std.testing.expectEqual(@as(usize, 0), t2.resolveSameKind(&good, &tb, &tl));

    // 断られた → (同じものがまた断られても知らせる) → 通った (一度だけ解消を知らせる)
    try std.testing.expect(t.setFailing(&p, true));
    try std.testing.expect(t.setFailing(&p, true));
    try std.testing.expect(t.setFailing(&p, false));
    try std.testing.expect(!t.setFailing(&p, false));
}

test "LatencyStats: percentiles over the recent samples, and only input-driven requests count" {
    var st = LatencyStats{};
    var i: i64 = 1;
    while (i <= 100) : (i += 1) st.record(i * 10); // 10, 20, ..., 1000 µs
    const s = st.summary();
    try std.testing.expectEqual(@as(u64, 100), s.samples);
    try std.testing.expectEqual(@as(u32, 500), s.p50_us);
    try std.testing.expectEqual(@as(u32, 950), s.p95_us);
    try std.testing.expectEqual(@as(u32, 1000), s.max_us);

    var bus = try event_bus.EventBus.init(std.testing.allocator, 16);
    defer bus.deinit();
    bus.verbose = false;
    var st2 = LatencyStats{};
    const init_msg = event_bus.EventMessage{ .id = 1, .topic = "core.obs.request.SetInputSettings", .timestamp = 0, .source_node_id = 100, .qos = .Reliable, .payload = "{}", .hops = 0, .origin_us = std.time.microTimestamp() };
    st2.onSent(&bus, 2, &init_msg); // 起動時の初期表示 (入力が起点ではない) は数えない
    try std.testing.expectEqual(@as(u64, 0), st2.summary().samples);
    const chat_msg = event_bus.EventMessage{ .id = 2, .topic = "core.obs.request.SetInputSettings", .timestamp = 0, .source_node_id = 100, .qos = .Reliable, .payload = "{}", .hops = 1, .origin_us = std.time.microTimestamp() - 1500 };
    st2.onSent(&bus, 2, &chat_msg);
    const s2 = st2.summary();
    try std.testing.expectEqual(@as(u64, 1), s2.samples);
    try std.testing.expect(s2.p50_us >= 1500);
}
