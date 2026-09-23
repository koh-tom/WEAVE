const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// 無限ループ (CPU 占有) の再現用 (デモ D / P0-1)。
// "!freeze" を含むチャットを受け取ると while(true) に入り、二度と戻らない。
// 素のプラグイン環境ならホストのスレッドごと固まる。WEAVE では manifest の
// limits.max_instructions を超えた時点で trap し、他のノードはそのまま動き続ける。
var handled: u32 = 0;

export fn on_init() i32 {
    sdk.log(1, "[loop_node] ready. send a chat containing !freeze to hang me");
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    handled += 1;
    if (std.mem.indexOf(u8, payload, "!freeze") == null) {
        _ = sdk.publish("ext.loop.alive", "{\"alive\":true}", .BestEffort);
        return;
    }
    sdk.log(2, "[loop_node] entering an infinite loop");
    // 最適化で消されないよう volatile に書き続ける
    var spin: u32 = 0;
    const p: *volatile u32 = &spin;
    while (true) p.* +%= 1;
}
