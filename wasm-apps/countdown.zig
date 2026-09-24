const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// countdown — OBS に同梱されている Countdown スクリプトと同じ振る舞いを、WEAVE のプラグインとして
// 書き直したもの (C3)。OBS のドキュメントに書かれた振る舞い (長さ・テキストソース・終了メッセージ、
// 開始 / 停止 / リセット、毎秒テキストを更新) から作ったクリーンルーム実装で、GPL のコードは含まない。
//
// 違い: OBS 内のスクリプトはタイマーとソースを直接触るが、ここでは
//   - 時刻は core.system.tick (と各メッセージのタイムスタンプ) で数える → 記録の再生でも同じ表示になる
//   - テキストの更新は core.obs.request.SetInputSettings を発行する → 権限は manifest の宣言だけ
//   - 状態は WEAVE に預ける (sdk.exportState) → trap や Core の再起動をまたいでも残り時間が続く
//
// 操作: ext.countdown.cmd に JSON を送る
//   {"cmd":"start","seconds":300,"source":"Countdown","final":"Starting soon!"}  (source / final は省略可)
//   {"cmd":"stop"}   一時停止 (残り時間を保持)
//   {"cmd":"start"}  再開 (seconds を省略すると続きから)
//   {"cmd":"reset"}  最初の長さに戻して停止
// (元のスクリプトは配信者のホットキーで操作する。チャットからの操作は、送り主が配信者か確かめられない
//  ので受け付けない。Stream Deck や `weave topic pub ext.countdown.cmd ...` から送る)

const MAX_SOURCE = 64;
const MAX_FINAL = 128;

const State = struct {
    running: bool = false,
    duration_ms: i64 = 0,
    /// 動作中: 終了予定時刻。停止中: 使わない
    end_ts: i64 = 0,
    /// 停止中の残り時間
    remaining_ms: i64 = 0,
    /// 最後に表示した秒数 (同じ表示を送り直さない)
    last_shown: i64 = -1,
    finished: bool = false,
    source_len: u8 = 0,
    source: [MAX_SOURCE]u8 = [_]u8{0} ** MAX_SOURCE,
    final_len: u8 = 0,
    final: [MAX_FINAL]u8 = [_]u8{0} ** MAX_FINAL,
};
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

fn setString(buf: []u8, len: *u8, value: []const u8) void {
    const n: u8 = @intCast(@min(value.len, buf.len));
    @memcpy(buf[0..n], value[0..n]);
    len.* = n;
}

fn sourceName() []const u8 {
    return if (state.source_len == 0) "Countdown" else state.source[0..state.source_len];
}

fn finalText() []const u8 {
    return state.final[0..state.final_len];
}

fn show(text: []const u8) void {
    _ = sdk.publishJson("core.obs.request.SetInputSettings", .{
        .inputName = sourceName(),
        .inputSettings = .{ .text = text },
    }, .Reliable) catch {};
}

fn showSeconds(total: i64) void {
    if (total == state.last_shown) return;
    state.last_shown = total;
    var buf: [16]u8 = undefined;
    const t: u64 = @intCast(@max(0, total));
    const text = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ t / 3600, (t / 60) % 60, t % 60 }) catch return;
    show(text);
}

/// 残り時間 (ms) を秒に切り上げる。1 ms でも残っていれば 1 秒と表示する
fn ceilSeconds(ms: i64) i64 {
    return @divFloor(ms + 999, 1000);
}

fn start(now: i64, seconds: ?i64) void {
    if (seconds) |s| {
        state.duration_ms = s * 1000;
        state.remaining_ms = s * 1000;
    } else if (state.remaining_ms <= 0) {
        state.remaining_ms = state.duration_ms;
    }
    if (state.remaining_ms <= 0) return;
    state.running = true;
    state.finished = false;
    state.end_ts = now + state.remaining_ms;
    state.last_shown = -1;
    showSeconds(ceilSeconds(state.remaining_ms));
}

fn stop(now: i64) void {
    if (!state.running) return;
    state.remaining_ms = @max(0, state.end_ts - now);
    state.running = false;
}

fn reset() void {
    state.running = false;
    state.finished = false;
    state.remaining_ms = state.duration_ms;
    state.last_shown = -1;
    showSeconds(ceilSeconds(state.duration_ms));
}

fn tick(now: i64) void {
    if (!state.running) return;
    const left = state.end_ts - now;
    if (left <= 0) {
        state.running = false;
        state.remaining_ms = 0;
        state.finished = true;
        state.last_shown = -1;
        if (state.final_len > 0) show(finalText()) else showSeconds(0);
        return;
    }
    showSeconds(ceilSeconds(left));
}

const Cmd = struct {
    cmd: []const u8,
    seconds: ?i64 = null,
    source: ?[]const u8 = null,
    final: ?[]const u8 = null,
};

fn handleCmd(now: i64, c: Cmd) void {
    if (c.source) |s| setString(&state.source, &state.source_len, s);
    if (c.final) |f| setString(&state.final, &state.final_len, f);
    if (std.mem.eql(u8, c.cmd, "start")) {
        start(now, if (c.seconds) |s| (if (s > 0) s else null) else null);
    } else if (std.mem.eql(u8, c.cmd, "stop")) {
        stop(now);
    } else if (std.mem.eql(u8, c.cmd, "reset")) {
        reset();
    }
}

export fn on_init() i32 {
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    const now = sdk.messageTimestamp();

    if (std.mem.eql(u8, topic, "core.system.tick")) return tick(now);

    if (std.mem.eql(u8, topic, "ext.countdown.cmd")) {
        const parsed = sdk.parseJson(Cmd, payload) catch return;
        defer parsed.deinit();
        handleCmd(now, parsed.value);
        return;
    }
}
