const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const log = @import("../common/log.zig");
const DesiredState = @import("obs.zig").DesiredState;

pub const MockObsEgressNode = struct {
    /// バスにつないだか (attach 済み)
    attached: bool = false,
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    password: ?[]const u8,
    filepath: []const u8,
    running: bool,
    mutex: std.Thread.Mutex,
    /// WEAVE が意図した OBS の状態 (スナップショットの対象, R7)
    desired: DesiredState,
    /// 接続時に出力ファイルを空にする。egress を別プロセスにしたとき (ADR-010) は、子プロセスが
    /// 再起動するたびに記録が消えないよう false にし、空にするのは Core の起動時 1 回だけにする
    truncate_on_connect: bool = true,

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, password: ?[]const u8, filepath: []const u8) !*MockObsEgressNode {
        const self = try allocator.create(MockObsEgressNode);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .password = if (password) |p| try allocator.dupe(u8, p) else null,
            .filepath = try allocator.dupe(u8, filepath),
            .running = false,
            .mutex = .{},
            .desired = DesiredState.init(allocator),
        };
        return self;
    }

    pub fn stop(self: *MockObsEgressNode) void {
        self.running = false;
    }

    pub fn deinit(self: *MockObsEgressNode) void {
        self.stop();
        if (self.password) |p| self.allocator.free(p);
        self.allocator.free(self.filepath);
        self.desired.deinit();
        self.allocator.destroy(self);
    }

    pub fn connect(self: *MockObsEgressNode, host: []const u8, port: u16) !void {
        _ = host;
        _ = port;
        try self.attach();
    }

    /// バスにつなぐ (出力ファイルの初期化・グラフ登録・購読)。プラグインより先に呼ぶと、
    /// プラグインが起動時に出した要求も取りこぼさない。connect() は未実行ならこれも行う
    pub fn attach(self: *MockObsEgressNode) !void {
        if (self.attached) return;
        self.attached = true;
        self.running = true;

        // 起動時にファイルクリア: deleteFile catch {} の後 create
        if (self.truncate_on_connect) {
            std.fs.cwd().deleteFile(self.filepath) catch {};
            const file = try std.fs.cwd().createFile(self.filepath, .{});
            file.close();
        }

        // OBS への送信は専用セル "egress" で行う (OBS が遅くても他の配送を待たせない)
        const cell = self.bus.getCell("egress") orelse try self.bus.createCell("egress", .{ .trust = .core });

        // グラフ登録を購読より先に行う (逆順だと購読が記録されず、トポロジから OBS への辺が消える)
        if (self.bus.graph) |g| {
            try g.registerNodeIn(self.node_id, "ObsEgress", .native, cell.name);
        }

        try self.bus.subscribeEx("core.obs.request.*", self.node_id, MockObsEgressNode.onMessage, self, .{ .cell = cell });
    }

    fn onMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *MockObsEgressNode = @ptrCast(@alignCast(context));
        if (!self.running) return;

        self.handleMessage(msg) catch |err| {
            std.debug.print("MockObsEgress error handling message: {any}\n", .{err});
        };
    }

    fn handleMessage(self: *MockObsEgressNode, msg: *const event_bus.EventMessage) !void {
        const ts = std.time.milliTimestamp();
        const prefix = "core.obs.request.";
        if (std.mem.startsWith(u8, msg.topic, prefix)) _ = self.desired.record(msg.topic[prefix.len..], msg.payload) catch false;

        // Try to parse payload as JSON
        var parsed_payload = std.json.parseFromSlice(std.json.Value, self.allocator, msg.payload, .{}) catch null;
        defer if (parsed_payload) |*p| p.deinit();

        // Write line using POSIX append + fsync for atomic append
        var line_list = std.ArrayList(u8){};
        defer line_list.deinit(self.allocator);

        if (parsed_payload) |p| {
            const entry = struct {
                ts: i64,
                topic: []const u8,
                payload: std.json.Value,
            }{
                .ts = ts,
                .topic = msg.topic,
                .payload = p.value,
            };
            try line_list.writer(self.allocator).print("{f}", .{std.json.fmt(entry, .{})});
        } else {
            const entry = struct {
                ts: i64,
                topic: []const u8,
                payload: []const u8,
            }{
                .ts = ts,
                .topic = msg.topic,
                .payload = msg.payload,
            };
            try line_list.writer(self.allocator).print("{f}", .{std.json.fmt(entry, .{})});
        }
        try line_list.append(self.allocator, '\n');

        // Atomically append to file using POSIX open with O_APPEND + fsync
        self.mutex.lock();
        defer self.mutex.unlock();

        const flags = std.posix.O{
            .ACCMODE = .WRONLY,
            .APPEND = true,
            .CREAT = true,
        };
        const fd = try std.posix.open(self.filepath, flags, 0o644);
        defer std.posix.close(fd);

        _ = try std.posix.write(fd, line_list.items);
        try std.posix.fsync(fd);

        // 100ms delayed stub publish for SetSceneItemEnabled
        if (std.mem.endsWith(u8, msg.topic, "SetSceneItemEnabled")) {
            var scene_item_id: i64 = 1;
            var scene_item_enabled: bool = true;
            var scene_name: []const u8 = "Overlay";

            if (parsed_payload) |p| {
                if (p.value == .object) {
                    if (p.value.object.get("sceneItemId")) |v| {
                        if (v == .integer) {
                            scene_item_id = v.integer;
                        }
                    }
                    if (p.value.object.get("sceneItemEnabled")) |v| {
                        if (v == .bool) {
                            scene_item_enabled = v.bool;
                        }
                    }
                    if (p.value.object.get("sceneName")) |v| {
                        if (v == .string) scene_name = v.string;
                    }
                }
            }

            // OBS が返すのと同じ形の状態変更イベントを発行する。
            // (以前は 100ms 待つスレッドを detach しており、終了後にバスへ触れる危険があった: P1-10)
            var buf: [512]u8 = undefined;
            var w = std.io.Writer.fixed(&buf);
            w.print("{f}", .{std.json.fmt(.{ .op = 5, .d = .{ .eventType = "SceneItemEnableStateChanged", .eventData = .{ .sceneName = scene_name, .sceneItemId = scene_item_id, .sceneItemEnabled = scene_item_enabled } } }, .{})}) catch return;
            self.bus.publish("core.obs.event.SceneItemEnableStateChanged", w.buffered(), .Transient, self.node_id) catch |err| {
                std.debug.print("MockObsEgress: failed to publish stub event: {any}\n", .{err});
            };
        }
    }
};
