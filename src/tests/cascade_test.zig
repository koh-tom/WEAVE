//! P0-6 回帰テスト: 「チャット 1 行で WEAVE 全体が落ちる」連鎖が起きないこと。
//!
//! 旧実装の連鎖 (2026-09-23 に実機で再現、gdb で確定):
//!   外部入力が Transient で保持される → プラグインが trap → 再起動がディスパッチャ上・
//!   ロック保持中に同期実行 → on_init の subscribe で毒が同期再配送 → 同じ mutex に再入
//!   → Debug では "Deadlock detected" でプロセスごと abort。
//!
//! 新しいバスでは購読時の再配送は必ずキュー経由で、購読は (node, パターン) で冪等。
//! このテストは毒メッセージをわざと Transient で流し、プロセスが生き残り、
//! プラグインが復帰し、別セルの配送が止まらないことを確かめる。

const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const plugin_manager = @import("../core/plugin_manager.zig");
const wamr = @import("../core/wamr_libs.zig").wamr;

test "cascade: a Transient poison message does not take down the bus" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 64);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("../core/wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = plugin_manager.PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    host_api.enable_log = false;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
        host_api.enable_log = true;
    }
    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    // 別セルで動く「他のツール」(カウンタ)
    const Other = struct {
        var n = std.atomic.Value(u32).init(0);
        fn cb(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = n.fetchAdd(1, .monotonic);
        }
    };
    Other.n.store(0, .monotonic);
    const other_cell = try bus.createCell("other", .{});
    try bus.subscribeEx("ext.other.ping", 50, Other.cb, null, .{ .cell = other_cell });

    // 故障する側 (bad_node) を専用セルで動かす
    const wasm_path = "wasm-apps/bad_node.wasm";
    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);
    const module = try runtime.loadModule(wasm_buffer);
    const inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);
    const meta = try pm.registerPlugin(module, inst, wasm_path, "wasm-apps/bad_node.json", wasm_buffer, &bus);
    const plugin_cell = try bus.createCell("plugin.BadNode", .{ .trust = .untrusted });
    meta.subscriber.?.cell = plugin_cell;

    var faults = std.atomic.Value(u32).init(0);
    const Fault = struct {
        fn cb(ctx: ?*anyopaque, _: *const event_bus.EventMessage) void {
            const c: *std.atomic.Value(u32) = @ptrCast(@alignCast(ctx));
            _ = c.fetchAdd(1, .monotonic);
        }
    };
    try bus.subscribe("core.node.fault", 99, Fault.cb, &faults);

    // on_init (動的に allowed.topic を購読する)
    {
        meta.subscriber.?.mutex.lock();
        defer meta.subscriber.?.mutex.unlock();
        const f = wamr.wasm_runtime_lookup_function(inst, "on_init") orelse return error.FunctionNotFound;
        const env = wamr.wasm_runtime_create_exec_env(inst, 16384);
        defer wamr.wasm_runtime_destroy_exec_env(env);
        var argv = [_]u32{0};
        _ = wamr.wasm_runtime_call_wasm(env, f, 0, &argv);
    }

    try bus.start();

    // 毒メッセージを「保持される」QoS で流す (旧実装が死んだ条件)
    try bus.publish("allowed.topic", "TRAP", .Transient, 0);
    bus.waitIdle();

    // ここまで到達した = プロセスは生きている。障害通知はちょうど 1 回
    try std.testing.expectEqual(@as(u32, 1), faults.load(.monotonic));

    // 他セルの配送は止まっていない
    var i: usize = 0;
    while (i < 3) : (i += 1) try bus.publish("ext.other.ping", "{}", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 3), Other.n.load(.monotonic));

    // 再起動後のプラグインは正常なメッセージを処理でき、失敗カウンタが戻る
    try bus.publish("allowed.topic", "HELLO", .BestEffort, 0);
    bus.waitIdle();
    var it = pm.plugins.valueIterator();
    const m = it.next().?.*;
    try std.testing.expectEqual(@as(u32, 0), m.subscriber.?.consecutive_failures);
    // 再購読は冪等: allowed.topic の購読は 1 本のまま
    try std.testing.expectEqual(@as(usize, 1), bus.subscriptionCount(100));
}

test "metering: an infinite loop traps, other cells keep delivering, the plugin comes back (P0-1)" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 64);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("../core/wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = plugin_manager.PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    host_api.enable_log = false;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
        host_api.enable_log = true;
    }
    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    // 別セルの「他のツール」
    const Other = struct {
        var n = std.atomic.Value(u32).init(0);
        fn cb(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = n.fetchAdd(1, .monotonic);
        }
    };
    Other.n.store(0, .monotonic);
    const other_cell = try bus.createCell("other", .{});
    try bus.subscribeEx("ext.other.ping", 50, Other.cb, null, .{ .cell = other_cell });

    // 障害通知: 理由が命令数上限であることを確かめる
    const Fault = struct {
        var n = std.atomic.Value(u32).init(0);
        var by_metering = std.atomic.Value(bool).init(false);
        fn cb(_: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            _ = n.fetchAdd(1, .monotonic);
            if (std.mem.indexOf(u8, msg.payload, "instruction limit exceeded") != null) by_metering.store(true, .monotonic);
        }
    };
    Fault.n.store(0, .monotonic);
    Fault.by_metering.store(false, .monotonic);
    try bus.subscribe("core.node.fault", 99, Fault.cb, null);

    // 復帰後の生存確認
    const Alive = struct {
        var n = std.atomic.Value(u32).init(0);
        fn cb(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = n.fetchAdd(1, .monotonic);
        }
    };
    Alive.n.store(0, .monotonic);
    try bus.subscribe("ext.loop.alive", 98, Alive.cb, null);

    const wasm_path = "wasm-apps/loop_node.wasm";
    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);
    const module = try runtime.loadModule(wasm_buffer);
    const inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);
    const meta = try pm.registerPlugin(module, inst, wasm_path, "wasm-apps/loop_node.json", wasm_buffer, &bus);
    try std.testing.expectEqual(@as(u32, 5_000_000), meta.subscriber.?.max_instructions);
    const plugin_cell = try bus.createCell("plugin.loop_node", .{ .trust = .untrusted });
    meta.subscriber.?.cell = plugin_cell;
    try pm.applyManifestSubscriptions(inst, &bus);

    try bus.start();

    // 無限ループを踏ませ、同時に別セルへ配送する
    try bus.publish("ext.twitch.chat.message", "{\"text\":\"!freeze\"}", .BestEffort, 0);
    var i: usize = 0;
    while (i < 3) : (i += 1) try bus.publish("ext.other.ping", "{}", .BestEffort, 0);
    bus.waitIdle();

    // 旧実装 (metering 無し) では waitIdle が永久に戻らなかった
    try std.testing.expectEqual(@as(u32, 1), Fault.n.load(.monotonic));
    try std.testing.expect(Fault.by_metering.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 3), Other.n.load(.monotonic));

    // 再起動後は普通のチャットを処理できる
    try bus.publish("ext.twitch.chat.message", "{\"text\":\"hello\"}", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), Alive.n.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 0), meta.subscriber.?.consecutive_failures);
}
