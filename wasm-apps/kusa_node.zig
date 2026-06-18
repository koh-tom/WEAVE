const std = @import("std");
const sdk = @import("plugin_sdk");

const TwitchMessage = struct {
    user: []const u8,
    message: []const u8,
};

var wc = sdk.WindowCounter{ .window_ms = 3000 };
var visible: bool = false;
var last_trigger_ts: i64 = 0;

export fn on_init() i32 {
    sdk.log(1, "[kusa_node] Initializing kusa_node Wasm plugin...");
    _ = sdk.subscribe("ext.twitch.chat.message");
    return 0;
}

fn containsKusa(message: []const u8) bool {
    if (std.mem.indexOf(u8, message, "草") != null) {
        return true;
    }
    for (message) |char| {
        if (char == 'w' or char == 'W') {
            return true;
        }
    }
    return false;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];

    if (std.mem.eql(u8, topic, "ext.twitch.chat.message")) {
        const parsed = sdk.parseJson(TwitchMessage, payload) catch {
            sdk.log(3, "[kusa_node] Error: Failed to parse Twitch message payload");
            return;
        };
        defer parsed.deinit();

        const now = sdk.getCurrentTimestamp();

        // 10 seconds auto-hide logic
        if (visible and now >= last_trigger_ts + 10000) {
            const res = sdk.publishJson("ext.obs.scene.item_control", .{
                .sceneName = "Overlay",
                .itemName = "KusaEffect",
                .visible = false,
            }, .BestEffort) catch |err| {
                var err_buf: [128]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "[kusa_node] Error publishing hide request: {any}", .{err}) catch "[kusa_node] Error publishing hide request";
                sdk.log(3, err_msg);
                return;
            };
            if (res == .SUCCESS) {
                visible = false;
                sdk.log(1, "[kusa_node] auto-hide: visible=false");
            }
        }

        // Check trigger condition
        if (containsKusa(parsed.value.message)) {
            wc.record(now);
            const count = wc.count(now);

            if (count >= 10 and !visible) {
                const res = sdk.publishJson("ext.obs.scene.item_control", .{
                    .sceneName = "Overlay",
                    .itemName = "KusaEffect",
                    .visible = true,
                }, .BestEffort) catch |err| {
                    var err_buf: [128]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "[kusa_node] Error publishing trigger request: {any}", .{err}) catch "[kusa_node] Error publishing trigger request";
                    sdk.log(3, err_msg);
                    return;
                };
                if (res == .SUCCESS) {
                    visible = true;
                    last_trigger_ts = now;
                    sdk.log(1, "[kusa_node] trigger: visible=true");
                }
            }
        }
    }
}
