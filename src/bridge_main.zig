//! `weave-bridge` — 既存ツール (Streamer.bot) を WEAVE に繋ぐブリッジ (互換戦略 C)
//!
//! 「今の Bot を捨てずに WEAVE のイベントに混ぜる」ための外部ノード。
//!   Streamer.bot のイベント  → WEAVE: ext.streamerbot.<Source>.<Type>
//!                              (Twitch の ChatMessage は ext.twitch.chat.message にも正規化して流す)
//!   WEAVE: ext.streamerbot.action.request {"name": "...", "args": {...}} → Streamer.bot の DoAction
//!
//! WEAVE 側へは manifest を名乗るリモートノード (remote セル) として接続するので、
//! 権限検査・レート制限・セルの bridge 制約をすべて通る。Streamer.bot 自体は
//! 「全接続が自 PC から出るローカル常駐ツール」だが、WEAVE 経由の部分は影響範囲が宣言で見える。
//!
//! プロトコル (Streamer.bot WebSocket Server, docs.streamer.bot/api/websocket):
//!   server → Hello {authentication?: {salt, challenge}}
//!   client → Authenticate {authentication: base64(sha256(base64(sha256(password + salt)) + challenge))}
//!   client → Subscribe {events: {"Twitch": ["ChatMessage", ...]}}
//!   server → {timeStamp, event: {source, type}, data}
//!   client → DoAction {action: {name} | {id}, args}
//!
//! Usage:
//!   weave-bridge [--weave ws://127.0.0.1:8081/] [--token T | env WEAVE_NODE_WS_TOKEN]
//!                [--streamerbot ws://127.0.0.1:8080/] [--password P | env STREAMERBOT_PASSWORD]
//!                [--events Twitch:ChatMessage,Twitch:Follow]
//!   weave-bridge mock-streamerbot [--port 8080] [--password P] [--chat "草" --count 10 --interval-ms 100]
//!                                 [--actions-log path]
//!   weave-bridge mock-astro [--port 9123] [--jwt mock-jwt] [--count 5] [--interval-ms 100]
//!                (StreamElements Astro のモック。Core の --streamelements-url に向ける)
//!   weave-bridge mock-streamlabs [--port 9124] [--token mock-token] [--count 5] [--interval-ms 100] [--ping-interval-ms 25000]
//!                (Streamlabs Socket API のモック。Core の --streamlabs-url に向ける)

const std = @import("std");
const ws = @import("transport/ws_proto.zig");
const pattern = @import("core/pattern.zig");
const ObsEgressNode = @import("builtin/obs.zig").ObsEgressNode;

const log = std.log.scoped(.bridge);

const Url = struct { host: []const u8, port: u16, path: []const u8 };

