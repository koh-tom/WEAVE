//! Blast Radius 監査エンジン
//!
//! WEAVE のセキュリティ核 (ADR-008): 「侵害を前提とし、プラグインの影響範囲を
//! 実行前に計算・提示し、実行時にその範囲へ閉じ込める」の "事前計算" 部分。
//!
//! 全ノードの manifest (宣言) だけから、あるノードが侵害された場合に
//! 「何を読めるか / 何を書けるか / どの実世界シンクに到達しうるか」を
//! 起動前に機械的に計算する。対象がコード実体ではなく宣言なので、
//! 難読化に影響されず健全 (sound) に計算できる。

const std = @import("std");

// ============================================================
// トピックパターンの交差判定 (patterns × patterns)
// ------------------------------------------------------------
// 既存の EventBus.isMatch は「パターン × 具体トピック」だが、
// blast 計算には「パターン P と パターン S がともにマッチする具体トピックが
// 存在するか (= 集合の交差が非空か)」が必要になる。
// セグメント (`.` 区切り) 単位の再帰で判定する。
//   +, *  : ちょうど 1 階層にマッチ
//   #     : 0 個以上の階層にマッチ (末尾でなくてもよい)
// ============================================================

/// パターン segs が「空トピック (階層 0 個)」にマッチしうるか。
/// 先頭から `#` が続く限り 0 階層として消費できる。
fn matchesEmpty(segs: []const []const u8) bool {
    if (segs.len == 0) return true;
    if (std.mem.eql(u8, segs[0], "#")) return matchesEmpty(segs[1..]);
    return false;
}

fn isWildcardSingle(seg: []const u8) bool {
    return std.mem.eql(u8, seg, "+") or std.mem.eql(u8, seg, "*");
}

/// 2 つのパターン (セグメント列) が共通の具体トピックを持つか。
fn interSegs(a: []const []const u8, b: []const []const u8) bool {
    if (a.len == 0) return matchesEmpty(b);
    if (b.len == 0) return matchesEmpty(a);

    const ha = a[0];
    const hb = b[0];

    // `#` は 0 個以上の階層を吸収する。どちら側にあっても両分岐を試す。
    if (std.mem.eql(u8, ha, "#")) {
        // 0 階層消費 (a[1..] へ) or 1 階層消費 (b の先頭 1 階層を任意の具体値とみなす)
        return interSegs(a[1..], b) or interSegs(a, b[1..]);
    }
    if (std.mem.eql(u8, hb, "#")) {
        return interSegs(a, b[1..]) or interSegs(a[1..], b);
    }

    // どちらも単一階層。共通の具体値を取れるのは、
    // いずれかがワイルドカード、または両者が同一リテラルのとき。
    const agree = isWildcardSingle(ha) or isWildcardSingle(hb) or std.mem.eql(u8, ha, hb);
    if (!agree) return false;
    return interSegs(a[1..], b[1..]);
}

/// パターン a と b の表すトピック集合が交差するか。
pub fn patternsIntersect(allocator: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    var a_list = std.ArrayListUnmanaged([]const u8){};
    defer a_list.deinit(allocator);
    var b_list = std.ArrayListUnmanaged([]const u8){};
    defer b_list.deinit(allocator);

    var a_it = std.mem.splitScalar(u8, a, '.');
    while (a_it.next()) |seg| a_list.append(allocator, seg) catch return false;
    var b_it = std.mem.splitScalar(u8, b, '.');
    while (b_it.next()) |seg| b_list.append(allocator, seg) catch return false;

    return interSegs(a_list.items, b_list.items);
}

// ============================================================
// トピック重要度クラス
// ------------------------------------------------------------
// 影響範囲を「単なるトピック名の羅列」ではなく人間が判断できる
// 帰結に翻訳するための分類。プレフィックスで機械的に判定する。
// ============================================================

pub const Importance = enum {
    control, // 実世界を操作する (OBS シーン操作等)
    pii, // 個人情報を含みうる (チャット本文・ユーザ名等)
    system, // WEAVE 内部の制御・ライフサイクル
    telemetry, // 観測・メトリクス
    data, // その他

    pub fn label(self: Importance) []const u8 {
        return switch (self) {
            .control => "CONTROL (実世界を操作)",
            .pii => "PII (個人情報を含みうる)",
            .system => "SYSTEM (内部制御)",
            .telemetry => "TELEMETRY (観測)",
            .data => "DATA",
        };
    }
};

