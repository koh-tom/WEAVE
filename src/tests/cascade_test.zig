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

test "memory limit: limits.memory_pages caps memory.grow (P1-5)" {
    const allocator = std.testing.allocator;
    var runtime = try @import("../core/wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();
    const host_api = @import("../api/host_api.zig");
    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, "wasm-apps/loop_node.wasm", 1024 * 1024);
    defer allocator.free(wasm_buffer);
    const module = try runtime.loadModule(wasm_buffer);
    defer wamr.wasm_runtime_unload(module);

    // 上限なしで初期ページ数を知る
    const probe = try runtime.instantiateLimited(module, 64 * 1024, 0, 0);
    const init_pages = wamr.wasm_memory_get_cur_page_count(wamr.wasm_runtime_get_default_memory(probe));
    wamr.wasm_runtime_deinstantiate(probe);

    // 初期 + 2 ページに制限: 2 ページは伸ばせるが、それ以上は拒否される
    const limit = init_pages + 2;
    const inst = try runtime.instantiateLimited(module, 64 * 1024, 0, @intCast(limit));
    defer wamr.wasm_runtime_deinstantiate(inst);
    const mem = wamr.wasm_runtime_get_default_memory(inst);
    try std.testing.expectEqual(limit, wamr.wasm_memory_get_max_page_count(mem));
    try std.testing.expect(wamr.wasm_runtime_enlarge_memory(inst, 2));
    try std.testing.expect(!wamr.wasm_runtime_enlarge_memory(inst, 1));
    try std.testing.expectEqual(limit, wamr.wasm_memory_get_cur_page_count(mem));
}

/// counter_node を PluginManager 経由で立ち上げる (Core.loadPlugin と同じ順序: 登録 → セル → initPlugin → 購読)
const CounterHarness = struct {
    bus: event_bus.EventBus,
    runtime: @import("../core/wasm_runtime.zig").WasmRuntime,
    pm: plugin_manager.PluginManager,
    meta: *plugin_manager.PluginMetadata = undefined,

    var last_value = std.atomic.Value(i64).init(-1);
    var values_seen = std.atomic.Value(u32).init(0);
    var faults = std.atomic.Value(u32).init(0);
    var poisons = std.atomic.Value(u32).init(0);

    fn onValue(_: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const P = struct { count: i64 };
        const parsed = std.json.parseFromSlice(P, std.heap.page_allocator, msg.payload, .{}) catch return;
        defer parsed.deinit();
        last_value.store(parsed.value.count, .monotonic);
        _ = values_seen.fetchAdd(1, .monotonic);
    }
    fn onFault(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
        _ = faults.fetchAdd(1, .monotonic);
    }
    fn onPoison(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
        _ = poisons.fetchAdd(1, .monotonic);
    }

    fn setUp(self: *CounterHarness, allocator: std.mem.Allocator) !void {
        last_value.store(-1, .monotonic);
        values_seen.store(0, .monotonic);
        faults.store(0, .monotonic);
        poisons.store(0, .monotonic);

        self.bus = try event_bus.EventBus.init(allocator, 64);
        self.bus.verbose = false;
        self.runtime = try @import("../core/wasm_runtime.zig").WasmRuntime.init();
        self.pm = plugin_manager.PluginManager.init(allocator);
        self.pm.runtime = &self.runtime;

        const host_api = @import("../api/host_api.zig");
        host_api.global_bus = &self.bus;
        host_api.global_plugin_manager = &self.pm;
        host_api.enable_log = false;
        var symbols = host_api.getNativeSymbols();
        try self.runtime.registerNatives("env", &symbols);

        try self.bus.subscribe("ext.counter.value", 90, onValue, null);
        try self.bus.subscribe("core.node.fault", 91, onFault, null);
        try self.bus.subscribe("core.node.poison", 92, onPoison, null);

        const wasm_path = "wasm-apps/counter_node.wasm";
        const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);
        const module = try self.runtime.loadModule(wasm_buffer);
        const inst = try self.runtime.instantiate(module, 128 * 1024, 64 * 1024);
        self.meta = try self.pm.registerPlugin(module, inst, wasm_path, "wasm-apps/counter_node.json", wasm_buffer, &self.bus);
        self.meta.subscriber.?.cell = try self.bus.createCell("plugin.counter_node", .{ .trust = .untrusted });
        self.pm.initPlugin(self.meta);
        try self.pm.applyManifestSubscriptions(self.meta.instance, &self.bus);
        try self.bus.start();
    }

    fn tearDown(self: *CounterHarness) void {
        const host_api = @import("../api/host_api.zig");
        self.bus.stop();
        self.pm.deinit();
        self.bus.deinit();
        self.runtime.deinit();
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
        host_api.enable_log = true;
    }

    fn send(self: *CounterHarness, payload: []const u8) !void {
        try self.bus.publish("ext.counter.inc", payload, .Reliable, 0);
        self.bus.waitIdle();
    }
};