fn parseUrl(url: []const u8) !Url {
    if (!std.mem.startsWith(u8, url, "ws://")) return error.UnsupportedUrl;
    const after = url["ws://".len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const hostport = after[0..slash];
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.MissingPort;
    return .{
        .host = hostport[0..colon],
        .port = try std.fmt.parseInt(u16, hostport[colon + 1 ..], 10),
        .path = if (slash < after.len) after[slash..] else "/",
    };
}

const Event = struct { source: []const u8, type: []const u8 };

const Bridge = struct {
    allocator: std.mem.Allocator,
    weave_url: Url,
    token: []const u8,
    sb_url: Url,
    password: ?[]const u8,
    events: []const Event,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    weave_mutex: std.Thread.Mutex = .{},
    weave: ?std.net.Stream = null,
    sb_mutex: std.Thread.Mutex = .{},
    sb: ?std.net.Stream = null,
    next_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(1),

    forwarded: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    actions: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    const MANIFEST =
        \\{"name":"streamerbot","version":"1.0.0","description":"Streamer.bot bridge",
        \\ "permissions":{"publish":["ext.streamerbot.#","ext.twitch.chat.message"],
        \\                "subscribe":["ext.streamerbot.action.request"]},
        \\ "rate_limit_eps":200}
    ;

    fn sendWeave(self: *Bridge, data: []const u8) void {
        self.weave_mutex.lock();
        defer self.weave_mutex.unlock();
        const s = self.weave orelse return;
        ws.writeFrame(s, .text, data, true) catch {};
    }

    fn sendSb(self: *Bridge, data: []const u8) bool {
        self.sb_mutex.lock();
        defer self.sb_mutex.unlock();
        const s = self.sb orelse return false;
        ws.writeFrame(s, .text, data, true) catch return false;
        return true;
    }

    // ---------------- WEAVE 側 ----------------

    fn weaveLoop(self: *Bridge) void {
        var backoff: u64 = 250;
        while (self.running.load(.acquire)) {
            self.weaveSession() catch |err| log.warn("WEAVE connection: {any}", .{err});
            self.weave_mutex.lock();
            if (self.weave) |s| s.close();
            self.weave = null;
            self.weave_mutex.unlock();
            if (!self.running.load(.acquire)) break;
            std.Thread.sleep(backoff * std.time.ns_per_ms);
            backoff = @min(backoff * 2, 5000);
        }
    }

    fn weaveSession(self: *Bridge) !void {
        const addr = try std.net.Address.resolveIp(self.weave_url.host, self.weave_url.port);
        const s = try std.net.tcpConnectToAddress(addr);
        var hdr: [256]u8 = undefined;
        const extra = try std.fmt.bufPrint(&hdr, "X-WEAVE-Token: {s}\r\n", .{self.token});
        ws.clientHandshake(s, self.weave_url.host, self.weave_url.port, self.weave_url.path, extra) catch |err| {
            s.close();
            return err;
        };
        self.weave_mutex.lock();
        self.weave = s;
        self.weave_mutex.unlock();

        var hello: std.ArrayListUnmanaged(u8) = .{};
        defer hello.deinit(self.allocator);
        try hello.writer(self.allocator).print("{{\"type\":\"hello\",\"manifest\":{s}}}", .{MANIFEST});
        self.sendWeave(hello.items);

        while (self.running.load(.acquire)) {
            const f = try ws.readMessage(s, self.allocator, 1 << 20);
            defer self.allocator.free(f.payload);
            if (f.opcode == .close) return error.EndOfStream;
            if (f.opcode != .text) continue;
            self.onWeaveMessage(f.payload);
        }
    }

    fn onWeaveMessage(self: *Bridge, text: []const u8) void {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, text, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        const o = parsed.value.object;
        const t = o.get("type") orelse return;
        if (t != .string) return;
        if (std.mem.eql(u8, t.string, "welcome")) {
            std.debug.print("[bridge] joined WEAVE as a remote node (cell 'remote')\n", .{});
            return;
        }
        if (std.mem.eql(u8, t.string, "error")) {
            std.debug.print("[bridge] WEAVE rejected: {s}\n", .{text});
            return;
        }
        if (!std.mem.eql(u8, t.string, "event")) return;
        const topic = o.get("topic") orelse return;
        if (topic != .string or !std.mem.eql(u8, topic.string, "ext.streamerbot.action.request")) return;
        const p = o.get("payload") orelse return;
        if (p != .object) return;

        // WEAVE → Streamer.bot: DoAction
        const name = p.object.get("name");
        const id = p.object.get("id");
        const args = p.object.get("args") orelse std.json.Value{ .object = std.json.ObjectMap.init(self.allocator) };
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        var idbuf: [32]u8 = undefined;
        const req_id = std.fmt.bufPrint(&idbuf, "weave-{d}", .{self.next_id.fetchAdd(1, .monotonic)}) catch return;
        if (id) |v| {
            if (v != .string) return;
            w.print("{f}", .{std.json.fmt(.{ .request = "DoAction", .action = .{ .id = v.string }, .args = args, .id = req_id }, .{})}) catch return;
        } else if (name) |v| {
            if (v != .string) return;
            w.print("{f}", .{std.json.fmt(.{ .request = "DoAction", .action = .{ .name = v.string }, .args = args, .id = req_id }, .{})}) catch return;
        } else return;
        if (self.sendSb(out.items)) _ = self.actions.fetchAdd(1, .monotonic);
    }

    // ---------------- Streamer.bot 側 ----------------

    fn sbLoop(self: *Bridge) void {
        var backoff: u64 = 250;
        while (self.running.load(.acquire)) {
            self.sbSession() catch |err| log.warn("Streamer.bot connection: {any}", .{err});
            self.sb_mutex.lock();
            if (self.sb) |s| s.close();
            self.sb = null;
            self.sb_mutex.unlock();
            if (!self.running.load(.acquire)) break;
            std.Thread.sleep(backoff * std.time.ns_per_ms);
            backoff = @min(backoff * 2, 5000);
        }
    }

    fn sbSession(self: *Bridge) !void {
        const addr = try std.net.Address.resolveIp(self.sb_url.host, self.sb_url.port);
        const s = try std.net.tcpConnectToAddress(addr);
        ws.clientHandshake(s, self.sb_url.host, self.sb_url.port, self.sb_url.path, "") catch |err| {
            s.close();
            return err;
        };
        self.sb_mutex.lock();
        self.sb = s;
        self.sb_mutex.unlock();

        while (self.running.load(.acquire)) {
            const f = try ws.readMessage(s, self.allocator, 4 << 20);
            defer self.allocator.free(f.payload);
            if (f.opcode == .close) return error.EndOfStream;
            if (f.opcode != .text) continue;
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, f.payload, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const o = parsed.value.object;

            if (o.get("request")) |r| {
                if (r == .string and std.mem.eql(u8, r.string, "Hello")) {
                    if (o.get("authentication")) |auth| {
                        if (auth == .object) {
                            const pw = self.password orelse return error.PasswordRequired;
                            const salt = auth.object.get("salt") orelse return error.BadHello;
                            const challenge = auth.object.get("challenge") orelse return error.BadHello;
                            if (salt != .string or challenge != .string) return error.BadHello;
                            const secret = ObsEgressNode.authString(pw, salt.string, challenge.string);
                            var buf: [256]u8 = undefined;
                            const req = try std.fmt.bufPrint(&buf, "{{\"request\":\"Authenticate\",\"id\":\"weave-auth\",\"authentication\":\"{s}\"}}", .{secret});
                            _ = self.sendSb(req);
                        }
                    }
                    try self.subscribe();
                    std.debug.print("[bridge] connected to Streamer.bot ({s}:{d})\n", .{ self.sb_url.host, self.sb_url.port });
                    continue;
                }
            }
            if (o.get("event")) |ev| {
                if (ev != .object) continue;
                const src = ev.object.get("source") orelse continue;
                const ty = ev.object.get("type") orelse continue;
                if (src != .string or ty != .string) continue;
                self.forwardEvent(src.string, ty.string, o.get("data") orelse .null);
            }
        }
    }

    fn subscribe(self: *Bridge) !void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        try w.writeAll("{\"request\":\"Subscribe\",\"id\":\"weave-sub\",\"events\":{");
        // source ごとにまとめる
        var sources: std.StringArrayHashMapUnmanaged(std.ArrayListUnmanaged([]const u8)) = .{};
        defer {
            for (sources.values()) |*l| l.deinit(self.allocator);
            sources.deinit(self.allocator);
        }
        for (self.events) |e| {
            const gop = try sources.getOrPut(self.allocator, e.source);
            if (!gop.found_existing) gop.value_ptr.* = .{};
            try gop.value_ptr.append(self.allocator, e.type);
        }
        var first = true;
        var it = sources.iterator();
        while (it.next()) |e| {
            if (!first) try w.writeAll(",");
            first = false;
            try w.print("{f}:{f}", .{ std.json.fmt(e.key_ptr.*, .{}), std.json.fmt(e.value_ptr.items, .{}) });
        }
        try w.writeAll("}}");
        _ = self.sendSb(out.items);
    }

    fn publishToWeave(self: *Bridge, topic: []const u8, payload: std.json.Value) void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        out.writer(self.allocator).print("{f}", .{std.json.fmt(.{ .type = "publish", .topic = topic, .payload = payload }, .{})}) catch return;
        self.sendWeave(out.items);
    }

    fn forwardEvent(self: *Bridge, source: []const u8, ty: []const u8, data: std.json.Value) void {
        var tbuf: [160]u8 = undefined;
        const topic = std.fmt.bufPrint(&tbuf, "ext.streamerbot.{s}.{s}", .{ source, ty }) catch return;
        if (!pattern.validTopic(topic)) return;
        self.publishToWeave(topic, data);
        _ = self.forwarded.fetchAdd(1, .monotonic);

        // Twitch のチャットは WEAVE 共通のチャットトピックにも正規化して流す
        // (既存の kusa_node などが、Streamer.bot 経由のチャットにもそのまま反応できる)
        if (std.mem.eql(u8, source, "Twitch") and std.mem.eql(u8, ty, "ChatMessage")) {
            const norm = normalizeChat(data) orelse return;
            var obj = std.json.ObjectMap.init(self.allocator);
            defer obj.deinit();
            obj.put("user", .{ .string = norm.user }) catch return;
            obj.put("message", .{ .string = norm.message }) catch return;
            obj.put("via", .{ .string = "streamerbot" }) catch return;
            self.publishToWeave("ext.twitch.chat.message", .{ .object = obj });
        }
    }

    /// Streamer.bot の Twitch ChatMessage から (user, message) を取り出す。
    /// data.message が {username|displayName, message} のオブジェクトである形式と、
    /// data.user.name + data.message (文字列) の形式の両方を受け付ける。
    pub fn normalizeChat(data: std.json.Value) ?struct { user: []const u8, message: []const u8 } {
        if (data != .object) return null;
        const d = data.object;
        if (d.get("message")) |m| {
            if (m == .object) {
                const text = m.object.get("message") orelse return null;
                const user = m.object.get("displayName") orelse m.object.get("username") orelse return null;
                if (text == .string and user == .string) return .{ .user = user.string, .message = text.string };
            } else if (m == .string) {
                const u = d.get("user") orelse return null;
                if (u == .object) {
                    const n = u.object.get("name") orelse u.object.get("login") orelse return null;
                    if (n == .string) return .{ .user = n.string, .message = m.string };
                }
            }
        }
        return null;
    }
};

