//! トピック / パターン照合 (割り当て無し)。
//!
//! 区切りは `.`。ワイルドカード:
//!   `+`, `*` : ちょうど 1 階層
//!   `#`      : 0 個以上の階層 (末尾でなくてもよい)
//!
//! EventBus (パターン × 具体トピック)、Manifest (ACL)、SystemGraph (辺)、
//! blast radius 監査 (パターン × パターン) がすべてこのモジュールを使う。
//! 以前は graph.zig に末尾 `*` だけを見る簡易版が別にあり、ACL と可視化で
//! 判定がずれていた。判定器を一つにすることで「見えている辺 = 実際の配送」を保証する。

const std = @import("std");

pub const MAX_SEGMENTS = 32;
pub const MAX_TOPIC_LEN = 256;

fn split(s: []const u8, out: *[MAX_SEGMENTS][]const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |seg| {
        if (n >= MAX_SEGMENTS) return null;
        out[n] = seg;
        n += 1;
    }
    return n;
}

fn isSingle(seg: []const u8) bool {
    return std.mem.eql(u8, seg, "+") or std.mem.eql(u8, seg, "*");
}

fn isMulti(seg: []const u8) bool {
    return std.mem.eql(u8, seg, "#");
}

/// パターンにワイルドカードが含まれるか。
pub fn hasWildcard(p: []const u8) bool {
    return std.mem.indexOfAny(u8, p, "+*#") != null;
}

/// パターン × 具体トピック。
pub fn isMatch(pattern: []const u8, topic: []const u8) bool {
    var ps: [MAX_SEGMENTS][]const u8 = undefined;
    var ts: [MAX_SEGMENTS][]const u8 = undefined;
    const pn = split(pattern, &ps) orelse return false;
    const tn = split(topic, &ts) orelse return false;
    return matchSegs(ps[0..pn], ts[0..tn]);
}

fn matchSegs(p: []const []const u8, t: []const []const u8) bool {
    if (p.len == 0) return t.len == 0;
    if (isMulti(p[0])) {
        // `#` は 0 個以上の階層を吸収する
        var k: usize = 0;
        while (k <= t.len) : (k += 1) {
            if (matchSegs(p[1..], t[k..])) return true;
        }
        return false;
    }
    if (t.len == 0) return false;
    if (isSingle(p[0]) or std.mem.eql(u8, p[0], t[0])) return matchSegs(p[1..], t[1..]);
    return false;
}

/// パターン × パターン: 両方にマッチする具体トピックが存在するか (集合の交差が非空か)。
pub fn intersect(a: []const u8, b: []const u8) bool {
    var as: [MAX_SEGMENTS][]const u8 = undefined;
    var bs: [MAX_SEGMENTS][]const u8 = undefined;
    const an = split(a, &as) orelse return false;
    const bn = split(b, &bs) orelse return false;
    return interSegs(as[0..an], bs[0..bn]);
}

fn matchesEmpty(segs: []const []const u8) bool {
    for (segs) |s| if (!isMulti(s)) return false;
    return true;
}

fn interSegs(a: []const []const u8, b: []const []const u8) bool {
    if (a.len == 0) return matchesEmpty(b);
    if (b.len == 0) return matchesEmpty(a);
    if (isMulti(a[0])) return interSegs(a[1..], b) or interSegs(a, b[1..]);
    if (isMulti(b[0])) return interSegs(a, b[1..]) or interSegs(a[1..], b);
    const agree = isSingle(a[0]) or isSingle(b[0]) or std.mem.eql(u8, a[0], b[0]);
    if (!agree) return false;
    return interSegs(a[1..], b[1..]);
}

/// パターン `inner` の表すトピック集合が `outer` に完全に含まれるか (保守的判定)。
/// cell の bridge 制約に manifest の publish 宣言が収まっているかを判定するのに使う。
/// 判定不能なケースは false (= 収まっていない扱い) に倒す。
pub fn covers(outer: []const u8, inner: []const u8) bool {
    var os: [MAX_SEGMENTS][]const u8 = undefined;
    var is: [MAX_SEGMENTS][]const u8 = undefined;
    const on = split(outer, &os) orelse return false;
    const in_n = split(inner, &is) orelse return false;
    return coverSegs(os[0..on], is[0..in_n]);
}

