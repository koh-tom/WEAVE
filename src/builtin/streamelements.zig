//! StreamElements Astro アダプタ (互換戦略 A: クラウドサービスの実プロトコルを Core 内で話す)
//!
//! wss://astro.streamelements.com/ に接続し、`channel.activities` (フォロー・投げ銭・サブスク・
//! チア・レイドなど) を購読して、WEAVE に `ext.streamelements.activity.<type>` として発行する。
//!
//! プロトコル (docs.streamelements.com/websockets):
//!   server → {"type":"welcome","data":{"client_id":...}}
//!   client → {"type":"subscribe","nonce":"...","data":{"topic":"channel.activities","room":"<channel id>","token":"<JWT>","token_type":"jwt"}}
//!   server → {"type":"response","nonce":"...","data":{...}} / 失敗時は "error" フィールド (err_unauthorized など)
//!   server → {"type":"message","topic":"channel.activities","room":"...","data":{"type":"follow",...}}
//!   server は 30 秒ごとに PING を送り、70 秒 PONG が無ければ切断する
//!
//! JWT は環境変数 STREAMELEMENTS_JWT で渡す (コマンドライン引数は ps で他ユーザーに見えるため)。

const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const pattern = @import("../core/pattern.zig");
const ws = @import("../transport/ws_proto.zig");
const log = @import("../common/log.zig");

pub const Url = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    path: []const u8,

    pub fn parse(url: []const u8) !Url {
        var tls = false;
        var rest: []const u8 = undefined;
        if (std.mem.startsWith(u8, url, "wss://")) {
            tls = true;
            rest = url["wss://".len..];
        } else if (std.mem.startsWith(u8, url, "ws://")) {
            rest = url["ws://".len..];
        } else return error.UnsupportedUrl;
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        const hostport = rest[0..slash];
        const path = if (slash < rest.len) rest[slash..] else "/";
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |c| {
            return .{ .tls = tls, .host = hostport[0..c], .port = try std.fmt.parseInt(u16, hostport[c + 1 ..], 10), .path = path };
        }
        return .{ .tls = tls, .host = hostport, .port = if (tls) 443 else 80, .path = path };
    }
};

pub const Options = struct {
    url: []const u8 = "wss://astro.streamelements.com/",
    token: []const u8,
    channel: []const u8,
    node_id: u32 = 4,
};

