//! 記録の再生 (record / replay, 計画書 §5.8)。
//!
//! `weave record <file>` (= Inspector の全イベントを contents レベルで JSONL に書いたもの) を読み、
//! そのうち「外から入ってきたもの」 = ext.* で送信元がプラグインでないもの (Twitch などのアダプタ、
//! Inspector のシミュレータ) と、時刻の入力である core.system.tick を、元の間隔で流し直す。
//! 再生中は Core の実時間の tick を止める (main.zig の replay_active)。
//!
//! タイムスタンプは「再生を始めた時刻 + 元の記録での経過時間」にずらす。元の絶対時刻のまま流すと、
//! OBS から戻ってくる状態イベント (今の時刻) と時間軸が食い違い、クールダウンなどの判断が変わる。
//! プラグインは処理中のメッセージの時刻を os_api_message_timestamp で見る (壁時計を見ない) ので、
//! 同じ入力を同じ間隔で与えれば同じ出力になる。本番で起きた障害をそのまま手元で再現し、
//! テストに落とすための道具。プラグイン自身の出力は流さない (再生した入力から再び生まれる)。

const std = @import("std");
const log = @import("../common/log.zig");
const event_bus = @import("../core/event_bus.zig");

pub const Replayer = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    path: []const u8,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    replayed: usize = 0,
    skipped: usize = 0,

    pub const Entry = struct {
        topic: []const u8,
        origin: u32,
        ts: i64,
        qos: event_bus.QoS,
        payload: []const u8,
    };

    /// 1 行を解釈する。再生対象でなければ null。payload は allocator で確保 (呼び出し側が free)
    pub fn parseLine(allocator: std.mem.Allocator, line: []const u8) !?Entry {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return null;
        defer parsed.deinit();
        if (parsed.value != .object) return null;
        const obj = parsed.value.object;
        const topic_v = obj.get("topic") orelse return null;
        if (topic_v != .string) return null;
        const topic = topic_v.string;
        const origin: u32 = if (obj.get("origin")) |o| (if (o == .integer and o.integer >= 0) @intCast(o.integer) else 0) else 0;
        // 外からの入力だけ: ext.* かつ送信元がプラグイン (id >= 100) ではないもの、と時刻 (tick)
        const is_tick = std.mem.eql(u8, topic, "core.system.tick") and origin == 0;
        if (!is_tick and (!std.mem.startsWith(u8, topic, "ext.") or origin >= 100)) return null;
        const ts: i64 = if (obj.get("ts")) |t| (if (t == .integer) t.integer else 0) else 0;
        const qos: event_bus.QoS = if (obj.get("qos")) |q| (if (q == .integer and q.integer >= 0 and q.integer <= 2) @enumFromInt(@as(u8, @intCast(q.integer))) else .BestEffort) else .BestEffort;
        const payload_v = obj.get("payload") orelse return null;
        // 観測レベル metadata で記録されたもの ({"hidden":true}) は中身が無いので再生できない
        if (payload_v == .object and payload_v.object.get("hidden") != null) return error.PayloadHidden;
        const payload = switch (payload_v) {
            .string => |s| try allocator.dupe(u8, s),
            else => try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(payload_v, .{})}),
        };
        return .{ .topic = try allocator.dupe(u8, topic), .origin = origin, .ts = ts, .qos = qos, .payload = payload };
    }

    pub fn run(self: *Replayer) !void {
        self.running.store(true, .release);
        const data = try std.fs.cwd().readFileAlloc(self.allocator, self.path, 256 * 1024 * 1024);
        defer self.allocator.free(data);

        var first_ts: ?i64 = null;
        const start_ns = std.time.nanoTimestamp();
        const start_ms = std.time.milliTimestamp();
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |raw| {
            if (!self.running.load(.acquire)) break;
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const e = (parseLine(self.allocator, line) catch |err| {
                if (err == error.PayloadHidden) {
                    log.err("Replay: '{s}' was recorded without payloads (observation level metadata). Record with `weave record`.", .{self.path});
                    return err;
                }
                return err;
            }) orelse {
                self.skipped += 1;
                continue;
            };
            defer {
                self.allocator.free(e.topic);
                self.allocator.free(e.payload);
            }
            // 元の間隔を保つ
            if (first_ts == null) first_ts = e.ts;
            const offset_ms: i64 = @max(0, e.ts - first_ts.?);
            const offset_ns: i128 = @as(i128, offset_ms) * std.time.ns_per_ms;
            while (self.running.load(.acquire)) {
                const wait = start_ns + offset_ns - std.time.nanoTimestamp();
                if (wait <= 0) break;
                std.Thread.sleep(@intCast(@min(wait, 50 * std.time.ns_per_ms)));
            }
            self.bus.publishWithMessageTimestamp(e.topic, e.payload, e.qos, e.origin, start_ms + offset_ms) catch |err| {
                log.warn("Replay: could not publish '{s}': {any}", .{ e.topic, err });
                continue;
            };
            self.replayed += 1;
        }
        log.info("Replay: done ({d} input event(s) replayed, {d} line(s) skipped)", .{ self.replayed, self.skipped });
    }

    pub fn stop(self: *Replayer) void {
        self.running.store(false, .release);
    }
};

test "replay: only external inputs (and ticks) are replayed" {
    const a = std.testing.allocator;
    // Twitch からの入力 → 再生する
    const in = (try Replayer.parseLine(a, "{\"id\":3,\"topic\":\"ext.twitch.chat.message\",\"origin\":1,\"ts\":1700000000123,\"qos\":0,\"payload\":{\"user\":\"a\",\"message\":\"草\"}}")).?;
    defer {
        a.free(in.topic);
        a.free(in.payload);
    }
    try std.testing.expectEqualStrings("ext.twitch.chat.message", in.topic);
    try std.testing.expectEqual(@as(i64, 1700000000123), in.ts);
    try std.testing.expect(std.mem.indexOf(u8, in.payload, "\"message\":\"草\"") != null);
    // プラグインの出力 (origin >= 100) と core.* は再生しない
    try std.testing.expect((try Replayer.parseLine(a, "{\"topic\":\"ext.as.greetings\",\"origin\":100,\"ts\":1,\"payload\":{}}")) == null);
    try std.testing.expect((try Replayer.parseLine(a, "{\"topic\":\"core.obs.request.X\",\"origin\":100,\"ts\":1,\"payload\":{}}")) == null);
    // 時刻の入力 (tick) は再生する
    const tick = (try Replayer.parseLine(a, "{\"topic\":\"core.system.tick\",\"origin\":0,\"ts\":42,\"qos\":0,\"payload\":{}}")).?;
    defer {
        a.free(tick.topic);
        a.free(tick.payload);
    }
    try std.testing.expectEqual(@as(i64, 42), tick.ts);
    // payload を伏せた記録は再生できない
    try std.testing.expectError(error.PayloadHidden, Replayer.parseLine(a, "{\"topic\":\"ext.twitch.chat.message\",\"origin\":1,\"ts\":1,\"payload\":{\"hidden\":true,\"size\":3}}"));
}
