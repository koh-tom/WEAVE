//! 最小の HTTP/1.1 + WebSocket (RFC 6455) 実装。サーバ側・クライアント側の両方で使う。
//! クライアント側の関数は `read(buf) !usize` と `writeAll(bytes) !void` を持つ任意の接続
//! (std.net.Stream / TLS の `TlsConn`) を受け取る。
//!
//! 以前は ws_gateway / node_ws / obs の 3 か所に似た実装が散らばり、それぞれ
//! - ハンドシェイクを read 1 回で読み切れる前提 (分割到着で失敗)
//! - フレーム長を無制限に信じる (8 バイト長で巨大確保 = DoS, P1-4)
//! - クライアントの WebSocket キーやマスクが固定値
//! という穴を持っていた。ここに一本化する。

const std = @import("std");

pub const MAX_HEADER_BYTES = 8192;
pub const DEFAULT_MAX_FRAME = 1024 * 1024;
const MAGIC = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

pub const Opcode = enum(u4) {
    continuation = 0x0,
    text = 0x1,
    binary = 0x2,
    close = 0x8,
    ping = 0x9,
    pong = 0xA,
    _,
};

pub const Frame = struct {
    opcode: Opcode,
    payload: []u8,
};

pub const Request = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8,
    ws_key: ?[]const u8 = null,
    token_header: ?[]const u8 = null,
    upgrade_websocket: bool = false,
    /// 元のヘッダバッファ (上のスライスはここを指す)
    raw: []const u8,

    /// クエリ文字列から値を取り出す (URL デコードはしない。トークンは英数字想定)
    pub fn queryParam(self: Request, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, self.query, '&');
        while (it.next()) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (std.mem.eql(u8, kv[0..eq], name)) return kv[eq + 1 ..];
        }
        return null;
    }
};

fn readSome(conn: anytype, buf: []u8) !usize {
    const n = try conn.read(buf);
    if (n == 0) return error.EndOfStream;
    return n;
}

fn readExact(conn: anytype, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) total += try readSome(conn, buf[total..]);
}

/// ヘッダ終端 (\r\n\r\n) まで読む。返り値は buf の中のヘッダ部分。
pub fn readHead(conn: anytype, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        if (len >= buf.len) return error.HeaderTooLarge;
        len += try readSome(conn, buf[len..]);
        if (std.mem.indexOf(u8, buf[0..len], "\r\n\r\n")) |end| return buf[0 .. end + 4];
    }
}

/// ヘッダ終端 (\r\n\r\n) まで 1 バイトずつ読み、終端より先は読まない。
/// クライアント側で使う。サーバー (OBS・Astro など) は 101 の直後に最初のフレームを送ってくるので、
/// readHead のようにまとめて読むと同じ read に入ったフレームの先頭を捨ててしまう。
pub fn readHeadExact(conn: anytype, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        if (len >= buf.len) return error.HeaderTooLarge;
        _ = try readSome(conn, buf[len .. len + 1]);
        len += 1;
        if (len >= 4 and std.mem.eql(u8, buf[len - 4 .. len], "\r\n\r\n")) return buf[0..len];
    }
}

fn headerValue(line: []const u8, name: []const u8) ?[]const u8 {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return null;
    if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return null;
    return std.mem.trim(u8, line[colon + 1 ..], " \t");
}

/// HTTP リクエストのヘッダ部分を解釈する。
pub fn parseRequest(head: []const u8) !Request {
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    const first = lines.next() orelse return error.BadRequest;
    var parts = std.mem.splitScalar(u8, first, ' ');
    const method = parts.next() orelse return error.BadRequest;
    const target = parts.next() orelse return error.BadRequest;
    const version = parts.next() orelse return error.BadRequest;
    if (!std.mem.startsWith(u8, version, "HTTP/1.")) return error.BadRequest;
    const qpos = std.mem.indexOfScalar(u8, target, '?');
    var req = Request{
        .method = method,
        .path = if (qpos) |q| target[0..q] else target,
        .query = if (qpos) |q| target[q + 1 ..] else "",
        .raw = head,
    };
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (headerValue(line, "Sec-WebSocket-Key")) |v| req.ws_key = v;
        if (headerValue(line, "X-WEAVE-Token")) |v| req.token_header = v;
        if (headerValue(line, "Upgrade")) |v| {
            if (std.ascii.eqlIgnoreCase(v, "websocket")) req.upgrade_websocket = true;
        }
    }
    return req;
}

/// Sec-WebSocket-Accept の値を計算する
pub fn acceptKey(key: []const u8, out: *[28]u8) []const u8 {
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(key);
    h.update(MAGIC);
    var digest: [20]u8 = undefined;
    h.final(&digest);
    return std.base64.standard.Encoder.encode(out, &digest);
}

