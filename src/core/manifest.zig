//! Manifest v1 — プラグインの権限・資源上限・所属セルの宣言。
//!
//! 変更点 (docs/v1_plan_2026-09.md §5.3, §5.5):
//! - `parse(bytes)` を正とする。署名検証に使ったのと同じバイト列をパースする (TOCTOU 対策 P1-1)。
//! - 予約名前空間 (`core.node.*` など) への publish 宣言は拒否 (P0-3)。
//! - PII を含みうるトピックの購読には `data_access: ["pii"]` が必要 (ADR-008 PR6)。
//! - `limits` で命令数・メモリ・状態サイズ・トピック数・メールボックスを宣言 (R3/R5/P0-1)。
//! - `restart` で再起動ポリシー (R1)。`config` はプラグインに `on_config` で渡す。

const std = @import("std");
const pattern = @import("pattern.zig");
const topics = @import("topics.zig");

pub const RestartPolicy = enum { always, on_failure, never };

pub const Limits = struct {
    /// on_message 1 回あたりの命令数上限 (無限ループ対策)
    max_instructions: u32 = 20_000_000,
    /// on_init / on_config の命令数上限
    max_init_instructions: u32 = 200_000_000,
    /// 線形メモリの上限 (64KiB ページ数)
    memory_pages: u32 = 256,
    /// 永続化する状態の最大バイト数
    state_bytes: u32 = 4096,
    /// publish できる異なるトピックの数
    max_topics: u32 = 64,
    /// 再起動中に溜めておけるメッセージ数
    mailbox: u32 = 256,
};

pub const Restart = struct {
    policy: RestartPolicy = .always,
    /// breaker が開く条件: この秒数以内に何回落ちたら隔離するか
    window_secs: u32 = 10,
    max_faults: u32 = 5,
    /// 隔離 (quarantine) の時間。経過後に half-open で 1 回試す
    quarantine_secs: u32 = 10,
};

pub const Manifest = struct {
    abi_version: u32 = 1,
    name: []const u8,
    version: []const u8,
    author: []const u8 = "",
    description: []const u8 = "",
    /// 希望する所属セル。信頼レベルが足りなければ untrusted に落とされる
    cell: ?[]const u8 = null,
    permissions: Permissions,
    /// 旧形式互換 (limits が無い manifest)
    rate_limit_eps: f64 = 0,
    limits: Limits = .{},
    restart: Restart = .{},
    config: ?std.json.Value = null,

    pub const Permissions = struct {
        publish: [][]const u8 = &.{},
        subscribe: [][]const u8 = &.{},
        /// 追加のデータ区分へのアクセス宣言 ("pii")
        data_access: [][]const u8 = &.{},
    };

    pub const Error = error{
        ManifestNameEmpty,
        ManifestNameInvalid,
        ManifestVersionEmpty,
        UnsupportedAbiVersion,
        PermissionTopicEmpty,
        PermissionTopicInvalid,
        GlobalPublishForbidden,
        ReservedTopicForbidden,
        PiiAccessNotDeclared,
    };

    /// バイト列からパースして検証する (呼び出し側が deinit)。
    pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(Manifest) {
        const parsed = try std.json.parseFromSlice(Manifest, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        errdefer parsed.deinit();
        try parsed.value.validate();
        return parsed;
    }

    /// ファイルから読み込む (テスト・ツール用)。
    pub fn load(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Manifest) {
        const content = try std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024);
        defer allocator.free(content);
        return parse(allocator, content);
    }

    pub fn validate(self: Manifest) Error!void {
        if (self.abi_version != 1) return error.UnsupportedAbiVersion;
        if (self.name.len == 0) return error.ManifestNameEmpty;
        if (self.name.len > 64) return error.ManifestNameInvalid;
        for (self.name) |c| {
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '-')) return error.ManifestNameInvalid;
        }
        if (self.version.len == 0) return error.ManifestVersionEmpty;

        for (self.permissions.publish) |p| {
            if (p.len == 0) return error.PermissionTopicEmpty;
            if (std.mem.eql(u8, p, "#")) return error.GlobalPublishForbidden;
            if (!pattern.validPattern(p)) return error.PermissionTopicInvalid;
            if (topics.touchesReserved(p)) return error.ReservedTopicForbidden;
        }
        for (self.permissions.subscribe) |s| {
            if (s.len == 0) return error.PermissionTopicEmpty;
            if (!pattern.validPattern(s)) return error.PermissionTopicInvalid;
            if (topics.touchesPii(s) and !self.hasDataAccess("pii")) return error.PiiAccessNotDeclared;
        }
    }

    pub fn hasDataAccess(self: Manifest, class: []const u8) bool {
        for (self.permissions.data_access) |d| if (std.mem.eql(u8, d, class)) return true;
        return false;
    }

    pub fn canPublish(self: Manifest, topic: []const u8) bool {
        for (self.permissions.publish) |p| if (pattern.isMatch(p, topic)) return true;
        return false;
    }

    /// 購読パターン s が宣言の範囲に収まっているか
    pub fn canSubscribe(self: Manifest, s: []const u8) bool {
        for (self.permissions.subscribe) |p| if (pattern.covers(p, s)) return true;
        return false;
    }

    /// 実世界を操作する (control 種別の) publish を宣言しているか
    pub fn requestsControl(self: Manifest) bool {
        for (self.permissions.publish) |p| if (topics.touchesControl(p)) return true;
        return false;
    }

    /// 実効レート上限 (旧形式の rate_limit_eps を尊重)
    pub fn rateLimit(self: Manifest) f64 {
        return self.rate_limit_eps;
    }
};

