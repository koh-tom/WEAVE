const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const log = @import("../common/log.zig");

pub const MockObsEgressNode = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    password: ?[]const u8,
    filepath: []const u8,
    running: bool,
    mutex: std.Thread.Mutex,

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
        self.allocator.destroy(self);
    }

    pub fn connect(self: *MockObsEgressNode, host: []const u8, port: u16) !void {
        _ = host;
        _ = port;
        self.running = true;

        // 起動時にファイルクリア: deleteFile catch {} の後 create
        std.fs.cwd().deleteFile(self.filepath) catch {};
        const file = try std.fs.cwd().createFile(self.filepath, .{});
        file.close();

        // 購読開始
        try self.bus.subscribe("core.obs.request.*", self.node_id, MockObsEgressNode.onMessage, self);

        // グラフ登録
        if (self.bus.graph) |g| {
            try g.registerNode(self.node_id, "ObsEgress", .native);
        }
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
                }
            }

            const StubContext = struct {
                bus: *event_bus.EventBus,
                node_id: u32,
                scene_item_id: i64,
                scene_item_enabled: bool,

                fn run(ctx: @This()) void {
                    std.Thread.sleep(100 * std.time.ns_per_ms);

                    var buf: [512]u8 = undefined;
                    // Format matching ObsEgress event structure: {"op":5,"d":{"eventType":"...","eventData":{...}}}
                    const event_payload = std.fmt.bufPrint(&buf, "{{\"op\":5,\"d\":{{\"eventType\":\"SceneItemEnableStateChanged\",\"eventData\":{{\"sceneName\":\"Scene\",\"sceneItemId\":{},\"sceneItemEnabled\":{}}}}}}}", .{ ctx.scene_item_id, ctx.scene_item_enabled }) catch return;

                    ctx.bus.publish("core.obs.event.SceneItemEnableStateChanged", event_payload, .Transient, ctx.node_id) catch |err| {
                        std.debug.print("MockObsEgress: failed to publish stub event: {any}\n", .{err});
                    };
                }
            };

            const ctx = StubContext{
                .bus = self.bus,
                .node_id = self.node_id,
                .scene_item_id = scene_item_id,
                .scene_item_enabled = scene_item_enabled,
            };
            const t = try std.Thread.spawn(.{}, StubContext.run, .{ctx});
            t.detach();
        }
    }
};