fn coverSegs(o: []const []const u8, i: []const []const u8) bool {
    if (o.len == 0) return i.len == 0;
    if (isMulti(o[0])) {
        var k: usize = 0;
        while (k <= i.len) : (k += 1) {
            if (coverSegs(o[1..], i[k..])) return true;
        }
        return false;
    }
    if (i.len == 0) return false;
    if (isMulti(i[0])) return false; // inner の `#` を覆えるのは outer の `#` だけ
    if (isSingle(o[0])) return coverSegs(o[1..], i[1..]);
    if (isSingle(i[0])) return false;
    if (!std.mem.eql(u8, o[0], i[0])) return false;
    return coverSegs(o[1..], i[1..]);
}

fn validChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

/// publish 可能な具体トピックか (ワイルドカード不可)。
/// 文字種を制限するのは、トピック名が JSON / ログ / ファイル名に埋め込まれるため
/// (引用符や制御文字による注入を入口で断つ)。
pub fn validTopic(t: []const u8) bool {
    if (t.len == 0 or t.len > MAX_TOPIC_LEN) return false;
    var it = std.mem.splitScalar(u8, t, '.');
    var n: usize = 0;
    while (it.next()) |seg| {
        n += 1;
        if (n > MAX_SEGMENTS or seg.len == 0) return false;
        for (seg) |c| if (!validChar(c)) return false;
    }
    return true;
}

/// subscribe / 権限宣言に使えるパターンか。
pub fn validPattern(p: []const u8) bool {
    if (p.len == 0 or p.len > MAX_TOPIC_LEN) return false;
    var it = std.mem.splitScalar(u8, p, '.');
    var n: usize = 0;
    while (it.next()) |seg| {
        n += 1;
        if (n > MAX_SEGMENTS or seg.len == 0) return false;
        if (isSingle(seg) or isMulti(seg)) continue;
        for (seg) |c| if (!validChar(c)) return false;
    }
    return true;
}

test "isMatch: exact, single, multi" {
    const m = isMatch;
    try std.testing.expect(m("a.b.c", "a.b.c"));
    try std.testing.expect(!m("a.b.c", "a.b.d"));
    try std.testing.expect(m("a.+.c", "a.b.c"));
    try std.testing.expect(m("a.*.c", "a.b.c"));
    try std.testing.expect(!m("a.+", "a.b.c"));
    try std.testing.expect(m("a.#", "a.b"));
    try std.testing.expect(m("a.#", "a"));
    try std.testing.expect(m("#", "x.y.z"));
    try std.testing.expect(m("a.#.d", "a.b.c.d"));
    try std.testing.expect(!m("a.#.d", "a.b.c.e"));
    try std.testing.expect(m("a.b.+.d.#", "a.b.c.d"));
    try std.testing.expect(!m("a.b.+.d.#", "a.b.d.e"));
    try std.testing.expect(!m("a.b.c", ""));
    try std.testing.expect(!m("", "a.b.c"));
    try std.testing.expect(!m("a.b", "a.b.c"));
}

test "intersect: pattern x pattern" {
    try std.testing.expect(intersect("core.obs.request.*", "core.obs.request.SetSceneItemEnabled"));
    try std.testing.expect(intersect("ext.twitch.#", "ext.twitch.chat.message"));
    try std.testing.expect(!intersect("core.obs.request.*", "ext.twitch.chat.message"));
    try std.testing.expect(intersect("core.+.request.*", "core.obs.+.SetX"));
    try std.testing.expect(!intersect("core.obs.#", "ext.twitch.#"));
    try std.testing.expect(intersect("#", "core.node.fault"));
    try std.testing.expect(intersect("a.#", "a"));
}

test "covers: bridge containment" {
    try std.testing.expect(covers("ext.#", "ext.chat.spam"));
    try std.testing.expect(covers("ext.#", "ext.twitch.#"));
    try std.testing.expect(covers("core.obs.request.*", "core.obs.request.SetSceneItemEnabled"));
    try std.testing.expect(!covers("core.obs.request.SetSceneItemEnabled", "core.obs.request.*"));
    try std.testing.expect(!covers("ext.#", "core.obs.request.SetSceneItemEnabled"));
    try std.testing.expect(!covers("ext.+", "ext.#"));
    try std.testing.expect(covers("#", "anything.#"));
}

test "validTopic / validPattern" {
    try std.testing.expect(validTopic("ext.twitch.chat.message"));
    try std.testing.expect(!validTopic("ext.twitch.#"));
    try std.testing.expect(!validTopic("a..b"));
    try std.testing.expect(!validTopic("a.\"b"));
    try std.testing.expect(!validTopic(""));
    try std.testing.expect(validPattern("ext.twitch.#"));
    try std.testing.expect(validPattern("#"));
    try std.testing.expect(!validPattern("ext.\"x"));
}
