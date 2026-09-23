const std = @import("std");
const common = @import("common");

// --- Host API (extern宣言) ---
/// WEAVE API 戻り値定義 (Host側と共通)
pub const Result = common.ResultCode;

pub const QoS = common.QoS;

extern fn os_api_publish(topic_ptr: [*]const u8, topic_len: u32, payload_ptr: [*]const u8, payload_len: u32, qos: u32) i32;
extern fn os_api_subscribe(topic_ptr: [*]const u8, topic_len: u32) i32;
extern fn os_api_log(level: i32, msg_ptr: [*]const u8, msg_len: u32) void;
extern fn os_api_unsubscribe(topic_ptr: [*]const u8, topic_len: u32) i32;
extern fn os_api_message_timestamp() i64;
extern fn os_api_now() i64;

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
    // 4バイトアラインメント。計算は u64 で行う (4 GiB 付近で u32 が折り返すと grow を飛ばして
    // 確保が「成功」し続け、メモリ上限に届かないまま無限ループになる)
    const aligned_size: u64 = (@as(u64, size) + 3) & ~@as(u64, 3);
    const ptr: u64 = @as(u64, getHeapBase()) + bump_offset;
    const end = ptr + aligned_size;
    if (end > 0xFFFF_FFFF) return 0;

    // 現在の Wasm メモリサイズ (ページ数 * 64KB)
    const mem_size: u64 = @as(u64, @wasmMemorySize(0)) * 65536;

    // メモリが足りなければ grow
    if (end > mem_size) {
        const needed: u32 = @intCast((end - mem_size + 65535) / 65536);
        const result = @wasmMemoryGrow(0, needed);
        if (result < 0) return 0; // grow 失敗 (limits.memory_pages に達した)
    }

    bump_offset = @intCast(end - getHeapBase());
    return @intCast(ptr);
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

/// 処理中のメッセージのタイムスタンプ (UNIX ミリ秒)。再生しても同じ値になる
pub fn messageTimestamp() i64 {
    if (comptime !is_wasm) return 0;
    return os_api_message_timestamp();
}

/// 旧名 (互換)
pub fn getCurrentTimestamp() i64 {
    return messageTimestamp();
}

/// 壁時計 (UNIX ミリ秒)
pub fn now() i64 {
    if (comptime !is_wasm) return 0;
    return os_api_now();
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

/// 購読を解除する
pub fn unsubscribe(topic: []const u8) Result {
    const res = os_api_unsubscribe(topic.ptr, @intCast(topic.len));
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

/// プラグインの状態を WEAVE に預ける (R5)。
///
/// 状態は on_message が成功した時だけホストがコミットし、プラグインが trap して再起動されたら
/// 直前にコミットした内容を書き戻す。毒メッセージで途中まで書き換えた状態は捨てられる。
/// 使い方: `var state: MyState = .{};` を定義し、`comptime { sdk.exportState(&state); }`。
/// T はポインタを含まない値型 (POD) に限る。大きさの上限は manifest の `limits.state_bytes`。
/// 書き戻しの後に後始末したければ `export fn on_restore() void` を定義する。
pub fn exportState(comptime state: anytype) void {
    const T = @TypeOf(state.*);
    comptime assertPod(T);
    const S = struct {
        fn ptr() callconv(.c) u32 {
            return @intCast(@intFromPtr(state));
        }
        fn len() callconv(.c) u32 {
            return @sizeOf(T);
        }
    };
    @export(&S.ptr, .{ .name = "weave_state_ptr" });
    @export(&S.len, .{ .name = "weave_state_len" });
}

fn assertPod(comptime T: type) void {
    switch (@typeInfo(T)) {
        .bool, .int, .float, .@"enum", .void => {},
        .array => |a| assertPod(a.child),
        .optional => |o| assertPod(o.child),
        .@"struct" => |st| for (st.fields) |f| assertPod(f.type),
        else => @compileError("sdk.exportState: " ++ @typeName(T) ++ " must not contain pointers (state is copied as bytes)"),
    }
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

    pub fn record(self: *WindowCounter, ts: i64) void {
        self.timestamps[self.head] = ts;
        self.head = (self.head + 1) % 128;
        if (self.count_val < 128) {
            self.count_val += 1;
        }
    }

    pub fn count(self: *WindowCounter, ts: i64) u8 {
        var valid_count: u8 = 0;
        var i: u8 = 0;
        const threshold = ts - @as(i64, self.window_ms);
        while (i < self.count_val) : (i += 1) {
            const idx = (self.head + 128 - self.count_val + i) % 128;
            const t = self.timestamps[idx];
            if (t >= threshold and t <= ts) {
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