test "R2/R4/R5: poisoned message is quarantined, restart uses the spare, committed state survives" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dlq_dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dlq_dir);

    var h: CounterHarness = .{ .bus = undefined, .runtime = undefined, .pm = undefined };
    try h.setUp(allocator);
    defer h.tearDown();
    h.pm.dlq_dir = dlq_dir;

    // 状態領域が見つかり、予備インスタンスが用意されている
    const sub = &h.meta.subscriber.?;
    try std.testing.expectEqual(@as(u32, 4), sub.state_len);
    try std.testing.expect(h.meta.spare != null);

    try h.send("{}");
    try h.send("{}");
    try h.send("{}");
    try std.testing.expectEqual(@as(i64, 3), CounterHarness.last_value.load(.monotonic));

    // +1 した後で落ちる毒メッセージ → 再起動 (予備と差し替え)
    const spare_before = h.meta.spare.?;
    try h.send("{\"cmd\":\"TRAP\"}");
    try std.testing.expectEqual(@as(u32, 1), CounterHarness.faults.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), CounterHarness.poisons.load(.monotonic));
    try std.testing.expectEqual(spare_before, h.meta.instance); // R4: 予備がそのまま使われた
    try std.testing.expect(h.meta.spare != null); // 次の予備も用意済み
    try std.testing.expectEqual(@as(u64, 1), sub.restarts_total);
    std.debug.print("\n[R4] restart (spare swap + on_init + state restore): {d} us\n", .{sub.last_restart_us});

    // R5: 落ちる直前にコミットされた 3 から続く (途中の +1 は捨てられ、初期値 0 にも戻らない)
    try h.send("{}");
    try std.testing.expectEqual(@as(i64, 4), CounterHarness.last_value.load(.monotonic));

    // R2: 同じ毒をもう一度送っても配送されず、落ちない
    try h.send("{\"cmd\":\"TRAP\"}");
    try std.testing.expectEqual(@as(u32, 1), CounterHarness.faults.load(.monotonic));
    try std.testing.expectEqual(@as(u64, 1), sub.poison_skipped);

    // DLQ に 1 行記録されている (payload は hex)
    const dlq = try tmp.dir.readFileAlloc(allocator, "100.jsonl", 64 * 1024);
    defer allocator.free(dlq);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, dlq, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, dlq, "\"payload_hex\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, dlq, "ext.counter.inc") != null);
}

test "R3/R8: repeated faults open the breaker, messages wait in the mailbox, half-open recovers" {
    const allocator = std.testing.allocator;
    var h: CounterHarness = .{ .bus = undefined, .runtime = undefined, .pm = undefined };
    try h.setUp(allocator);
    defer h.tearDown();
    const sub = &h.meta.subscriber.?;
    const Breaker = @import("../core/wasm_subscriber.zig").Breaker;

    // 変種の毒で 3 回 (manifest の max_faults) 落ちる → 隔離
    try h.send("TRAP-1");
    try h.send("TRAP-2");
    try std.testing.expectEqual(Breaker.closed, sub.breaker);
    try h.send("TRAP-3");
    try std.testing.expectEqual(Breaker.open, sub.breaker);
    try std.testing.expectEqual(@as(u32, 3), CounterHarness.faults.load(.monotonic));

    // 隔離中のメッセージは配送されずメールボックスで待つ
    try h.send("{}");
    try std.testing.expectEqual(@as(usize, 1), sub.mailbox.items.len);
    try std.testing.expectEqual(@as(u32, 0), CounterHarness.values_seen.load(.monotonic));

    // quarantine_secs (1 秒) 経過後の次のメッセージで half-open → 復帰し、溜まった分も配送される
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try h.send("{}");
    try std.testing.expectEqual(Breaker.closed, sub.breaker);
    try std.testing.expectEqual(@as(usize, 0), sub.mailbox.items.len);
    try std.testing.expectEqual(@as(u32, 2), CounterHarness.values_seen.load(.monotonic));
    // 毒の +1 は 3 回とも捨てられているので 2
    try std.testing.expectEqual(@as(i64, 2), CounterHarness.last_value.load(.monotonic));
}

