const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// subgoal — サブスク目標バー。配信画面によくある「サブ 12 / 50」の実用ウィジェット。
// 新しいサブが来たら数を 1 増やし、OBS のテキストソースを更新し、数秒だけお祝いのオーバーレイを出す。
//
//   - テキストの更新は core.obs.request.SetInputSettings (input "SubGoal")
//   - お祝いの表示/非表示は core.obs.request.SetSceneItemEnabled (Overlay#1) と、その文言 (input "OverlayText")
//     ※ 本物の OBS ではシーン名と入力名が同じ名前空間なので、シーン "Overlay" と同名の入力は作れない
//   - 数は sdk.exportState に預ける → trap や Core の再起動をまたいでも数が続く
//   - 時刻は各メッセージのタイムスタンプで数える → 記録の再生でも同じ表示
//
// 操作 (チャット / Stream Deck / weave topic pub のいずれでも):
//   "!sub"        … サブが 1 増える (デモ用。実運用では ext.twitch.sub などの本物のイベントに繋ぐ)
//   "!goal 100"   … 目標を変える
//   ext.subgoal.cmd に {"cmd":"sub","user":"name"} / {"cmd":"goal","goal":100} でも可

const OVERLAY_MS = 5000; // お祝いを出す時間

const State = struct {
    count: u32 = 8,
    goal: u32 = 50,
    showing: bool = false,
    show_until: i64 = 0,
    last_pushed_count: i32 = -1,
};
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

fn pushBar() void {
    if (@as(i32, @intCast(state.count)) == state.last_pushed_count) return;
    state.last_pushed_count = @intCast(state.count);
    var buf: [96]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "サブ  {d} / {d}", .{ state.count, state.goal }) catch return;
    _ = sdk.publishJson("core.obs.request.SetInputSettings", .{
        .inputName = "SubGoal",
        .inputSettings = .{ .text = text },
    }, .Reliable) catch {};
}

fn celebrate(user: []const u8, now: i64) void {
    var buf: [160]u8 = undefined;
    // 絵文字は本物の OBS のテキストソース (Noto Sans CJK) で豆腐になるので、CJK フォントにある記号にする
    const text = std.fmt.bufPrint(&buf, "★ {s} さんが新規サブ！  ({d}/{d})", .{ user, state.count, state.goal }) catch return;
    _ = sdk.publishJson("core.obs.request.SetInputSettings", .{ .inputName = "OverlayText", .inputSettings = .{ .text = text } }, .Reliable) catch {};
    _ = sdk.publishJson("core.obs.request.SetSceneItemEnabled", .{ .sceneName = "Overlay", .sceneItemId = 1, .sceneItemEnabled = true }, .Reliable) catch {};
    state.showing = true;
    state.show_until = now + OVERLAY_MS;
}

fn maybeHide(now: i64) void {
    if (state.showing and now >= state.show_until) {
        _ = sdk.publishJson("core.obs.request.SetSceneItemEnabled", .{ .sceneName = "Overlay", .sceneItemId = 1, .sceneItemEnabled = false }, .Reliable) catch {};
        state.showing = false;
    }
}

fn addSub(user: []const u8, now: i64) void {
    state.count += 1;
    pushBar();
    celebrate(user, now);
}

export fn on_init() i32 {
    state.last_pushed_count = -1;
    pushBar();
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    const now = sdk.messageTimestamp();

    if (std.mem.eql(u8, topic, "core.system.tick")) return maybeHide(now);

    if (std.mem.eql(u8, topic, "ext.subgoal.cmd")) {
        const C = struct { cmd: []const u8 = "", user: []const u8 = "配信者", goal: u32 = 0 };
        const c = sdk.parseJson(C, payload) catch return;
        defer c.deinit();
        if (std.mem.eql(u8, c.value.cmd, "sub")) addSub(c.value.user, now) else if (std.mem.eql(u8, c.value.cmd, "goal") and c.value.goal > 0) {
            state.goal = c.value.goal;
            state.last_pushed_count = -1;
            pushBar();
        }
        return;
    }

    if (std.mem.eql(u8, topic, "ext.twitch.chat.message")) {
        const Chat = struct { user: []const u8 = "", message: []const u8 = "" };
        const chat = sdk.parseJson(Chat, payload) catch return;
        defer chat.deinit();
        const m = std.mem.trim(u8, chat.value.message, " ");
        if (std.mem.eql(u8, m, "!sub")) {
            addSub(if (chat.value.user.len > 0) chat.value.user else "viewer", now);
        } else if (std.mem.startsWith(u8, m, "!goal ")) {
            const g = std.fmt.parseInt(u32, std.mem.trim(u8, m[6..], " "), 10) catch return;
            if (g > 0) {
                state.goal = g;
                state.last_pushed_count = -1;
                pushBar();
            }
        }
        maybeHide(now);
    }
}