pub fn classify(topic_pattern: []const u8) Importance {
    if (std.mem.startsWith(u8, topic_pattern, "core.obs.request")) return .control;
    if (std.mem.startsWith(u8, topic_pattern, "ext.twitch.chat")) return .pii;
    if (std.mem.startsWith(u8, topic_pattern, "core.obs.event")) return .telemetry;
    if (std.mem.startsWith(u8, topic_pattern, "core.node.metrics")) return .telemetry;
    if (std.mem.startsWith(u8, topic_pattern, "core.")) return .system;
    return .data;
}

// ============================================================
// ノードモデル
// ============================================================

pub const Node = struct {
    name: []const u8,
    kind: []const u8, // "wasm" | "native" | "remote"
    /// このノードが実世界に副作用を及ぼすシンクか (OBS 等)。侵害時の到達先として重要。
    is_sink: bool = false,
    sink_desc: []const u8 = "",
    pub_patterns: [][]const u8,
    sub_patterns: [][]const u8,
};

/// builtin (ネイティブ) ノードの宣言。コード内の固定 pub/sub を宣言として持つ。
/// (将来は各ノードに宣言を持たせて自動収集するが、まずは監査エンジン側で保持)
pub fn builtinNodes(allocator: std.mem.Allocator) ![]Node {
    var list = std.ArrayListUnmanaged(Node){};

    const twitch_pub = try allocator.dupe([]const u8, &.{"ext.twitch.chat.message"});
    try list.append(allocator, .{
        .name = "TwitchAdapter",
        .kind = "native",
        .pub_patterns = twitch_pub,
        .sub_patterns = try allocator.dupe([]const u8, &.{}),
    });

    const obs_sub = try allocator.dupe([]const u8, &.{"core.obs.request.*"});
    const obs_pub = try allocator.dupe([]const u8, &.{"core.obs.event.*"});
    try list.append(allocator, .{
        .name = "ObsEgress",
        .kind = "native",
        .is_sink = true,
        .sink_desc = "OBS を操作 (シーン切替・ソース表示など配信画面に作用)",
        .pub_patterns = obs_pub,
        .sub_patterns = obs_sub,
    });

    return list.toOwnedSlice(allocator);
}

// ============================================================
// manifest からのノード読み込み
// ============================================================

const ManifestShape = struct {
    name: []const u8,
    version: []const u8 = "",
    permissions: struct {
        publish: [][]const u8 = &.{},
        subscribe: [][]const u8 = &.{},
    },
};

/// manifest JSON ファイルを読み込み Node を返す。呼び出し側が arena で管理する前提。
pub fn loadManifestNode(arena: std.mem.Allocator, path: []const u8) !Node {
    const content = try std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024);
    const parsed = try std.json.parseFromSliceLeaky(ManifestShape, arena, content, .{
        .ignore_unknown_fields = true,
    });
    return Node{
        .name = parsed.name,
        .kind = "wasm",
        .pub_patterns = parsed.permissions.publish,
        .sub_patterns = parsed.permissions.subscribe,
    };
}

// ============================================================
// Blast Radius 計算
// ============================================================

pub const Reach = struct {
    node_name: []const u8,
    via_topic: []const u8, // 到達に使った (侵害ノードの) publish パターン
};

pub const BlastReport = struct {
    target: []const u8,
    /// 侵害ノードが読めるトピック (source ノード名, publish パターン)
    readable: []ReadEntry,
    /// 侵害ノードが直接書けるトピックパターン
    writable: [][]const u8,
    /// publish を辿って到達しうるシンクノード
    reachable_sinks: []Reach,

    pub const ReadEntry = struct {
        source: []const u8,
        topic: []const u8,
    };
};

