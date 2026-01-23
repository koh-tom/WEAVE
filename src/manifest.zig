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

        // .allocate = .alloc_always を指定して、入力バッファから文字列をコピーさせる
        return std.json.parseFromSlice(Manifest, allocator, content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
    }

    /// 特定のトピックへのPublish権限があるかチェック
    pub fn canPublish(self: Manifest, topic: []const u8) bool {
        for (self.permissions.publish) |p| {
            if (matchTopic(p, topic)) return true;
        }
        return false;
    }

    /// 特定のトピックへのSubscribe権限があるかチェック
    pub fn canSubscribe(self: Manifest, topic: []const u8) bool {
        for (self.permissions.subscribe) |s| {
            if (matchTopic(s, topic)) return true;
        }
        return false;
    }

    /// トピックのマッチング判定
    /// - 完全一致: "a.b.c" == "a.b.c"
    /// - グローバルワイルドカード: "*" matches anything
    /// - プレフィックスワイルドカード: "a.b.*" matches "a.b.c", "a.b.d", etc.
    fn matchTopic(pattern: []const u8, topic: []const u8) bool {
        if (std.mem.eql(u8, pattern, "*")) return true;
        if (std.mem.endsWith(u8, pattern, ".*")) {
            const prefix = pattern[0 .. pattern.len - 1]; // "a.b."
            return std.mem.startsWith(u8, topic, prefix);
        }
        return std.mem.eql(u8, pattern, topic);
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

    const parsed = try std.json.parseFromSlice(Manifest, allocator, json_text, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("test-plugin", parsed.value.name);
    try std.testing.expect(parsed.value.canPublish("sensor.temp"));
    try std.testing.expect(parsed.value.canPublish("log.info")); // wildcard log.*
    try std.testing.expect(parsed.value.canPublish("log.error"));
    try std.testing.expect(!parsed.value.canPublish("sensor.hum"));
    try std.testing.expect(parsed.value.canSubscribe("command.start")); // wildcard command.*
    try std.testing.expect(!parsed.value.canSubscribe("event.any"));
}
