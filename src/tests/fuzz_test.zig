//! ファズテスト (D2): 外から入ってくるバイト列を解釈する部分を、壊れた入力で叩く。
//!
//! - `zig build test_all` では、種 (corpus) と、シード固定の乱数入力 (各数万件) を流す。CI で毎回回る。
//! - `zig build test --fuzz` で、std.testing.fuzz による本格的なカバレッジ誘導ファズになる。
//!
//! 確かめる性質: クラッシュしない (境界外アクセス・整数オーバーフロー・不正 enum で panic しない)、
//! リークしない (testing allocator)、宣言した上限を超えて確保しない、結果が性質を満たす。

const std = @import("std");
const ws = @import("../transport/ws_proto.zig");
const manifest = @import("../core/manifest.zig");
const pattern = @import("../core/pattern.zig");

/// 読み出し側だけのメモリ上の接続 (readMessage に渡す)
const SliceConn = struct {
    data: []const u8,
    pos: usize = 0,
    /// 1 回の read で返す最大バイト数 (分割到着を再現する)
    chunk: usize = 7,

    pub fn read(self: *SliceConn, buf: []u8) !usize {
        const n = @min(buf.len, self.chunk, self.data.len - self.pos);
        @memcpy(buf[0..n], self.data[self.pos..][0..n]);
        self.pos += n;
        return n;
    }
};

fn oneFrame(_: void, input: []const u8) anyerror!void {
    const max_len = 4096;
    var conn = SliceConn{ .data = input, .chunk = 1 + (if (input.len > 0) input[0] % 13 else 0) };
    const frame = ws.readMessage(&conn, std.testing.allocator, max_len) catch return;
    defer std.testing.allocator.free(frame.payload);
    try std.testing.expect(frame.payload.len <= max_len);
}

fn oneRequest(_: void, input: []const u8) anyerror!void {
    const req = ws.parseRequest(input) catch return;
    _ = req.queryParam("token");
}

fn oneManifest(_: void, input: []const u8) anyerror!void {
    const parsed = manifest.Manifest.parse(std.testing.allocator, input) catch return;
    defer parsed.deinit();
    // 受理された manifest は予約名前空間やワイルドカード全体への publish を含まない
    for (parsed.value.permissions.publish) |p| {
        try std.testing.expect(!std.mem.eql(u8, p, "#"));
        try std.testing.expect(!std.mem.startsWith(u8, p, "core.security."));
        try std.testing.expect(!std.mem.startsWith(u8, p, "core.node."));
    }
}

fn onePattern(_: void, input: []const u8) anyerror!void {
    const cut = if (input.len > 0) input[0] % (input.len + 1) else 0;
    const a = input[0..cut];
    const b = input[cut..];
    // 交差判定は対称
    try std.testing.expectEqual(pattern.intersect(a, b), pattern.intersect(b, a));
    // 具体トピックにマッチするパターンは、そのトピックと交差する
    if (pattern.validTopic(b) and pattern.validPattern(a) and pattern.isMatch(a, b)) {
        try std.testing.expect(pattern.intersect(a, b));
    }
    // 正しいパターンは自分自身と交差する
    if (pattern.validPattern(a)) try std.testing.expect(pattern.intersect(a, a));
}

/// シード固定の乱数入力。半分は種を少し壊したもの、半分は完全な乱数
fn randomRounds(comptime f: fn (void, []const u8) anyerror!void, seeds: []const []const u8, rounds: usize, seed: u64) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const r = prng.random();
    var buf: [512]u8 = undefined;
    for (seeds) |s| try f({}, s);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        var len: usize = undefined;
        if (i % 2 == 0 and seeds.len > 0) {
            const s = seeds[r.uintLessThan(usize, seeds.len)];
            len = @min(s.len, buf.len);
            @memcpy(buf[0..len], s[0..len]);
            var k: usize = 0;
            const flips = 1 + r.uintLessThan(usize, 4);
            while (k < flips and len > 0) : (k += 1) buf[r.uintLessThan(usize, len)] = r.int(u8);
            if (r.boolean() and len > 0) len = r.uintLessThan(usize, len + 1); // 途中で切る
        } else {
            len = r.uintLessThan(usize, buf.len);
            r.bytes(buf[0..len]);
        }
        try f({}, buf[0..len]);
    }
}

const frame_seeds = [_][]const u8{
    &.{ 0x81, 0x85, 1, 2, 3, 4, 'h' ^ 1, 'e' ^ 2, 'l' ^ 3, 'l' ^ 4, 'o' ^ 1 },
    &.{ 0x01, 0x02, 'a', 'b', 0x80, 0x02, 'c', 'd' },
    &.{ 0x01, 0x01, 'a', 0x89, 0x00, 0x80, 0x01, 'b' }, // 断片の途中に ping
    &.{ 0x81, 126, 0x00, 0x05, 'h', 'e', 'l', 'l', 'o' },
    &.{ 0x81, 127, 0x7f, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    &.{ 0x88, 0x02, 0x03, 0xe8 },
    &.{ 0x83, 0x00 }, // 未定義のオペコード
};
const request_seeds = [_][]const u8{
    "GET /ws?token=abc HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
    "GET / HTTP/1.1\r\n\r\n",
    "POST /a?b=c&d HTTP/1.0\r\nX: y\r\n\r\n",
};
const manifest_seeds = [_][]const u8{
    \\{"name":"kusa_node","version":"1","permissions":{"publish":["core.obs.request.*"],"subscribe":["ext.twitch.chat.message"],"data_access":["pii"]}}
    ,
    \\{"name":"x","version":"1","permissions":{"publish":["#"]}}
    ,
    \\{"name":"x","version":"1","permissions":{"publish":["core.node.fault"]},"limits":{"max_instructions":1},"restart":{"policy":"never"}}
    ,
    \\{"name":"x","version":"1","cell":"plugins.a","permissions":{},"config":{"a":[1,2,{"b":null}]}}
    ,
};
const pattern_seeds = [_][]const u8{ "\x05core.#core.obs.event.x", "\x03a.+a.b", "\x01#", "\x04a.*.cx.y.c", "\x00" };

test "fuzz: WebSocket frame parser" {
    try std.testing.fuzz({}, oneFrame, .{ .corpus = &frame_seeds });
    try randomRounds(oneFrame, &frame_seeds, 30_000, 0xF1);
}

test "fuzz: HTTP request head parser" {
    try std.testing.fuzz({}, oneRequest, .{ .corpus = &request_seeds });
    try randomRounds(oneRequest, &request_seeds, 30_000, 0xF2);
}

test "fuzz: manifest parser keeps its invariants" {
    try std.testing.fuzz({}, oneManifest, .{ .corpus = &manifest_seeds });
    try randomRounds(oneManifest, &manifest_seeds, 20_000, 0xF3);
}

test "fuzz: topic pattern intersection is symmetric and consistent with matching" {
    try std.testing.fuzz({}, onePattern, .{ .corpus = &pattern_seeds });
    try randomRounds(onePattern, &pattern_seeds, 50_000, 0xF4);
}
