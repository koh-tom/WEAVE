//! Streamlabs Socket API アダプタ (互換戦略 A: クラウドサービスの実プロトコルを Core 内で話す)
//!
//! Streamlabs のアラート (投げ銭・フォロー・サブスク・ビッツ・ホスト・レイドなど) を受け取り、
//! WEAVE に `ext.streamlabs.event.<type>` として発行する。読み取り専用。
//!
//! プロトコル (dev.streamlabs.com, Socket API): socket.io 2.x = Engine.IO v3 over WebSocket
//!   client → GET /socket.io/?EIO=3&transport=websocket&token=<socket token>
//!   server → "0{"sid":"...","pingInterval":25000,"pingTimeout":60000,...}"   (Engine.IO open)
//!   server → "40"                                                           (socket.io 名前空間 / に接続)
//!   server → "42["event",{"type":"donation","for":"streamlabs","message":[{...}, ...]}]"
//!   client → "2" (ping) を pingInterval ごとに送る。server → "3" (pong)
//!   server → "1" (close) / "41" (切断) / "44..." (接続エラー)
//!
//! Socket トークンは環境変数 STREAMLABS_SOCKET_TOKEN で渡す。プロトコルの都合で URL のクエリに載るので、
//! URL は決してログに出さない。

const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const pattern = @import("../core/pattern.zig");
const ws = @import("../transport/ws_proto.zig");
const log = @import("../common/log.zig");
const Url = @import("streamelements.zig").Url;

pub const DEFAULT_URL = "wss://sockets.streamlabs.com/socket.io/?EIO=3&transport=websocket";

pub const Options = struct {
    url: []const u8 = DEFAULT_URL,
    token: []const u8,
    node_id: u32 = 5,
};

/// トークンは URL のクエリにそのまま載せるので、URL エンコード不要な文字だけを許す
pub fn validToken(t: []const u8) bool {
    if (t.len == 0 or t.len > 2048) return false;
    for (t) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return false;
    }
    return true;
}

