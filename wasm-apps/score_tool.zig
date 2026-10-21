const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// score_tool — 競技イベントのスコア係 (デモ用)。チャットの "!point A" / "!point B" で点を数え、
// ext.score.update に {"a":N,"b":M} を出す。scoreboard (配信画面のスコア表示) はこれだけを頼りにしている。
//
// 「起動し忘れると、スコア表示は 0-0 のまま固まる。見た目は正常なので誰も気づかない」という
// イベント運営で実際に起きた事故を再現するためのもの。WEAVE は `--expect wasm-apps/score_tool.json`
// で「本来いるはず」と宣言しておけば、起動していないことと、それで止まった scoreboard を出す。

const State = struct {
    a: u32 = 0,
    b: u32 = 0,
};
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

fn push() void {
    _ = sdk.publishJson("ext.score.update", .{ .a = state.a, .b = state.b }, .Reliable) catch {};
}

export fn on_init() i32 {
    push();
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    const Chat = struct { user: []const u8 = "", message: []const u8 = "" };
    const chat = sdk.parseJson(Chat, payload) catch return;
    defer chat.deinit();
    const m = std.mem.trim(u8, chat.value.message, " ");
    if (std.ascii.eqlIgnoreCase(m, "!point a")) {
        state.a += 1;
        push();
    } else if (std.ascii.eqlIgnoreCase(m, "!point b")) {
        state.b += 1;
        push();
    }
}
