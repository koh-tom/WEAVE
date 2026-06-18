const std = @import("std");
const common = @import("common");

// --- Host API (extern宣言) ---
/// WEAVE API 戻り値定義 (Host側と共通)
pub const Result = common.ResultCode;

pub const QoS = common.QoS;

extern fn os_api_publish(topic_ptr: [*]const u8, topic_len: u32, payload_ptr: [*]const u8, payload_len: u32, qos: u32) i32;
extern fn os_api_subscribe(topic_ptr: [*]const u8, topic_len: u32) i32;
extern fn os_api_log(level: i32, msg_ptr: [*]const u8, msg_len: u32) void;
extern fn os_api_current_timestamp() i64;

// --- バンプアロケータ ---
// Wasm linear memory の末尾を管理するシンプルなアロケータ。
// __heap_base はリンカが自動で設定する「ヒープ開始位置」。
// ここから先を自由に使える。

const builtin = @import("builtin");
const is_wasm = builtin.cpu.arch == .wasm32;

const heap_base_ptr = if (is_wasm) &struct {
    extern var __heap_base: u8;
}.__heap_base else null;

var bump_offset: u32 = 0;

fn getHeapBase() u32 {
    if (comptime !is_wasm) return 0;
    return @intCast(@intFromPtr(heap_base_ptr));
}

/// Host側から呼び出されるメモリ確保関数。
/// 4バイトアラインメントを保証する。
export fn os_alloc(size: u32) u32 {
    if (!is_wasm) {
        return 0;
    }
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
pub const allocator = if (is_wasm) std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    },
} else std.heap.page_allocator;

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

/// 現在のメッセージタイムスタンプを取得する
pub fn getCurrentTimestamp() i64 {
    if (comptime !is_wasm) return 0;
    return os_api_current_timestamp();
}

/// 指定したトピックにイベントを発行する
pub fn publish(topic: []const u8, payload: []const u8, qos: QoS) Result {
    const res = os_api_publish(topic.ptr, @intCast(topic.len), payload.ptr, @intCast(payload.len), @intFromEnum(qos));
    return @enumFromInt(res);
}

/// 指定したトピックを動的に購読する
pub fn subscribe(topic: []const u8) Result {
    const res = os_api_subscribe(topic.ptr, @intCast(topic.len));
    return @enumFromInt(res);
}

/// JSONペイロードを構造体に変換する
/// 戻り値の Parsed(T) は deinit() を呼ぶことでメモリ管理される（実際にはバンプアロケータのリセットに依存）
pub fn parseJson(comptime T: type, payload: []const u8) !std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, payload, .{ .ignore_unknown_fields = true });
}

/// 構造体をJSONシリアライズしてパブリッシュする
pub fn publishJson(topic: []const u8, value: anytype, qos: QoS) !Result {
    var list = std.array_list.Managed(u8).init(allocator);
    defer list.deinit();
    try list.writer().print("{f}", .{std.json.fmt(value, .{})});
    return publish(topic, list.items, qos);
}

pub fn panic(msg: []const u8, error_return_trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    _ = error_return_trace;
    _ = ret_addr;
    log(3, msg);
    @trap();
}

pub const WindowCounter = struct {
    window_ms: u32,
    timestamps: [128]i64 = undefined,
    head: u8 = 0,
    count_val: u8 = 0,

    pub fn record(self: *WindowCounter, now: i64) void {
        self.timestamps[self.head] = now;
        self.head = (self.head + 1) % 128;
        if (self.count_val < 128) {
            self.count_val += 1;
        }
    }

    pub fn count(self: *WindowCounter, now: i64) u8 {
        var valid_count: u8 = 0;
        var i: u8 = 0;
        const threshold = now - @as(i64, self.window_ms);
        while (i < self.count_val) : (i += 1) {
            const idx = (self.head + 128 - self.count_val + i) % 128;
            const ts = self.timestamps[idx];
            if (ts >= threshold and ts <= now) {
                valid_count += 1;
            }
        }
        return valid_count;
    }
};

test "WindowCounter: boundary" {
    var wc = WindowCounter{ .window_ms = 3000 };
    wc.record(0);
    wc.record(2999);
    wc.record(3001);
    try std.testing.expectEqual(@as(u8, 2), wc.count(3001));
}

test "WindowCounter: wrap around" {
    var wc = WindowCounter{ .window_ms = 10 };
    var i: i64 = 0;
    while (i < 130) : (i += 1) {
        wc.record(i);
    }
    // Latest timestamps recorded are 0 to 129.
    // The timestamps inside the 10ms window of 129 should be: 119 to 129 (11 items).
    try std.testing.expectEqual(@as(u8, 11), wc.count(129));
}
