//! 利用者による承認 — トラストアンカー Stage 0 (TOFU)
//!
//! 「誰が権限の妥当さを保証するのか」への答えの 1 段目。
//!   作者が manifest で権限を **申告** する → 利用者が `weave add` で人の言葉の説明と影響範囲を見て **承認** する
//!   → Core が起動時に、承認したときから **権限が増えていないか** を確かめる → (Stage 1) 署名で作者を確かめる
//!
//! 記録 (.weave/approved.json) には、承認した時点の権限と wasm+manifest のダイジェストを残す。
//!   - ダイジェストが同じ                         → 承認済み
//!   - ダイジェストは違うが、権限は増えていない     → コードの更新として通す (記録は承認時のまま)
//!   - 承認されていない / 権限が増えた             → strict なら読み込まない。スマホアプリの権限と同じ考え方で、
//!                                                   増えた分だけを見せて再承認を求める
//! 権限の比較は文字列の完全一致で行う (パターンの包含で緩めない: 「増えたかもしれない」は増えたとみなす)。

const std = @import("std");
const signing = @import("signing.zig");

pub const DEFAULT_PATH = ".weave/approved.json";

pub const Mode = enum {
    off,
    /// 確かめるが、未承認でも警告だけで読み込む
    warn,
    /// 未承認・権限が増えたものは読み込まない
    strict,

    pub fn parse(s: []const u8) ?Mode {
        return std.meta.stringToEnum(Mode, s);
    }
};

pub const Permissions = struct {
    publish: []const []const u8 = &.{},
    subscribe: []const []const u8 = &.{},
    data_access: []const []const u8 = &.{},
};

pub const Entry = struct {
    name: []const u8,
    version: []const u8 = "",
    /// wasm の場所 (絶対パス)。プラグインを指定せずに weave run すると、ここにあるものを起動する
    path: []const u8 = "",
    /// wasm + manifest の SHA-512 (signing.computeDigest) の 16 進
    digest: []const u8,
    permissions: Permissions,
    approved_at: i64 = 0,
};

/// manifest から承認に要る部分だけを読む
pub const ManifestView = struct {
    name: []const u8,
    version: []const u8 = "",
    permissions: Permissions = .{},
};

