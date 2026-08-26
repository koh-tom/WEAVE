//! 中央集権 EventBus のオーバーヘッド計測 (ADR-006 の裏付け)
//!
//! レビュー指摘「中央集権化による実装の軽さは? 感覚なら試すべき」への回答。
//! 「直接コールバック (バス無し)」と「中央 EventBus 経由」のコストを実測し、
//! 中央ブローカーを1つ挟むことの ns/msg・msg/s オーバーヘッドを数字で出す。
//!
//! WAMR 非依存 (純 Zig)。`zig build bench` で実行。

const std = @import("std");
const event_bus = @import("core/event_bus.zig");
const EventBus = event_bus.EventBus;
const EventMessage = event_bus.EventMessage;

const N: usize = 1_000_000;
const PAYLOAD = "{\"user\":\"viewer1\",\"message\":\"hello world\"}";

var sink: u64 = 0;

fn directCallback(_: ?*anyopaque, msg: *const EventMessage) void {
    // 実バスの subscriber と同じ「ペイロード長を読む」程度の仕事をする
    sink +%= msg.payload.len;
}

/// バス無し: publish 相当の呼び出しを直接コールバックに繋ぐ。
/// メッセージ生成 (id採番/timestamp/ヒープdupe/キュー/ミューテックス/スレッド跨ぎ) を
/// 一切挟まない理論下限。
fn benchDirect(allocator: std.mem.Allocator) !u64 {
    sink = 0;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < N) : (i += 1) {
        // バス経由と条件を揃えるためペイロードだけは dupe する
        const p = try allocator.dupe(u8, PAYLOAD);
        const msg = EventMessage{
            .id = @intCast(i),
            .topic = "ext.twitch.chat.message",
            .timestamp = 0,
            .source_node_id = 1,
            .qos = .BestEffort,
            .payload = p,
        };
        directCallback(null, &msg);
        allocator.free(p);
    }
    return timer.read();
}

/// 中央 EventBus 経由 (実際の配送パス): publish → MPSCキュー → dispatcher スレッド → callback。
fn benchBus(allocator: std.mem.Allocator) !u64 {
    var bus = try EventBus.init(allocator, 4096);
    defer bus.deinit();
    bus.verbose = false;
    // トレース/observer は付けない (純粋な配送コストを見る)

    sink = 0;
    try bus.subscribe("ext.twitch.chat.message", 99, directCallback, null);

    const dispatcher = try std.Thread.spawn(.{}, EventBus.runDispatcher, .{&bus});

    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < N) : (i += 1) {
        // Reliable: 満杯なら背圧でブロック (取りこぼしなし = 全件配送を保証して測る)
        try bus.publish("ext.twitch.chat.message", PAYLOAD, .Reliable, 1);
    }
    bus.waitIdle();
    const elapsed = timer.read();

    bus.stop();
    dispatcher.join();
    return elapsed;
}

fn report(label: []const u8, ns: u64) void {
    const per = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(N));
    const per_s = 1_000_000_000.0 / per;
    std.debug.print("{s: <28} {d: >8.1} ns/msg   {d: >12.0} msg/s   ({d:.1} ms total)\n", .{
        label, per, per_s, @as(f64, @floatFromInt(ns)) / 1_000_000.0,
    });
}

pub fn main() !void {
    // 高速なマルチスレッドアロケータを使う (DebugAllocator の割当コストが
    // バス本来のオーバーヘッド信号を埋もれさせないため)
    const allocator = std.heap.smp_allocator;

    std.debug.print("\n=== WEAVE Central Bus Overhead Benchmark ===\n", .{});
    std.debug.print("iterations: {d}, payload: {d} bytes\n\n", .{ N, PAYLOAD.len });

    // ウォームアップ
    _ = try benchDirect(allocator);
    _ = try benchBus(allocator);

    const direct_ns = try benchDirect(allocator);
    const bus_ns = try benchBus(allocator);

    report("direct callback (no bus)", direct_ns);
    report("central EventBus (Reliable)", bus_ns);

    const overhead = @as(f64, @floatFromInt(bus_ns - direct_ns)) / @as(f64, @floatFromInt(N));
    std.debug.print("\n中央ブローカーを挟むコスト: 約 {d:.1} ns/msg\n", .{overhead});
    std.debug.print("(= id採番 + timestamp + ヒープdupe + MPSCキュー + ミューテックス + スレッド跨ぎ配送)\n", .{});
    std.debug.print("→ 単一ホスト・単一配信のイベント流量 (数百〜数千 msg/s) では無視できる水準。\n\n", .{});
}