test "R5+R7: plugin state is saved in the snapshot and restored after a Core restart" {
    const allocator = std.testing.allocator;
    const Snapshot = @import("../core/snapshot.zig").Snapshot;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(dir);
    const path = try std.fmt.allocPrint(allocator, "{s}/snapshot.json", .{dir});
    defer allocator.free(path);

    // 1 回目の Core: 3 まで数えてスナップショットを書く
    {
        var h: CounterHarness = .{ .bus = undefined, .runtime = undefined, .pm = undefined };
        try h.setUp(allocator);
        defer h.tearDown();
        try h.send("{}");
        try h.send("{}");
        try h.send("{}");
        try std.testing.expectEqual(@as(i64, 3), CounterHarness.last_value.load(.monotonic));
        var snap = Snapshot.init(allocator, path, &h.bus, null);
        snap.pm = &h.pm;
        try std.testing.expect(try snap.saveIfChanged());
    }

    // 2 回目の Core (kill -9 の後の起動に相当): 復元すると 3 から続く
    var h: CounterHarness = .{ .bus = undefined, .runtime = undefined, .pm = undefined };
    try h.setUp(allocator);
    defer h.tearDown();
    var snap = Snapshot.init(allocator, path, &h.bus, null);
    snap.pm = &h.pm;
    const r = try snap.restore(false);
    try std.testing.expectEqual(@as(usize, 1), r.plugin_states);
    try h.send("{}");
    try std.testing.expectEqual(@as(i64, 4), CounterHarness.last_value.load(.monotonic));
}

