const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const manifest = @import("manifest.zig");
const event_bus = @import("event_bus.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;
const RateLimiter = @import("rate_limiter.zig").RateLimiter;

pub const PluginMetadata = struct {
    node_id: u32,
    wasm_path: []const u8, // 追加: 再起動用
    manifest_path: []const u8, // 追加: 再起動用
    wasm_buffer: []const u8, // WAMR要求によりメモリに保持
    /// 署名検証に使ったのと同じ wasm のバイト列 (WAMR に渡す前の複製)。自動再起動はここから作り直し、
    /// ディスクを読み直さない。ロード後にファイルを差し替えてからトラップさせても、未検証のコードは動かない。
    verified_wasm: ?[]u8 = null,
    manifest_parsed: std.json.Parsed(manifest.Manifest),
    module: wamr.wasm_module_t,
    instance: wamr.wasm_module_inst_t,
    subscriber: ?WasmSubscriber = null,
    rate_limiter: RateLimiter = .{},
    /// rate_limited セキュリティイベントの集約 (1 秒に 1 件、間引いた件数を添える)
    rl_last_emit_ms: i64 = 0,
    rl_suppressed: u32 = 0,

    pub fn deinit(self: *PluginMetadata, allocator: std.mem.Allocator) void {
        if (self.subscriber) |*sub| sub.deinit();
        self.manifest_parsed.deinit();
        wamr.wasm_runtime_deinstantiate(self.instance);
        wamr.wasm_runtime_unload(self.module);
        allocator.free(self.wasm_path);
        allocator.free(self.manifest_path);
        allocator.free(self.wasm_buffer);
        if (self.verified_wasm) |v| allocator.free(v);
    }
};

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata),
    /// plugins の排他。再起動はそのプラグインのセルのスレッドで表を書き換え、Host API は他のセルの
    /// スレッドから引くので必要。表の操作の間だけ持つ (保持したまま Wasm や購読処理を呼ばない)
    plugins_mutex: std.Thread.Mutex = .{},
    next_node_id: u32,
    runtime: ?*@import("wasm_runtime.zig").WasmRuntime = null, // 追加
    wasm_stack_size: u32 = 128 * 1024,
    wasm_heap_size: u32 = 64 * 1024,

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return PluginManager{
            .allocator = allocator,
            .plugins = std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata).init(allocator),
            .next_node_id = 100,
            .runtime = null,
            .wasm_stack_size = 128 * 1024,
            .wasm_heap_size = 64 * 1024,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        var it = self.plugins.valueIterator();
        while (it.next()) |p| {
            p.*.deinit(self.allocator);
            self.allocator.destroy(p.*);
        }
        self.plugins.deinit();
    }

    /// プラグインを管理テーブルに登録する
    pub fn registerPlugin(self: *PluginManager, module: wamr.wasm_module_t, instance: wamr.wasm_module_inst_t, wasm_path: []const u8, manifest_path: []const u8, wasm_buffer: []const u8, bus: *event_bus.EventBus) !*PluginMetadata {
        const bytes = try std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 1024 * 1024);
        defer self.allocator.free(bytes);
        return self.registerPluginWithManifest(module, instance, wasm_path, manifest_path, bytes, wasm_buffer, bus);
    }

    /// manifest をバイト列で受け取る版。署名検証に使ったのと同じバイト列をパースすることで、
    /// 検証とロードの間に manifest を差し替えられる隙 (TOCTOU, P1-1) を無くす。
    pub fn registerPluginWithManifest(self: *PluginManager, module: wamr.wasm_module_t, instance: wamr.wasm_module_inst_t, wasm_path: []const u8, manifest_path: []const u8, manifest_bytes: []const u8, wasm_buffer: []const u8, bus: *event_bus.EventBus) !*PluginMetadata {
        const parsed = try manifest.Manifest.parse(self.allocator, manifest_bytes);
        errdefer parsed.deinit();

        const node_id = self.next_node_id;
        const meta = try self.allocator.create(PluginMetadata);
        meta.* = .{
            .node_id = node_id,
            .wasm_path = try self.allocator.dupe(u8, wasm_path),
            .manifest_path = try self.allocator.dupe(u8, manifest_path),
            .wasm_buffer = wasm_buffer,
            .manifest_parsed = parsed,
            .module = module,
            .instance = instance,
            .subscriber = try WasmSubscriber.init(instance, node_id, bus, self),
            .rate_limiter = RateLimiter.init(parsed.value.rate_limit_eps),
        };
        meta.subscriber.?.max_instructions = parsed.value.limits.max_instructions;
        meta.subscriber.?.max_init_instructions = parsed.value.limits.max_init_instructions;
        self.next_node_id += 1;

        self.plugins_mutex.lock();
        defer self.plugins_mutex.unlock();
        try self.plugins.put(instance, meta);
        return meta;
    }

    pub fn getMetadata(self: *PluginManager, instance: wamr.wasm_module_inst_t) ?*PluginMetadata {
        self.plugins_mutex.lock();
        defer self.plugins_mutex.unlock();
        return self.plugins.get(instance);
    }

    /// 指定したノードを再起動する (Fault復旧用)
    ///
    /// 新しいインスタンスの生成に成功してから旧インスタンスと差し替える (P0-4)。
    /// 途中で失敗した場合は旧インスタンスをそのまま残し、ノードを停止扱いにする。
    /// こうしないと EventBus に残った購読が破棄済みの instance を指し (use-after-free)、
    /// map から外れた meta もリークする。
    pub fn restartPlugin(self: *PluginManager, node_id: u32, bus: *event_bus.EventBus) !void {
        const meta = self.findByNodeId(node_id) orelse return error.NodeNotFound;
        const runtime = self.runtime orelse return error.RuntimeNotSet;

        std.debug.print("PluginManager: Restarting Node {} ({s})...\n", .{ node_id, meta.wasm_path });

        // 1. 新インスタンスの作成 (旧インスタンスにはまだ触らない)
        const created = self.createInstance(runtime, meta, meta.manifest_parsed.value.limits.memory_pages) catch |err| {
            self.quarantine(meta, bus);
            return err;
        };

        // 2. 差し替え: map のキーを新インスタンスへ付け替えてから旧を破棄する
        const swap_err: ?std.mem.Allocator.Error = swap: {
            self.plugins_mutex.lock();
            defer self.plugins_mutex.unlock();
            _ = self.plugins.remove(meta.instance);
            self.plugins.put(created.instance, meta) catch |err| {
                // 旧インスタンスを map に戻す (新しい方はロードを離してから捨てる)
                self.plugins.put(meta.instance, meta) catch {};
                break :swap err;
            };
            break :swap null;
        };
        if (swap_err) |err| {
            created.destroy(self.allocator);
            self.quarantine(meta, bus);
            return err;
        }
        wamr.wasm_runtime_deinstantiate(meta.instance);
        wamr.wasm_runtime_unload(meta.module);
        self.allocator.free(meta.wasm_buffer);

        meta.wasm_buffer = created.wasm_buffer;
        meta.module = created.module;
        meta.instance = created.instance;
        var needs_subscription = false;
        if (meta.subscriber) |*sub| {
            sub.updateInstance(created.instance);
        } else {
            meta.subscriber = try WasmSubscriber.init(created.instance, node_id, bus, self);
            meta.subscriber.?.max_instructions = meta.manifest_parsed.value.limits.max_instructions;
            meta.subscriber.?.max_init_instructions = meta.manifest_parsed.value.limits.max_init_instructions;
            needs_subscription = true;
        }

        // 3. 初期化と購読再開
        if (wamr.wasm_runtime_lookup_function(created.instance, "on_init")) |func| {
            const env = wamr.wasm_runtime_create_exec_env(created.instance, 16384);
            defer wamr.wasm_runtime_destroy_exec_env(env);
            WasmSubscriber.setInstructionLimit(env, meta.manifest_parsed.value.limits.max_init_instructions);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
        }

        // 新規作成された場合のみ購読を適用（既存の購読はEventBusに残っているため）
        if (needs_subscription) {
            try self.applyManifestSubscriptions(created.instance, bus);
        }

        if (bus.graph) |g| {
            g.updateNodeStatus(node_id, .active);
        }
        std.debug.print("PluginManager: Node {} restarted successfully.\n", .{node_id});
    }

    const CreatedInstance = struct {
        wasm_buffer: []u8,
        module: wamr.wasm_module_t,
        instance: wamr.wasm_module_inst_t,

        fn destroy(self: CreatedInstance, allocator: std.mem.Allocator) void {
            wamr.wasm_runtime_deinstantiate(self.instance);
            wamr.wasm_runtime_unload(self.module);
            allocator.free(self.wasm_buffer);
        }
    };

    fn createInstance(self: *PluginManager, runtime: *@import("wasm_runtime.zig").WasmRuntime, meta: *const PluginMetadata, max_pages: u32) !CreatedInstance {
        // 検証済みのバイト列があればその複製から作る (WAMR は渡したバッファを使い続けるので毎回複製する)。
        // 無いのは Core.loadPlugin を通さずに登録した場合 (テスト) だけ
        const wasm_buffer = if (meta.verified_wasm) |v|
            try self.allocator.dupe(u8, v)
        else
            try std.fs.cwd().readFileAlloc(self.allocator, meta.wasm_path, 1024 * 1024);
        errdefer self.allocator.free(wasm_buffer);
        const module = try runtime.loadModule(wasm_buffer);
        errdefer wamr.wasm_runtime_unload(module);
        const instance = try runtime.instantiateLimited(module, self.wasm_stack_size, self.wasm_heap_size, max_pages);
        return .{ .wasm_buffer = wasm_buffer, .module = module, .instance = instance };
    }

    /// 再起動できなかったノードを停止扱いにする。旧インスタンスは有効なまま map に残るので
    /// 以後の配送で破棄済みメモリに触れることはなく、終了時の deinit で正しく解放される。
    fn quarantine(self: *PluginManager, meta: *PluginMetadata, bus: *event_bus.EventBus) void {
        _ = self;
        if (meta.subscriber) |*sub| sub.consecutive_failures = WasmSubscriber.MAX_RESTART_ATTEMPTS;
        if (bus.graph) |g| g.updateNodeStatus(meta.node_id, .stopped);
        std.debug.print("PluginManager: Node {} could not be restarted; stopped (old instance kept, no deliveries).\n", .{meta.node_id});
    }

    /// テスト・外部から引く用 (ロックを取る)
    pub fn findByNodeIdLocked(self: *PluginManager, node_id: u32) ?*PluginMetadata {
        return self.findByNodeId(node_id);
    }

    fn findByNodeId(self: *PluginManager, node_id: u32) ?*PluginMetadata {
        self.plugins_mutex.lock();
        defer self.plugins_mutex.unlock();
        var it = self.plugins.valueIterator();
        while (it.next()) |m| {
            if (m.*.node_id == node_id) return m.*;
        }
        return null;
    }

    /// マニフェストに記載された購読トピックをEventBusに自動登録する
    pub fn applyManifestSubscriptions(self: *PluginManager, instance: wamr.wasm_module_inst_t, bus: *event_bus.EventBus) !void {
        const meta = self.getMetadata(instance) orelse return error.PluginNotFound;
        const sub_ptr = if (meta.subscriber) |*s| s else return;

        for (meta.manifest_parsed.value.permissions.subscribe) |topic| {
            try bus.subscribeEx(topic, meta.node_id, WasmSubscriber.callback, sub_ptr, .{ .cell = sub_ptr.cell });
        }
    }
};

