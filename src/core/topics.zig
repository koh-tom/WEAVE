//! トピック空間の規約 (R11 / P0-3)。
//!
//! 1. 予約名前空間: `core.node.*` / `core.system.*` / `core.security.*` / `core.cell.*` は
//!    Core だけが発行できる。プラグインがこれらを発行できると、障害通知や監査イベントを
//!    偽造して Inspector と audit.log を欺けてしまう。
//! 2. トピック種別: 種別ごとに「既定 QoS」「最新値を保持するか」「重要度」を決める。
//!    チャットのような event を Transient で保持すると、毒入力がバスに住み着いて
//!    新しい購読者 (再起動したプラグインを含む) に再配送され続ける (P0-6 の一因)。

const std = @import("std");
const pattern = @import("pattern.zig");
const QoS = @import("../common/types.zig").QoS;

pub const Class = enum {
    /// 起きた出来事。保持しない (チャット、tick など)
    event,
    /// 現在の状態。最新値を保持し、新しい購読者に渡す
    state,
    /// 実世界を操作する要求 (OBS 操作など)。承認時に警告する
    control,
    /// 観測・メトリクス
    telemetry,
    /// Core 内部 (予約名前空間)
    system,

    pub fn label(self: Class) []const u8 {
        return switch (self) {
            .event => "EVENT",
            .state => "STATE",
            .control => "CONTROL (実世界を操作)",
            .telemetry => "TELEMETRY",
            .system => "SYSTEM (Core 専用)",
        };
    }
};

/// Core だけが publish できるパターン。
pub const reserved = [_][]const u8{
    "core.node.#",
    "core.system.#",
    "core.security.#",
    "core.cell.#",
    // 稼働状態のまとめ (HealthMonitor)。偽造されると「止まっていない」と見せかけられる
    "core.health.#",
    // OBS からの報告。出すのは OBS への送信役 (Core) だけ。偽造されると、OBS の状態を偽ったり (event / link)、
    // /status に偽の「どうすれば」(problem) や遅延 (latency) を出して配信者を誤誘導できてしまう。
    // core.obs.request.* (OBS への要求) はプラグインが宣言して使うので予約しない
    "core.obs.event.#",
    "core.obs.link",
    "core.obs.problem",
    "core.obs.latency",
};

/// 個人情報を含みうるパターン (購読には `data_access: ["pii"]` の宣言が要る)。
pub const pii = [_][]const u8{
    "ext.twitch.chat.#",
    "ext.chat.#",
};

/// 実世界を操作するパターン。
pub const control = [_][]const u8{
    "core.obs.request.#",
};

/// 最新値を保持する (Transient 既定) パターン。
pub const state_topics = [_][]const u8{
    "core.node.status.#",
    "core.node.registered",
    "core.node.fault",
    "core.system.graph.full",
    "core.system.introspection.changed",
    "core.obs.event.#",
    "core.obs.link",
    "core.obs.latency",
    // 稼働状態のまとめ。後から開いた /status にも今の状態を渡す
    "core.health.#",
    // プラグイン・外部ノードが自分の状態を公開するための慣例 (例: ext.chat_node.status)
    "ext.+.status",
    "ext.+.state.#",
};

/// パターン (または具体トピック) が予約名前空間に触れるか。
pub fn touchesReserved(p: []const u8) bool {
    for (reserved) |r| if (pattern.intersect(r, p)) return true;
    return false;
}

pub fn touchesPii(p: []const u8) bool {
    for (pii) |r| if (pattern.intersect(r, p)) return true;
    return false;
}

pub fn touchesControl(p: []const u8) bool {
    for (control) |r| if (pattern.intersect(r, p)) return true;
    return false;
}

pub fn classify(topic: []const u8) Class {
    for (control) |r| if (pattern.isMatch(r, topic)) return .control;
    if (std.mem.startsWith(u8, topic, "core.node.metrics") or std.mem.startsWith(u8, topic, "core.cell.metrics")) return .telemetry;
    for (state_topics) |r| if (pattern.isMatch(r, topic)) return .state;
    for (reserved) |r| if (pattern.isMatch(r, topic)) return .system;
    return .event;
}

/// 外部入力 (Dashboard / リモートノード) が QoS を指定しなかったときの既定値。
/// state 種別だけを Transient にし、それ以外は保持しない。
pub fn defaultQos(topic: []const u8) QoS {
    return switch (classify(topic)) {
        .state => .Transient,
        .control => .Reliable,
        else => .BestEffort,
    };
}

test "reserved namespaces" {
    try std.testing.expect(touchesReserved("core.node.fault"));
    try std.testing.expect(touchesReserved("core.#"));
    try std.testing.expect(touchesReserved("#"));
    try std.testing.expect(!touchesReserved("core.obs.request.SetSceneItemEnabled"));
    try std.testing.expect(!touchesReserved("ext.chat.spam"));
}

test "classify and default qos" {
    try std.testing.expectEqual(Class.control, classify("core.obs.request.SetSceneItemEnabled"));
    try std.testing.expectEqual(Class.event, classify("ext.twitch.chat.message"));
    try std.testing.expectEqual(Class.state, classify("core.obs.event.SceneItemEnableStateChanged"));
    try std.testing.expectEqual(Class.telemetry, classify("core.node.metrics"));
    try std.testing.expectEqual(Class.state, classify("ext.chat_node.status"));
    try std.testing.expectEqual(Class.state, classify("ext.kusa.state.visible"));
    try std.testing.expectEqual(Class.event, classify("ext.chat_node.status.extra"));
    try std.testing.expectEqual(QoS.BestEffort, defaultQos("ext.twitch.chat.message"));
    try std.testing.expectEqual(QoS.Transient, defaultQos("core.node.status.kusa_node"));
    try std.testing.expect(touchesPii("ext.twitch.chat.message"));
    try std.testing.expect(touchesPii("ext.twitch.#"));
    try std.testing.expect(!touchesPii("core.system.tick"));
}

test "OBS からの報告は予約。OBS への要求は予約しない" {
    try std.testing.expect(touchesReserved("core.obs.problem"));
    try std.testing.expect(touchesReserved("core.obs.latency"));
    try std.testing.expect(touchesReserved("core.obs.link"));
    try std.testing.expect(touchesReserved("core.obs.event.SceneItemEnableStateChanged"));
    try std.testing.expect(touchesReserved("core.obs.#")); // 広いパターンも拒否
    try std.testing.expect(!touchesReserved("core.obs.request.SetInputSettings"));
}