pub fn parseManifest(arena: std.mem.Allocator, bytes: []const u8) !ManifestView {
    return std.json.parseFromSliceLeaky(ManifestView, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn digestHex(arena: std.mem.Allocator, wasm: []const u8, manifest: []const u8) ![]u8 {
    const d = signing.computeDigest(wasm, manifest);
    return signing.toHex(arena, &d);
}

pub const Store = struct {
    entries: std.ArrayListUnmanaged(Entry) = .{},

    const FileShape = struct { version: u32 = 1, plugins: []Entry = &.{} };

    /// ファイルが無ければ空の記録 (まだ何も承認していない)
    pub fn load(arena: std.mem.Allocator, path: []const u8) !Store {
        const bytes = std.fs.cwd().readFileAlloc(arena, path, 4 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return .{},
            else => return err,
        };
        const parsed = try std.json.parseFromSliceLeaky(FileShape, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        var s = Store{};
        try s.entries.appendSlice(arena, parsed.plugins);
        return s;
    }

    pub fn find(self: *const Store, name: []const u8) ?Entry {
        for (self.entries.items) |e| if (std.mem.eql(u8, e.name, name)) return e;
        return null;
    }

    pub fn remove(self: *Store, name: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn upsert(self: *Store, arena: std.mem.Allocator, e: Entry) !void {
        for (self.entries.items) |*old| {
            if (std.mem.eql(u8, old.name, e.name)) {
                old.* = e;
                return;
            }
        }
        try self.entries.append(arena, e);
    }

    /// 書き出しは一時ファイル → rename (途中で落ちても記録が壊れない)
    pub fn save(self: *const Store, arena: std.mem.Allocator, path: []const u8) !void {
        if (std.fs.path.dirname(path)) |d| try std.fs.cwd().makePath(d);
        var out = std.ArrayListUnmanaged(u8){};
        try out.writer(arena).print("{f}\n", .{std.json.fmt(FileShape{ .plugins = self.entries.items }, .{ .whitespace = .indent_2 })});
        const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
        try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = out.items });
        try std.fs.cwd().rename(tmp, path);
    }
};

pub const Added = struct {
    publish: []const []const u8,
    subscribe: []const []const u8,
    data_access: []const []const u8,

    pub fn isEmpty(self: Added) bool {
        return self.publish.len == 0 and self.subscribe.len == 0 and self.data_access.len == 0;
    }
};

fn missingFrom(arena: std.mem.Allocator, now: []const []const u8, before: []const []const u8) ![]const []const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    outer: for (now) |n| {
        for (before) |b| if (std.mem.eql(u8, n, b)) continue :outer;
        try out.append(arena, n);
    }
    return out.toOwnedSlice(arena);
}

/// 承認したときから増えた権限
pub fn added(arena: std.mem.Allocator, approved: Permissions, now: Permissions) !Added {
    return .{
        .publish = try missingFrom(arena, now.publish, approved.publish),
        .subscribe = try missingFrom(arena, now.subscribe, approved.subscribe),
        .data_access = try missingFrom(arena, now.data_access, approved.data_access),
    };
}

pub const Verdict = union(enum) {
    /// 承認したときと同じもの
    approved,
    /// コードは変わったが、権限は増えていない
    updated,
    /// まだ承認されていない
    not_approved,
    /// 権限が増えた (増えた分)
    permissions_increased: Added,
};

pub fn check(arena: std.mem.Allocator, store: *const Store, m: ManifestView, digest: []const u8) !Verdict {
    const e = store.find(m.name) orelse return .not_approved;
    if (std.mem.eql(u8, e.digest, digest)) return .approved;
    const a = try added(arena, e.permissions, m.permissions);
    return if (a.isEmpty()) .updated else .{ .permissions_increased = a };
}

// ------------------------------------------------------------------ 人の言葉での説明

pub const Weight = enum { normal, sensitive, strong };

pub const Description = struct { text: []const u8, weight: Weight };

/// 購読 (受け取る) パターンの説明
pub fn describeSubscribe(p: []const u8) Description {
    if (startsWith(p, "ext.twitch.chat") or startsWith(p, "ext.chat")) return .{ .text = "チャットの本文を読む (個人情報を含む)", .weight = .sensitive };
    if (startsWith(p, "ext.twitch.")) return .{ .text = "Twitch のイベントを受け取る", .weight = .normal };
    if (startsWith(p, "ext.streamelements.") or startsWith(p, "ext.streamlabs.")) return .{ .text = "フォロー・サブ・投げ銭などのイベントを受け取る", .weight = .sensitive };
    if (eql(p, "core.system.tick")) return .{ .text = "時刻 (一定間隔の合図) を受け取る", .weight = .normal };
    if (startsWith(p, "core.obs.event")) return .{ .text = "OBS の状態の変化を受け取る", .weight = .normal };
    if (eql(p, "#") or startsWith(p, "core.")) return .{ .text = "WEAVE 内部のイベントを受け取る", .weight = .strong };
    return .{ .text = "ほかのプラグインのイベントを受け取る", .weight = .normal };
}

/// 発行 (出す) パターンの説明
pub fn describePublish(p: []const u8) Description {
    const pre = "core.obs.request.";
    if (startsWith(p, pre)) {
        const r = p[pre.len..];
        if (eql(r, "*") or eql(r, "#")) return .{ .text = "OBS をすべて操作する (配信の停止も含む)", .weight = .strong };
        if (eql(r, "StopStream") or eql(r, "StartStream") or eql(r, "StopRecord") or eql(r, "StartRecord"))
            return .{ .text = "配信・録画を始める / 止める", .weight = .strong };
        if (eql(r, "SetCurrentProgramScene")) return .{ .text = "OBS のシーンを切り替える", .weight = .sensitive };
        if (eql(r, "SetSceneItemEnabled")) return .{ .text = "配信画面の表示 (ソースの表示 / 非表示) を変える", .weight = .sensitive };
        if (eql(r, "SetInputSettings")) return .{ .text = "配信画面の文字などの中身を変える", .weight = .sensitive };
        if (eql(r, "SetInputMute")) return .{ .text = "音声をミュート / 解除する", .weight = .sensitive };
        return .{ .text = "OBS を操作する", .weight = .sensitive };
    }
    if (startsWith(p, "core.")) return .{ .text = "WEAVE 内部のイベントを出す (予約名のため実際には拒否される)", .weight = .strong };
    return .{ .text = "自分のイベントを出す (ほかのプラグイン向け)", .weight = .normal };
}

pub fn describeDataAccess(d: []const u8) Description {
    if (eql(d, "pii")) return .{ .text = "個人情報 (チャットの本文・ユーザー名) に触れる", .weight = .sensitive };
    return .{ .text = d, .weight = .normal };
}

fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}
fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ------------------------------------------------------------------ テスト

