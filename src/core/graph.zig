const std = @import("std");
const event_bus = @import("event_bus.zig");

pub const NodeType = enum {
    wasm,
    native,
    remote,
};

pub const NodeInfo = struct {
    id: u32,
    name: []const u8,
    node_type: NodeType,
    status: enum { active, fault, disconnected },
    pub_topics: std.ArrayListUnmanaged([]const u8),
    sub_topics: std.ArrayListUnmanaged([]const u8),
    last_activity_ts: i64 = 0,
    last_topic: ?[]const u8 = null,
};

pub const SystemGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(u32, NodeInfo),
    mutex: std.Thread.Mutex,
    bus: ?*event_bus.EventBus = null, // 追加: 差分配信先

    pub fn init(allocator: std.mem.Allocator) SystemGraph {
        return .{
            .allocator = allocator,
            .nodes = .{},
            .mutex = .{},
            .bus = null,
        };
    }

    pub fn deinit(self: *SystemGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            self.allocator.free(node.name);
            for (node.pub_topics.items) |t| self.allocator.free(t);
            for (node.sub_topics.items) |t| self.allocator.free(t);
            if (node.last_topic) |t| self.allocator.free(t);
            node.pub_topics.deinit(self.allocator);
            node.sub_topics.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn registerNode(self: *SystemGraph, id: u32, name: []const u8, node_type: NodeType) !void {
        self.mutex.lock();
        var is_changed = false;
        
        if (self.nodes.getPtr(id)) |node| {
            if (!std.mem.eql(u8, node.name, name) or node.node_type != node_type or node.status != .active) {
                self.allocator.free(node.name);
                node.name = try self.allocator.dupe(u8, name);
                node.node_type = node_type;
                node.status = .active;
                is_changed = true;
            }
            node.last_activity_ts = std.time.milliTimestamp();
        } else {
            try self.nodes.put(self.allocator, id, .{
                .id = id,
                .name = try self.allocator.dupe(u8, name),
                .node_type = node_type,
                .status = .active,
                .pub_topics = .{},
                .sub_topics = .{},
                .last_activity_ts = std.time.milliTimestamp(),
                .last_topic = null,
            });
            is_changed = true;
        }
        self.mutex.unlock();

        if (is_changed) {
            if (self.bus) |bus| {
                var buf: [256]u8 = undefined;
                const payload = std.fmt.bufPrint(&buf, "{{\"type\":\"node_reg\",\"id\":{},\"name\":\"{s}\",\"node_type\":\"{s}\"}}", .{id, name, @tagName(node_type)}) catch "";
                if (payload.len > 0) {
                    _ = bus.publish("core.system.graph.delta", payload, .Transient, 0) catch {};
                }
            }
        }
    }

    pub fn updateSubscription(self: *SystemGraph, node_id: u32, topic: []const u8) !void {
        self.mutex.lock();
        const node = self.nodes.getPtr(node_id) orelse { self.mutex.unlock(); return error.NodeNotFound; };
        
        node.last_activity_ts = std.time.milliTimestamp();
        if (node.last_topic) |t| self.allocator.free(t);
        node.last_topic = try self.allocator.dupe(u8, topic);

        for (node.sub_topics.items) |t| {
            if (std.mem.eql(u8, t, topic)) { self.mutex.unlock(); return; }
        }
        try node.sub_topics.append(self.allocator, try self.allocator.dupe(u8, topic));
        self.mutex.unlock();

        if (self.bus) |bus| {
            var buf: [256]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"type\":\"link_sub\",\"id\":{},\"topic\":\"{s}\"}}", .{node_id, topic}) catch "";
            if (payload.len > 0) {
                _ = bus.publish("core.system.graph.delta", payload, .Transient, 0) catch {};
            }
        }
    }

    pub fn recordPublish(self: *SystemGraph, node_id: u32, topic: []const u8) !void {
        self.mutex.lock();
        const node = self.nodes.getPtr(node_id) orelse { self.mutex.unlock(); return; };
        
        node.last_activity_ts = std.time.milliTimestamp();
        if (node.last_topic) |t| self.allocator.free(t);
        node.last_topic = try self.allocator.dupe(u8, topic);

        for (node.pub_topics.items) |t| {
            if (std.mem.eql(u8, t, topic)) { self.mutex.unlock(); return; }
        }
        try node.pub_topics.append(self.allocator, try self.allocator.dupe(u8, topic));
        self.mutex.unlock();

        if (self.bus) |bus| {
            var buf: [256]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"type\":\"link_pub\",\"id\":{},\"topic\":\"{s}\"}}", .{node_id, topic}) catch "";
            if (payload.len > 0) {
                _ = bus.publish("core.system.graph.delta", payload, .Transient, 0) catch {};
            }
        }
    }

    pub fn updateNodeStatus(self: *SystemGraph, node_id: u32, status: anytype) void {
        self.mutex.lock();
        if (self.nodes.getPtr(node_id)) |node| {
            node.status = status;
            node.last_activity_ts = std.time.milliTimestamp();
            self.mutex.unlock();

            if (self.bus) |bus| {
                var buf: [128]u8 = undefined;
                const payload = std.fmt.bufPrint(&buf, "{{\"type\":\"node_status\",\"id\":{},\"status\":\"{any}\"}}", .{node_id, status}) catch "";
                _ = bus.publish("core.system.graph.delta", payload, .Transient, 0) catch {};
            }
        } else {
            self.mutex.unlock();
        }
    }

    /// グラフ全体をJSON形式でシリアライズする
    pub fn toJson(self: *SystemGraph, allocator: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var list = std.ArrayListUnmanaged(u8){};
        errdefer list.deinit(allocator);
        
        var writer = list.writer(allocator);
        try writer.writeAll("{\"nodes\":[");
        
        var first = true;
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (!first) try writer.writeAll(",");
            first = false;
            
            try writer.writeAll("{");
            try writer.print("\"id\":{},", .{node.id});
            try writer.print("\"name\":\"{s}\",", .{node.name});
            try writer.print("\"type\":\"{s}\",", .{@tagName(node.node_type)});
            try writer.print("\"status\":\"{s}\",", .{@tagName(node.status)});
            try writer.print("\"last_active\":{},", .{node.last_activity_ts});
            try writer.writeAll("\"last_topic\":");
            
            if (node.last_topic) |t| {
                try writer.print("\"{s}\"", .{t});
            } else {
                try writer.writeAll("null");
            }

            try writer.writeAll(",\"pub\":[");
            
            for (node.pub_topics.items, 0..) |t, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{t});
            }
            try writer.writeAll("],\"sub\":[");
            for (node.sub_topics.items, 0..) |t, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.print("\"{s}\"", .{t});
            }
            try writer.writeAll("]}");
        }
        try writer.writeAll("]}");
        
        return list.toOwnedSlice(allocator);
    }
};