pub const StreamElementsAdapter = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    url: Url,
    url_owned: []u8,
    token: []u8,
    channel: []u8,
    node_id: u32,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    sock_mutex: std.Thread.Mutex = .{},
    sock: ?std.posix.socket_t = null,
    received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    unauthorized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, opts: Options) !*StreamElementsAdapter {
        const self = try allocator.create(StreamElementsAdapter);
        errdefer allocator.destroy(self);
        const url_owned = try allocator.dupe(u8, opts.url);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .url = try Url.parse(url_owned),
            .url_owned = url_owned,
            .token = try allocator.dupe(u8, opts.token),
            .channel = try allocator.dupe(u8, opts.channel),
            .node_id = opts.node_id,
        };
        return self;
    }

    pub fn start(self: *StreamElementsAdapter) !void {
        if (self.bus.graph) |g| try g.registerNodeIn(self.node_id, "StreamElements", .native, "ingress");
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *StreamElementsAdapter) void {
        if (!self.running.swap(false, .acq_rel)) return;
        self.sock_mutex.lock();
        if (self.sock) |fd| std.posix.shutdown(fd, .both) catch {};
        self.sock_mutex.unlock();
    }

    pub fn deinit(self: *StreamElementsAdapter) void {
        self.stop();
        if (self.thread) |t| t.join();
        std.crypto.secureZero(u8, self.token);
        self.allocator.free(self.token);
        self.allocator.free(self.channel);
        self.allocator.free(self.url_owned);
        self.allocator.destroy(self);
    }

    fn setSock(self: *StreamElementsAdapter, fd: ?std.posix.socket_t) void {
        self.sock_mutex.lock();
        self.sock = fd;
        self.sock_mutex.unlock();
    }

    fn loop(self: *StreamElementsAdapter) void {
        var backoff: u64 = 500;
        while (self.running.load(.acquire)) {
            const r = if (self.url.tls) self.runTls() else self.runPlain();
            r catch |err| {
                if (self.running.load(.acquire)) log.warn("StreamElements: connection ended: {any}", .{err});
            };
            self.setSock(null);
            if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, .degraded);
            if (!self.running.load(.acquire)) break;
            // 認証エラーで何度も叩かない
            const wait = if (self.unauthorized.load(.acquire)) 60_000 else backoff;
            backoff = @min(backoff * 2, 30_000);
            var slept: u64 = 0;
            while (slept < wait and self.running.load(.acquire)) : (slept += 50) std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    fn runPlain(self: *StreamElementsAdapter) !void {
        const stream = try std.net.tcpConnectToHost(self.allocator, self.url.host, self.url.port);
        defer stream.close();
        self.setSock(stream.handle);
        try self.session(stream);
    }

    fn runTls(self: *StreamElementsAdapter) !void {
        const conn = try self.allocator.create(ws.TlsConn);
        defer self.allocator.destroy(conn);
        try conn.connect(self.allocator, self.url.host, self.url.port);
        defer conn.close(self.allocator);
        self.setSock(conn.stream.handle);
        try self.session(conn);
    }

    fn session(self: *StreamElementsAdapter, conn: anytype) !void {
        try ws.clientHandshake(conn, self.url.host, self.url.port, self.url.path, "");
        var subscribed = false;
        while (self.running.load(.acquire)) {
            const f = try ws.readMessage(conn, self.allocator, 4 << 20);
            defer self.allocator.free(f.payload);
            switch (f.opcode) {
                .ping => {
                    try ws.writeFrame(conn, .pong, f.payload, true);
                    continue;
                },
                .close => return error.EndOfStream,
                .text => {},
                else => continue,
            }
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, f.payload, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const o = parsed.value.object;
            const t = o.get("type") orelse continue;
            if (t != .string) continue;

            if (std.mem.eql(u8, t.string, "welcome") and !subscribed) {
                var out: std.ArrayListUnmanaged(u8) = .{};
                defer out.deinit(self.allocator);
                try out.writer(self.allocator).print("{f}", .{std.json.fmt(.{ .type = "subscribe", .nonce = "weave-activities", .data = .{ .topic = "channel.activities", .room = self.channel, .token = self.token, .token_type = "jwt" } }, .{})});
                try ws.writeFrame(conn, .text, out.items, true);
                subscribed = true;
            } else if (std.mem.eql(u8, t.string, "response")) {
                if (o.get("error")) |e| {
                    const code = if (e == .string) e.string else "error";
                    log.err("StreamElements: subscribe failed: {s}", .{code});
                    if (std.mem.eql(u8, code, "err_unauthorized")) {
                        self.unauthorized.store(true, .release);
                        log.err("StreamElements: JWT が拒否されました。STREAMELEMENTS_JWT を確認してください (60 秒後に再試行)", .{});
                    }
                    return error.SubscribeRejected;
                }
                self.unauthorized.store(false, .release);
                if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, .active);
                log.info("StreamElements: subscribed to channel.activities", .{});
            } else if (std.mem.eql(u8, t.string, "message")) {
                const data = o.get("data") orelse continue;
                var topic_buf: [128]u8 = undefined;
                const topic = activityTopic(&topic_buf, data) orelse continue;
                var out: std.ArrayListUnmanaged(u8) = .{};
                defer out.deinit(self.allocator);
                try out.writer(self.allocator).print("{f}", .{std.json.fmt(data, .{})});
                self.bus.publish(topic, out.items, .BestEffort, self.node_id) catch |err| {
                    log.warn("StreamElements: publish {s} failed: {any}", .{ topic, err });
                    continue;
                };
                _ = self.received.fetchAdd(1, .monotonic);
            }
        }
    }
};

/// `data.type` からトピック `ext.streamelements.activity.<type>` を作る。
/// type に使えない文字は `_` に置き換える (外部入力をそのままトピックにしない)。
pub fn activityTopic(buf: []u8, data: std.json.Value) ?[]const u8 {
    const prefix = "ext.streamelements.activity.";
    var kind: []const u8 = "unknown";
    if (data == .object) {
        if (data.object.get("type")) |v| {
            if (v == .string and v.string.len > 0) kind = v.string;
        }
    }
    if (kind.len > 64 or prefix.len + kind.len > buf.len) return null;
    @memcpy(buf[0..prefix.len], prefix);
    for (kind, 0..) |c, i| {
        buf[prefix.len + i] = if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') c else '_';
    }
    const topic = buf[0 .. prefix.len + kind.len];
    if (!pattern.validTopic(topic)) return null;
    return topic;
}

test "Url.parse" {
    const a = try Url.parse("wss://astro.streamelements.com/");
    try std.testing.expect(a.tls);
    try std.testing.expectEqualStrings("astro.streamelements.com", a.host);
    try std.testing.expectEqual(@as(u16, 443), a.port);
    try std.testing.expectEqualStrings("/", a.path);
    const b = try Url.parse("ws://127.0.0.1:9123");
    try std.testing.expect(!b.tls);
    try std.testing.expectEqual(@as(u16, 9123), b.port);
    try std.testing.expectEqualStrings("/", b.path);
    try std.testing.expectError(error.UnsupportedUrl, Url.parse("http://x/"));
}

test "activityTopic sanitizes type" {
    var buf: [128]u8 = undefined;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"tip\"}", .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("ext.streamelements.activity.tip", activityTopic(&buf, p.value).?);
    var q = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"a.b#c\"}", .{});
    defer q.deinit();
    try std.testing.expectEqualStrings("ext.streamelements.activity.a_b_c", activityTopic(&buf, q.value).?);
    var r = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{}", .{});
    defer r.deinit();
    try std.testing.expectEqualStrings("ext.streamelements.activity.unknown", activityTopic(&buf, r.value).?);
}
