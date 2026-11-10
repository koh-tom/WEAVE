const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// sfx — チャットのコマンドとアラートで、OBS の効果音 (メディアソース) を鳴らす。
//   !clap / 888 / ナイス → SE_clap、!drum → SE_drum、!yay → SE_yay
//   フォロー・サブ・投げ銭 (StreamElements / Streamlabs) → SE_fanfare
// 鳴らし方は OBS のメディアソースを頭から再生し直す (TriggerMediaInputAction RESTART)。
// 同じ音は 300 ms 以内に重ねない (連打で鳴りっぱなしにしない)。音のファイル自体は OBS 側にあり、プラグインは触れない。

const Sound = enum { clap, drum, yay, fanfare };
const names = [_][]const u8{ "SE_clap", "SE_drum", "SE_yay", "SE_fanfare" };
const COOLDOWN_MS = 300;

const State = struct { last: [4]i64 = .{ -100000, -100000, -100000, -100000 }, played: u32 = 0 };
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

export fn on_init() i32 {
    return 0;
}

fn play(s: Sound, now: i64) void {
    const i = @intFromEnum(s);
    if (now - state.last[i] < COOLDOWN_MS) return;
    const res = sdk.publishJson("core.obs.request.TriggerMediaInputAction", .{
        .inputName = names[i],
        .mediaAction = "OBS_WEBSOCKET_MEDIA_INPUT_ACTION_RESTART",
    }, .BestEffort) catch return;
    if (res == .SUCCESS) {
        state.last[i] = now;
        state.played += 1;
    }
}

fn soundForChat(msg: []const u8) ?Sound {
    const t = std.mem.trim(u8, msg, " \t");
    if (std.mem.startsWith(u8, t, "!clap") or std.mem.indexOf(u8, t, "888") != null or std.mem.indexOf(u8, t, "ナイス") != null) return .clap;
    if (std.mem.startsWith(u8, t, "!drum")) return .drum;
    if (std.mem.startsWith(u8, t, "!yay")) return .yay;
    return null;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    const now = sdk.messageTimestamp();

    if (std.mem.eql(u8, topic, "ext.twitch.chat.message")) {
        const Chat = struct { user: []const u8 = "", message: []const u8 = "" };
        const c = sdk.parseJson(Chat, payload) catch return;
        defer c.deinit();
        if (soundForChat(c.value.message)) |s| play(s, now);
        return;
    }
    // アラート (フォロー・サブ・投げ銭) はトピックの種類だけで判断する (中身の金額や名前は見ない)
    const alerts = [_][]const u8{ "follower", "follow", "subscriber", "tip", "donation", "cheer", "raid" };
    for (alerts) |a| {
        if (std.mem.endsWith(u8, topic, a)) return play(.fanfare, now);
    }
}