test "R4 bench: restart time distribution (spare swap + on_init + state restore + next spare)" {
    const allocator = std.testing.allocator;
    var h: CounterHarness = .{ .bus = undefined, .runtime = undefined, .pm = undefined };
    try h.setUp(allocator);
    defer h.tearDown();
    try h.send("{}");

    const N = 500;
    var samples: [N]u64 = undefined;
    const sub = &h.meta.subscriber.?;
    for (&samples) |*s| {
        sub.mutex.lock();
        const t0 = std.time.nanoTimestamp();
        try h.pm.restartPlugin(h.meta.node_id, &h.bus);
        s.* = @intCast(std.time.nanoTimestamp() - t0);
        sub.mutex.unlock();
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    std.debug.print("\n[R4 bench] {d} restarts: p50 {d} us, p99 {d} us, max {d} us\n", .{ N, samples[N / 2] / 1000, samples[N * 99 / 100] / 1000, samples[N - 1] / 1000 });

    // 何度差し替えても状態は保たれ、リークしない (testing allocator)
    try h.send("{}");
    try std.testing.expectEqual(@as(i64, 2), CounterHarness.last_value.load(.monotonic));
}

test "lock order: snapshotting plugin state while the plugin restarts does not deadlock" {
    // 再起動はプラグインの mutex を持ったまま plugins_mutex を取る。スナップショットが逆の順序で
    // 両方を持っていた頃は、実デーモンで trap の直後に止まった (tests/e2e/infinite_loop.sh で発見)。
    const allocator = std.testing.allocator;
    var h: CounterHarness = .{ .bus = undefined, .runtime = undefined, .pm = undefined };
    try h.setUp(allocator);
    defer h.tearDown();
    try h.send("{}");

    const Snapper = struct {
        fn run(pm: *plugin_manager.PluginManager, stop: *std.atomic.Value(bool), rounds: *std.atomic.Value(u32)) void {
            while (!stop.load(.acquire)) {
                const states = pm.copyCommittedStates(std.heap.page_allocator) catch continue;
                plugin_manager.PluginManager.freeStateCopies(std.heap.page_allocator, states);
                _ = rounds.fetchAdd(1, .monotonic);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    var rounds = std.atomic.Value(u32).init(0);
    const t = try std.Thread.spawn(.{}, Snapper.run, .{ &h.pm, &stop, &rounds });

    const sub = &h.meta.subscriber.?;
    var i: usize = 0;
    while (i < 300) : (i += 1) {
        sub.mutex.lock(); // WasmSubscriber.callback と同じくプラグインの mutex を持ったまま再起動する
        defer sub.mutex.unlock();
        try h.pm.restartPlugin(h.meta.node_id, &h.bus);
    }
    stop.store(true, .release);
    t.join();
    try std.testing.expect(rounds.load(.monotonic) > 0);
    try h.send("{}");
    try std.testing.expectEqual(@as(i64, 2), CounterHarness.last_value.load(.monotonic));
}

test "A5: exceeding any declared limit is refused and audited as core.security.limit_exceeded" {
    const allocator = std.testing.allocator;
    var bus = try event_bus.EventBus.init(allocator, 256);
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

    const L = struct {
        var by_kind = [_]std.atomic.Value(u32){std.atomic.Value(u32).init(0)} ** 4;
        const kinds = [_][]const u8{ "\"max_topics\"", "\"max_subscriptions\"", "\"max_instructions\"", "\"memory_pages\"" };
        var last_report: [64]u8 = undefined;
        var last_len = std.atomic.Value(usize).init(0);
        fn onLimit(_: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            for (kinds, 0..) |k, i| {
                if (std.mem.indexOf(u8, msg.payload, k) != null) _ = by_kind[i].fetchAdd(1, .monotonic);
            }
        }
        fn onReport(_: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const n = @min(msg.payload.len, last_report.len);
            @memcpy(last_report[0..n], msg.payload[0..n]);
            last_len.store(n, .release);
        }
    };
    for (&L.by_kind) |*v| v.store(0, .monotonic);
    try bus.subscribe("core.security.limit_exceeded", 90, L.onLimit, null);
    try bus.subscribe("ext.limits.report", 91, L.onReport, null);

    // limits_node: トピック 5 個・購読 3 個まで
    const load = struct {
        fn f(a: std.mem.Allocator, rt: anytype, p: *plugin_manager.PluginManager, b: *event_bus.EventBus, name: []const u8, cell_name: []const u8) !*plugin_manager.PluginMetadata {
            var pb: [64]u8 = undefined;
            var mb: [64]u8 = undefined;
            const wasm_path = try std.fmt.bufPrint(&pb, "wasm-apps/{s}.wasm", .{name});
            const buf = try std.fs.cwd().readFileAlloc(a, wasm_path, 1024 * 1024);
            const module = try rt.loadModule(buf);
            const inst = try rt.instantiateLimited(module, 128 * 1024, 64 * 1024, 256);
            const meta = try p.registerPlugin(module, inst, wasm_path, try std.fmt.bufPrint(&mb, "wasm-apps/{s}.json", .{name}), buf, b);
            meta.subscriber.?.cell = try b.createCell(cell_name, .{ .trust = .untrusted });
            p.initPlugin(meta);
            try p.applyManifestSubscriptions(meta.instance, b);
            return meta;
        }
    }.f;
    _ = try load(allocator, &runtime, &pm, &bus, "limits_node", "plugin.limits_node");
    _ = try load(allocator, &runtime, &pm, &bus, "loop_node", "plugin.loop_node");
    _ = try load(allocator, &runtime, &pm, &bus, "bad_node", "plugin.bad_node");
    try bus.start();

    // 8 個のトピックへ publish → 5 個まで (report 用の ext.limits.report も 1 個と数える)
    try bus.publish("ext.limits.cmd", "topics:8", .Reliable, 0);
    bus.waitIdle();
    // 超過した試みは 1 秒に 1 件へ集約して監査される (暴走で監査ログを埋め尽くせない)
    try std.testing.expectEqual(@as(u32, 1), L.by_kind[0].load(.monotonic));

    // 集約の窓 (1 秒, ノード単位) を越えてから、5 個の購読 → manifest の購読 (ext.limits.#) に加えて 2 個まで。
    // 超過した 3 回の試みは監査イベント 1 件にまとまる
    std.Thread.sleep(1100 * std.time.ns_per_ms);
    try bus.publish("ext.limits.cmd", "subs:5", .Reliable, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), L.by_kind[1].load(.monotonic));
    try std.testing.expectEqual(@as(usize, 3), bus.subscriptionCount(100));
    // 同じ窓の中でもう一度試みても、監査イベントは増えない (件数は次のイベントに添えられる)
    try bus.publish("ext.limits.cmd", "subs:5", .Reliable, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), L.by_kind[1].load(.monotonic));

    // 命令数上限とメモリ上限による停止も同じイベントで残る
    try bus.publish("ext.twitch.chat.message", "{\"text\":\"!freeze\"}", .BestEffort, 0);
    try bus.publish("allowed.topic", "ALLOC_UNTIL_OOM", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), L.by_kind[2].load(.monotonic));
    try std.testing.expectEqual(@as(u32, 1), L.by_kind[3].load(.monotonic));
}

test "A3 bench: other cells' delivery latency while 4 kinds of faults are injected" {
    const allocator = std.testing.allocator;
    var bus = try event_bus.EventBus.init(allocator, 1024);
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

    const load = struct {
        fn f(a: std.mem.Allocator, rt: anytype, p: *plugin_manager.PluginManager, b: *event_bus.EventBus, name: []const u8) !void {
            var pb: [64]u8 = undefined;
            var mb: [64]u8 = undefined;
            var cb: [64]u8 = undefined;
            const wasm_path = try std.fmt.bufPrint(&pb, "wasm-apps/{s}.wasm", .{name});
            const buf = try std.fs.cwd().readFileAlloc(a, wasm_path, 1024 * 1024);
            const module = try rt.loadModule(buf);
            const inst = try rt.instantiateLimited(module, 128 * 1024, 64 * 1024, 256);
            const meta = try p.registerPlugin(module, inst, wasm_path, try std.fmt.bufPrint(&mb, "wasm-apps/{s}.json", .{name}), buf, b);
            meta.subscriber.?.cell = try b.createCell(try std.fmt.bufPrint(&cb, "plugin.{s}", .{name}), .{ .trust = .untrusted });
            p.initPlugin(meta);
            try p.applyManifestSubscriptions(meta.instance, b);
        }
    }.f;
    try load(allocator, &runtime, &pm, &bus, "loop_node"); // 無限ループ
    try load(allocator, &runtime, &pm, &bus, "bad_node"); // OOM と trap
    try load(allocator, &runtime, &pm, &bus, "counter_node"); // trap
    try load(allocator, &runtime, &pm, &bus, "limits_node"); // 購読の暴走

    // 測られる側: 何もしない購読者を持つ別セル (Twitch / OBS / 他プラグインの代わり)
    const Nop = struct {
        fn cb(_: ?*anyopaque, _: *const event_bus.EventMessage) void {}
    };
    const base_cell = try bus.createCell("other.baseline", .{});
    const fault_cell = try bus.createCell("other.under_faults", .{});
    try bus.subscribeEx("ext.ping.base", 60, Nop.cb, null, .{ .cell = base_cell });
    try bus.subscribeEx("ext.ping.fault", 61, Nop.cb, null, .{ .cell = fault_cell });
    try bus.start();

    const N = 400;
    // 1. 障害なし
    var i: usize = 0;
    while (i < N) : (i += 1) {
        try bus.publish("ext.ping.base", "{}", .BestEffort, 0);
        std.Thread.sleep(500 * std.time.ns_per_us);
    }
    bus.waitIdle();

    // 2. 障害を注入しながら (別スレッドから 4 種類を交互に、毎回少し違う内容で)
    const Injector = struct {
        fn run(b: *event_bus.EventBus, stop: *std.atomic.Value(bool)) void {
            var k: u32 = 0;
            var buf: [64]u8 = undefined;
            while (!stop.load(.acquire)) : (k += 1) {
                const r = switch (k % 4) {
                    0 => b.publish("ext.twitch.chat.message", std.fmt.bufPrint(&buf, "!freeze {d}", .{k}) catch "!freeze", .BestEffort, 0),
                    1 => b.publish("allowed.topic", std.fmt.bufPrint(&buf, "ALLOC_UNTIL_OOM#{d}", .{k}) catch "ALLOC_UNTIL_OOM", .BestEffort, 0),
                    2 => b.publish("ext.counter.inc", std.fmt.bufPrint(&buf, "TRAP {d}", .{k}) catch "TRAP", .BestEffort, 0),
                    else => b.publish("ext.limits.cmd", "subs:1000", .BestEffort, 0),
                };
                r catch {};
                std.Thread.sleep(2 * std.time.ns_per_ms);
            }
        }
    };
    var stop = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, Injector.run, .{ &bus, &stop });
    i = 0;
    while (i < N) : (i += 1) {
        try bus.publish("ext.ping.fault", "{}", .BestEffort, 0);
        std.Thread.sleep(500 * std.time.ns_per_us);
    }
    stop.store(true, .release);
    t.join();
    bus.waitIdle();

    const base = base_cell.latency();
    const under = fault_cell.latency();
    std.debug.print("\n[A3 bench] other cell latency  baseline p50 {d} us / p99 {d} us  |  under faults p50 {d} us / p99 {d} us  ({d} samples)\n", .{ base.p50_us, base.p99_us, under.p50_us, under.p99_us, under.samples });
    try std.testing.expectEqual(@as(usize, N), under.samples);
    // 配送が止まらない (全件届く) ことと、p99 が桁違いに悪化しないこと。
    // 細かい比率は負荷とスケジューラに依存するので benchmark.md に数字で残す
    try std.testing.expect(under.p99_us <= @max(base.p99_us * 10, 2000));
}

