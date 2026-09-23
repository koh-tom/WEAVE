//! Dashboard / Inspector サーバ (zap を置き換える自前の HTTP + WebSocket 実装)。
//!
//! - GET  /...   : dashboard/dist の静的ファイル (パスを正規化し、ディレクトリ外は拒否)
//! - GET  /ws    : WebSocket。バスのイベントを Inspector に配信し、Inspector からの publish を受ける
//!
//! 置き換えた理由 (docs/v1_plan_2026-09.md R12):
//! - zap の HttpListener.listen() に 500ms の固定 sleep があり、起動時間の約 9 割を占めていた
//! - facil.io (C) への依存が消え、供給網の攻撃面が減る
//!
//! セキュリティ (P0-3):
//! - 既定は 127.0.0.1 で待ち受ける。外に開くのは --bind で明示したときだけ
//! - WebSocket はトークン必須 (development でループバックからの接続だけは省略可)
//! - Inspector からの publish は固定の権限 (ALLOW_*) とレート制限を通す。予約名前空間は発行不可
//! - introspection レベルに応じて、PII を含みうる payload を隠す

const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const topics = @import("../core/topics.zig");
const pattern = @import("../core/pattern.zig");
const ws = @import("../transport/ws_proto.zig");
const RateLimiter = @import("../core/rate_limiter.zig").RateLimiter;
const log = @import("../common/log.zig");

pub const Options = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = 3030,
    dist_dir: []const u8 = "dashboard/dist",
    /// WebSocket 接続に必要なトークン
    token: []const u8,
    /// ループバックからの接続はトークンを省略してよいか (development の利便性)
    allow_loopback_without_token: bool = true,
    /// チャットシミュレータ (ext.* への publish) を許可するか
    simulator: bool = true,
    max_clients: usize = 32,
    publish_rate_eps: f64 = 200,
};

