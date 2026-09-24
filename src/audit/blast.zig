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
const pattern = @import("../core/pattern.zig");

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

/// パターン a と b の表すトピック集合が交差するか。
/// 実装はバス・ACL と共通の pattern.intersect (判定器を一つにして、監査と実行時の食い違いを防ぐ)。
pub fn patternsIntersect(allocator: std.mem.Allocator, a: []const u8, b: []const u8) bool {
    _ = allocator;
    return pattern.intersect(a, b);
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
    /// 所属セル (実行時と同じ名前)。同じセルのノードは executor (実行スレッド) を共有する
    cell: []const u8 = "core",
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

    // Core 自身: 時刻 (tick) を全ノードに供給する
    try list.append(allocator, .{
        .name = "Core",
        .kind = "native",
        .pub_patterns = try allocator.dupe([]const u8, &.{"core.system.tick"}),
        .sub_patterns = try allocator.dupe([]const u8, &.{}),
    });

    const twitch_pub = try allocator.dupe([]const u8, &.{"ext.twitch.chat.message"});
    try list.append(allocator, .{
        .name = "TwitchAdapter",
        .kind = "native",
        .cell = "core",
        .pub_patterns = twitch_pub,
        .sub_patterns = try allocator.dupe([]const u8, &.{}),
    });

    // StreamElements Astro (互換 A): フォロー・投げ銭・サブスクなどを外から持ち込む入口
    try list.append(allocator, .{
        .name = "StreamElements",
        .kind = "native",
        .cell = "ingress",
        .pub_patterns = try allocator.dupe([]const u8, &.{"ext.streamelements.activity.*"}),
        .sub_patterns = try allocator.dupe([]const u8, &.{}),
    });

    // Streamlabs Socket API (互換 A): 投げ銭・フォロー・サブスクなど
    try list.append(allocator, .{
        .name = "Streamlabs",
        .kind = "native",
        .cell = "ingress",
        .pub_patterns = try allocator.dupe([]const u8, &.{"ext.streamlabs.event.*"}),
        .sub_patterns = try allocator.dupe([]const u8, &.{}),
    });

    const obs_sub = try allocator.dupe([]const u8, &.{"core.obs.request.*"});
    const obs_pub = try allocator.dupe([]const u8, &.{"core.obs.event.*"});
    try list.append(allocator, .{
        .name = "ObsEgress",
        .kind = "native",
        .cell = "egress",
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
    cell: ?[]const u8 = null,
    permissions: struct {
        publish: [][]const u8 = &.{},
        subscribe: [][]const u8 = &.{},
    },
};

/// manifest JSON ファイルを読み込み Node を返す。呼び出し側が arena で管理する前提。
/// セルは実行時 (Core.pluginCell) と同じ規則: manifest の `cell` が運用者の宣言したセル
/// (declared_cells) にあればそこ、無ければ `plugin.<name>` 専用セル。
pub fn loadManifestNode(arena: std.mem.Allocator, path: []const u8) !Node {
    return loadManifestNodeIn(arena, path, &.{});
}

pub fn loadManifestNodeIn(arena: std.mem.Allocator, path: []const u8, declared_cells: []const []const u8) !Node {
    const content = try std.fs.cwd().readFileAlloc(arena, path, 1024 * 1024);
    const parsed = try std.json.parseFromSliceLeaky(ManifestShape, arena, content, .{
        .ignore_unknown_fields = true,
    });
    var cell = try std.fmt.allocPrint(arena, "plugin.{s}", .{parsed.name});
    if (parsed.cell) |requested| {
        for (declared_cells) |d| {
            if (std.mem.eql(u8, d, requested)) cell = try arena.dupe(u8, requested);
        }
    }
    return Node{
        .name = parsed.name,
        .kind = "wasm",
        .cell = cell,
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
// 障害の影響範囲 (R9): 「このノードが落ちたら、どこまで止まるか」
// ------------------------------------------------------------
// セキュリティの blast radius と同じグラフ (宣言された pub/sub) で計算する。
//   - 縮退 (degraded): 購読の一部について、提供者が全員落ちている
//   - 沈黙 (stalled) : 提供者のいる購読が全て途絶えた → 以後の出力も止まるとみなし、
//                      落ちたノードの集合に加えて推移的に辿る
// ============================================================

pub const FailureReport = struct {
    target: []const u8,
    degraded: []Affected,
    stalled: [][]const u8,
    unaffected: [][]const u8,
    /// 止まる実世界シンク (OBS など)
    sinks_stopped: [][]const u8,
    /// 同じプラグインセルにいて executor を共有するノード。落ちたノードが命令数上限まで CPU を使う間、
    /// それらへの配送は待たされる (pub/sub の宣言だけでは見えない影響)
    cell_mates: [][]const u8 = &.{},

    pub const Affected = struct {
        node: []const u8,
        lost: [][]const u8,
    };
};

fn providers(nodes: []const Node, sub: []const u8, exclude_self: []const u8) usize {
    var n: usize = 0;
    for (nodes) |p| {
        if (std.mem.eql(u8, p.name, exclude_self)) continue;
        for (p.pub_patterns) |pp| {
            if (pattern.intersect(pp, sub)) {
                n += 1;
                break;
            }
        }
    }
    return n;
}

fn providedOnlyByFailed(nodes: []const Node, failed: *const std.StringHashMapUnmanaged(void), sub: []const u8, self_name: []const u8) bool {
    var any = false;
    for (nodes) |p| {
        if (std.mem.eql(u8, p.name, self_name)) continue;
        for (p.pub_patterns) |pp| {
            if (pattern.intersect(pp, sub)) {
                any = true;
                if (!failed.contains(p.name)) return false;
                break;
            }
        }
    }
    return any;
}

pub fn computeFailure(arena: std.mem.Allocator, nodes: []const Node, target_name: []const u8) !FailureReport {
    if (findNode(nodes, target_name) == null) return error.NodeNotFound;
    var failed = std.StringHashMapUnmanaged(void){};
    try failed.put(arena, target_name, {});

    // 沈黙が連鎖しなくなるまで繰り返す
    var changed = true;
    while (changed) {
        changed = false;
        for (nodes) |n| {
            if (failed.contains(n.name)) continue;
            var fed: usize = 0;
            var lost: usize = 0;
            for (n.sub_patterns) |sp| {
                if (providers(nodes, sp, n.name) == 0) continue; // 元々外部入力 (tick など) 扱い
                fed += 1;
                if (providedOnlyByFailed(nodes, &failed, sp, n.name)) lost += 1;
            }
            if (fed > 0 and lost == fed) {
                try failed.put(arena, n.name, {});
                changed = true;
            }
        }
    }

    var degraded = std.ArrayListUnmanaged(FailureReport.Affected){};
    var stalled = std.ArrayListUnmanaged([]const u8){};
    var unaffected = std.ArrayListUnmanaged([]const u8){};
    var sinks = std.ArrayListUnmanaged([]const u8){};
    for (nodes) |n| {
        if (std.mem.eql(u8, n.name, target_name)) continue;
        if (failed.contains(n.name)) {
            try stalled.append(arena, n.name);
            if (n.is_sink) try sinks.append(arena, n.name);
            continue;
        }
        var lost = std.ArrayListUnmanaged([]const u8){};
        for (n.sub_patterns) |sp| {
            if (providedOnlyByFailed(nodes, &failed, sp, n.name)) try lost.append(arena, sp);
        }
        if (lost.items.len > 0) {
            try degraded.append(arena, .{ .node = n.name, .lost = try lost.toOwnedSlice(arena) });
        } else {
            try unaffected.append(arena, n.name);
        }
    }
    var mates = std.ArrayListUnmanaged([]const u8){};
    const t = findNode(nodes, target_name).?;
    if (std.mem.startsWith(u8, t.cell, "plugin")) {
        for (nodes) |n| {
            if (!std.mem.eql(u8, n.name, target_name) and std.mem.eql(u8, n.cell, t.cell)) try mates.append(arena, n.name);
        }
    }
    return .{
        .target = target_name,
        .cell_mates = try mates.toOwnedSlice(arena),
        .degraded = try degraded.toOwnedSlice(arena),
        .stalled = try stalled.toOwnedSlice(arena),
        .unaffected = try unaffected.toOwnedSlice(arena),
        .sinks_stopped = try sinks.toOwnedSlice(arena),
    };
}

pub fn printFailure(writer: anytype, r: FailureReport) !void {
    try writer.print("\n=== Failure Radius: {s} ===\n", .{r.target});
    try writer.print("(このノードが落ちた場合に、どこまで止まるかの上限。宣言された pub/sub から計算)\n\n", .{});
    try writer.print("[同じセルで待たされる (executor を共有)]\n", .{});
    if (r.cell_mates.len == 0) try writer.print("  (なし — 専用セル)\n", .{});
    for (r.cell_mates) |m| try writer.print("  - {s}  (障害中・再起動中は配送が遅れる)\n", .{m});
    try writer.print("\n", .{});
    try writer.print("[入力の一部を失う (縮退)]\n", .{});
    if (r.degraded.len == 0) try writer.print("  (なし)\n", .{});
    for (r.degraded) |d| {
        try writer.print("  - {s}  失う入力:", .{d.node});
        for (d.lost) |l| try writer.print(" {s}", .{l});
        try writer.print("\n", .{});
    }
    try writer.print("\n[入力が全て途絶えて沈黙する]\n", .{});
    if (r.stalled.len == 0) try writer.print("  (なし)\n", .{});
    for (r.stalled) |s| try writer.print("  - {s}\n", .{s});
    try writer.print("\n[止まる実世界シンク]\n", .{});
    if (r.sinks_stopped.len == 0) try writer.print("  (なし — 配信画面の操作は止まらない)\n", .{});
    for (r.sinks_stopped) |s| try writer.print("  - {s}\n", .{s});
    try writer.print("\n[影響なし]\n", .{});
    for (r.unaffected) |u| try writer.print("  - {s}\n", .{u});
    try writer.print("\n", .{});
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

test "computeFailure: only the plugin's own downstream degrades" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var nodes = std.ArrayListUnmanaged(Node){};
    try nodes.append(arena, .{ .name = "Core", .kind = "native", .pub_patterns = try arena.dupe([]const u8, &.{"core.system.tick"}), .sub_patterns = try arena.dupe([]const u8, &.{}) });
    try nodes.append(arena, .{ .name = "TwitchAdapter", .kind = "native", .pub_patterns = try arena.dupe([]const u8, &.{"ext.twitch.chat.message"}), .sub_patterns = try arena.dupe([]const u8, &.{}) });
    try nodes.append(arena, .{ .name = "ObsEgress", .kind = "native", .is_sink = true, .pub_patterns = try arena.dupe([]const u8, &.{"core.obs.event.*"}), .sub_patterns = try arena.dupe([]const u8, &.{"core.obs.request.*"}) });
    try nodes.append(arena, .{ .name = "kusa_node", .kind = "wasm", .pub_patterns = try arena.dupe([]const u8, &.{"core.obs.request.SetSceneItemEnabled"}), .sub_patterns = try arena.dupe([]const u8, &.{ "ext.twitch.chat.message", "core.system.tick" }) });
    try nodes.append(arena, .{ .name = "emote_wall", .kind = "wasm", .pub_patterns = try arena.dupe([]const u8, &.{"ext.overlay.emotes"}), .sub_patterns = try arena.dupe([]const u8, &.{"ext.twitch.chat.message"}) });
    try nodes.append(arena, .{ .name = "emote_overlay", .kind = "remote", .pub_patterns = try arena.dupe([]const u8, &.{}), .sub_patterns = try arena.dupe([]const u8, &.{"ext.overlay.emotes"}) });

    // emote_wall が落ちても、止まるのはその下流 (emote_overlay) だけ。OBS 操作は止まらない
    const r = try computeFailure(arena, nodes.items, "emote_wall");
    try std.testing.expectEqual(@as(usize, 1), r.stalled.len);
    try std.testing.expectEqualStrings("emote_overlay", r.stalled[0]);
    try std.testing.expectEqual(@as(usize, 0), r.sinks_stopped.len);

    // チャットの入口 (TwitchAdapter) が落ちると、チャットだけに依存する emote 系は沈黙し、
    // kusa は tick があるので「縮退」に留まる
    const r2 = try computeFailure(arena, nodes.items, "TwitchAdapter");
    var kusa_degraded = false;
    for (r2.degraded) |d| {
        if (std.mem.eql(u8, d.node, "kusa_node")) kusa_degraded = true;
    }
    try std.testing.expect(kusa_degraded);
    // emote_wall と emote_overlay はチャットにしか依存しないので沈黙する
    try std.testing.expectEqual(@as(usize, 2), r2.stalled.len);
    try std.testing.expectEqual(@as(usize, 0), r2.sinks_stopped.len);
}

test "computeFailure: plugins sharing an operator-declared cell wait for each other" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const nodes = [_]Node{
        .{ .name = "bot_a", .kind = "wasm", .cell = "plugins.bots", .pub_patterns = try a.dupe([]const u8, &.{"ext.a"}), .sub_patterns = try a.dupe([]const u8, &.{"ext.twitch.chat.message"}) },
        .{ .name = "bot_b", .kind = "wasm", .cell = "plugins.bots", .pub_patterns = try a.dupe([]const u8, &.{"ext.b"}), .sub_patterns = try a.dupe([]const u8, &.{"ext.twitch.chat.message"}) },
        .{ .name = "solo", .kind = "wasm", .cell = "plugin.solo", .pub_patterns = try a.dupe([]const u8, &.{"ext.c"}), .sub_patterns = try a.dupe([]const u8, &.{"ext.twitch.chat.message"}) },
    };
    const r = try computeFailure(a, &nodes, "bot_a");
    try std.testing.expectEqual(@as(usize, 1), r.cell_mates.len);
    try std.testing.expectEqualStrings("bot_b", r.cell_mates[0]);
    // pub/sub では無関係なので、宣言グラフの上では誰も止まらない
    try std.testing.expectEqual(@as(usize, 0), r.stalled.len);
    const solo = try computeFailure(a, &nodes, "solo");
    try std.testing.expectEqual(@as(usize, 0), solo.cell_mates.len);
}

test "loadManifestNodeIn: a requested cell counts only if the operator declared it" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "m.json", .data = "{\"name\":\"x\",\"cell\":\"plugins.bots\",\"permissions\":{}}" });
    const path = try tmp.dir.realpathAlloc(a, "m.json");
    try std.testing.expectEqualStrings("plugin.x", (try loadManifestNodeIn(a, path, &.{})).cell);
    try std.testing.expectEqualStrings("plugins.bots", (try loadManifestNodeIn(a, path, &.{"plugins.bots"})).cell);
}
