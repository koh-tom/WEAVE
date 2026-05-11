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
        const file_content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(file_content);

        const parsed = try std.json.parseFromSlice(Manifest, allocator, file_content, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();

        // バリデーションの実行
        try parsed.value.validate();

        return parsed;
    }

    /// マニフェストの内容を検証する
    pub fn validate(self: Manifest) !void {
        if (self.name.len == 0) return error.ManifestNameEmpty;
        if (self.version.len == 0) return error.ManifestVersionEmpty;

        // 1. 空トピック定義の禁止
        for (self.permissions.publish) |p| {
            if (p.len == 0) return error.PermissionTopicEmpty;
            // 2. publish でのグローバルワイルドカード「#」の禁止 (セキュリティポリシー)
            if (std.mem.eql(u8, p, "#")) return error.GlobalPublishForbidden;
        }

        for (self.permissions.subscribe) |s| {
            if (s.len == 0) return error.PermissionTopicEmpty;
        }
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
    fn matchTopic(pattern: []const u8, topic: []const u8) bool {
        return @import("event_bus.zig").EventBus.isMatch(pattern, topic);
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

test "manifest: invalid manifest" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "",
        \\  "version": "1.0.0",
        \\  "permissions": { "publish": [], "subscribe": [] }
        \\}
    ;

    const parsed = std.json.parseFromSlice(Manifest, allocator, json, .{}) catch unreachable;
    defer parsed.deinit();

    try std.testing.expectError(error.ManifestNameEmpty, parsed.value.validate());
}

test "manifest: strict semantic validations" {
    const allocator = std.testing.allocator;

    // 1. publish に "#" を指定したマニフェスト (GlobalPublishForbidden エラーになるべき)
    const json_global_pub =
        \\{
        \\  "name": "hacker-plugin",
        \\  "version": "1.0.0",
        \\  "permissions": {
        \\    "publish": ["#"],
        \\    "subscribe": ["some.topic"]
        \\  }
        \\}
    ;
    const parsed_global = try std.json.parseFromSlice(Manifest, allocator, json_global_pub, .{
        .allocate = .alloc_always,
    });
    defer parsed_global.deinit();
    try std.testing.expectError(error.GlobalPublishForbidden, parsed_global.value.validate());

    // 2. 空のトピック文字列を含むマニフェスト (PermissionTopicEmpty エラーになるべき)
    const json_empty_topic =
        \\{
        \\  "name": "buggy-plugin",
        \\  "version": "1.0.0",
        \\  "permissions": {
        \\    "publish": [""],
        \\    "subscribe": []
        \\  }
        \\}
    ;
    const parsed_empty = try std.json.parseFromSlice(Manifest, allocator, json_empty_topic, .{
        .allocate = .alloc_always,
    });
    defer parsed_empty.deinit();
    try std.testing.expectError(error.PermissionTopicEmpty, parsed_empty.value.validate());
}