fn parseStr(json: []const u8) !std.json.Parsed(Manifest) {
    return Manifest.parse(std.testing.allocator, json);
}

test "manifest parse and ACL" {
    const p = try parseStr(
        \\{"name":"test-plugin","version":"1.0.0",
        \\ "permissions":{"publish":["sensor.temp","log.*"],"subscribe":["command.*"]}}
    );
    defer p.deinit();
    try std.testing.expectEqualStrings("test-plugin", p.value.name);
    try std.testing.expect(p.value.canPublish("sensor.temp"));
    try std.testing.expect(p.value.canPublish("log.info"));
    try std.testing.expect(!p.value.canPublish("sensor.hum"));
    try std.testing.expect(p.value.canSubscribe("command.start"));
    try std.testing.expect(p.value.canSubscribe("command.*"));
    try std.testing.expect(!p.value.canSubscribe("command.#")); // 宣言より広い購読は不可
    try std.testing.expect(!p.value.canSubscribe("event.any"));
    try std.testing.expectEqual(@as(u32, 20_000_000), p.value.limits.max_instructions);
}

test "manifest: invalid manifests are rejected" {
    try std.testing.expectError(error.ManifestNameEmpty, parseStr(
        \\{"name":"","version":"1","permissions":{"publish":[],"subscribe":[]}}
    ));
    try std.testing.expectError(error.GlobalPublishForbidden, parseStr(
        \\{"name":"h","version":"1","permissions":{"publish":["#"],"subscribe":[]}}
    ));
    try std.testing.expectError(error.PermissionTopicEmpty, parseStr(
        \\{"name":"b","version":"1","permissions":{"publish":[""],"subscribe":[]}}
    ));
    try std.testing.expectError(error.ManifestNameInvalid, parseStr(
        \\{"name":"bad\"name","version":"1","permissions":{"publish":[],"subscribe":[]}}
    ));
}

test "manifest: reserved namespaces cannot be published by plugins" {
    try std.testing.expectError(error.ReservedTopicForbidden, parseStr(
        \\{"name":"forger","version":"1","permissions":{"publish":["core.node.fault"],"subscribe":[]}}
    ));
    try std.testing.expectError(error.ReservedTopicForbidden, parseStr(
        \\{"name":"forger","version":"1","permissions":{"publish":["core.#"],"subscribe":[]}}
    ));
    const ok = try parseStr(
        \\{"name":"obsctl","version":"1","permissions":{"publish":["core.obs.request.SetSceneItemEnabled"],"subscribe":[]}}
    );
    defer ok.deinit();
    try std.testing.expect(ok.value.requestsControl());
}

test "manifest: PII subscriptions require data_access" {
    try std.testing.expectError(error.PiiAccessNotDeclared, parseStr(
        \\{"name":"c","version":"1","permissions":{"publish":[],"subscribe":["ext.twitch.chat.message"]}}
    ));
    const ok = try parseStr(
        \\{"name":"c","version":"1","permissions":{"publish":[],"subscribe":["ext.twitch.chat.message"],"data_access":["pii"]}}
    );
    ok.deinit();
}

test "manifest: limits, restart and config" {
    const p = try parseStr(
        \\{"name":"k","version":"1","cell":"plugins.untrusted",
        \\ "permissions":{"publish":["ext.k.out"],"subscribe":["core.system.tick"]},
        \\ "limits":{"max_instructions":1000,"memory_pages":16},
        \\ "restart":{"policy":"on_failure","max_faults":3},
        \\ "config":{"threshold":10}}
    );
    defer p.deinit();
    try std.testing.expectEqual(@as(u32, 1000), p.value.limits.max_instructions);
    try std.testing.expectEqual(@as(u32, 16), p.value.limits.memory_pages);
    try std.testing.expectEqual(@as(u32, 4096), p.value.limits.state_bytes);
    try std.testing.expectEqual(RestartPolicy.on_failure, p.value.restart.policy);
    try std.testing.expectEqualStrings("plugins.untrusted", p.value.cell.?);
    try std.testing.expect(p.value.config != null);
}
