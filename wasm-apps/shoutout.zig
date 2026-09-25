const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// shoutout — 配信者コマンド Bot。チャットの "!so <名前>" に反応して、
// 「▶ <名前> さんをチェック！」を配信画面に数秒だけ出す。Nightbot / Streamer.bot でおなじみの実用機能。
//
//   - 表示文言は core.obs.request.SetInputSettings (input "Overlay")
//   - 表示/非表示は core.obs.request.SetSceneItemEnabled (Overlay#2)
//   - 時刻は各メッセージのタイムスタンプで数える → 記録の再生でも同じ表示
//
// 注意: このプラグインは「!so」に反応するだけで、送り主がモデレーターかは確かめない。
// 実運用でモデレーター限定にするなら、送り主の役割を持つイベント (ext.twitch.chat with badges) に繋ぐ。

const SHOW_MS = 8000;
const MAX_NAME = 48;

const State = struct {
    showing: bool = false,
    show_until: i64 = 0,
};
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

fn hide() void {
    _ = sdk.publishJson("core.obs.request.SetSceneItemEnabled", .{ .sceneName = "Overlay", .sceneItemId = 2, .sceneItemEnabled = false }, .Reliable) catch {};
    state.showing = false;
}

fn shout(name: []const u8, now: i64) void {
    const n = name[0..@min(name.len, MAX_NAME)];
    var buf: [128]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "▶ {s} さんをチェック！", .{n}) catch return;
    _ = sdk.publishJson("core.obs.request.SetInputSettings", .{ .inputName = "Overlay", .inputSettings = .{ .text = text } }, .Reliable) catch {};
    _ = sdk.publishJson("core.obs.request.SetSceneItemEnabled", .{ .sceneName = "Overlay", .sceneItemId = 2, .sceneItemEnabled = true }, .Reliable) catch {};
    state.showing = true;
    state.show_until = now + SHOW_MS;
}

export fn on_init() i32 {
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    const now = sdk.messageTimestamp();

    if (std.mem.eql(u8, topic, "core.system.tick")) {
        if (state.showing and now >= state.show_until) hide();
        return;
    }

    if (std.mem.eql(u8, topic, "ext.twitch.chat.message")) {
        const Chat = struct { user: []const u8 = "", message: []const u8 = "" };
        const chat = sdk.parseJson(Chat, payload) catch return;
        defer chat.deinit();
        const m = std.mem.trim(u8, chat.value.message, " ");
        const prefix = "!so ";
        if (std.mem.startsWith(u8, m, prefix)) {
            const name = std.mem.trim(u8, m[prefix.len..], " ");
            if (name.len > 0) shout(name, now);
        }
        if (state.showing and now >= state.show_until) hide();
    }
}
