const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// scoreboard — 配信画面のスコア表示 (デモ用)。score_tool が出す ext.score.update だけを受け取り、
// OBS のテキストソース "Scoreboard" を「A 3 - 2 B」に書き換える。
// score_tool が起動していないと最初の「A 0 - 0 B」のまま固まる。自分では異常に気づけない。

export fn on_init() i32 {
    _ = sdk.publishJson("core.obs.request.SetInputSettings", .{ .inputName = "Scoreboard", .inputSettings = .{ .text = "A 0 - 0 B" } }, .Reliable) catch {};
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    const Score = struct { a: u32 = 0, b: u32 = 0 };
    const s = sdk.parseJson(Score, payload) catch return;
    defer s.deinit();
    var buf: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "A {d} - {d} B", .{ s.value.a, s.value.b }) catch return;
    _ = sdk.publishJson("core.obs.request.SetInputSettings", .{ .inputName = "Scoreboard", .inputSettings = .{ .text = text } }, .Reliable) catch {};
}