/// サーバ側: 101 Switching Protocols を返す
pub fn writeUpgrade(stream: std.net.Stream, key: []const u8) !void {
    if (key.len == 0 or key.len > 64) return error.BadWebSocketKey;
    var acc: [28]u8 = undefined;
    const accept = acceptKey(key, &acc);
    var buf: [256]u8 = undefined;
    const resp = try std.fmt.bufPrint(&buf, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n\r\n", .{accept});
    try stream.writeAll(resp);
}

pub fn writeStatus(stream: std.net.Stream, code: u16, reason: []const u8, body: []const u8) !void {
    var buf: [256]u8 = undefined;
    const head = try std.fmt.bufPrint(&buf, "HTTP/1.1 {d} {s}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ code, reason, body.len });
    try stream.writeAll(head);
    try stream.writeAll(body);
}

/// クライアント側のハンドシェイク。ランダムなキーを送り、応答の Accept を検証する。
pub fn clientHandshake(conn: anytype, host: []const u8, port: u16, path: []const u8, extra_headers: []const u8) !void {
    var raw_key: [16]u8 = undefined;
    std.crypto.random.bytes(&raw_key);
    var key_buf: [24]u8 = undefined;
    const key = std.base64.standard.Encoder.encode(&key_buf, &raw_key);
    var req_buf: [1024]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n{s}\r\n", .{ path, host, port, key, extra_headers });
    try conn.writeAll(req);

    var head_buf: [MAX_HEADER_BYTES]u8 = undefined;
    const head = try readHeadExact(conn, &head_buf);
    if (std.mem.indexOf(u8, head, " 101 ") == null) return error.HandshakeRejected;
    var expected_buf: [28]u8 = undefined;
    const expected = acceptKey(key, &expected_buf);
    var lines = std.mem.splitSequence(u8, head, "\r\n");
    while (lines.next()) |line| {
        if (headerValue(line, "Sec-WebSocket-Accept")) |v| {
            if (std.mem.eql(u8, v, expected)) return;
            return error.BadAcceptKey;
        }
    }
    return error.BadAcceptKey;
}

/// フレームを 1 つ読む。断片化 (continuation) は結合して 1 メッセージとして返す。
/// max_len を超える長さは読む前に拒否する。
pub fn readMessage(conn: anytype, allocator: std.mem.Allocator, max_len: usize) !Frame {
    var out: std.ArrayListUnmanaged(u8) = .{};
    errdefer out.deinit(allocator);
    var first_opcode: ?Opcode = null;
    while (true) {
        var head: [2]u8 = undefined;
        try readExact(conn, &head);
        const fin = (head[0] & 0x80) != 0;
        const opcode: Opcode = @enumFromInt(head[0] & 0x0F);
        const masked = (head[1] & 0x80) != 0;
        var len: u64 = head[1] & 0x7F;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try readExact(conn, &ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try readExact(conn, &ext);
            len = std.mem.readInt(u64, &ext, .big);
        }
        if (len > max_len or out.items.len + len > max_len) return error.FrameTooLarge;
        var mask: [4]u8 = .{ 0, 0, 0, 0 };
        if (masked) try readExact(conn, &mask);

        const start = out.items.len;
        try out.resize(allocator, start + @as(usize, @intCast(len)));
        try readExact(conn, out.items[start..]);
        if (masked) {
            for (out.items[start..], 0..) |*b, i| b.* ^= mask[i % 4];
        }

        // 制御フレームは断片の途中にも来うる。単独で返す。
        switch (opcode) {
            .close, .ping, .pong => {
                if (first_opcode == null) {
                    return .{ .opcode = opcode, .payload = try out.toOwnedSlice(allocator) };
                }
                // 断片の途中の制御フレームは内容を捨てて続行 (ping への応答は呼び出し側で行わない)
                out.shrinkRetainingCapacity(start);
                continue;
            },
            else => {},
        }
        if (first_opcode == null) {
            if (opcode == .continuation) return error.UnexpectedContinuation;
            first_opcode = opcode;
        } else if (opcode != .continuation) return error.ExpectedContinuation;
        if (fin) return .{ .opcode = first_opcode.?, .payload = try out.toOwnedSlice(allocator) };
    }
}

/// フレームを書く。client=true ならランダムなマスクを付ける (RFC 6455 §5.3)。
pub fn writeFrame(conn: anytype, opcode: Opcode, data: []const u8, client: bool) !void {
    var head: [14]u8 = undefined;
    head[0] = 0x80 | @as(u8, @intFromEnum(opcode));
    var hl: usize = 2;
    const mask_bit: u8 = if (client) 0x80 else 0;
    if (data.len <= 125) {
        head[1] = @as(u8, @intCast(data.len)) | mask_bit;
    } else if (data.len <= 65535) {
        head[1] = 126 | mask_bit;
        std.mem.writeInt(u16, head[2..4], @intCast(data.len), .big);
        hl = 4;
    } else {
        head[1] = 127 | mask_bit;
        std.mem.writeInt(u64, head[2..10], data.len, .big);
        hl = 10;
    }
    if (!client) {
        try conn.writeAll(head[0..hl]);
        try conn.writeAll(data);
        return;
    }
    var mask: [4]u8 = undefined;
    std.crypto.random.bytes(&mask);
    @memcpy(head[hl .. hl + 4], &mask);
    hl += 4;
    try conn.writeAll(head[0..hl]);
    var chunk: [4096]u8 = undefined;
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(chunk.len, data.len - off);
        for (0..n) |i| chunk[i] = data[off + i] ^ mask[(off + i) % 4];
        try conn.writeAll(chunk[0..n]);
        off += n;
    }
}

/// 送信のタイムアウトを設定する (遅いクライアントでスレッドが永久に止まらないように)
pub fn setSendTimeout(stream: std.net.Stream, ms: u32) void {
    const tv = std.posix.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    std.posix.setsockopt(stream.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
}

/// 読めるデータが来るまで最大 timeout_ms 待つ。true = 読める (データまたは切断), false = 時間切れ。
/// 読み取りを待ちながら定期的に送信したい (Engine.IO の ping など) 1 スレッドのクライアント用。
pub fn waitReadable(conn: anytype, timeout_ms: i32) !bool {
    const T = @TypeOf(conn);
    const fd = if (T == *TlsConn) blk: {
        if (conn.hasBuffered()) return true;
        break :blk conn.stream.handle;
    } else conn.handle;
    var fds = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return (try std.posix.poll(&fds, timeout_ms)) > 0;
}

/// 定数時間の比較 (トークン検証用)
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

/// TLS (wss://) 接続。証明書はシステムの CA バンドルで検証し、ホスト名も検証する。
pub const TlsConn = struct {
    stream: std.net.Stream,
    sr: std.net.Stream.Reader,
    sw: std.net.Stream.Writer,
    client: std.crypto.tls.Client,
    in_buf: [std.crypto.tls.Client.min_buffer_len]u8,
    out_buf: [std.crypto.tls.Client.min_buffer_len]u8,
    tls_read: [std.crypto.tls.Client.min_buffer_len]u8,
    tls_write: [std.crypto.tls.Client.min_buffer_len]u8,
    bundle: std.crypto.Certificate.Bundle,

    /// 接続して TLS ハンドシェイクを行う。self は固定アドレスに置くこと (内部バッファを指すため)
    pub fn connect(self: *TlsConn, allocator: std.mem.Allocator, host: []const u8, port: u16) !void {
        self.bundle = .{};
        errdefer self.bundle.deinit(allocator);
        try self.bundle.rescan(allocator);
        self.stream = try std.net.tcpConnectToHost(allocator, host, port);
        errdefer self.stream.close();
        self.sr = self.stream.reader(&self.in_buf);
        self.sw = self.stream.writer(&self.out_buf);
        self.client = std.crypto.tls.Client.init(self.sr.interface(), &self.sw.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = self.bundle },
            .read_buffer = &self.tls_read,
            .write_buffer = &self.tls_write,
        }) catch return error.TlsHandshakeFailed;
    }

    /// 0 は接続の終わりを意味する。
    /// (std.Io.Reader.readVec は復号したレコードを内部バッファに入れただけで 0 を返すことがあり、
    ///  0 = EOF の約束を満たさない。fill(1) で 1 バイト以上溜まるまで待ってから取り出す)
    pub fn read(self: *TlsConn, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        const r = &self.client.reader;
        if (r.bufferedLen() == 0) {
            r.fill(1) catch |err| switch (err) {
                error.EndOfStream => return 0,
                else => return error.ReadFailed,
            };
        }
        const avail = r.buffered();
        const n = @min(buf.len, avail.len);
        @memcpy(buf[0..n], avail[0..n]);
        r.toss(n);
        return n;
    }

    /// 復号済み・受信済みのデータが手元にあるか (poll する前に確かめる。あれば read は待たずに進む)
    pub fn hasBuffered(self: *TlsConn) bool {
        return self.client.reader.bufferedLen() > 0 or self.sr.interface().bufferedLen() > 0;
    }

    pub fn writeAll(self: *TlsConn, bytes: []const u8) !void {
        self.client.writer.writeAll(bytes) catch return error.WriteFailed;
        self.client.writer.flush() catch return error.WriteFailed;
        self.sw.interface.flush() catch return error.WriteFailed;
    }

    pub fn close(self: *TlsConn, allocator: std.mem.Allocator) void {
        self.client.end() catch {};
        self.sw.interface.flush() catch {};
        self.stream.close();
        self.bundle.deinit(allocator);
    }
};

