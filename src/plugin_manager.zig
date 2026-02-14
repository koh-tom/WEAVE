const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const manifest = @import("manifest.zig");
const event_bus = @import("event_bus.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;

pub const PluginMetadata = struct {
    node_id: u32,
    wasm_path: []const u8, // 追加: 再起動用
    manifest_path: []const u8, // 追加: 再起動用
    manifest_parsed: std.json.Parsed(manifest.Manifest),
    instance: wamr.wasm_module_inst_t,
    subscriber: ?WasmSubscriber = null,

    pub fn deinit(self: *PluginMetadata, allocator: std.mem.Allocator) void {
        if (self.subscriber) |*sub| sub.deinit();
        self.manifest_parsed.deinit();
        allocator.free(self.wasm_path);
        allocator.free(self.manifest_path);
    }
};

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata),
    next_node_id: u32,
    runtime: ?*@import("wasm_runtime.zig").WasmRuntime = null, // 追加

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return PluginManager{
            .allocator = allocator,
            .plugins = std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata).init(allocator),
            .next_node_id = 100,
            .runtime = null,
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
    pub fn registerPlugin(self: *PluginManager, instance: wamr.wasm_module_inst_t, wasm_path: []const u8, manifest_path: []const u8, bus: *event_bus.EventBus) !*PluginMetadata {
        const parsed = try manifest.Manifest.load(self.allocator, manifest_path);
        errdefer parsed.deinit();

        const node_id = self.next_node_id;
        const meta = try self.allocator.create(PluginMetadata);
        meta.* = .{
            .node_id = node_id,
            .wasm_path = try self.allocator.dupe(u8, wasm_path),
            .manifest_path = try self.allocator.dupe(u8, manifest_path),
            .manifest_parsed = parsed,
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

        // 1. 旧インスタンスの破棄
        if (meta.subscriber) |*sub| sub.deinit();
        wamr.wasm_runtime_deinstantiate(meta.instance);

        // 2. 新インスタンスの作成
        const wasm_buffer = try std.fs.cwd().readFileAlloc(self.allocator, meta.wasm_path, 1024 * 1024);
        defer self.allocator.free(wasm_buffer);

        const module = try runtime.loadModule(wasm_buffer);
        // Note: モジュール管理の詳細は簡略化
        const new_inst = try runtime.instantiate(module, 64 * 1024, 64 * 1024);

        // 3. メタデータの更新
        meta.instance = new_inst;
        meta.subscriber = try WasmSubscriber.init(new_inst, node_id, bus, self);
        try self.plugins.put(new_inst, meta);

        // 4. 初期化と購読再開
        if (wamr.wasm_runtime_lookup_function(new_inst, "on_init")) |func| {
            const env = wamr.wasm_runtime_create_exec_env(new_inst, 16384);
            defer wamr.wasm_runtime_destroy_exec_env(env);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
        }

        try self.applyManifestSubscriptions(new_inst, bus);
        
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