test "PluginManager: ACL Violation Integrated Test" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
    }

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    const wasm_path = "wasm-apps/bad_node.wasm";
    const manifest_path = "wasm-apps/bad_node.json";

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);

    const module = try runtime.loadModule(wasm_buffer);
    const module_inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);

    const meta = try pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &bus);
    _ = meta;

    const func = wamr.wasm_runtime_lookup_function(module_inst, "on_init") orelse return error.FunctionNotFound;
    const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
    defer wamr.wasm_runtime_destroy_exec_env(env);

    var argv = [_]u32{0};
    const call_res = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);

    try std.testing.expect(call_res);
    try std.testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(argv[0])));
}

test "PluginManager: chat_node ACL Integration Test" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
    }

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    const wasm_path = "wasm-apps/chat_node.wasm";
    const manifest_path = "wasm-apps/chat_node.json";

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);

    const module = try runtime.loadModule(wasm_buffer);
    const module_inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);

    const meta = try pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &bus);
    _ = meta;

    const func = wamr.wasm_runtime_lookup_function(module_inst, "on_init") orelse return error.FunctionNotFound;
    const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
    defer wamr.wasm_runtime_destroy_exec_env(env);

    var argv = [_]u32{0};
    const call_res = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);

    try std.testing.expect(call_res);
    try std.testing.expectEqual(@as(i32, 0), @as(i32, @bitCast(argv[0])));
}

