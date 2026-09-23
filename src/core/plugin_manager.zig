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
    manifest_parsed: std.json.Parsed(manifest.Manifest),
    /// 署名検証したバイト列からロードしたモジュール。プラグインの生涯を通じて保持し、再起動はここから
    /// インスタンスを作る。ディスクは読み直さないので、ロード後に .wasm を差し替えても未検証のコードは動かない。
    module: wamr.wasm_module_t,
    instance: wamr.wasm_module_inst_t,
    /// 予備インスタンス (R4)。再起動はこれとの差し替えで済ませ、使った後に次の予備を作る
    spare: ?wamr.wasm_module_inst_t = null,
    subscriber: ?WasmSubscriber = null,
    rate_limiter: RateLimiter = .{},
    /// rate_limited セキュリティイベントの集約 (1 秒に 1 件、間引いた件数を添える)
    rl_last_emit_ms: i64 = 0,
    rl_suppressed: u32 = 0,

    pub fn deinit(self: *PluginMetadata, allocator: std.mem.Allocator) void {
        if (self.subscriber) |*sub| sub.deinit();
        self.manifest_parsed.deinit();
        if (self.spare) |sp| wamr.wasm_runtime_deinstantiate(sp);
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
    /// plugins の排他。再起動はそのプラグインのセルのスレッドで表を書き換え、Host API は他のセルの
    /// スレッドから引くので必要。表の操作の間だけ持つ (保持したまま Wasm や購読処理を呼ばない)
    plugins_mutex: std.Thread.Mutex = .{},
    next_node_id: u32,
    runtime: ?*@import("wasm_runtime.zig").WasmRuntime = null, // 追加
    wasm_stack_size: u32 = 128 * 1024,
    wasm_heap_size: u32 = 64 * 1024,
    /// 毒メッセージの記録先 (R2)。null なら `core.node.poison` イベントだけ出す
    dlq_dir: ?[]const u8 = null,
    /// テスト用: 次の再起動でインスタンス生成を失敗させる (再起動失敗の経路を検証するため)
    test_fail_next_instantiate: bool = false,

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
        meta.subscriber.?.applyManifest(&parsed.value);
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

    /// 登録直後の初期化: on_init を呼び、状態領域を見つけて初期値をコミットし、予備インスタンスを用意する。
    /// 呼ぶ側は購読の前に呼ぶこと (Core.loadPlugin が使う)。
    pub fn initPlugin(self: *PluginManager, meta: *PluginMetadata) void {
        const sub = if (meta.subscriber) |*s| s else return;
        sub.mutex.lock();
        defer sub.mutex.unlock();
        const env = wamr.wasm_runtime_create_exec_env(meta.instance, 16384);
        if (env == null) return;
        defer wamr.wasm_runtime_destroy_exec_env(env);
        if (wamr.wasm_runtime_lookup_function(meta.instance, "on_init")) |func| {
            WasmSubscriber.setInstructionLimit(env, meta.manifest_parsed.value.limits.max_init_instructions);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
        }
        sub.discoverState(env);
        self.prepareSpare(meta);
    }

    fn instantiateFor(self: *PluginManager, meta: *const PluginMetadata) !wamr.wasm_module_inst_t {
        if (self.test_fail_next_instantiate) {
            self.test_fail_next_instantiate = false;
            return error.ModuleInstantiationFailed;
        }
        const runtime = self.runtime orelse return error.RuntimeNotSet;
        return runtime.instantiateLimited(meta.module, self.wasm_stack_size, self.wasm_heap_size, meta.manifest_parsed.value.limits.memory_pages);
    }

    /// 予備インスタンスを用意する (R4)。失敗しても致命的ではない (次の再起動でその場で作る)
    fn prepareSpare(self: *PluginManager, meta: *PluginMetadata) void {
        if (meta.spare != null) return;
        meta.spare = self.instantiateFor(meta) catch null;
    }

    /// 指定したノードを再起動する (Fault復旧用)
    ///
    /// - 予備インスタンスとの差し替えで済ませる (R4)。モジュールはロード済みのまま使い回すので、
    ///   ファイルの読み込み・検証・ロードは起きない (署名検証済みのコードだけが動く)。
    /// - 新しいインスタンスが用意できてから旧インスタンスと差し替える (P0-4)。用意できなければ
    ///   旧インスタンスをそのまま残し、ノードを停止扱いにする (破棄済みメモリに触れない)。
    /// - on_init の後、直前にコミットした状態を書き戻す (R5)。
    pub fn restartPlugin(self: *PluginManager, node_id: u32, bus: *event_bus.EventBus) !void {
        const meta = self.findByNodeId(node_id) orelse return error.NodeNotFound;

        // 1. 新インスタンス (予備があればそれ)。旧インスタンスにはまだ触らない
        const new_inst = if (meta.spare) |sp| blk: {
            meta.spare = null;
            break :blk sp;
        } else self.instantiateFor(meta) catch |err| {
            self.quarantine(meta, bus);
            return err;
        };

        // 2. 差し替え: map のキーを新インスタンスへ付け替えてから旧を破棄する
        const swap_err: ?std.mem.Allocator.Error = swap: {
            self.plugins_mutex.lock();
            defer self.plugins_mutex.unlock();
            _ = self.plugins.remove(meta.instance);
            self.plugins.put(new_inst, meta) catch |err| {
                self.plugins.put(meta.instance, meta) catch {};
                break :swap err;
            };
            break :swap null;
        };
        if (swap_err) |err| {
            wamr.wasm_runtime_deinstantiate(new_inst);
            self.quarantine(meta, bus);
            return err;
        }
        wamr.wasm_runtime_deinstantiate(meta.instance);
        meta.instance = new_inst;

        var needs_subscription = false;
        if (meta.subscriber) |*sub| {
            sub.updateInstance(new_inst);
        } else {
            meta.subscriber = try WasmSubscriber.init(new_inst, node_id, bus, self);
            meta.subscriber.?.applyManifest(&meta.manifest_parsed.value);
            needs_subscription = true;
        }

        // 3. 初期化 → 状態の書き戻し
        {
            const env = wamr.wasm_runtime_create_exec_env(new_inst, 16384);
            defer if (env != null) wamr.wasm_runtime_destroy_exec_env(env);
            if (env != null) {
                if (wamr.wasm_runtime_lookup_function(new_inst, "on_init")) |func| {
                    WasmSubscriber.setInstructionLimit(env, meta.manifest_parsed.value.limits.max_init_instructions);
                    var argv = [_]u32{0};
                    _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
                }
                if (meta.subscriber) |*sub| {
                    if (sub.state_valid) sub.restoreState(env) else sub.discoverState(env);
                }
            }
        }

        // 新規作成された場合のみ購読を適用（既存の購読はEventBusに残っているため）
        if (needs_subscription) {
            try self.applyManifestSubscriptions(new_inst, bus);
        }

        if (bus.graph) |g| {
            g.updateNodeStatus(node_id, .active);
        }
        std.debug.print("PluginManager: Node {} restarted successfully.\n", .{node_id});

        // 4. 次の予備を用意する
        self.prepareSpare(meta);
    }

    /// 再起動できなかったノードを停止扱いにする。旧インスタンスは有効なまま map に残るので
    /// 以後の配送で破棄済みメモリに触れることはなく、終了時の deinit で正しく解放される。
    fn quarantine(self: *PluginManager, meta: *PluginMetadata, bus: *event_bus.EventBus) void {
        _ = self;
        if (meta.subscriber) |*sub| sub.stop() else if (bus.graph) |g| g.updateNodeStatus(meta.node_id, .stopped);
        std.debug.print("PluginManager: Node {} could not be restarted; stopped (old instance kept, no deliveries).\n", .{meta.node_id});
    }

    /// 毒メッセージを DLQ (`<dlq_dir>/<node_id>.jsonl`) に 1 行追記する (R2)。payload は hex で持つ
    pub fn appendDlq(self: *PluginManager, node_id: u32, event_json: []const u8, payload: []const u8) void {
        const dir = self.dlq_dir orelse return;
        std.fs.cwd().makePath(dir) catch return;
        var path_buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{d}.jsonl", .{ dir, node_id }) catch return;
        const file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;
        const shown = payload[0..@min(payload.len, 4096)];
        const hex = std.fmt.allocPrint(self.allocator, "{x}", .{shown}) catch return;
        defer self.allocator.free(hex);
        const line = std.fmt.allocPrint(self.allocator, "{{\"event\":{s},\"payload_hex\":\"{s}\",\"payload_len\":{d}}}\n", .{ event_json, hex, payload.len }) catch return;
        defer self.allocator.free(line);
        file.writeAll(line) catch {};
    }

    pub const StateCopy = struct { name: []u8, bytes: []u8 };

    /// 全プラグインのコミット済み状態を複製する (スナップショット用, R7)
    ///
    /// ロックの順序: plugins_mutex の中ではメタデータへのポインタを集めるだけにし、手放してから
    /// 各プラグインの mutex を取る。再起動はプラグインの mutex を持ったまま plugins_mutex を取るので、
    /// 逆の順序で両方を持つとデッドロックする (スナップショットのスレッドは 200 ms ごとに走る)。
    /// メタデータ自体は PluginManager.deinit まで解放されない。
    pub fn copyCommittedStates(self: *PluginManager, a: std.mem.Allocator) ![]StateCopy {
        var metas: std.ArrayListUnmanaged(*PluginMetadata) = .{};
        defer metas.deinit(a);
        {
            self.plugins_mutex.lock();
            defer self.plugins_mutex.unlock();
            var it = self.plugins.valueIterator();
            while (it.next()) |m| try metas.append(a, m.*);
        }

        var list: std.ArrayListUnmanaged(StateCopy) = .{};
        errdefer {
            for (list.items) |c| {
                a.free(c.name);
                a.free(c.bytes);
            }
            list.deinit(a);
        }
        for (metas.items) |m| {
            const sub = if (m.subscriber) |*s| s else continue;
            sub.mutex.lock();
            defer sub.mutex.unlock();
            const st = sub.committedState() orelse continue;
            const name = try a.dupe(u8, m.manifest_parsed.value.name);
            errdefer a.free(name);
            const bytes = try a.dupe(u8, st);
            errdefer a.free(bytes);
            try list.append(a, .{ .name = name, .bytes = bytes });
        }
        const out = try list.toOwnedSlice(a);
        std.mem.sort(StateCopy, out, {}, struct {
            fn lt(_: void, x: StateCopy, y: StateCopy) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        return out;
    }

    pub fn freeStateCopies(a: std.mem.Allocator, list: []StateCopy) void {
        for (list) |c| {
            a.free(c.name);
            a.free(c.bytes);
        }
        a.free(list);
    }

    /// スナップショットの状態を名前の一致するプラグインに戻す (R7)。戻せたら true
    pub fn restoreCommittedState(self: *PluginManager, name: []const u8, bytes: []const u8) bool {
        const meta = blk: {
            self.plugins_mutex.lock();
            defer self.plugins_mutex.unlock();
            var it = self.plugins.valueIterator();
            while (it.next()) |m| {
                if (std.mem.eql(u8, m.*.manifest_parsed.value.name, name)) break :blk m.*;
            }
            return false;
        };
        const sub = if (meta.subscriber) |*s| s else return false;
        sub.mutex.lock();
        defer sub.mutex.unlock();
        return sub.setCommittedState(bytes);
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

    // 再起動時のインスタンス生成が失敗する状況 (メモリ不足など) を作る。予備インスタンスは無い
    try std.testing.expect(meta.spare == null);
    pm.test_fail_next_instantiate = true;

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
    try std.testing.expectEqual(@import("wasm_subscriber.zig").Breaker.stopped, meta.subscriber.?.breaker);

    // 以後の配送は無視され、クラッシュしない
    try bus.publish("allowed.topic", "HELLO", .BestEffort, 0);
    try bus.publish("allowed.topic", "TRAP", .BestEffort, 0);
    bus.waitIdle();
    try std.testing.expect(pm.getMetadata(module_inst) != null);

    bus.stop();
    thread.join();
    // pm.deinit が旧インスタンスを正しく解放する (testing allocator がリークを検出する)
}