fn socketPair() ![2]std.net.Stream {
    var fds: [2]i32 = undefined;
    const rc = std.os.linux.socketpair(std.os.linux.AF.UNIX, std.os.linux.SOCK.STREAM, 0, &fds);
    if (rc != 0) return error.SocketPairFailed;
    return .{ .{ .handle = fds[0] }, .{ .handle = fds[1] } };
}

test "readHeadExact leaves the first frame after 101 unread" {
    const pair = try socketPair();
    defer pair[0].close();
    defer pair[1].close();
    // 101 と最初のフレーム (welcome) が 1 回の write で届く
    var msg: [256]u8 = undefined;
    const head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n";
    @memcpy(msg[0..head.len], head);
    const body = "{\"type\":\"welcome\"}";
    msg[head.len] = 0x81;
    msg[head.len + 1] = body.len;
    @memcpy(msg[head.len + 2 ..][0..body.len], body);
    try pair[1].writeAll(msg[0 .. head.len + 2 + body.len]);

    var buf: [MAX_HEADER_BYTES]u8 = undefined;
    try std.testing.expectEqualStrings(head, try readHeadExact(pair[0], &buf));
    const f = try readMessage(pair[0], std.testing.allocator, 1024);
    defer std.testing.allocator.free(f.payload);
    try std.testing.expectEqual(Opcode.text, f.opcode);
    try std.testing.expectEqualStrings(body, f.payload);
}

