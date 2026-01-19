const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const manifest = @import("manifest.zig");
const WasmSubscriber = @import("wasm_subscriber.zig").WasmSubscriber;

pub const PluginMetadata = struct {
    node_id: u32,
    manifest_parsed: std.json.Parsed(manifest.Manifest),
    instance: wamr.wasm_module_inst_t,
    subscriber: ?WasmSubscriber = null, // 追加: このプラグイン用の購読ハンドラ

    pub fn deinit(self: *PluginMetadata) void {
        if (self.subscriber) |*sub| sub.deinit();
        self.manifest_parsed.deinit();
    }
};

pub const PluginManager = struct {
    allocator: std.mem.Allocator,
    plugins: std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata),
    next_node_id: u32,

    pub fn init(allocator: std.mem.Allocator) PluginManager {
        return PluginManager{
            .allocator = allocator,
            .plugins = std.AutoHashMap(wamr.wasm_module_inst_t, *PluginMetadata).init(allocator),
            .next_node_id = 100,
        };
    }

    pub fn deinit(self: *PluginManager) void {
        var it = self.plugins.valueIterator();
        while (it.next()) |p| {
            p.*.deinit();
            self.allocator.destroy(p.*);
        }
        self.plugins.deinit();
    }

    /// プラグインを管理テーブルに登録する
    pub fn registerPlugin(self: *PluginManager, instance: wamr.wasm_module_inst_t, manifest_path: []const u8) !*PluginMetadata {
        const parsed = try manifest.Manifest.load(self.allocator, manifest_path);
        errdefer parsed.deinit();

        const meta = try self.allocator.create(PluginMetadata);
        meta.* = .{
            .node_id = self.next_node_id,
            .manifest_parsed = parsed,
            .instance = instance,
            .subscriber = try WasmSubscriber.init(instance),
        };
        self.next_node_id += 1;

        try self.plugins.put(instance, meta);
        return meta;
    }

    pub fn getMetadata(self: *PluginManager, instance: wamr.wasm_module_inst_t) ?*PluginMetadata {
        return self.plugins.get(instance);
    }
};
