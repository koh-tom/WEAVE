const std = @import("std");
const sdk = @import("plugin_sdk");

// 「暴走したチャット Bot」をシミュレートするデモ用プラグイン。
// tick ごとに ext.chat.spam へ大量 publish を試みる。
// 現状の世界: こういう Bot が 1 つ暴れると、直結された全ツールが巻き込まれて配信が崩壊する。
// WEAVE:      manifest の rate_limit_eps によりバス手前でドロップされ、他ノードは無傷。
var tick_count: u32 = 0;
var total_sent: u32 = 0;
var total_dropped: u32 = 0;

const BURST: u32 = 50; // 毎 tick 50 件を投げつける (tick=500ms なので ~100 eps 相当)

export fn on_init() i32 {
    sdk.log(2, "[spam_node] 暴走Botをシミュレート開始: tick毎に大量publishを試みます");
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = payload_ptr;
    _ = payload_len;
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    if (!std.mem.eql(u8, topic, "core.system.tick")) return;

    tick_count += 1;
    var sent: u32 = 0;
    var dropped: u32 = 0;
    var i: u32 = 0;
    while (i < BURST) : (i += 1) {
        const res = sdk.publish("ext.chat.spam", "{\"spam\":true}", .BestEffort);
        if (res == .SUCCESS) {
            sent += 1;
        } else {
            dropped += 1; // ERROR_RATE_LIMITED でここに来る
        }
    }
    total_sent += sent;
    total_dropped += dropped;

    var buf: [192]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[spam_node] tick#{}: 試行{}件 -> 通過{} / レート制限でドロップ{} (累計ドロップ{})", .{ tick_count, BURST, sent, dropped, total_dropped }) catch return;
    sdk.log(1, msg);
}
