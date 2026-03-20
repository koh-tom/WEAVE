const std = @import("std");
const sdk = @import("plugin_sdk");

const TwitchMessage = struct {
    user: []const u8,
    message: []const u8,
};

export fn on_init() i32 {
    sdk.log(1, "Hello WEAVE! Twitch Monitor Node active.");
    _ = sdk.subscribe("ext.twitch.chat.message");
    
    // Test Transient QoS: このノードの起動ステータスを保持
    _ = sdk.publish("core.node.status", "{\"status\": \"active\"}", .Transient);
    
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];

    if (std.mem.eql(u8, topic, "ext.twitch.chat.message")) {
        const parsed = sdk.parseJson(TwitchMessage, payload) catch {
            sdk.log(1, "Error: Failed to parse JSON payload");
            return;
        };
        defer parsed.deinit();

        var buf: [256]u8 = undefined;
        const log_msg = std.fmt.bufPrint(&buf, "[Twitch] {s}: {s}", .{parsed.value.user, parsed.value.message}) catch return;
        sdk.log(1, log_msg);
    }
}
