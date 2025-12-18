// WEAVE Plugin: Chat Node (Zig version)
extern fn os_api_publish(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32, qos: u32) i32;
extern fn os_api_log(level: u32, msg_ptr: u32, msg_len: u32) i32;

// WAMR runtime will call these
export fn os_alloc(size: u32) u32 {
    // 非常に簡易的なアロケータ（実際は proper な allocator が必要）
    // 今回はスタックを使わず、固定領域を返すか、Zig の std.heap.WasmPageAllocator を使う
    _ = size;
    // 簡易化のため、今回は static なバッファを返す (リエントラント性は無視)
    const buf = struct {
        var storage: [1024]u8 = undefined;
    };
    return @intFromPtr(&buf.storage);
}

export fn on_init() i32 {
    const msg = "Hello WEAVE!";
    _ = os_api_log(1, @intFromPtr(msg.ptr), @intCast(msg.len));
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const msg = "Wasm Node received event!";
    _ = os_api_log(1, @intFromPtr(msg.ptr), @intCast(msg.len));
    
    // イベントをそのまま再送 (ループテスト)
    _ = os_api_publish(topic_ptr, topic_len, payload_ptr, payload_len, 1);
}
