const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// 状態の保持 (R5) と毒メッセージの隔離 (R2) の確認用。
// ext.counter.inc を受け取るたびに数を 1 増やして ext.counter.value に出す。
// payload に "TRAP" を含むと、数を増やした「後で」落ちる。WEAVE は成功した時だけ状態を
// コミットするので、再起動後の数は落ちる直前の正しい値から続き、途中の +1 は捨てられる。
const State = struct {
    count: u32 = 0,
};
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

export fn on_init() i32 {
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    state.count += 1;
    if (std.mem.indexOf(u8, payload, "TRAP") != null) @panic("counter_node: poisoned increment");
    _ = sdk.publishJson("ext.counter.value", .{ .count = state.count }, .BestEffort) catch {};
}