test "accept key matches RFC 6455 example" {
    var out: [28]u8 = undefined;
    try std.testing.expectEqualStrings("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", acceptKey("dGhlIHNhbXBsZSBub25jZQ==", &out));
}

test "parseRequest: path, query, headers" {
    const head = "GET /ws?token=abc&x=1 HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: k==\r\nX-WEAVE-Token: t1\r\n\r\n";
    const r = try parseRequest(head);
    try std.testing.expectEqualStrings("/ws", r.path);
    try std.testing.expectEqualStrings("abc", r.queryParam("token").?);
    try std.testing.expectEqualStrings("k==", r.ws_key.?);
    try std.testing.expectEqualStrings("t1", r.token_header.?);
    try std.testing.expect(r.upgrade_websocket);
}

test "frames: masked client -> server roundtrip, fragmentation, size limit" {
    const a = std.testing.allocator;
    const pair = try socketPair();
    defer pair[0].close();
    defer pair[1].close();

    try writeFrame(pair[0], .text, "hello weave", true);
    const f = try readMessage(pair[1], a, 1024);
    defer a.free(f.payload);
    try std.testing.expectEqual(Opcode.text, f.opcode);
    try std.testing.expectEqualStrings("hello weave", f.payload);

    // 断片化: "ab" (FIN=0) + "cd" (continuation, FIN=1)
    try pair[0].writeAll(&[_]u8{ 0x01, 0x02, 'a', 'b', 0x80, 0x02, 'c', 'd' });
    const g = try readMessage(pair[1], a, 1024);
    defer a.free(g.payload);
    try std.testing.expectEqualStrings("abcd", g.payload);

    // 8 バイト長で巨大サイズを宣言 → 本体を読む前に拒否
    try pair[0].writeAll(&[_]u8{ 0x81, 127, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff });
    try std.testing.expectError(error.FrameTooLarge, readMessage(pair[1], a, 1024));
}

test "readHead handles headers split across reads" {
    const pair = try socketPair();
    defer pair[0].close();
    defer pair[1].close();
    try pair[0].writeAll("GET / HTTP/1.1\r\nHo");
    const t = try std.Thread.spawn(.{}, struct {
        fn run(s: std.net.Stream) void {
            std.Thread.sleep(20 * std.time.ns_per_ms);
            s.writeAll("st: x\r\n\r\n") catch {};
        }
    }.run, .{pair[0]});
    defer t.join();
    var buf: [256]u8 = undefined;
    const head = try readHead(pair[1], &buf);
    try std.testing.expect(std.mem.endsWith(u8, head, "\r\n\r\n"));
}

test "constant time compare" {
    try std.testing.expect(constantTimeEql("abc", "abc"));
    try std.testing.expect(!constantTimeEql("abc", "abd"));
    try std.testing.expect(!constantTimeEql("abc", "ab"));
}
