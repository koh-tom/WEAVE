const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;
const manifest = @import("manifest.zig");

pub const PluginMetadata = struct {
    node_id: u32,
    manifest_parsed: std.json.Parsed(manifest.Manifest),
    instance: wamr.wasm_module_inst_t,

    pub fn deinit(self: *PluginMetadata) void {
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
            .next_node_id = 100, // プラグインは100番から開始 (0-99はシステム予約)
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
        };
        self.next_node_id += 1;

        try self.plugins.put(instance, meta);
        return meta;
    }

    /// Wasmインスタンスからメタデータを取得する (Host API内で使用)
    pub fn getMetadata(self: *PluginManager, instance: wamr.wasm_module_inst_t) ?*PluginMetadata {
        return self.plugins.get(instance);
    }
};

test "plugin manager registration test" {
    const allocator = std.testing.allocator;
    var pm = PluginManager.init(allocator);
    defer pm.deinit();

    // 実際にはファイルが必要なので、テスト用のダミーマニフェストファイルを作成するか、
    // ここではロジックの構造確認のみとする。
    // (manifest.zig のテストで中身のパースは保証されている)
}
