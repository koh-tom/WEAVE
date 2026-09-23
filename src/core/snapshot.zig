//! スナップショット (R7): Core が落ちて再起動しても、配信の状態を元に戻すための記録。
//!
//! 記録するもの:
//!   - OBS に対して WEAVE が意図した状態 (表示切替・シーン切替など)
//!   - 保持されている OBS の状態イベント (core.obs.event.*) — 元のタイムスタンプ付き
//! 復元すると:
//!   - 実 OBS: 意図した状態が ObsEgress に戻り、接続時に再適用される
//!   - mock OBS: 意図した状態を要求として発行し直す
//!   - 状態イベントが保持され直すので、プラグインは購読した瞬間に「今の状態」を受け取れる
//!     (kusa はこれで表示中かどうかを取り戻し、自動非表示が正しく来る)
//!
//! 書き込みは tmp → fsync → rename で原子的に行い、途中で落ちても壊れたファイルを残さない。

const std = @import("std");
const event_bus = @import("event_bus.zig");
const obs = @import("../builtin/obs.zig");
const log = @import("../common/log.zig");

pub const VERSION: u32 = 1;

const Entry = struct { topic: []const u8, payload: []const u8, ts: i64 = 0 };
const Desired = struct { request_type: []const u8, data: []const u8 };
const FileShape = struct {
    version: u32,
    saved_at: i64,
    obs_desired: []Desired = &.{},
    retained: []Entry = &.{},
};

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    bus: *event_bus.EventBus,
    desired: ?*obs.DesiredState,
    interval_ms: u64 = 200,

    thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_hash: u64 = 0,
    writes: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, bus: *event_bus.EventBus, desired: ?*obs.DesiredState) Snapshot {
        return .{ .allocator = allocator, .path = path, .bus = bus, .desired = desired };
    }

    fn keepTopic(topic: []const u8) bool {
        return std.mem.startsWith(u8, topic, "core.obs.event.");
    }

    /// 現在の状態を JSON にする (呼び出し側が free)
    pub fn collect(self: *Snapshot, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .{};
        errdefer out.deinit(allocator);
        const w = out.writer(allocator);
        try w.print("{{\"version\":{d},\"saved_at\":{d},\"obs_desired\":[", .{ VERSION, std.time.milliTimestamp() });
        if (self.desired) |d| {
            const entries = try d.copies(allocator);
            defer obs.DesiredState.freeCopies(allocator, entries);
            for (entries, 0..) |e, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("{f}", .{std.json.fmt(.{ .request_type = e.request_type, .data = e.data }, .{})});
            }
        }
        try w.writeAll("],\"retained\":[");
        var list = try self.bus.snapshotRetained(allocator, keepTopic);
        defer {
            for (list.items) |e| {
                allocator.free(e.topic);
                allocator.free(e.payload);
            }
            list.deinit(allocator);
        }
        // 順序を安定させる (内容が同じなら同じバイト列 = 無駄な書き込みをしない)
        std.mem.sort(event_bus.EventBus.RetainedEntry, list.items, {}, struct {
            fn lt(_: void, a: event_bus.EventBus.RetainedEntry, b: event_bus.EventBus.RetainedEntry) bool {
                return std.mem.lessThan(u8, a.topic, b.topic);
            }
        }.lt);
        for (list.items, 0..) |e, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{f}", .{std.json.fmt(.{ .topic = e.topic, .payload = e.payload, .ts = e.ts }, .{})});
        }
        try w.writeAll("]}\n");
        return out.toOwnedSlice(allocator);
    }

    fn contentHash(json: []const u8) u64 {
        // saved_at を除いた部分で比較する
        const idx = std.mem.indexOf(u8, json, "\"obs_desired\"") orelse 0;
        return std.hash.Wyhash.hash(0, json[idx..]);
    }

    /// 変化があれば書き出す
    pub fn saveIfChanged(self: *Snapshot) !bool {
        const json = try self.collect(self.allocator);
        defer self.allocator.free(json);
        const h = contentHash(json);
        if (h == self.last_hash) return false;
        try writeAtomic(self.path, json);
        self.last_hash = h;
        self.writes += 1;
        return true;
    }

    fn writeAtomic(path: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path});
        {
            const f = try std.fs.cwd().createFile(tmp, .{ .truncate = true, .mode = 0o600 });
            defer f.close();
            try f.writeAll(data);
            try f.sync();
        }
        try std.fs.cwd().rename(tmp, path);
    }

    pub const RestoreResult = struct { desired: usize = 0, retained: usize = 0, age_ms: i64 = 0 };

    /// スナップショットを読み込んで状態を戻す。mock_obs=true なら意図した状態を要求として発行し直す。
    pub fn restore(self: *Snapshot, republish_requests: bool) !RestoreResult {
        const data = std.fs.cwd().readFileAlloc(self.allocator, self.path, 8 * 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return .{};
            return err;
        };
        defer self.allocator.free(data);
        const parsed = std.json.parseFromSlice(FileShape, self.allocator, data, .{ .ignore_unknown_fields = true }) catch |err| {
            log.warn("Snapshot: '{s}' is unreadable ({any}); starting fresh", .{ self.path, err });
            return .{};
        };
        defer parsed.deinit();
        if (parsed.value.version != VERSION) return .{};

        var r = RestoreResult{ .age_ms = std.time.milliTimestamp() - parsed.value.saved_at };
        for (parsed.value.retained) |e| {
            if (!keepTopic(e.topic)) continue;
            // 元のタイムスタンプで戻す (プラグインが「いつからその状態か」を正しく判断できるように)
            self.bus.publishWithMessageTimestamp(e.topic, e.payload, .Transient, 0, if (e.ts != 0) e.ts else std.time.milliTimestamp()) catch continue;
            r.retained += 1;
        }
        for (parsed.value.obs_desired) |d| {
            if (self.desired) |ds| {
                _ = ds.record(d.request_type, d.data) catch continue;
            }
            if (republish_requests) {
                var tbuf: [128]u8 = undefined;
                const t = std.fmt.bufPrint(&tbuf, "core.obs.request.{s}", .{d.request_type}) catch continue;
                self.bus.publish(t, d.data, .Reliable, 0) catch continue;
            }
            r.desired += 1;
        }
        // 復元した内容を「保存済み」とみなす
        const json = self.collect(self.allocator) catch return r;
        defer self.allocator.free(json);
        self.last_hash = contentHash(json);
        return r;
    }

    pub fn start(self: *Snapshot) !void {
        self.running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    pub fn stop(self: *Snapshot) void {
        if (!self.running.swap(false, .acq_rel)) return;
        if (self.thread) |t| t.join();
        self.thread = null;
        _ = self.saveIfChanged() catch {};
    }

    fn loop(self: *Snapshot) void {
        while (self.running.load(.acquire)) {
            _ = self.saveIfChanged() catch |err| log.warn("Snapshot: write failed: {any}", .{err});
            var slept: u64 = 0;
            while (slept < self.interval_ms and self.running.load(.acquire)) : (slept += 20) std.Thread.sleep(20 * std.time.ns_per_ms);
        }
    }
};

