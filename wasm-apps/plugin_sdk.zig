const std = @import("std");
const common = @import("common");

// --- Host API (extern宣言) ---
/// WEAVE API 戻り値定義 (Host側と共通)
pub const Result = common.ResultCode;

pub const QoS = common.QoS;

extern fn os_api_publish(topic_ptr: [*]const u8, payload_ptr: [*]const u8, payload_len: u32, qos: u32) i32;
extern fn os_api_subscribe(topic_ptr: [*]const u8) i32;
extern fn os_api_log(level: i32, msg_ptr: [*]const u8, msg_len: u32) void;

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

/// 現在のヒープ使用量を取得
export fn os_api_get_heap_usage() u32 {
    return bump_offset;
}

// --- Allocator Interface ---

/// SDKが使用するアロケータ（バンプアロケータのラッパー）
pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    },
};

fn allocFn(_: *anyopaque, len: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ptr_align;
    _ = ret_addr;
    const ptr = os_alloc(@intCast(len));
    if (ptr == 0) return null;
    return @ptrFromInt(ptr);
}

fn resizeFn(_: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return false; // バンプアロケータなのでリサイズ不可
}

fn remapFn(_: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    _ = buf;
    _ = buf_align;
    _ = new_len;
    _ = ret_addr;
    return null; // バンプアロケータなのでリマップ不可
}

fn freeFn(_: *anyopaque, buf: []u8, buf_align: std.mem.Alignment, ret_addr: usize) void {
    _ = buf;
    _ = buf_align;
    _ = ret_addr;
    // 解放は行わない
}

// --- ヘルパー関数 ---

/// ログ出力
pub fn log(level: i32, msg: []const u8) void {
    _ = os_api_log(level, msg.ptr, msg.len);
}

/// 指定したトピックにイベントを発行する
pub fn publish(topic: []const u8, payload: []const u8, qos: QoS) Result {
    const res = os_api_publish(topic.ptr, payload.ptr, @intCast(payload.len), @intFromEnum(qos));
    return @enumFromInt(res);
}

/// 指定したトピックを動的に購読する
pub fn subscribe(topic: []const u8) Result {
    const res = os_api_subscribe(topic.ptr);
    return @enumFromInt(res);
}

/// JSONペイロードを構造体に変換する
/// 戻り値の Parsed(T) は deinit() を呼ぶことでメモリ管理される（実際にはバンプアロケータのリセットに依存）
pub fn parseJson(comptime T: type, payload: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, payload, .{ .ignore_unknown_fields = true });
}

/// 構造体をJSONシリアライズしてパブリッシュする
pub fn publishJson(topic: []const u8, value: anytype, qos: QoS) !Result {
    var list = std.ArrayList(u8).init(allocator);
    try std.json.stringify(value, .{}, list.writer());
    return publish(topic, list.items, qos);
}