test "C3: countdown (clean-room port of OBS's Countdown script) shows the same sequence for the same timestamps" {
    const allocator = std.testing.allocator;
    var bus = try event_bus.EventBus.init(allocator, 256);
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

    const T = struct {
        var mutex: std.Thread.Mutex = .{};
        var texts: [16][32]u8 = undefined;
        var lens: [16]usize = undefined;
        var n: usize = 0;
        fn onReq(_: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const P = struct { inputName: []const u8, inputSettings: struct { text: []const u8 } };
            const p = std.json.parseFromSlice(P, std.heap.page_allocator, msg.payload, .{}) catch return;
            defer p.deinit();
            mutex.lock();
            defer mutex.unlock();
            if (n >= texts.len or !std.mem.eql(u8, p.value.inputName, "Timer")) return;
            const l = @min(p.value.inputSettings.text.len, 32);
            @memcpy(texts[n][0..l], p.value.inputSettings.text[0..l]);
            lens[n] = l;
            n += 1;
        }
    };
    T.n = 0;
    try bus.subscribe("core.obs.request.SetInputSettings", 90, T.onReq, null);

    const wasm_path = "wasm-apps/countdown.wasm";
    const buf = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);
    const module = try runtime.loadModule(buf);
    const inst = try runtime.instantiateLimited(module, 128 * 1024, 64 * 1024, 256);
    const meta = try pm.registerPlugin(module, inst, wasm_path, "wasm-apps/countdown.json", buf, &bus);
    meta.subscriber.?.cell = try bus.createCell("plugin.countdown", .{ .trust = .untrusted });
    pm.initPlugin(meta);
    try pm.applyManifestSubscriptions(meta.instance, &bus);
    try bus.start();

    const t0: i64 = 1_700_000_000_000;
    const at = struct {
        fn f(b: *event_bus.EventBus, topic: []const u8, payload: []const u8, ts: i64) !void {
            try b.publishWithMessageTimestamp(topic, payload, .Reliable, 0, ts);
            b.waitIdle();
        }
    }.f;
    try at(&bus, "ext.countdown.cmd", "{\"cmd\":\"start\",\"seconds\":3,\"source\":\"Timer\",\"final\":\"Go!\"}", t0);
    try at(&bus, "core.system.tick", "{}", t0 + 500); // まだ 3 秒 (表示は変えない)
    try at(&bus, "core.system.tick", "{}", t0 + 1000);
    try at(&bus, "ext.countdown.cmd", "{\"cmd\":\"stop\"}", t0 + 1500); // 残り 1.5 秒で一時停止
    try at(&bus, "core.system.tick", "{}", t0 + 3000); // 停止中は変わらない
    try at(&bus, "ext.countdown.cmd", "{\"cmd\":\"start\"}", t0 + 5000); // 続きから
    try at(&bus, "core.system.tick", "{}", t0 + 6000);
    try at(&bus, "core.system.tick", "{}", t0 + 6500); // 終了
    try at(&bus, "core.system.tick", "{}", t0 + 7500); // 終了後は何もしない
    try at(&bus, "ext.countdown.cmd", "{\"cmd\":\"reset\"}", t0 + 8000);

    const expected = [_][]const u8{ "00:00:03", "00:00:02", "00:00:02", "00:00:01", "Go!", "00:00:03" };
    T.mutex.lock();
    defer T.mutex.unlock();
    try std.testing.expectEqual(expected.len, T.n);
    for (expected, 0..) |e, i| try std.testing.expectEqualStrings(e, T.texts[i][0..T.lens[i]]);
}