test "PluginManager: Fault Isolation and Safe Recovery Test" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
    }

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    const wasm_path = "wasm-apps/bad_node.wasm";
    const manifest_path = "wasm-apps/bad_node.json";

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 1024 * 1024);

    const module = try runtime.loadModule(wasm_buffer);
    const module_inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);

    const meta = try pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &bus);
    _ = meta;

    var fault_count: u32 = 0;
    var received_exception: [128]u8 = undefined;
    var received_node_id: u32 = 0;

    const TestContext = struct {
        fc: *u32,
        exc: []u8,
        nid: *u32,
    };

    const S = struct {
        fn cb(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const context = @as(*TestContext, @ptrCast(@alignCast(ctx)));
            context.fc.* += 1;

            var parsed = std.json.parseFromSlice(struct { node_id: u32, exception: []const u8 }, std.testing.allocator, msg.payload, .{}) catch return;
            defer parsed.deinit();

            context.nid.* = parsed.value.node_id;
            @memcpy(context.exc[0..parsed.value.exception.len], parsed.value.exception);
            context.exc[parsed.value.exception.len] = 0;
        }
    };

    var metrics_count: u32 = 0;
    const MetricsS = struct {
        fn cb(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            const mc = @as(*u32, @ptrCast(@alignCast(ctx)));
            if (std.mem.indexOf(u8, msg.payload, "\"node_id\":100") != null) {
                mc.* += 1;
            }
        }
    };
    try bus.subscribe("core.node.metrics", 98, MetricsS.cb, &metrics_count);

    var context_struct = TestContext{ .fc = &fault_count, .exc = &received_exception, .nid = &received_node_id };
    try bus.subscribe("core.node.fault", 99, S.cb, &context_struct);

    const thread = try std.Thread.spawn(.{}, event_bus.EventBus.runDispatcher, .{&bus});

    const func_init = wamr.wasm_runtime_lookup_function(module_inst, "on_init") orelse return error.FunctionNotFound;
    const env_init = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
    var argv_init = [_]u32{0};
    _ = wamr.wasm_runtime_call_wasm(env_init, func_init, 0, &argv_init);
    wamr.wasm_runtime_destroy_exec_env(env_init);

    // 長さ 4 のペイロード "TRAP" を publish してトラップを発生させる
    try bus.publish("allowed.topic", "TRAP", .BestEffort, 0);

    bus.waitIdle(); // 登録時on_init、TRAP処理、非同期再起動、再起動時on_initの全イベント完了を待つ

    // 1. 障害通知イベントが確実に届いたことの検証
    try std.testing.expectEqual(@as(u32, 1), fault_count);
    try std.testing.expectEqual(@as(u32, 100), received_node_id);

    // 例外内容が "unreachable" であることの検証
    const exc_str = std.mem.span(@as([*c]const u8, @ptrCast(&received_exception)));
    try std.testing.expect(std.mem.indexOf(u8, exc_str, "unreachable") != null);

    // 2. 自動再起動が実行され、インスタンスが正しく差し替えられたか検証する
    var it = pm.plugins.iterator();
    var new_meta: ?*PluginMetadata = null;
    while (it.next()) |entry| {
        if (entry.value_ptr.*.node_id == 100) {
            new_meta = entry.value_ptr.*;
            break;
        }
    }
    const meta_after_restart = new_meta orelse return error.MetaNotFound;

    // リスタートスロットリング用の失敗カウンタが 1 になっていることを検証
    if (meta_after_restart.subscriber) |sub| {
        try std.testing.expectEqual(@as(u32, 1), sub.consecutive_failures);
    } else {
        return error.SubscriberNotFound;
    }

    // この時点でメトリクスは0つ (Wasm自身のpublishはSelf-publishフィルタにより自分自身には届かないため) のはず
    try std.testing.expectEqual(@as(u32, 0), metrics_count);

    // 3. 正常なメッセージを publish し、再起動後の新インスタンスが問題なく応答できるか検証する
    // 長さ 5 のペイロード "HELLO" をパブリッシュする（トラップしない）
    try bus.publish("allowed.topic", "HELLO", .BestEffort, 0);
    bus.waitIdle();

    // 再起動時の on_init で同じトピックを再購読しても、購読は (node, パターン) で冪等なので
    // 二重購読にならない (旧実装では 2 回配送されていた = P1-6)。メトリクスはちょうど 1 回。
    try std.testing.expectEqual(@as(u32, 1), metrics_count);

    // 新インスタンスの連続失敗カウンタが、成功によりリセット（0）されたことを検証
    if (meta_after_restart.subscriber) |sub| {
        try std.testing.expectEqual(@as(u32, 0), sub.consecutive_failures);
    }

    bus.stop();
    thread.join();
}

