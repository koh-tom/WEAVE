const sdk = @import("plugin_sdk.zig");

// WAMR runtime が期待するエクスポート
// plugin_sdk.zig で定義された os_alloc, os_dealloc が利用可能

export fn on_init() i32 {
    sdk.log(1, "Hello WEAVE! (Enhanced SDK)");
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    // ポインタからスライスを復元
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];

    sdk.log(1, "Wasm Node received event via Dynamic Memory!");
    
    // イベントの再送テスト
    sdk.publish(topic, payload, 1);
}