const Client = struct {
    stream: std.net.Stream,
    send_mutex: std.Thread.Mutex = .{},
    alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

pub const DashboardNode = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    opts: Options,
    token: []u8,
    dist_dir: []u8,
    bind: []u8,

    server: ?std.net.Server = null,
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    clients_mutex: std.Thread.Mutex = .{},
    clients: std.ArrayListUnmanaged(*Client) = .{},
    conn_threads: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    rate_mutex: std.Thread.Mutex = .{},
    rate: RateLimiter,

    const ALLOW_ALWAYS = [_][]const u8{ "core.system.graph.request", "core.system.introspection" };
    const ALLOW_SIMULATOR = [_][]const u8{"ext.#"};

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, opts: Options) !*DashboardNode {
        const self = try allocator.create(DashboardNode);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .opts = opts,
            .token = try allocator.dupe(u8, opts.token),
            .dist_dir = try allocator.dupe(u8, opts.dist_dir),
            .bind = try allocator.dupe(u8, opts.bind),
            .rate = RateLimiter.init(opts.publish_rate_eps),
        };
        return self;
    }

    pub fn start(self: *DashboardNode) !void {
        const address = try std.net.Address.parseIp(self.bind, self.opts.port);
        self.server = try address.listen(.{ .reuse_address = true });
        self.running.store(true, .release);
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});

        const observe = self.bus.getCell("observe") orelse try self.bus.createCell("observe", .{ .trust = .core });
        try self.bus.subscribeEx("#", self.node_id, onBusMessage, self, .{ .cell = observe, .receive_own = true, .record_graph = false });
        log.info("Dashboard: http://{s}:{d}/  (Inspector WebSocket: /ws)", .{ self.bind, self.opts.port });
    }

    pub fn stop(self: *DashboardNode) void {
        if (!self.running.swap(false, .acq_rel)) return;
        // accept() で寝ているスレッドを自分への接続で起こす
        if (std.net.Address.parseIp(if (std.mem.eql(u8, self.bind, "0.0.0.0")) "127.0.0.1" else self.bind, self.opts.port)) |addr| {
            if (std.net.tcpConnectToAddress(addr)) |c| c.close() else |_| {}
        } else |_| {}
        if (self.accept_thread) |t| t.join();
        self.accept_thread = null;
        self.clients_mutex.lock();
        for (self.clients.items) |c| {
            c.alive.store(false, .release);
            std.posix.shutdown(c.stream.handle, .both) catch {};
        }
        self.clients_mutex.unlock();
        // 接続スレッドの終了を待つ (最大 2 秒)
        var waited: usize = 0;
        while (self.conn_threads.load(.acquire) > 0 and waited < 200) : (waited += 1) std.Thread.sleep(10 * std.time.ns_per_ms);
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    pub fn deinit(self: *DashboardNode) void {
        self.stop();
        self.clients_mutex.lock();
        for (self.clients.items) |c| {
            c.stream.close();
            self.allocator.destroy(c);
        }
        self.clients.deinit(self.allocator);
        self.clients_mutex.unlock();
        self.allocator.free(self.token);
        self.allocator.free(self.dist_dir);
        self.allocator.free(self.bind);
        self.allocator.destroy(self);
    }

    fn acceptLoop(self: *DashboardNode) void {
        while (self.running.load(.acquire)) {
            const conn = self.server.?.accept() catch |err| {
                if (!self.running.load(.acquire)) break;
                log.warn("Dashboard: accept error: {any}", .{err});
                continue;
            };
            if (!self.running.load(.acquire)) {
                conn.stream.close();
                break;
            }
            _ = self.conn_threads.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, handleConn, .{ self, conn }) catch {
                _ = self.conn_threads.fetchSub(1, .acq_rel);
                conn.stream.close();
                continue;
            };
            t.detach();
        }
    }

    fn handleConn(self: *DashboardNode, conn: std.net.Server.Connection) void {
        defer _ = self.conn_threads.fetchSub(1, .acq_rel);
        var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
        const head = ws.readHead(conn.stream, &head_buf) catch {
            conn.stream.close();
            return;
        };
        const req = ws.parseRequest(head) catch {
            ws.writeStatus(conn.stream, 400, "Bad Request", "bad request") catch {};
            conn.stream.close();
            return;
        };
        if (req.upgrade_websocket and std.mem.eql(u8, req.path, "/ws")) {
            self.handleWebSocket(conn, req);
        } else {
            self.serveStatic(conn.stream, req) catch {};
            conn.stream.close();
        }
    }

    // ------------------------------------------------------------------
    // 静的ファイル
    // ------------------------------------------------------------------

    fn contentType(path: []const u8) []const u8 {
        const ext = std.fs.path.extension(path);
        const map = [_]struct { []const u8, []const u8 }{
            .{ ".html", "text/html; charset=utf-8" },
            .{ ".js", "text/javascript; charset=utf-8" },
            .{ ".css", "text/css; charset=utf-8" },
            .{ ".svg", "image/svg+xml" },
            .{ ".png", "image/png" },
            .{ ".json", "application/json" },
            .{ ".ico", "image/x-icon" },
            .{ ".woff2", "font/woff2" },
        };
        for (map) |m| if (std.mem.eql(u8, ext, m[0])) return m[1];
        return "application/octet-stream";
    }

    /// URL パスを dist_dir 内の相対パスにする。ディレクトリ外を指すものは null。
    pub fn sanitizePath(url_path: []const u8, out: []u8) ?[]const u8 {
        var p = url_path;
        while (p.len > 0 and p[0] == '/') p = p[1..];
        if (p.len == 0) p = "index.html";
        if (p.len >= out.len) return null;
        var it = std.mem.splitScalar(u8, p, '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return null;
            for (seg) |c| if (c == '\\' or c == 0 or c == '%') return null;
        }
        @memcpy(out[0..p.len], p);
        return out[0..p.len];
    }

    fn serveStatic(self: *DashboardNode, stream: std.net.Stream, req: ws.Request) !void {
        if (!std.mem.eql(u8, req.method, "GET") and !std.mem.eql(u8, req.method, "HEAD")) {
            return ws.writeStatus(stream, 405, "Method Not Allowed", "method not allowed");
        }
        var rel_buf: [512]u8 = undefined;
        var rel = sanitizePath(req.path, &rel_buf) orelse return ws.writeStatus(stream, 404, "Not Found", "not found");
        var dir = std.fs.cwd().openDir(self.dist_dir, .{}) catch {
            return ws.writeStatus(stream, 503, "Service Unavailable", "dashboard is not built. Run: cd dashboard && bun install && bun run build");
        };
        defer dir.close();
        const data = dir.readFileAlloc(self.allocator, rel, 16 * 1024 * 1024) catch blk: {
            // SPA: 拡張子の無いパスは index.html にフォールバック
            if (std.fs.path.extension(rel).len != 0) return ws.writeStatus(stream, 404, "Not Found", "not found");
            rel = "index.html";
            break :blk dir.readFileAlloc(self.allocator, rel, 16 * 1024 * 1024) catch return ws.writeStatus(stream, 404, "Not Found", "not found");
        };
        defer self.allocator.free(data);
        var hbuf: [512]u8 = undefined;
        const h = try std.fmt.bufPrint(&hbuf, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nCache-Control: no-cache\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n", .{ contentType(rel), data.len });
        try stream.writeAll(h);
        if (std.mem.eql(u8, req.method, "GET")) try stream.writeAll(data);
    }

    // ------------------------------------------------------------------
    // WebSocket (Inspector)
    // ------------------------------------------------------------------

    fn isLoopback(addr: std.net.Address) bool {
        return switch (addr.any.family) {
            std.posix.AF.INET => (std.mem.bigToNative(u32, addr.in.sa.addr) >> 24) == 127,
            std.posix.AF.INET6 => std.mem.eql(u8, &addr.in6.sa.addr, &(([_]u8{0} ** 15) ++ [_]u8{1})),
            else => false,
        };
    }

    fn authorized(self: *DashboardNode, conn: std.net.Server.Connection, req: ws.Request) bool {
        const presented = req.token_header orelse req.queryParam("token");
        if (presented) |t| return ws.constantTimeEql(t, self.token);
        return self.opts.allow_loopback_without_token and isLoopback(conn.address);
    }

    fn handleWebSocket(self: *DashboardNode, conn: std.net.Server.Connection, req: ws.Request) void {
        if (!self.authorized(conn, req)) {
            ws.writeStatus(conn.stream, 401, "Unauthorized", "token required") catch {};
            conn.stream.close();
            self.emitSecurity("auth_failed", "dashboard websocket");
            return;
        }
        self.clients_mutex.lock();
        const full = self.clients.items.len >= self.opts.max_clients;
        self.clients_mutex.unlock();
        if (full) {
            ws.writeStatus(conn.stream, 503, "Service Unavailable", "too many clients") catch {};
            conn.stream.close();
            return;
        }
        ws.writeUpgrade(conn.stream, req.ws_key orelse "") catch {
            conn.stream.close();
            return;
        };
        ws.setSendTimeout(conn.stream, 250);

        const client = self.allocator.create(Client) catch {
            conn.stream.close();
            return;
        };
        client.* = .{ .stream = conn.stream };
        self.clients_mutex.lock();
        self.clients.append(self.allocator, client) catch {
            self.clients_mutex.unlock();
            conn.stream.close();
            self.allocator.destroy(client);
            return;
        };
        self.clients_mutex.unlock();
        log.info("Dashboard: Inspector connected from {f}", .{conn.address});

        // 接続直後に現在のトポロジと、保持されている状態 (OBS 接続・観測レベル・ノード状態など) を送る。
        // 後から開いた Inspector でも「今の状態」が正しく見えるようにするため。
        self.sendGraph(client);
        self.sendRetained(client);

        while (self.running.load(.acquire) and client.alive.load(.acquire)) {
            const frame = ws.readMessage(conn.stream, self.allocator, 64 * 1024) catch break;
            defer self.allocator.free(frame.payload);
            switch (frame.opcode) {
                .text => self.handleInspectorMessage(frame.payload),
                .ping => {
                    client.send_mutex.lock();
                    ws.writeFrame(conn.stream, .pong, frame.payload, false) catch {};
                    client.send_mutex.unlock();
                },
                .close => break,
                else => {},
            }
        }

        client.alive.store(false, .release);
        self.clients_mutex.lock();
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
        self.clients_mutex.unlock();
        // ブロードキャスト中でないことを send_mutex で確認してから閉じる
        client.send_mutex.lock();
        client.stream.close();
        client.send_mutex.unlock();
        self.allocator.destroy(client);
    }

    fn sendGraph(self: *DashboardNode, client: *Client) void {
        const g = self.bus.graph orelse return;
        const json = g.toJsonAlloc(self.allocator) catch return;
        defer self.allocator.free(json);
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        out.writer(self.allocator).print("{{\"topic\":\"core.system.graph.full\",\"payload\":{s},\"origin\":0,\"ts\":{d}}}", .{ json, std.time.milliTimestamp() }) catch return;
        client.send_mutex.lock();
        defer client.send_mutex.unlock();
        ws.writeFrame(client.stream, .text, out.items, false) catch client.alive.store(false, .release);
    }

    fn retainedFilter(topic: []const u8) bool {
        return std.mem.startsWith(u8, topic, "core.") and !std.mem.eql(u8, topic, "core.system.graph.full");
    }

    fn sendRetained(self: *DashboardNode, client: *Client) void {
        var list = self.bus.snapshotRetained(self.allocator, retainedFilter) catch return;
        defer {
            for (list.items) |e| {
                self.allocator.free(e.topic);
                self.allocator.free(e.payload);
            }
            list.deinit(self.allocator);
        }
        for (list.items) |e| {
            var out: std.ArrayListUnmanaged(u8) = .{};
            defer out.deinit(self.allocator);
            const w = out.writer(self.allocator);
            w.print("{{\"topic\":\"{s}\",\"origin\":0,\"ts\":{d},\"retained\":true,\"payload\":", .{ e.topic, std.time.milliTimestamp() }) catch continue;
            if (std.json.validate(self.allocator, e.payload) catch false) {
                w.writeAll(e.payload) catch continue;
            } else {
                w.print("{f}", .{std.json.fmt(e.payload, .{})}) catch continue;
            }
            w.writeAll("}") catch continue;
            client.send_mutex.lock();
            ws.writeFrame(client.stream, .text, out.items, false) catch client.alive.store(false, .release);
            client.send_mutex.unlock();
        }
    }

    pub fn canPublish(self: *const DashboardNode, topic: []const u8) bool {
        for (ALLOW_ALWAYS) |p| if (pattern.isMatch(p, topic)) return true;
        if (self.opts.simulator) {
            for (ALLOW_SIMULATOR) |p| if (pattern.isMatch(p, topic)) return true;
        }
        return false;
    }

    fn handleInspectorMessage(self: *DashboardNode, message: []const u8) void {
        const parsed = std.json.parseFromSlice(struct {
            topic: []const u8,
            payload: std.json.Value = .null,
        }, self.allocator, message, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const topic = parsed.value.topic;

        if (!pattern.validTopic(topic)) return;
        if (!self.canPublish(topic) or (topics.touchesReserved(topic) and !isAllowedSystem(topic))) {
            log.warn("Dashboard: publish to '{s}' denied (not in Inspector permissions)", .{topic});
            self.emitSecurity("acl_denied", topic);
            return;
        }
        self.rate_mutex.lock();
        const ok = self.rate.tryConsume(std.time.milliTimestamp());
        self.rate_mutex.unlock();
        if (!ok) return;

        if (std.mem.eql(u8, topic, "core.system.graph.request")) {
            const g = self.bus.graph orelse return;
            const json = g.toJsonAlloc(self.allocator) catch return;
            defer self.allocator.free(json);
            self.bus.publish("core.system.graph.full", json, .Transient, 0) catch {};
            return;
        }

        var payload_buf: std.ArrayListUnmanaged(u8) = .{};
        defer payload_buf.deinit(self.allocator);
        const payload: []const u8 = switch (parsed.value.payload) {
            .string => |s| s,
            else => blk: {
                payload_buf.writer(self.allocator).print("{f}", .{std.json.fmt(parsed.value.payload, .{})}) catch return;
                break :blk payload_buf.items;
            },
        };
        // 外部入力は種別ごとの既定 QoS (R11)。チャット (event) は保持しない
        self.bus.publish(topic, payload, topics.defaultQos(topic), self.node_id) catch |err| {
            log.warn("Dashboard: publish '{s}' failed: {any}", .{ topic, err });
        };
    }

    fn isAllowedSystem(topic: []const u8) bool {
        for (ALLOW_ALWAYS) |p| if (std.mem.eql(u8, p, topic)) return true;
        return false;
    }

    fn emitSecurity(self: *DashboardNode, kind: []const u8, detail: []const u8) void {
        var tbuf: [64]u8 = undefined;
        const t = std.fmt.bufPrint(&tbuf, "core.security.{s}", .{kind}) catch return;
        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{ .node_id = self.node_id, .name = "Inspector", .detail = detail }, .{})}) catch return;
        self.bus.publish(t, w.buffered(), .Transient, 0) catch {};
    }

    /// バスの全イベントを Inspector に配信する (observe セルの executor 上)
    fn onBusMessage(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *DashboardNode = @ptrCast(@alignCast(ctx orelse return));
        self.clients_mutex.lock();
        const n = self.clients.items.len;
        self.clients_mutex.unlock();
        if (n == 0) return;

        const level: event_bus.IntrospectionLevel = @enumFromInt(self.bus.introspection_level.load(.monotonic));
        const is_core = std.mem.startsWith(u8, msg.topic, "core.");
        // off: システムイベント (core.*) のみ。metadata: core 以外の payload はサイズだけ
        if (level == .off and !is_core) return;
        const show_payload = is_core or level == .contents;

        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        w.print("{{\"id\":{d},\"topic\":\"{s}\",\"origin\":{d},\"ts\":{d},\"qos\":{d},\"parent\":{d},\"hops\":{d},\"payload\":", .{ msg.id, msg.topic, msg.source_node_id, msg.timestamp, @intFromEnum(msg.qos), msg.parent_id, msg.hops }) catch return;
        if (!show_payload) {
            w.print("{{\"hidden\":true,\"size\":{d}}}", .{msg.payload.len}) catch return;
        } else if (std.json.validate(self.allocator, msg.payload) catch false) {
            w.writeAll(msg.payload) catch return;
        } else {
            // JSON でない payload は文字列として埋め込む (生で埋めると受信側の JSON が壊れる)
            w.print("{f}", .{std.json.fmt(msg.payload, .{})}) catch return;
        }
        w.writeAll("}") catch return;

        self.clients_mutex.lock();
        defer self.clients_mutex.unlock();
        for (self.clients.items) |c| {
            if (!c.alive.load(.acquire)) continue;
            c.send_mutex.lock();
            ws.writeFrame(c.stream, .text, out.items, false) catch {
                c.alive.store(false, .release);
                std.posix.shutdown(c.stream.handle, .both) catch {};
            };
            c.send_mutex.unlock();
        }
    }
};

