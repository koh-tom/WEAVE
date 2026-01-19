// ========================================================
// WEAVE Plugin SDK (Wasm側)
// std ライブラリに依存しないバンプアロケータ実装
// Reference Types 問題を完全に回避する
// ========================================================

// --- Host API (extern宣言) ---
pub extern fn os_api_publish(topic_ptr: [*]const u8, topic_len: usize, payload_ptr: [*]const u8, payload_len: usize, qos: u8) i32;
extern fn os_api_subscribe(topic_ptr: [*]const u8, topic_len: usize) i32;
extern fn os_api_log(level: u32, msg_ptr: [*]const u8, msg_len: usize) i32;

// --- バンプアロケータ ---
// Wasm linear memory の末尾を管理するシンプルなアロケータ。
// __heap_base はリンカが自動で設定する「ヒープ開始位置」。
// ここから先を自由に使える。

extern var __heap_base: u8;

var bump_offset: u32 = 0;

fn getHeapBase() u32 {
    return @intFromPtr(&__heap_base);
}

/// Host側から呼び出されるメモリ確保関数。
/// 4バイトアラインメントを保証する。
export fn os_alloc(size: u32) u32 {
    // 4バイトアラインメント
    const aligned_size = (size + 3) & ~@as(u32, 3);
    const base = getHeapBase();
    const ptr = base + bump_offset;

    // 現在の Wasm メモリサイズ (ページ数 * 64KB)
    const current_pages = @wasmMemorySize(0);
    const mem_size = current_pages * 65536;

    // メモリが足りなければ grow
    if (ptr + aligned_size > mem_size) {
        const needed = ((ptr + aligned_size - mem_size) + 65535) / 65536;
        const result = @wasmMemoryGrow(0, needed);
        if (result < 0) return 0; // grow 失敗
    }

    bump_offset += aligned_size;
    return ptr;
}

/// Host側から呼び出されるメモリ解放関数。
/// バンプアロケータのため、個別解放は行わない。
/// 全体リセット用の os_reset_heap を別途用意する。
export fn os_dealloc(ptr: u32, size: u32) void {
    _ = ptr;
    _ = size;
}

/// ヒープ全体をリセット（イベント処理完了後に呼ぶ想定）
export fn os_reset_heap() void {
    bump_offset = 0;
}

// --- ヘルパー関数 ---

/// ログ出力
pub fn log(level: u32, msg: []const u8) void {
    _ = os_api_log(level, msg.ptr, msg.len);
}

/// イベント発行
pub fn publish(topic: []const u8, payload: []const u8, qos: u8) void {
    _ = os_api_publish(topic.ptr, topic.len, payload.ptr, payload.len, qos);
}

/// トピック購読
pub fn subscribe(topic: []const u8) void {
    _ = os_api_subscribe(topic.ptr, topic.len);
}