test "check: same digest → approved, code-only change → updated, new permission → increased (only the new part)" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    var store = Store{};
    try store.upsert(a, .{ .name = "subgoal", .digest = "aaaa", .permissions = .{
        .publish = &.{"core.obs.request.SetInputSettings"},
        .subscribe = &.{"ext.twitch.chat.message"},
        .data_access = &.{"pii"},
    } });
    const same = ManifestView{ .name = "subgoal", .permissions = .{ .publish = &.{"core.obs.request.SetInputSettings"}, .subscribe = &.{"ext.twitch.chat.message"}, .data_access = &.{"pii"} } };
    try std.testing.expect((try check(a, &store, same, "aaaa")) == .approved);
    try std.testing.expect((try check(a, &store, same, "bbbb")) == .updated);

    const more = ManifestView{ .name = "subgoal", .permissions = .{ .publish = &.{ "core.obs.request.SetInputSettings", "core.obs.request.StopStream" }, .subscribe = &.{"ext.twitch.chat.message"}, .data_access = &.{"pii"} } };
    const v = try check(a, &store, more, "cccc");
    try std.testing.expect(v == .permissions_increased);
    try std.testing.expectEqual(@as(usize, 1), v.permissions_increased.publish.len);
    try std.testing.expectEqualStrings("core.obs.request.StopStream", v.permissions_increased.publish[0]);
    try std.testing.expectEqual(@as(usize, 0), v.permissions_increased.subscribe.len);

    // 権限を減らしただけなら、コードの更新として通す
    const fewer = ManifestView{ .name = "subgoal", .permissions = .{ .publish = &.{}, .subscribe = &.{"ext.twitch.chat.message"} } };
    try std.testing.expect((try check(a, &store, fewer, "dddd")) == .updated);

    try std.testing.expect((try check(a, &store, .{ .name = "unknown" }, "eeee")) == .not_approved);
}

test "Store: save → load keeps the approved permissions and digest" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try tmp.dir.realpath(".", &buf);
    const path = try std.fmt.allocPrint(a, "{s}/sub/approved.json", .{dir});

    var s = Store{};
    try s.upsert(a, .{ .name = "x", .version = "1.0.0", .digest = "abcd", .permissions = .{ .publish = &.{"ext.x.out"} }, .approved_at = 42 });
    try s.save(a, path);
    const t = try Store.load(a, path);
    const e = t.find("x").?;
    try std.testing.expectEqualStrings("abcd", e.digest);
    try std.testing.expectEqualStrings("ext.x.out", e.permissions.publish[0]);
    try std.testing.expectEqual(@as(i64, 42), e.approved_at);

    // 記録がまだ無い = 何も承認していない
    const empty = try Store.load(a, try std.fmt.allocPrint(a, "{s}/none.json", .{dir}));
    try std.testing.expect(empty.find("x") == null);
}

test "describe: strong permissions are called out" {
    try std.testing.expectEqual(Weight.strong, describePublish("core.obs.request.StopStream").weight);
    try std.testing.expectEqual(Weight.strong, describePublish("core.obs.request.*").weight);
    try std.testing.expectEqual(Weight.sensitive, describeSubscribe("ext.twitch.chat.message").weight);
    try std.testing.expectEqual(Weight.normal, describePublish("ext.score.update").weight);
}