/// target ノードが侵害された場合の影響範囲を計算する。
pub fn computeBlast(arena: std.mem.Allocator, nodes: []const Node, target_name: []const u8) !BlastReport {
    const target = blk: {
        for (nodes) |n| {
            if (std.mem.eql(u8, n.name, target_name)) break :blk n;
        }
        return error.NodeNotFound;
    };

    // --- readable: 他ノードの publish のうち target の subscribe と交差するもの ---
    var readable = std.ArrayListUnmanaged(BlastReport.ReadEntry){};
    for (nodes) |src| {
        if (std.mem.eql(u8, src.name, target_name)) continue;
        for (src.pub_patterns) |pp| {
            for (target.sub_patterns) |sp| {
                if (patternsIntersect(arena, pp, sp)) {
                    try readable.append(arena, .{ .source = src.name, .topic = pp });
                    break;
                }
            }
        }
    }

    // --- writable: target の publish ---
    const writable = try arena.dupe([]const u8, target.pub_patterns);

    // --- reachable sinks: publish → subscribe を辿る BFS ---
    var reached = std.StringHashMapUnmanaged(void){};
    var via = std.StringHashMapUnmanaged([]const u8){};
    var frontier = std.ArrayListUnmanaged([]const u8){};
    try frontier.append(arena, target_name);
    try reached.put(arena, target_name, {});

    while (frontier.items.len > 0) {
        const cur_name = frontier.pop().?;
        const cur = findNode(nodes, cur_name) orelse continue;
        for (cur.pub_patterns) |pp| {
            for (nodes) |dst| {
                if (reached.contains(dst.name)) continue;
                var edge = false;
                for (dst.sub_patterns) |sp| {
                    if (patternsIntersect(arena, pp, sp)) {
                        edge = true;
                        break;
                    }
                }
                if (edge) {
                    try reached.put(arena, dst.name, {});
                    // via には「侵害ノード自身が最初に投げた publish」を記録すると分かりやすいが、
                    // 簡潔さのため直近ホップの topic を記録する
                    try via.put(arena, dst.name, pp);
                    try frontier.append(arena, dst.name);
                }
            }
        }
    }

    var sinks = std.ArrayListUnmanaged(Reach){};
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, target_name)) continue;
        if (!n.is_sink) continue;
        if (reached.contains(n.name)) {
            const v = via.get(n.name) orelse "";
            try sinks.append(arena, .{ .node_name = n.name, .via_topic = v });
        }
    }

    return BlastReport{
        .target = target_name,
        .readable = try readable.toOwnedSlice(arena),
        .writable = writable,
        .reachable_sinks = try sinks.toOwnedSlice(arena),
    };
}

fn findNode(nodes: []const Node, name: []const u8) ?Node {
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, name)) return n;
    }
    return null;
}

// ============================================================
// レポート出力
// ============================================================

pub fn printReport(writer: anytype, report: BlastReport) !void {
    try writer.print("\n=== Blast Radius: {s} ===\n", .{report.target});
    try writer.print("(このノードが完全に乗っ取られた場合に攻撃者ができることの上限)\n\n", .{});

    try writer.print("[読める / 傍受できる]\n", .{});
    if (report.readable.len == 0) {
        try writer.print("  (なし)\n", .{});
    } else {
        for (report.readable) |r| {
            const cls = classify(r.topic);
            try writer.print("  - {s}  <- {s}  [{s}]\n", .{ r.topic, r.source, cls.label() });
        }
    }

    try writer.print("\n[書ける / 発行できる]\n", .{});
    if (report.writable.len == 0) {
        try writer.print("  (なし)\n", .{});
    } else {
        for (report.writable) |w| {
            const cls = classify(w);
            try writer.print("  - {s}  [{s}]\n", .{ w, cls.label() });
        }
    }

    try writer.print("\n[到達しうる実世界シンク]\n", .{});
    if (report.reachable_sinks.len == 0) {
        try writer.print("  (なし — 外界への副作用に到達できない)\n", .{});
    } else {
        for (report.reachable_sinks) |s| {
            try writer.print("  - {s}  (経路: {s} → ...)\n", .{ s.node_name, s.via_topic });
        }
    }
    try writer.print("\n", .{});
}

// ============================================================
// Tests
// ============================================================

test "patternsIntersect: exact and single-level" {
    const a = std.testing.allocator;
    try std.testing.expect(patternsIntersect(a, "a.b.c", "a.b.c"));
    try std.testing.expect(!patternsIntersect(a, "a.b.c", "a.b.d"));
    try std.testing.expect(patternsIntersect(a, "a.+.c", "a.b.c"));
    try std.testing.expect(patternsIntersect(a, "a.b.c", "a.*.c"));
    try std.testing.expect(!patternsIntersect(a, "a.+", "a.b.c"));
}

test "patternsIntersect: multi-level hash" {
    const a = std.testing.allocator;
    try std.testing.expect(patternsIntersect(a, "a.#", "a.b"));
    try std.testing.expect(patternsIntersect(a, "a.#", "a.b.c.d"));
    try std.testing.expect(patternsIntersect(a, "#", "anything.here"));
    // # は 0 階層も許容
    try std.testing.expect(patternsIntersect(a, "a.#", "a"));
}