test "snapshot: save and restore OBS desired state and retained events" {
    const a = std.testing.allocator;
    const path = "test_snapshot_tmp/state.json";
    defer std.fs.cwd().deleteTree("test_snapshot_tmp") catch {};

    {
        var bus = try event_bus.EventBus.init(a, 16);
        defer bus.deinit();
        bus.verbose = false;
        var desired = obs.DesiredState.init(a);
        defer desired.deinit();
        _ = try desired.record("SetSceneItemEnabled", "{\"sceneName\":\"Overlay\",\"sceneItemId\":1,\"sceneItemEnabled\":true}");
        try bus.publish("core.obs.event.SceneItemEnableStateChanged", "{\"op\":5,\"d\":{\"eventData\":{\"sceneItemEnabled\":true}}}", .Transient, 2);
        try bus.publish("ext.chat.x", "not kept", .Transient, 1);
        var snap = Snapshot.init(a, path, &bus, &desired);
        try std.testing.expect(try snap.saveIfChanged());
        try std.testing.expect(!try snap.saveIfChanged()); // 変化なし → 書かない
    }

    // 「再起動後」: 新しいバスと空の意図状態に復元する
    var bus = try event_bus.EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    var desired = obs.DesiredState.init(a);
    defer desired.deinit();
    var snap = Snapshot.init(a, path, &bus, &desired);
    const r = try snap.restore(false);
    try std.testing.expectEqual(@as(usize, 1), r.desired);
    try std.testing.expectEqual(@as(usize, 1), r.retained);
    try std.testing.expectEqual(@as(usize, 1), desired.count());
    const p = bus.retainedPayload(a, "core.obs.event.SceneItemEnableStateChanged").?;
    defer a.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "true") != null);
    try std.testing.expect(bus.retainedPayload(a, "ext.chat.x") == null);
}