// ======================================================================
// Streamer.bot のモック (テスト・デモ用)
// ======================================================================

const Mock = struct {
    password: ?[]const u8 = null,
    chat: []const u8 = "草",
    count: u32 = 10,
    interval_ms: u64 = 100,
    actions_log: ?[]const u8 = null,
};

fn mockServe(allocator: std.mem.Allocator, port: u16, m: Mock) !void {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try ws.listenExclusive(addr);
    defer server.deinit();
    std.debug.print("[mock-streamerbot] ws://127.0.0.1:{d}/ (auth: {s})\n", .{ port, if (m.password != null) "on" else "off" });
    while (true) {
        const conn = try server.accept();
        mockClient(allocator, conn.stream, m) catch |err| std.debug.print("[mock-streamerbot] client ended: {any}\n", .{err});
        conn.stream.close();
    }
}

fn mockClient(allocator: std.mem.Allocator, s: std.net.Stream, m: Mock) !void {
    var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
    const head = try ws.readHead(s, &head_buf);
    const req = try ws.parseRequest(head);
    try ws.writeUpgrade(s, req.ws_key orelse "");

    const salt = "bW9jay1zYWx0";
    const challenge = "bW9jay1jaGFsbGVuZ2U=";
    if (m.password != null) {
        try ws.writeFrame(s, .text, "{\"request\":\"Hello\",\"info\":{\"name\":\"mock\",\"source\":\"websocketServer\"},\"authentication\":{\"salt\":\"" ++ salt ++ "\",\"challenge\":\"" ++ challenge ++ "\"}}", false);
    } else {
        try ws.writeFrame(s, .text, "{\"request\":\"Hello\",\"info\":{\"name\":\"mock\",\"source\":\"websocketServer\"}}", false);
    }

    var authed = m.password == null;
    var emitted = false;
    while (true) {
        const f = try ws.readMessage(s, allocator, 1 << 20);
        defer allocator.free(f.payload);
        if (f.opcode == .close) return;
        if (f.opcode != .text) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, f.payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const r = parsed.value.object.get("request") orelse continue;
        if (r != .string) continue;
        if (std.mem.eql(u8, r.string, "Authenticate")) {
            const got = parsed.value.object.get("authentication") orelse .null;
            const expected = ObsEgressNode.authString(m.password orelse "", salt, challenge);
            authed = got == .string and std.mem.eql(u8, got.string, &expected);
            try ws.writeFrame(s, .text, if (authed) "{\"id\":\"weave-auth\",\"status\":\"ok\"}" else "{\"id\":\"weave-auth\",\"status\":\"error\",\"error\":\"authentication failed\"}", false);
            if (!authed) return error.AuthenticationFailed;
        } else if (std.mem.eql(u8, r.string, "Subscribe")) {
            if (!authed) return error.NotAuthenticated;
            try ws.writeFrame(s, .text, "{\"id\":\"weave-sub\",\"status\":\"ok\"}", false);
            if (!emitted) {
                emitted = true;
                // 購読が確立したらチャットを流す (WEAVE 側の hello/welcome を待つ)
                std.Thread.sleep(500 * std.time.ns_per_ms);
                var i: u32 = 0;
                while (i < m.count) : (i += 1) {
                    var buf: [512]u8 = undefined;
                    var w = std.io.Writer.fixed(&buf);
                    var ubuf: [32]u8 = undefined;
                    const user = std.fmt.bufPrint(&ubuf, "sb_viewer{d}", .{i + 1}) catch "sb_viewer";
                    try w.print("{f}", .{std.json.fmt(.{ .timeStamp = "2026-09-23T12:00:00+09:00", .event = .{ .source = "Twitch", .type = "ChatMessage" }, .data = .{ .message = .{ .username = user, .displayName = user, .message = m.chat } } }, .{})});
                    try ws.writeFrame(s, .text, w.buffered(), false);
                    std.Thread.sleep(m.interval_ms * std.time.ns_per_ms);
                }
            }
        } else if (std.mem.eql(u8, r.string, "DoAction")) {
            std.debug.print("[mock-streamerbot] DoAction {s}\n", .{f.payload});
            if (m.actions_log) |path| {
                const fd = try std.posix.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true }, 0o644);
                defer std.posix.close(fd);
                _ = try std.posix.write(fd, f.payload);
                _ = try std.posix.write(fd, "\n");
            }
            try ws.writeFrame(s, .text, "{\"status\":\"ok\"}", false);
        }
    }
}

