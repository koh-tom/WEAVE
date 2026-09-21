const std = @import("std");
const event_bus = @import("event_bus.zig");

/// 監査ログ: core.security.* イベントを JSON Lines でファイルに追記する。
/// 「セキュリティが効いた証跡」を残し、Dashboard/CLI から後追いできるようにする。
pub const AuditLog = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    mutex: std.Thread.Mutex = .{},
    count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) AuditLog {
        return .{ .allocator = allocator, .path = path };
    }

    /// core.security.# を購読して以後のセキュリティイベントを記録する。
    pub fn subscribeBus(self: *AuditLog, bus: *event_bus.EventBus) !void {
        try bus.subscribe("core.security.#", 97, callback, self);
    }

    fn callback(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *AuditLog = @ptrCast(@alignCast(ctx orelse return));
        self.append(msg.topic, msg.payload) catch {};
    }

    pub fn append(self: *AuditLog, topic: []const u8, payload: []const u8) !void {
        const ts = std.time.milliTimestamp();
        var line = std.ArrayList(u8){};
        defer line.deinit(self.allocator);
        const pl = if (payload.len > 0) payload else "{}";
        try line.writer(self.allocator).print("{{\"ts\":{},\"topic\":\"{s}\",\"payload\":{s}}}\n", .{ ts, topic, pl });

        self.mutex.lock();
        defer self.mutex.unlock();
        const flags = std.posix.O{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true };
        const fd = try std.posix.open(self.path, flags, 0o644);
        defer std.posix.close(fd);
        _ = try std.posix.write(fd, line.items);
        self.count += 1;
    }
};

test "AuditLog: appends JSON lines" {
    const allocator = std.testing.allocator;
    const path = "test_audit_tmp.jsonl";
    std.fs.cwd().deleteFile(path) catch {};
    defer std.fs.cwd().deleteFile(path) catch {};

    var al = AuditLog.init(allocator, path);
    try al.append("core.security.acl_denied", "{\"node_id\":100,\"action\":\"publish\"}");
    try al.append("core.security.rate_limited", "{\"node_id\":100}");
    try std.testing.expectEqual(@as(usize, 2), al.count);

    const content = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
    defer allocator.free(content);
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |l| {
        if (l.len == 0) continue;
        lines += 1;
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, l, .{}); // 各行が正しい JSON
        parsed.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), lines);
    try std.testing.expect(std.mem.indexOf(u8, content, "acl_denied") != null);
}
