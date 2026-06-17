const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const manifest = @import("manifest.zig");
const event_bus = @import("event_bus.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;

pub const PluginMetadata = struct {
    node_id: u32,
    wasm_path: []const u8, // 追加: 再起動用
    manifest_path: []const u8, // 追加: 再起動用
    wasm_buffer: []const u8, // WAMR要求によりメモリに保持
    manifest_parsed: std.json.Parsed(manifest.Manifest),
    module: wamr.wasm_module_t,
    instance: wamr.wasm_module_inst_t,
    subscriber: ?WasmSubscriber = null,

    pub fn deinit(self: *PluginMetadata, allocator: std.mem.Allocator) void {
        if (self.subscriber) |*sub| sub.deinit();
        self.manifest_parsed.deinit();
        wamr.wasm_runtime_deinstantiate(self.instance);
        wamr.wasm_runtime_unload(self.module);
        allocator.free(self.wasm_path);
        allocator.free(self.manifest_path);
        allocator.free(self.wasm_buffer);
    }
};

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata),
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
        const parsed = try manifest.Manifest.load(self.allocator, manifest_path);
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
        };
        self.next_node_id += 1;

        try self.plugins.put(instance, meta);
        return meta;
    }

    pub fn getMetadata(self: *PluginManager, instance: wamr.wasm_module_inst_t) ?*PluginMetadata {
        return self.plugins.get(instance);
    }

    /// 指定したノードを再起動する (Fault復旧用)
    pub fn restartPlugin(self: *PluginManager, node_id: u32, bus: *event_bus.EventBus) !void {
        var it = self.plugins.iterator();
        var target_meta: ?*PluginMetadata = null;
        while (it.next()) |entry| {
            if (entry.value_ptr.*.node_id == node_id) {
                target_meta = entry.value_ptr.*;
                _ = self.plugins.remove(entry.key_ptr.*);
                break;
            }
        }

        const meta = target_meta orelse return error.NodeNotFound;
        const runtime = self.runtime orelse return error.RuntimeNotSet;

        std.debug.print("PluginManager: Restarting Node {} ({s})...\n", .{ node_id, meta.wasm_path });

        // 1. 旧インスタンスおよびモジュールの破棄
        // WasmSubscriberはEventBusに登録済みのポインタを維持するためdeinitしない
        wamr.wasm_runtime_deinstantiate(meta.instance);
        wamr.wasm_runtime_unload(meta.module);

        // 2. 新インスタンスの作成
        const wasm_buffer = try std.fs.cwd().readFileAlloc(self.allocator, meta.wasm_path, 1024 * 1024);
        errdefer self.allocator.free(wasm_buffer);

        const module = try runtime.loadModule(wasm_buffer);
        const new_inst = try runtime.instantiate(module, self.wasm_stack_size, self.wasm_heap_size);

        // 3. メタデータの更新 (wasm_bufferおよびモジュールの差し替え)
        self.allocator.free(meta.wasm_buffer);
        meta.wasm_buffer = wasm_buffer;
        meta.module = module;
        meta.instance = new_inst;
        var needs_subscription = false;
        if (meta.subscriber) |*sub| {
            sub.updateInstance(new_inst);
        } else {
            meta.subscriber = try WasmSubscriber.init(new_inst, node_id, bus, self);
            needs_subscription = true;
        }
        try self.plugins.put(new_inst, meta);

        // 4. 初期化と購読再開
        if (wamr.wasm_runtime_lookup_function(new_inst, "on_init")) |func| {
            const env = wamr.wasm_runtime_create_exec_env(new_inst, 16384);
            defer wamr.wasm_runtime_destroy_exec_env(env);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
        }

        // 新規作成された場合のみ購読を適用（既存の購読はEventBusに残っているため）
        if (needs_subscription) {
            try self.applyManifestSubscriptions(new_inst, bus);
        }

        if (bus.graph) |g| {
            g.updateNodeStatus(node_id, .active);
        }
        std.debug.print("PluginManager: Node {} restarted successfully.\n", .{node_id});
    }

    /// マニフェストに記載された購読トピックをEventBusに自動登録する
    pub fn applyManifestSubscriptions(self: *PluginManager, instance: wamr.wasm_module_inst_t, bus: *event_bus.EventBus) !void {
        const meta = self.getMetadata(instance) orelse return error.PluginNotFound;
        const sub_ptr = if (meta.subscriber) |*s| s else return;

        for (meta.manifest_parsed.value.permissions.subscribe) |topic| {
            try bus.subscribe(topic, meta.node_id, WasmSubscriber.callback, sub_ptr);
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

    // 再起動時の on_init 内で dynamic subscribe が再度実行されて 2 重購読となるため、
    // HELLO パブリッシュによって WasmSubscriber が 2 回呼び出され、計 2 回のメトリクスが送信されます。
    try std.testing.expectEqual(@as(u32, 2), metrics_count);

    // 新インスタンスの連続失敗カウンタが、成功によりリセット（0）されたことを検証
    if (meta_after_restart.subscriber) |sub| {
        try std.testing.expectEqual(@as(u32, 0), sub.consecutive_failures);
    }

    bus.stop();
    thread.join();
}