// ======================================================================
// StreamElements Astro のモック (Core の StreamElements アダプタのテスト用)
// 実サービスには繋がない。JWT はモック専用の偽値。
// ======================================================================

const MockAstro = struct {
    jwt: []const u8 = "mock-jwt",
    count: u32 = 5,
    interval_ms: u64 = 100,
};

fn astroServe(allocator: std.mem.Allocator, port: u16, m: MockAstro) !void {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try ws.listenExclusive(addr);
    defer server.deinit();
    std.debug.print("[mock-astro] ws://127.0.0.1:{d}/\n", .{port});
    while (true) {
        const conn = try server.accept();
        const th = std.Thread.spawn(.{}, astroThread, .{ allocator, conn.stream, m }) catch {
            conn.stream.close();
            continue;
        };
        th.detach();
    }
}

fn astroThread(allocator: std.mem.Allocator, s: std.net.Stream, m: MockAstro) void {
    defer s.close();
    astroClient(allocator, s, m) catch |err| std.debug.print("[mock-astro] client ended: {any}\n", .{err});
}

fn astroClient(allocator: std.mem.Allocator, s: std.net.Stream, m: MockAstro) !void {
    var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
    const head = try ws.readHead(s, &head_buf);
    const req = try ws.parseRequest(head);
    try ws.writeUpgrade(s, req.ws_key orelse "");
    try ws.writeFrame(s, .text, "{\"type\":\"welcome\",\"data\":{\"client_id\":\"mock-client\",\"message\":\"You are connected\"}}", false);

    // subscribe を待つ
    const sub = try ws.readMessage(s, allocator, 1 << 20);
    defer allocator.free(sub.payload);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, sub.payload, .{});
    defer parsed.deinit();
    const o = if (parsed.value == .object) parsed.value.object else return error.BadSubscribe;
    const t = o.get("type") orelse return error.BadSubscribe;
    if (t != .string or !std.mem.eql(u8, t.string, "subscribe")) return error.BadSubscribe;
    const data = o.get("data") orelse return error.BadSubscribe;
    if (data != .object) return error.BadSubscribe;
    const topic = data.object.get("topic") orelse .null;
    const room = data.object.get("room") orelse .null;
    const token = data.object.get("token") orelse .null;
    if (topic != .string or room != .string or token != .string) return error.BadSubscribe;

    if (!ws.constantTimeEql(token.string, m.jwt)) {
        std.debug.print("[mock-astro] subscribe rejected: err_unauthorized\n", .{});
        try ws.writeFrame(s, .text, "{\"type\":\"response\",\"nonce\":\"weave-activities\",\"error\":\"err_unauthorized\",\"data\":{\"message\":\"invalid token\"}}", false);
        return;
    }
    std.debug.print("[mock-astro] subscribed {s} room={s}\n", .{ topic.string, room.string });
    try ws.writeFrame(s, .text, "{\"type\":\"response\",\"nonce\":\"weave-activities\",\"data\":{\"message\":\"successfully subscribed to topic\"}}", false);

    // PING → PONG を確かめながら、アクティビティを流す
    const kinds = [_][]const u8{ "follower", "tip", "subscriber", "cheer", "raid" };
    var pongs: u32 = 0;
    var i: u32 = 0;
    while (i < m.count) : (i += 1) {
        try ws.writeFrame(s, .ping, "astro", false);
        const pf = try ws.readMessage(s, allocator, 1 << 16);
        allocator.free(pf.payload);
        if (pf.opcode == .pong) pongs += 1;

        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        var ubuf: [32]u8 = undefined;
        const user = std.fmt.bufPrint(&ubuf, "se_viewer{d}", .{i + 1}) catch "se_viewer";
        try w.print("{f}", .{std.json.fmt(.{ .type = "message", .topic = topic.string, .room = room.string, .data = .{ .type = kinds[i % kinds.len], .provider = "twitch", .channel = room.string, .data = .{ .username = user, .displayName = user, .amount = i + 1 } } }, .{})});
        try ws.writeFrame(s, .text, w.buffered(), false);
        std.Thread.sleep(m.interval_ms * std.time.ns_per_ms);
    }
    std.debug.print("[mock-astro] sent {d} activities, pongs {d}/{d}\n", .{ m.count, pongs, m.count });
    // 切断されるまで待つ
    while (true) {
        const f = try ws.readMessage(s, allocator, 1 << 16);
        allocator.free(f.payload);
        if (f.opcode == .close) return;
    }
}