test "SystemGraph: Idempotent registerNode" {
    const allocator = std.testing.allocator;
    var bus = try event_bus.EventBus.init(allocator, 10);
    defer bus.deinit();
    bus.verbose = false;

    var graph = SystemGraph.init(allocator);
    defer graph.deinit();
    graph.bus = &bus;

    var count: u32 = 0;
    const S = struct {
        fn cb(ctx: ?*anyopaque, _: *const event_bus.EventMessage) void {
            const c_ptr = @as(*u32, @ptrCast(@alignCast(ctx)));
            c_ptr.* += 1;
        }
    };

    // delta トピックを購読
    try bus.subscribe("core.system.graph.delta", 1, S.cb, &count);

    const thread = try std.Thread.spawn(.{}, event_bus.EventBus.runDispatcher, .{&bus});

    // 1. 初回登録 -> delta が飛ぶはず
    try graph.registerNode(42, "test_node", .wasm);
    
    // 2. 同じ内容で再登録 -> 冪等性により delta は無視されるはず
    try graph.registerNode(42, "test_node", .wasm);

    // 3. 違う内容で再登録 -> 更新されたので delta が飛ぶはず
    try graph.registerNode(42, "updated_node", .wasm);

    bus.waitIdle();
    bus.stop();
    thread.join();

    // 期待値: 初回(1) + 変更(3) = 合計 2 回の delta が発行されているはず
    try std.testing.expectEqual(@as(u32, 2), count);
}
