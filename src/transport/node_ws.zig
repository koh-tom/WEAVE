//! リモートノード (別プロセス・別言語のノード) を WebSocket で接続するトランスポート。
//!
//! プロトコル v1 (docs/v1_plan_2026-09.md §5.6):
//!   client → {"type":"hello","manifest":{...}}              (最初の 1 通。5 秒以内)
//!   server → {"type":"welcome","node_id":N,"cell":"remote"}  または {"type":"error","reason":...}
//!   client → {"type":"subscribe","topic":P} / {"type":"unsubscribe","topic":P}
//!   client → {"type":"publish","topic":T,"payload":...,"qos":"BestEffort|Reliable|Transient"?}
//!   server → {"type":"event","id":..,"topic":T,"payload":..,"qos":..}
//!
//! P0-3 の修正: 以前はトークンさえ知っていれば任意のトピック (OBS 操作や core.node.fault の
//! 偽造を含む) を publish でき、全イベントを受け取れた。今は Wasm プラグインと同じ
//! Manifest 検査・レート制限・セルの bridge 制約を通る。予約名前空間は発行できない。

const std = @import("std");
const log = @import("../common/log.zig");
const event_bus = @import("../core/event_bus.zig");
const topics = @import("../core/topics.zig");
const pattern = @import("../core/pattern.zig");
const manifest_mod = @import("../core/manifest.zig");
const RateLimiter = @import("../core/rate_limiter.zig").RateLimiter;
const ws = @import("ws_proto.zig");
const QoS = event_bus.QoS;

pub const Options = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 8081,
    token: []const u8,
    max_clients: usize = 64,
    max_frame: usize = 1024 * 1024,
    /// manifest が rate_limit_eps を宣言しない場合の既定値
    default_rate_eps: f64 = 100,
    hello_timeout_ms: u32 = 5000,
};

/// リモートノードが入るセルの既定制約。OBS 操作 (core.obs.request.*) は既定では出せない。
pub const REMOTE_BRIDGES_IN = [_][]const u8{ "ext.#", "core.system.tick", "core.node.status.#", "core.obs.event.#" };
pub const REMOTE_BRIDGES_OUT = [_][]const u8{"ext.#"};

const Client = struct {
    server: *NodeWsTransport,
    stream: std.net.Stream,
    node_id: u32,
    manifest: ?std.json.Parsed(manifest_mod.Manifest) = null,
    name_buf: [80]u8 = undefined,
    name_len: usize = 0,
    rate: RateLimiter = .{},
    send_mutex: std.Thread.Mutex = .{},
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    finished: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    closed: bool = false,

    fn name(self: *const Client) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    /// ソケットを閉じる。stop() の shutdown と競合しないよう send_mutex の下で行う
    /// (閉じた fd は別の接続に再利用されうるので、閉じた後に shutdown してはいけない)
    fn closeStream(self: *Client) void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (self.closed) return;
        self.alive.store(false, .release);
        self.closed = true;
        self.stream.close();
    }

    /// 別スレッドから接続を切る (読み込み中のスレッドを起こす)
    fn interrupt(self: *Client) void {
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (self.closed) return;
        self.alive.store(false, .release);
        std.posix.shutdown(self.stream.handle, .both) catch {};
    }

    fn send(self: *Client, data: []const u8) void {
        if (!self.alive.load(.acquire)) return;
        self.send_mutex.lock();
        defer self.send_mutex.unlock();
        if (self.closed) return;
        ws.writeFrame(self.stream, .text, data, false) catch {
            self.alive.store(false, .release);
            std.posix.shutdown(self.stream.handle, .both) catch {};
        };
    }
};

