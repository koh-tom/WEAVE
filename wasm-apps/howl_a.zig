const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// ハウリング (ツール同士の無限反響) の再現用。単体では無害な「反応するだけ」のプラグイン。
// howl_a は ext.howl.b を受け取ったら ext.howl.a を発行する。相方と組むと互いに反応し合い、
// 直結の世界では止まらない反響になる。WEAVE では因果の深さ (hops) が上限を超えた時点でバスが止める。
var echoes: u32 = 0;

export fn on_init() i32 {
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = payload_ptr;
    _ = payload_len;
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const start = std.mem.eql(u8, topic, "ext.twitch.chat.message");
    if (!start and !std.mem.eql(u8, topic, "ext.howl.b")) return;
    echoes += 1;
    const res = sdk.publish("ext.howl.a", "{\"echo\":true}", .BestEffort);
    if (res == .ERROR_LIMIT_EXCEEDED) {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "[howl_a] echo stopped by WEAVE after {d} hops", .{echoes}) catch return;
        sdk.log(2, msg);
    }
}