pub const StreamlabsAdapter = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    url: Url,
    url_owned: []u8,
    /// url.path + token。トークンを含むので秘密として扱う
    request_path: []u8,
    node_id: u32,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,
    sock_mutex: std.Thread.Mutex = .{},
    sock: ?std.posix.socket_t = null,
    received: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pings: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, opts: Options) !*StreamlabsAdapter {
        if (!validToken(opts.token)) return error.InvalidToken;
        const self = try allocator.create(StreamlabsAdapter);
        errdefer allocator.destroy(self);
        const url_owned = try allocator.dupe(u8, opts.url);
        errdefer allocator.free(url_owned);
        const url = try Url.parse(url_owned);
        const sep: []const u8 = if (std.mem.indexOfScalar(u8, url.path, '?') != null) "&" else "?";
        const request_path = try std.fmt.allocPrint(allocator, "{s}{s}token={s}", .{ url.path, sep, opts.token });
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .url = url,
            .url_owned = url_owned,
            .request_path = request_path,
            .node_id = opts.node_id,
        };
        return self;
    }

    pub fn start(self: *StreamlabsAdapter) !void {
        if (self.bus.graph) |g| try g.registerNodeIn(self.node_id, "Streamlabs", .native, "ingress");
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *StreamlabsAdapter) void {
        if (!self.running.swap(false, .acq_rel)) return;
        self.sock_mutex.lock();
        if (self.sock) |fd| std.posix.shutdown(fd, .both) catch {};
        self.sock_mutex.unlock();
    }

    pub fn deinit(self: *StreamlabsAdapter) void {
        self.stop();
        if (self.thread) |t| t.join();
        std.crypto.secureZero(u8, self.request_path);
        self.allocator.free(self.request_path);
        self.allocator.free(self.url_owned);
        self.allocator.destroy(self);
    }

    fn setSock(self: *StreamlabsAdapter, fd: ?std.posix.socket_t) void {
        self.sock_mutex.lock();
        self.sock = fd;
        self.sock_mutex.unlock();
    }

    fn loop(self: *StreamlabsAdapter) void {
        var backoff: u64 = 500;
        while (self.running.load(.acquire)) {
            const r = if (self.url.tls) self.runTls() else self.runPlain();
            r catch |err| {
                if (self.running.load(.acquire)) log.warn("Streamlabs: connection ended: {any}", .{err});
            };
            self.setSock(null);
            if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, .degraded);
            if (!self.running.load(.acquire)) break;
            // トークンが拒否されたときは叩き続けない
            const wait = if (self.rejected.load(.acquire)) 60_000 else backoff;
            backoff = @min(backoff * 2, 30_000);
            var slept: u64 = 0;
            while (slept < wait and self.running.load(.acquire)) : (slept += 50) std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }

    fn runPlain(self: *StreamlabsAdapter) !void {
        const stream = try std.net.tcpConnectToHost(self.allocator, self.url.host, self.url.port);
        defer stream.close();
        self.setSock(stream.handle);
        try self.session(stream);
    }

    fn runTls(self: *StreamlabsAdapter) !void {
        const conn = try self.allocator.create(ws.TlsConn);
        defer self.allocator.destroy(conn);
        try conn.connect(self.allocator, self.url.host, self.url.port);
        defer conn.close(self.allocator);
        self.setSock(conn.stream.handle);
        try self.session(conn);
    }

    fn session(self: *StreamlabsAdapter, conn: anytype) !void {
        ws.clientHandshake(conn, self.url.host, self.url.port, self.request_path, "") catch |err| {
            if (err == error.HandshakeRejected) {
                self.rejected.store(true, .release);
                log.err("Streamlabs: handshake rejected. STREAMLABS_SOCKET_TOKEN を確認してください (60 秒後に再試行)", .{});
            }
            return err;
        };
        var ping_interval_ms: i64 = 25_000;
        var connected = false;
        var next_ping: i64 = std.time.milliTimestamp() + ping_interval_ms;
        while (self.running.load(.acquire)) {
            const now = std.time.milliTimestamp();
            if (now >= next_ping) {
                try ws.writeFrame(conn, .text, "2", true);
                next_ping = now + ping_interval_ms;
            }
            const wait: i32 = @intCast(@max(1, @min(next_ping - now, 1000)));
            if (!try ws.waitReadable(conn, wait)) continue;

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
            const pkt = f.payload;
            if (pkt.len == 0) continue;
            switch (pkt[0]) {
                '0' => {
                    // サーバーが決めた間隔に合わせ、次の ping もそこから数え直す
                    ping_interval_ms = parsePingInterval(self.allocator, pkt[1..]) orelse ping_interval_ms;
                    next_ping = std.time.milliTimestamp() + ping_interval_ms;
                },
                '1' => return error.EndOfStream,
                '3' => _ = self.pings.fetchAdd(1, .monotonic),
                '4' => {
                    if (std.mem.startsWith(u8, pkt, "40")) {
                        connected = true;
                        self.rejected.store(false, .release);
                        if (self.bus.graph) |g| g.updateNodeStatus(self.node_id, .active);
                        log.info("Streamlabs: connected to the Socket API", .{});
                    } else if (std.mem.startsWith(u8, pkt, "41")) {
                        return error.EndOfStream;
                    } else if (std.mem.startsWith(u8, pkt, "44")) {
                        self.rejected.store(true, .release);
                        log.err("Streamlabs: connection refused by the server (token?). 60 秒後に再試行", .{});
                        return error.ConnectRejected;
                    } else if (std.mem.startsWith(u8, pkt, "42")) {
                        if (!connected) continue;
                        self.handleEvent(pkt[2..]);
                    }
                },
                else => {},
            }
        }
    }

    /// 42 の本体 `["event", {type, for, message: [...]}]` を 1 件ずつ発行する
    fn handleEvent(self: *StreamlabsAdapter, body: []const u8) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch return;
        defer parsed.deinit();
        const arr = if (parsed.value == .array) parsed.value.array.items else return;
        if (arr.len < 2 or arr[0] != .string or !std.mem.eql(u8, arr[0].string, "event")) return;
        const ev = arr[1];
        if (ev != .object) return;
        var topic_buf: [128]u8 = undefined;
        const topic = eventTopic(&topic_buf, ev) orelse return;
        const platform: []const u8 = if (ev.object.get("for")) |v| (if (v == .string) v.string else "") else "";

        // message は通常配列。単体のオブジェクトで来た場合も 1 件として扱う
        const msg: std.json.Value = ev.object.get("message") orelse .null;
        const single = [1]std.json.Value{msg};
        const items: []const std.json.Value = switch (msg) {
            .array => |a| a.items,
            .object => &single,
            else => &.{},
        };
        for (items) |item| {
            var out: std.ArrayListUnmanaged(u8) = .{};
            defer out.deinit(self.allocator);
            out.writer(self.allocator).print("{f}", .{std.json.fmt(.{ .platform = platform, .data = item }, .{})}) catch return;
            self.bus.publish(topic, out.items, .BestEffort, self.node_id) catch |err| {
                log.warn("Streamlabs: publish {s} failed: {any}", .{ topic, err });
                continue;
            };
            _ = self.received.fetchAdd(1, .monotonic);
        }
    }
};