pub const NodeWsTransport = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    opts: Options,
    token: []u8,
    bind: []u8,
    cell: *event_bus.Cell,
    server: ?std.net.Server = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready: std.Thread.ResetEvent = .{},
    next_node_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(200),

    mutex: std.Thread.Mutex = .{},
    /// 接続中と切断済みのクライアント。切断済みも、セルのキューに残った配送が
    /// 参照しうるので停止まで解放しない (上限を超えたら古いものから解放)
    clients: std.ArrayListUnmanaged(*Client) = .{},

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, opts: Options) !*NodeWsTransport {
        const self = try allocator.create(NodeWsTransport);
        errdefer allocator.destroy(self);
        const cell = bus.getCell("remote") orelse try bus.createCell("remote", .{
            .trust = .remote,
            .bridges_in = &REMOTE_BRIDGES_IN,
            .bridges_out = &REMOTE_BRIDGES_OUT,
        });
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .opts = opts,
            .token = try allocator.dupe(u8, opts.token),
            .bind = try allocator.dupe(u8, opts.bind),
            .cell = cell,
        };
        return self;
    }

    pub fn deinit(self: *NodeWsTransport) void {
        self.stop();
        // 接続スレッドの終了を待つ
        var waited: usize = 0;
        while (waited < 300) : (waited += 1) {
            self.mutex.lock();
            var all_done = true;
            for (self.clients.items) |c| {
                if (!c.finished.load(.acquire)) all_done = false;
            }
            self.mutex.unlock();
            if (all_done) break;
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
        if (self.server) |*s| s.deinit();
        self.server = null;
        self.mutex.lock();
        for (self.clients.items) |c| self.freeClient(c);
        self.clients.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.free(self.token);
        self.allocator.free(self.bind);
        self.allocator.destroy(self);
    }

    fn freeClient(self: *NodeWsTransport, c: *Client) void {
        if (c.manifest) |m| m.deinit();
        self.allocator.destroy(c);
    }

    pub fn stop(self: *NodeWsTransport) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.server) |s| {
            const addr = s.listen_address;
            var wake = addr;
            if (addr.any.family == std.posix.AF.INET and addr.in.sa.addr == 0) {
                wake = std.net.Address.parseIp("127.0.0.1", addr.getPort()) catch addr;
            }
            if (std.net.tcpConnectToAddress(wake)) |c| c.close() else |_| {}
        }
        self.mutex.lock();
        for (self.clients.items) |c| c.interrupt();
        self.mutex.unlock();
    }

    /// 実際に待ち受けているポート (テストで port=0 を使う場合用)
    pub fn listenPort(self: *NodeWsTransport) u16 {
        return if (self.server) |s| s.listen_address.getPort() else self.opts.port;
    }

    /// 接続待ち受けループ (別スレッドで実行)
    pub fn run(self: *NodeWsTransport) !void {
        const address = try std.net.Address.parseIp(self.bind, self.opts.port);
        self.server = try address.listen(.{ .reuse_address = true });
        self.running.store(true, .release);
        self.ready.set();
        log.info("NodeWsTransport: Listening on ws://{s}:{d} (remote nodes, cell 'remote')", .{ self.bind, self.listenPort() });

        while (self.running.load(.acquire)) {
            const conn = self.server.?.accept() catch |err| {
                if (!self.running.load(.acquire)) break;
                log.err("NodeWsTransport: accept error: {any}", .{err});
                continue;
            };
            if (!self.running.load(.acquire)) {
                conn.stream.close();
                break;
            }
            self.mutex.lock();
            var live: usize = 0;
            for (self.clients.items) |c| {
                if (!c.finished.load(.acquire)) live += 1;
            }
            // 切断済みを溜めすぎない
            if (self.clients.items.len > self.opts.max_clients * 4) {
                var i: usize = 0;
                while (i < self.clients.items.len and self.clients.items.len > self.opts.max_clients * 2) {
                    const c = self.clients.items[i];
                    if (c.finished.load(.acquire)) {
                        _ = self.clients.orderedRemove(i);
                        self.freeClient(c);
                    } else i += 1;
                }
            }
            self.mutex.unlock();
            if (live >= self.opts.max_clients) {
                ws.writeStatus(conn.stream, 503, "Service Unavailable", "too many nodes") catch {};
                conn.stream.close();
                continue;
            }

            const client = self.allocator.create(Client) catch {
                conn.stream.close();
                continue;
            };
            client.* = .{ .server = self, .stream = conn.stream, .node_id = self.next_node_id.fetchAdd(1, .monotonic) };
            self.mutex.lock();
            self.clients.append(self.allocator, client) catch {
                self.mutex.unlock();
                conn.stream.close();
                self.allocator.destroy(client);
                continue;
            };
            self.mutex.unlock();
            const t = std.Thread.spawn(.{}, clientMain, .{ self, client }) catch {
                client.closeStream();
                client.finished.store(true, .release);
                continue;
            };
            t.detach();
        }
    }

    fn sendJson(client: *Client, value: anytype) void {
        var buf: [1024]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(value, .{})}) catch return;
        client.send(w.buffered());
    }

    fn clientMain(self: *NodeWsTransport, client: *Client) void {
        defer client.finished.store(true, .release);
        defer client.closeStream();

        // 1. ハンドシェイク + 認証
        var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
        const head = ws.readHead(client.stream, &head_buf) catch return;
        const req = ws.parseRequest(head) catch return;
        const presented = req.token_header orelse req.queryParam("token");
        if (presented == null or !ws.constantTimeEql(presented.?, self.token)) {
            ws.writeStatus(client.stream, 401, "Unauthorized", "token required") catch {};
            self.emitSecurity(client.node_id, "unknown", "auth_failed", "node websocket");
            return;
        }
        ws.writeUpgrade(client.stream, req.ws_key orelse "") catch return;
        ws.setSendTimeout(client.stream, 500);

        // 2. hello (manifest) を待つ
        const tv = std.posix.timeval{ .sec = @intCast(self.opts.hello_timeout_ms / 1000), .usec = @intCast((self.opts.hello_timeout_ms % 1000) * 1000) };
        std.posix.setsockopt(client.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
        const hello = ws.readMessage(client.stream, self.allocator, self.opts.max_frame) catch return;
        defer self.allocator.free(hello.payload);
        if (!self.acceptHello(client, hello.payload)) return;
        const none = std.posix.timeval{ .sec = 0, .usec = 0 };
        std.posix.setsockopt(client.stream.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, std.mem.asBytes(&none)) catch {};

        // 3. メッセージループ
        while (self.running.load(.acquire) and client.alive.load(.acquire)) {
            const frame = ws.readMessage(client.stream, self.allocator, self.opts.max_frame) catch break;
            defer self.allocator.free(frame.payload);
            switch (frame.opcode) {
                .text => self.handleText(client, frame.payload),
                .ping => {
                    client.send_mutex.lock();
                    ws.writeFrame(client.stream, .pong, frame.payload, false) catch {};
                    client.send_mutex.unlock();
                },
                .close => break,
                else => {},
            }
        }

        // 4. 切断: 購読を外し、状態を disconnected に
        client.alive.store(false, .release);
        self.bus.unsubscribeAll(client.node_id);
        if (self.bus.graph) |g| g.updateNodeStatus(client.node_id, .disconnected);
        var buf: [256]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{ .node_id = client.node_id, .name = client.name(), .status = "disconnected" }, .{})}) catch {};
        var tbuf: [128]u8 = undefined;
        if (std.fmt.bufPrint(&tbuf, "core.node.status.{s}", .{client.name()})) |t| {
            self.bus.publish(t, w.buffered(), .Transient, 0) catch {};
        } else |_| {}
        log.info("NodeWsTransport: remote node '{s}' (id {d}) disconnected", .{ client.name(), client.node_id });
    }

    fn acceptHello(self: *NodeWsTransport, client: *Client, text: []const u8) bool {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch {
            sendJson(client, .{ .type = "error", .reason = "hello must be JSON" });
            return false;
        };
        defer parsed.deinit();
        const root = if (parsed.value == .object) parsed.value.object else {
            sendJson(client, .{ .type = "error", .reason = "hello must be an object" });
            return false;
        };
        const t = root.get("type") orelse .null;
        if (t != .string or !std.mem.eql(u8, t.string, "hello")) {
            sendJson(client, .{ .type = "error", .reason = "first message must be hello" });
            return false;
        }
        const mv = root.get("manifest") orelse {
            sendJson(client, .{ .type = "error", .reason = "hello requires manifest" });
            return false;
        };
        var mbuf: std.ArrayListUnmanaged(u8) = .{};
        defer mbuf.deinit(self.allocator);
        mbuf.writer(self.allocator).print("{f}", .{std.json.fmt(mv, .{})}) catch return false;
        const m = manifest_mod.Manifest.parse(self.allocator, mbuf.items) catch |err| {
            var ebuf: [128]u8 = undefined;
            const reason = std.fmt.bufPrint(&ebuf, "invalid manifest: {s}", .{@errorName(err)}) catch "invalid manifest";
            sendJson(client, .{ .type = "error", .reason = reason });
            self.emitSecurity(client.node_id, "unknown", "manifest_rejected", @errorName(err));
            return false;
        };
        client.manifest = m;
        const n = std.fmt.bufPrint(&client.name_buf, "remote.{s}", .{m.value.name}) catch return false;
        client.name_len = n.len;
        const eps = if (m.value.rate_limit_eps > 0) m.value.rate_limit_eps else self.opts.default_rate_eps;
        client.rate = RateLimiter.init(eps);

        if (self.bus.graph) |g| g.registerNodeIn(client.node_id, client.name(), .remote, self.cell.name) catch {};
        // manifest の購読宣言を適用 (bridge で入れないものは黙って外す)
        for (m.value.permissions.subscribe) |p| {
            if (!self.cell.intersectsIn(p)) continue;
            self.bus.subscribeEx(p, client.node_id, onEvent, client, .{ .cell = self.cell }) catch {};
        }
        sendJson(client, .{ .type = "welcome", .node_id = client.node_id, .name = client.name(), .cell = self.cell.name });
        log.info("NodeWsTransport: remote node '{s}' joined (id {d})", .{ client.name(), client.node_id });
        return true;
    }

    fn parseQos(v: ?std.json.Value, topic: []const u8) QoS {
        const val = v orelse return topics.defaultQos(topic);
        switch (val) {
            .string => |s| {
                if (std.mem.eql(u8, s, "Reliable")) return .Reliable;
                if (std.mem.eql(u8, s, "BestEffort")) return .BestEffort;
                // Transient (保持) は state 種別のトピックにだけ許す
                if (std.mem.eql(u8, s, "Transient") and topics.classify(topic) == .state) return .Transient;
            },
            .integer => |i| {
                if (i == 1) return .Reliable;
                if (i == 0) return .BestEffort;
            },
            else => {},
        }
        return topics.defaultQos(topic);
    }

    fn handleText(self: *NodeWsTransport, client: *Client, text: []const u8) void {
        const m = (client.manifest orelse return).value;
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const root = parsed.value.object;
        const tv = root.get("type") orelse return;
        if (tv != .string) return;
        const kind = tv.string;
        const topic_v = root.get("topic") orelse return;
        if (topic_v != .string) return;
        const topic = topic_v.string;

        if (std.mem.eql(u8, kind, "subscribe")) {
            if (!pattern.validPattern(topic) or !m.canSubscribe(topic) or !self.cell.intersectsIn(topic)) {
                self.emitSecurity(client.node_id, client.name(), "acl_denied", topic);
                sendJson(client, .{ .type = "error", .reason = "subscribe denied", .topic = topic });
                return;
            }
            self.bus.subscribeEx(topic, client.node_id, onEvent, client, .{ .cell = self.cell }) catch {};
        } else if (std.mem.eql(u8, kind, "unsubscribe")) {
            self.bus.unsubscribe(client.node_id, topic);
            if (self.bus.graph) |g| g.removeSubscription(client.node_id, topic);
        } else if (std.mem.eql(u8, kind, "publish")) {
            if (!pattern.validTopic(topic) or !m.canPublish(topic) or !self.cell.allowsOut(topic) or topics.touchesReserved(topic)) {
                self.emitSecurity(client.node_id, client.name(), "acl_denied", topic);
                sendJson(client, .{ .type = "error", .reason = "publish denied", .topic = topic });
                return;
            }
            if (!client.rate.tryConsume(std.time.milliTimestamp())) {
                self.emitSecurity(client.node_id, client.name(), "rate_limited", topic);
                return;
            }
            var pbuf: std.ArrayListUnmanaged(u8) = .{};
            defer pbuf.deinit(self.allocator);
            const payload: []const u8 = switch (root.get("payload") orelse .null) {
                .string => |s| s,
                else => |v| blk: {
                    pbuf.writer(self.allocator).print("{f}", .{std.json.fmt(v, .{})}) catch return;
                    break :blk pbuf.items;
                },
            };
            self.bus.publish(topic, payload, parseQos(root.get("qos"), topic), client.node_id) catch {};
        }
    }

    /// バスからの配送 (remote セルの executor 上)
    fn onEvent(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const client: *Client = @ptrCast(@alignCast(ctx orelse return));
        if (!client.alive.load(.acquire)) return;
        const a = client.server.allocator;
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(a);
        const w = out.writer(a);
        w.print("{{\"type\":\"event\",\"id\":{d},\"topic\":\"{s}\",\"qos\":{d},\"payload\":", .{ msg.id, msg.topic, @intFromEnum(msg.qos) }) catch return;
        if (std.json.validate(a, msg.payload) catch false) {
            w.writeAll(msg.payload) catch return;
        } else {
            w.print("{f}", .{std.json.fmt(msg.payload, .{})}) catch return;
        }
        w.writeAll("}") catch return;
        client.send(out.items);
    }

    fn emitSecurity(self: *NodeWsTransport, node_id: u32, name: []const u8, kind: []const u8, detail: []const u8) void {
        var tbuf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "core.security.{s}", .{kind}) catch return;
        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{ .node_id = node_id, .name = name, .detail = detail }, .{})}) catch return;
        self.bus.publish(t, w.buffered(), .Transient, 0) catch {};
    }
};