// ======================================================================
// Streamlabs Socket API のモック (socket.io 2.x = Engine.IO v3)
// 実サービスには繋がない。トークンはモック専用の偽値。
// ======================================================================

const MockStreamlabs = struct {
    token: []const u8 = "mock-token",
    count: u32 = 5,
    interval_ms: u64 = 100,
    ping_interval_ms: u32 = 25_000,
};

fn slServe(port: u16, m: MockStreamlabs) !void {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try ws.listenExclusive(addr);
    defer server.deinit();
    std.debug.print("[mock-streamlabs] ws://127.0.0.1:{d}/socket.io/?EIO=3&transport=websocket\n", .{port});
    while (true) {
        const conn = try server.accept();
        const th = std.Thread.spawn(.{}, slThread, .{ conn.stream, m }) catch {
            conn.stream.close();
            continue;
        };
        th.detach();
    }
}

fn slThread(s: std.net.Stream, m: MockStreamlabs) void {
    defer s.close();
    slClient(std.heap.smp_allocator, s, m) catch |err| std.debug.print("[mock-streamlabs] client ended: {any}\n", .{err});
}

fn slClient(allocator: std.mem.Allocator, s: std.net.Stream, m: MockStreamlabs) !void {
    var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
    const head = try ws.readHead(s, &head_buf);
    const req = try ws.parseRequest(head);
    const eio = req.queryParam("EIO") orelse "";
    const token = req.queryParam("token") orelse "";
    if (!std.mem.eql(u8, eio, "3")) {
        try ws.writeStatus(s, 400, "Bad Request", "unsupported EIO");
        return;
    }
    try ws.writeUpgrade(s, req.ws_key orelse "");
    var open_buf: [160]u8 = undefined;
    const open = try std.fmt.bufPrint(&open_buf, "0{{\"sid\":\"mock-sid\",\"upgrades\":[],\"pingInterval\":{d},\"pingTimeout\":60000}}", .{m.ping_interval_ms});
    try ws.writeFrame(s, .text, open, false);
    if (!ws.constantTimeEql(token, m.token)) {
        std.debug.print("[mock-streamlabs] connect rejected: bad token\n", .{});
        try ws.writeFrame(s, .text, "44\"Unauthorized\"", false);
        return;
    }
    try ws.writeFrame(s, .text, "40", false);
    std.debug.print("[mock-streamlabs] connected\n", .{});

    const kinds = [_][]const u8{ "donation", "follow", "subscription", "bits", "raid" };
    var pings: u32 = 0;
    var i: u32 = 0;
    var next_emit: i64 = std.time.milliTimestamp() + 300;
    while (true) {
        const now = std.time.milliTimestamp();
        if (i < m.count and now >= next_emit) {
            var buf: [640]u8 = undefined;
            var w = std.io.Writer.fixed(&buf);
            var ubuf: [32]u8 = undefined;
            const user = std.fmt.bufPrint(&ubuf, "sl_viewer{d}", .{i + 1}) catch "sl_viewer";
            try w.writeAll("42");
            try w.print("{f}", .{std.json.fmt(.{ "event", .{ .type = kinds[i % kinds.len], .@"for" = if (i % kinds.len == 0) "streamlabs" else "twitch_account", .message = .{.{ .name = user, .amount = i + 1, .formatted_amount = "$1.00", .message = "gg", ._id = user }} } }, .{})});
            try ws.writeFrame(s, .text, w.buffered(), false);
            i += 1;
            next_emit = now + @as(i64, @intCast(m.interval_ms));
            if (i == m.count) std.debug.print("[mock-streamlabs] sent {d} events\n", .{m.count});
        }
        if (!try ws.waitReadable(s, 50)) continue;
        const f = try ws.readMessage(s, allocator, 1 << 16);
        defer allocator.free(f.payload);
        if (f.opcode == .close) return;
        if (f.opcode == .text and std.mem.eql(u8, f.payload, "2")) {
            pings += 1;
            std.debug.print("[mock-streamlabs] ping {d}\n", .{pings});
            try ws.writeFrame(s, .text, "3", false);
        }
    }
}