test "patternsIntersect: pattern vs pattern (both wildcard)" {
    const a = std.testing.allocator;
    // core.obs.request.* と core.obs.request.SetSceneItemEnabled は交差する
    try std.testing.expect(patternsIntersect(a, "core.obs.request.*", "core.obs.request.SetSceneItemEnabled"));
    // ext.twitch.# と ext.twitch.chat.message は交差する
    try std.testing.expect(patternsIntersect(a, "ext.twitch.#", "ext.twitch.chat.message"));
    // 別サブツリーは交差しない
    try std.testing.expect(!patternsIntersect(a, "core.obs.request.*", "ext.twitch.chat.message"));
    // 両方ワイルドカードで前半一致
    try std.testing.expect(patternsIntersect(a, "core.+.request.*", "core.obs.+.SetX"));
    // 両方ワイルドカードだが前半不一致
    try std.testing.expect(!patternsIntersect(a, "core.obs.#", "ext.twitch.#"));
}

test "classify" {
    try std.testing.expectEqual(Importance.control, classify("core.obs.request.SetSceneItemEnabled"));
    try std.testing.expectEqual(Importance.pii, classify("ext.twitch.chat.message"));
    try std.testing.expectEqual(Importance.telemetry, classify("core.obs.event.SceneChanged"));
    try std.testing.expectEqual(Importance.system, classify("core.node.fault"));
    try std.testing.expectEqual(Importance.data, classify("my.custom.topic"));
}

test "computeBlast: kusa_node reaches OBS sink but cannot read chat beyond its sub" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 手組みのノード集合: TwitchAdapter, ObsEgress(sink), kusa_node
    var nodes = std.ArrayListUnmanaged(Node){};
    try nodes.append(arena, .{
        .name = "TwitchAdapter",
        .kind = "native",
        .pub_patterns = try arena.dupe([]const u8, &.{"ext.twitch.chat.message"}),
        .sub_patterns = try arena.dupe([]const u8, &.{}),
    });
    try nodes.append(arena, .{
        .name = "ObsEgress",
        .kind = "native",
        .is_sink = true,
        .sink_desc = "OBS",
        .pub_patterns = try arena.dupe([]const u8, &.{"core.obs.event.*"}),
        .sub_patterns = try arena.dupe([]const u8, &.{"core.obs.request.*"}),
    });
    try nodes.append(arena, .{
        .name = "kusa_node",
        .kind = "wasm",
        .pub_patterns = try arena.dupe([]const u8, &.{"core.obs.request.SetSceneItemEnabled"}),
        .sub_patterns = try arena.dupe([]const u8, &.{ "ext.twitch.chat.message", "core.system.tick" }),
    });

    const report = try computeBlast(arena, nodes.items, "kusa_node");

    // kusa は chat を読める (TwitchAdapter の publish と交差)
    var reads_chat = false;
    for (report.readable) |r| {
        if (std.mem.eql(u8, r.topic, "ext.twitch.chat.message")) reads_chat = true;
    }
    try std.testing.expect(reads_chat);

    // kusa は OBS シンクに到達しうる
    try std.testing.expectEqual(@as(usize, 1), report.reachable_sinks.len);
    try std.testing.expectEqualStrings("ObsEgress", report.reachable_sinks[0].node_name);
}

test "computeBlast: isolated node reaches no sink" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var nodes = std.ArrayListUnmanaged(Node){};
    try nodes.append(arena, .{
        .name = "ObsEgress",
        .kind = "native",
        .is_sink = true,
        .pub_patterns = try arena.dupe([]const u8, &.{"core.obs.event.*"}),
        .sub_patterns = try arena.dupe([]const u8, &.{"core.obs.request.*"}),
    });
    // logger は自分の閉じたトピックしか触らない
    try nodes.append(arena, .{
        .name = "logger",
        .kind = "wasm",
        .pub_patterns = try arena.dupe([]const u8, &.{"ext.logger.out"}),
        .sub_patterns = try arena.dupe([]const u8, &.{"ext.twitch.chat.message"}),
    });

    const report = try computeBlast(arena, nodes.items, "logger");
    try std.testing.expectEqual(@as(usize, 0), report.reachable_sinks.len);
}
