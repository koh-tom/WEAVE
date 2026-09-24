const std = @import("std");
const sdk = @import("plugin_sdk");

pub const panic = sdk.panic;

// 資源上限 (A5) の確認用。ext.limits.cmd に届いた命令に従って、異なるトピックへの publish や
// 購読を N 個作ろうとする。manifest の limits.max_topics / max_subscriptions を超えた分は
// ERROR_LIMIT_EXCEEDED になり、core.security.limit_exceeded が監査ログに残る。
var accepted: u32 = 0;
var refused: u32 = 0;

export fn on_init() i32 {
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
    var buf: [64]u8 = undefined;
    if (std.mem.startsWith(u8, payload, "topics:")) {
        const n = std.fmt.parseInt(u32, payload[7..], 10) catch return;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const t = std.fmt.bufPrint(&buf, "ext.limits.t{d}", .{i}) catch return;
            count(sdk.publish(t, "{}", .BestEffort));
        }
    } else if (std.mem.startsWith(u8, payload, "subs:")) {
        const n = std.fmt.parseInt(u32, payload[5..], 10) catch return;
        var i: u32 = 0;
        while (i < n) : (i += 1) {
            const t = std.fmt.bufPrint(&buf, "ext.limits.s{d}", .{i}) catch return;
            count(sdk.subscribe(t));
        }
    }
    const report = std.fmt.bufPrint(&buf, "{{\"accepted\":{d},\"refused\":{d}}}", .{ accepted, refused }) catch return;
    _ = sdk.publish("ext.limits.report", report, .BestEffort);
}

fn count(r: sdk.Result) void {
    if (r == .SUCCESS) accepted += 1 else if (r == .ERROR_LIMIT_EXCEEDED) refused += 1;
}