fn parseEvents(allocator: std.mem.Allocator, spec: []const u8) ![]Event {
    var list: std.ArrayListUnmanaged(Event) = .{};
    var it = std.mem.splitScalar(u8, spec, ',');
    while (it.next()) |item| {
        const t = std.mem.trim(u8, item, " ");
        const colon = std.mem.indexOfScalar(u8, t, ':') orelse return error.BadEventSpec;
        try list.append(allocator, .{ .source = t[0..colon], .type = t[colon + 1 ..] });
    }
    return list.toOwnedSlice(allocator);
}

pub fn main() !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const allocator = arena_inst.allocator();
    const args = try std.process.argsAlloc(allocator);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "mock-streamerbot")) {
        var port: u16 = 8080;
        var m = Mock{};
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (i + 1 >= args.len) break;
            if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--password")) {
                i += 1;
                m.password = args[i];
            } else if (std.mem.eql(u8, args[i], "--chat")) {
                i += 1;
                m.chat = args[i];
            } else if (std.mem.eql(u8, args[i], "--count")) {
                i += 1;
                m.count = try std.fmt.parseInt(u32, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--interval-ms")) {
                i += 1;
                m.interval_ms = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--actions-log")) {
                i += 1;
                m.actions_log = args[i];
            }
        }
        return mockServe(allocator, port, m);
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "mock-streamlabs")) {
        var port: u16 = 9124;
        var m = MockStreamlabs{};
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--token")) {
                i += 1;
                m.token = args[i];
            } else if (std.mem.eql(u8, args[i], "--count")) {
                i += 1;
                m.count = try std.fmt.parseInt(u32, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--interval-ms")) {
                i += 1;
                m.interval_ms = try std.fmt.parseInt(u64, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--ping-interval-ms")) {
                i += 1;
                m.ping_interval_ms = try std.fmt.parseInt(u32, args[i], 10);
            }
        }
        return slServe(port, m);
    }

    if (args.len >= 2 and std.mem.eql(u8, args[1], "mock-astro")) {
        var port: u16 = 9123;
        var m = MockAstro{};
        var i: usize = 2;
        while (i + 1 < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--port")) {
                i += 1;
                port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--jwt")) {
                i += 1;
                m.jwt = args[i];
            } else if (std.mem.eql(u8, args[i], "--count")) {
                i += 1;
                m.count = try std.fmt.parseInt(u32, args[i], 10);
            } else if (std.mem.eql(u8, args[i], "--interval-ms")) {
                i += 1;
                m.interval_ms = try std.fmt.parseInt(u64, args[i], 10);
            }
        }
        return astroServe(std.heap.smp_allocator, port, m);
    }

    var weave_url: []const u8 = "ws://127.0.0.1:8081/";
    var sb_url: []const u8 = "ws://127.0.0.1:8080/";
    var token: ?[]const u8 = std.process.getEnvVarOwned(allocator, "WEAVE_NODE_WS_TOKEN") catch null;
    var password: ?[]const u8 = std.process.getEnvVarOwned(allocator, "STREAMERBOT_PASSWORD") catch null;
    var events_spec: []const u8 = "Twitch:ChatMessage,Twitch:Follow,Twitch:Cheer,Twitch:Sub,Twitch:Raid";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("see the header of src/bridge_main.zig for usage\n", .{});
            return;
        }
        if (i + 1 >= args.len) break;
        if (std.mem.eql(u8, a, "--weave")) {
            i += 1;
            weave_url = args[i];
        } else if (std.mem.eql(u8, a, "--streamerbot")) {
            i += 1;
            sb_url = args[i];
        } else if (std.mem.eql(u8, a, "--token")) {
            i += 1;
            token = args[i];
        } else if (std.mem.eql(u8, a, "--password")) {
            i += 1;
            password = args[i];
        } else if (std.mem.eql(u8, a, "--events")) {
            i += 1;
            events_spec = args[i];
        }
    }
    const tok = token orelse {
        std.debug.print("weave-bridge: WEAVE node token required (--token or WEAVE_NODE_WS_TOKEN)\n", .{});
        std.process.exit(2);
    };

    var bridge = Bridge{
        .allocator = std.heap.page_allocator,
        .weave_url = try parseUrl(weave_url),
        .token = tok,
        .sb_url = try parseUrl(sb_url),
        .password = password,
        .events = try parseEvents(allocator, events_spec),
    };
    const t1 = try std.Thread.spawn(.{}, Bridge.weaveLoop, .{&bridge});
    const t2 = try std.Thread.spawn(.{}, Bridge.sbLoop, .{&bridge});
    t1.join();
    t2.join();
}

