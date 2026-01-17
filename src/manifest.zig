const std = @import("std");

pub const Manifest = struct {
    name: []const u8,
    version: []const u8,
    permissions: Permissions,

    pub const Permissions = struct {
        publish: [][]const u8,
        subscribe: [][]const u8,
    };

    /// JSONファイルからマニフェストを読み込む
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Manifest) {
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024);
        defer allocator.free(content);

        return std.json.parseFromSlice(Manifest, allocator, content, .{
            .ignore_unknown_fields = true,
        });
    }

    /// 特定のトピックへのPublish権限があるかチェック
    pub fn canPublish(self: Manifest, topic: []const u8) bool {
        for (self.permissions.publish) |p| {
            if (std.mem.eql(u8, p, topic) or std.mem.eql(u8, p, "*")) return true;
        }
        return false;
    }

    /// 特定のトピックへのSubscribe権限があるかチェック
    pub fn canSubscribe(self: Manifest, topic: []const u8) bool {
        for (self.permissions.subscribe) |s| {
            if (std.mem.eql(u8, s, topic) or std.mem.eql(u8, s, "*")) return true;
        }
        return false;
    }
};

test "manifest parse test" {
    const allocator = std.testing.allocator;
    const json_text =
        \\{
        \\  "name": "test-plugin",
        \\  "version": "1.0.0",
        \\  "permissions": {
        \\    "publish": ["sensor.temp", "log.*"],
        \\    "subscribe": ["command.*"]
        \\  }
        \\}
    ;

    const parsed = try std.json.parseFromSlice(Manifest, allocator, json_text, .{});
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-plugin", parsed.value.name);
    try std.testing.expect(parsed.value.canPublish("sensor.temp"));
    try std.testing.expect(!parsed.value.canPublish("other.topic"));
    // ワイルドカードの簡易実装 (完全な正規表現ではないが、現時点では完全一致または"*"を想定)
}