test "sanitizePath rejects traversal" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("index.html", DashboardNode.sanitizePath("/", &buf).?);
    try std.testing.expectEqualStrings("assets/app.js", DashboardNode.sanitizePath("/assets/app.js", &buf).?);
    try std.testing.expect(DashboardNode.sanitizePath("/../etc/passwd", &buf) == null);
    try std.testing.expect(DashboardNode.sanitizePath("/a/../../x", &buf) == null);
    try std.testing.expect(DashboardNode.sanitizePath("/a%2e%2e/x", &buf) == null);
    try std.testing.expect(DashboardNode.sanitizePath("/a//b", &buf) == null);
}

test "Inspector publish permissions" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 8);
    defer bus.deinit();
    bus.verbose = false;
    var d = try DashboardNode.init(a, &bus, 10, .{ .token = "t", .port = 0 });
    defer d.deinit();
    try std.testing.expect(d.canPublish("ext.twitch.chat.message"));
    try std.testing.expect(d.canPublish("core.system.introspection"));
    try std.testing.expect(!d.canPublish("core.obs.request.SetSceneItemEnabled"));
    try std.testing.expect(!d.canPublish("core.node.fault"));
    d.opts.simulator = false;
    try std.testing.expect(!d.canPublish("ext.twitch.chat.message"));
}
