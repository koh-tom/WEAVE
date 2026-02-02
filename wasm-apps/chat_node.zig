const sdk = @import("plugin_sdk.zig");

// WAMR runtime が期待するエクスポート
// plugin_sdk.zig で定義された os_alloc, os_dealloc が利用可能

export fn on_init() i32 {
    sdk.log(1, "Hello WEAVE! Twitch Monitor Node active.");
    _ = sdk.subscribe("ext.twitch.chat.message");
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    // ポインタからスライスを復元
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];

    sdk.log(1, "Twitch Event Received!");
    sdk.log(1, payload);
}