fn parsePingInterval(allocator: std.mem.Allocator, json: []const u8) ?i64 {
    var p = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return null;
    defer p.deinit();
    if (p.value != .object) return null;
    const v = p.value.object.get("pingInterval") orelse return null;
    if (v != .integer or v.integer < 100 or v.integer > 600_000) return null;
    return v.integer;
}

/// `type` からトピック `ext.streamlabs.event.<type>` を作る。使えない文字は `_` に置き換える
pub fn eventTopic(buf: []u8, ev: std.json.Value) ?[]const u8 {
    const prefix = "ext.streamlabs.event.";
    var kind: []const u8 = "unknown";
    if (ev == .object) {
        if (ev.object.get("type")) |v| {
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

test "validToken" {
    try std.testing.expect(validToken("eyJhbGciOi.JIUzI1-NiJ9_x"));
    try std.testing.expect(!validToken(""));
    try std.testing.expect(!validToken("a&b=c"));
    try std.testing.expect(!validToken("a b"));
}

test "parsePingInterval" {
    try std.testing.expectEqual(@as(?i64, 25000), parsePingInterval(std.testing.allocator, "{\"sid\":\"x\",\"pingInterval\":25000,\"pingTimeout\":60000}"));
    try std.testing.expectEqual(@as(?i64, null), parsePingInterval(std.testing.allocator, "{\"pingInterval\":5}"));
    try std.testing.expectEqual(@as(?i64, null), parsePingInterval(std.testing.allocator, "not json"));
}

test "eventTopic sanitizes type" {
    var buf: [128]u8 = undefined;
    var p = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"donation\"}", .{});
    defer p.deinit();
    try std.testing.expectEqualStrings("ext.streamlabs.event.donation", eventTopic(&buf, p.value).?);
    var q = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"type\":\"a.#\"}", .{});
    defer q.deinit();
    try std.testing.expectEqualStrings("ext.streamlabs.event.a__", eventTopic(&buf, q.value).?);
}

test "init builds the request path without logging the token" {
    var bus = try event_bus.EventBus.init(std.testing.allocator, 4);
    defer bus.deinit();
    const a = try StreamlabsAdapter.init(std.testing.allocator, &bus, .{ .url = "ws://127.0.0.1:1/socket.io/?EIO=3&transport=websocket", .token = "tok" });
    defer a.deinit();
    try std.testing.expectEqualStrings("/socket.io/?EIO=3&transport=websocket&token=tok", a.request_path);
    try std.testing.expectError(error.InvalidToken, StreamlabsAdapter.init(std.testing.allocator, &bus, .{ .token = "x&admin=1" }));
}