test "normalizeChat handles both payload shapes" {
    const a = std.testing.allocator;
    const p1 = try std.json.parseFromSlice(std.json.Value, a, "{\"message\":{\"username\":\"u1\",\"displayName\":\"U1\",\"message\":\"hi\"}}", .{});
    defer p1.deinit();
    const n1 = Bridge.normalizeChat(p1.value).?;
    try std.testing.expectEqualStrings("U1", n1.user);
    try std.testing.expectEqualStrings("hi", n1.message);
    const p2 = try std.json.parseFromSlice(std.json.Value, a, "{\"user\":{\"name\":\"u2\"},\"message\":\"yo\"}", .{});
    defer p2.deinit();
    const n2 = Bridge.normalizeChat(p2.value).?;
    try std.testing.expectEqualStrings("u2", n2.user);
    try std.testing.expect(Bridge.normalizeChat(.null) == null);
}

test "parseUrl and parseEvents" {
    const u = try parseUrl("ws://127.0.0.1:8080/");
    try std.testing.expectEqual(@as(u16, 8080), u.port);
    try std.testing.expectEqualStrings("/", u.path);
    const ev = try parseEvents(std.testing.allocator, "Twitch:ChatMessage,YouTube:Message");
    defer std.testing.allocator.free(ev);
    try std.testing.expectEqual(@as(usize, 2), ev.len);
    try std.testing.expectEqualStrings("YouTube", ev[1].source);
}
