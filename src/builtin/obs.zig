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

const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const ws = @import("../transport/ws_proto.zig");
const log = @import("../common/log.zig");

/// 冪等な (最後の値だけが意味を持つ) 要求。再接続時に再適用する
const STATEFUL = [_]struct { request: []const u8, keys: []const []const u8 }{
    .{ .request = "SetSceneItemEnabled", .keys = &.{ "sceneName", "sceneItemId" } },
    .{ .request = "SetCurrentProgramScene", .keys = &.{} },
    .{ .request = "SetInputMute", .keys = &.{"inputName"} },
    .{ .request = "SetSourceFilterEnabled", .keys = &.{ "sourceName", "filterName" } },
};

/// 「WEAVE が意図した OBS の状態」。キー = 要求種別 + 対象を特定するフィールド
pub const DesiredState = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// key -> { request_type, request_data (JSON) }
    map: std.StringArrayHashMapUnmanaged(Entry) = .{},

    pub const Entry = struct { request_type: []u8, data: []u8 };

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
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, key.items);
            gop.value_ptr.* = .{
                .request_type = try self.allocator.dupe(u8, request_type),
                .data = try self.allocator.dupe(u8, data_json),
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
            out[i] = .{ .request_type = try allocator.dupe(u8, e.value_ptr.request_type), .data = try allocator.dupe(u8, e.value_ptr.data) };
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

pub const ObsEgressNode = struct {
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
        if (self.password) |p| self.allocator.free(p);
        if (self.host) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }

    /// OBS への接続をバックグラウンドで開始し、要求トピックを購読する
    pub fn connect(self: *ObsEgressNode, host: []const u8, port: u16) !void {
        self.host = try self.allocator.dupe(u8, host);
        self.port = port;
        self.running.store(true, .release);

        // OBS への送信は専用セル "egress" で行う (OBS が遅くても他の配送を待たせない)
        const cell = self.bus.getCell("egress") orelse try self.bus.createCell("egress", .{ .trust = .core });
        // グラフ登録を購読より先に行う (逆順だと購読が記録されず、トポロジから OBS への辺が消える)
        if (self.bus.graph) |g| try g.registerNodeIn(self.node_id, "ObsEgress", .native, cell.name);
        try self.bus.subscribeEx("core.obs.request.*", self.node_id, ObsEgressNode.onMessage, self, .{ .cell = cell });

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
                7 => onResponse(d.object),
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
            msg = try std.fmt.bufPrint(&buf, "{{\"op\":1,\"d\":{{\"rpcVersion\":1,\"authentication\":\"{s}\",\"eventSubscriptions\":33}}}}", .{secret});
        } else {
            msg = "{\"op\":1,\"d\":{\"rpcVersion\":1,\"eventSubscriptions\":33}}";
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
        for (entries) |e| self.sendRequest(e.request_type, e.data) catch {};
        self.reapplied_total += entries.len;
        if (self.connections > 1) {
            self.reconnects += 1;
            log.info("ObsEgress: re-applied {d} desired state(s) after reconnect", .{entries.len});
        }
    }

    fn onEvent(self: *ObsEgressNode, d: std.json.ObjectMap, raw: []const u8) void {
        const et = d.get("eventType") orelse return;
        if (et != .string) return;
        var topic_buf: [128]u8 = undefined;
        const topic = std.fmt.bufPrint(&topic_buf, "core.obs.event.{s}", .{et.string}) catch return;
        self.bus.publish(topic, raw, .Transient, self.node_id) catch {};
    }

    fn onResponse(d: std.json.ObjectMap) void {
        const status = d.get("requestStatus") orelse return;
        if (status != .object) return;
        const result = status.object.get("result") orelse return;
        if (result == .bool and !result.bool) {
            const rt = if (d.get("requestType")) |v| (if (v == .string) v.string else "?") else "?";
            const comment = if (status.object.get("comment")) |c| (if (c == .string) c.string else "") else "";
            log.err("ObsEgress: OBS rejected {s}: {s}", .{ rt, comment });
        }
    }

    fn sendRaw(self: *ObsEgressNode, data: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.stream orelse return error.NotConnected;
        try ws.writeFrame(s, .text, data, true);
    }

    fn buildRequest(self: *ObsEgressNode, request_type: []const u8, data_json: []const u8) ![]u8 {
        const id = self.next_request.fetchAdd(1, .monotonic);
        return std.fmt.allocPrint(self.allocator, "{{\"op\":6,\"d\":{{\"requestType\":\"{s}\",\"requestId\":\"weave-{d}\",\"requestData\":{s}}}}}", .{ request_type, id, data_json });
    }

    fn sendRequest(self: *ObsEgressNode, request_type: []const u8, data_json: []const u8) !void {
        const req = try self.buildRequest(request_type, data_json);
        defer self.allocator.free(req);
        try self.sendRaw(req);
    }

    /// 要求を処理する (egress セルの executor 上)
    pub fn handleRequest(self: *ObsEgressNode, request_type: []const u8, payload: []const u8) void {
        // 要求種別はトピックの一部なので英数字のみ (validTopic 済み)。requestData は JSON オブジェクトに限る
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch {
            log.warn("ObsEgress: {s}: requestData must be a JSON object", .{request_type});
            return;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return;

        const stateful = self.desired.record(request_type, payload) catch false;
        if (self.identified.load(.acquire)) {
            self.sendRequest(request_type, payload) catch |err| log.warn("ObsEgress: send failed: {any}", .{err});
            return;
        }
        if (stateful) return; // 状態は接続後の reconcile で送られる
        const req = self.buildRequest(request_type, payload) catch return;
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
        self.handleRequest(msg.topic[prefix.len..], msg.payload);
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