// ======================================================================
// Integration test: 実ソケットでリモートノードの ACL を確認する
// ======================================================================

fn connectClient(port: u16, token: []const u8) !std.net.Stream {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    const s = try std.net.tcpConnectToAddress(addr);
    errdefer s.close();
    var hdr: [128]u8 = undefined;
    const extra = try std.fmt.bufPrint(&hdr, "X-WEAVE-Token: {s}\r\n", .{token});
    try ws.clientHandshake(s, "127.0.0.1", port, "/", extra);
    return s;
}

fn recvText(s: std.net.Stream, a: std.mem.Allocator) ![]u8 {
    const f = try ws.readMessage(s, a, 1 << 20);
    return f.payload;
}

test "NodeWs: hello manifest gates publish/subscribe (P0-3)" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 64);
    defer bus.deinit();
    bus.verbose = false;

    const Sink = struct {
        var obs_requests = std.atomic.Value(u32).init(0);
        var ext_msgs = std.atomic.Value(u32).init(0);
        fn obs(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = obs_requests.fetchAdd(1, .monotonic);
        }
        fn ext(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = ext_msgs.fetchAdd(1, .monotonic);
        }
    };
    Sink.obs_requests.store(0, .monotonic);
    Sink.ext_msgs.store(0, .monotonic);
    try bus.subscribe("core.obs.request.*", 2, Sink.obs, null);
    try bus.subscribe("ext.remote.out", 3, Sink.ext, null);
    try bus.start();

    var t = try NodeWsTransport.init(a, &bus, .{ .port = 0, .token = "secret" });
    defer t.deinit();
    const th = try std.Thread.spawn(.{}, NodeWsTransport.run, .{t});
    defer th.join();
    defer t.stop();
    t.ready.wait();
    const port = t.listenPort();

    // トークン無しは拒否
    {
        const addr = try std.net.Address.parseIp("127.0.0.1", port);
        const s = try std.net.tcpConnectToAddress(addr);
        defer s.close();
        try std.testing.expectError(error.HandshakeRejected, ws.clientHandshake(s, "127.0.0.1", port, "/", ""));
    }

    // 予約名前空間を宣言した manifest は拒否
    {
        const s = try connectClient(port, "secret");
        defer s.close();
        try ws.writeFrame(s, .text, "{\"type\":\"hello\",\"manifest\":{\"name\":\"forger\",\"version\":\"1\",\"permissions\":{\"publish\":[\"core.node.fault\"]}}}", true);
        const r = try recvText(s, a);
        defer a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, r, "ReservedTopicForbidden") != null);
    }

    // 正規の manifest: ext.remote.out は出せる / OBS 操作は宣言していても bridge で拒否
    const s = try connectClient(port, "secret");
    defer s.close();
    try ws.writeFrame(s, .text, "{\"type\":\"hello\",\"manifest\":{\"name\":\"tool\",\"version\":\"1\",\"permissions\":{\"publish\":[\"ext.remote.out\",\"core.obs.request.SetSceneItemEnabled\"],\"subscribe\":[\"ext.remote.in\"]}}}", true);
    const welcome = try recvText(s, a);
    defer a.free(welcome);
    try std.testing.expect(std.mem.indexOf(u8, welcome, "\"welcome\"") != null);

    try ws.writeFrame(s, .text, "{\"type\":\"publish\",\"topic\":\"ext.remote.out\",\"payload\":{\"x\":1}}", true);
    try ws.writeFrame(s, .text, "{\"type\":\"publish\",\"topic\":\"core.obs.request.SetSceneItemEnabled\",\"payload\":{}}", true);
    const denied = try recvText(s, a);
    defer a.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "publish denied") != null);

    // manifest で宣言した購読には配送される
    std.Thread.sleep(50 * std.time.ns_per_ms);
    try bus.publish("ext.remote.in", "{\"hello\":true}", .BestEffort, 0);
    const ev = try recvText(s, a);
    defer a.free(ev);
    try std.testing.expect(std.mem.indexOf(u8, ev, "\"ext.remote.in\"") != null);

    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), Sink.ext_msgs.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), Sink.obs_requests.load(.monotonic));
}