test "PluginManager: restart failure keeps the old instance and stops the node (P0-4)" {
    const allocator = std.testing.allocator;

    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var runtime = try @import("wasm_runtime.zig").WasmRuntime.init();
    defer runtime.deinit();

    var pm = PluginManager.init(allocator);
    defer pm.deinit();
    pm.runtime = &runtime;

    const host_api = @import("../api/host_api.zig");
    host_api.global_bus = &bus;
    host_api.global_plugin_manager = &pm;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
    }

    var symbols = host_api.getNativeSymbols();
    try runtime.registerNatives("env", &symbols);

    const wasm_buffer = try std.fs.cwd().readFileAlloc(allocator, "wasm-apps/bad_node.wasm", 1024 * 1024);
    const module = try runtime.loadModule(wasm_buffer);
    const module_inst = try runtime.instantiate(module, 128 * 1024, 64 * 1024);
    const meta = try pm.registerPlugin(module, module_inst, "wasm-apps/bad_node.wasm", "wasm-apps/bad_node.json", wasm_buffer, &bus);

    // デモ中に .wasm が消えた/壊れた状況: 再起動時の読み込みが必ず失敗する
    allocator.free(meta.wasm_path);
    meta.wasm_path = try allocator.dupe(u8, "wasm-apps/__missing_for_test__.wasm");

    const thread = try std.Thread.spawn(.{}, event_bus.EventBus.runDispatcher, .{&bus});

    const func_init = wamr.wasm_runtime_lookup_function(module_inst, "on_init") orelse return error.FunctionNotFound;
    const env_init = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
    var argv_init = [_]u32{0};
    _ = wamr.wasm_runtime_call_wasm(env_init, func_init, 0, &argv_init);
    wamr.wasm_runtime_destroy_exec_env(env_init);

    // trap → 再起動 (失敗) → 停止扱い
    try bus.publish("allowed.topic", "TRAP", .BestEffort, 0);
    bus.waitIdle();

    // 旧実装ではここで meta が map から消え、次の配送で破棄済み instance に触れていた
    try std.testing.expect(pm.findByNodeId(100) != null);
    try std.testing.expect(pm.getMetadata(module_inst) != null);
    try std.testing.expectEqual(WasmSubscriber.MAX_RESTART_ATTEMPTS, meta.subscriber.?.consecutive_failures);

    // 以後の配送は無視され、クラッシュしない
    try bus.publish("allowed.topic", "HELLO", .BestEffort, 0);
    try bus.publish("allowed.topic", "TRAP", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expect(pm.getMetadata(module_inst) != null);

    bus.stop();
    thread.join();
    // pm.deinit が旧インスタンスを正しく解放する (testing allocator がリークを検出する)
}
