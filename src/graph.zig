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
            node.pub_topics.deinit(self.allocator);
            node.sub_topics.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
    }

    pub fn registerNode(self: *SystemGraph, id: u32, name: []const u8, node_type: NodeType) !void {
        self.mutex.lock();
        if (self.nodes.getPtr(id)) |node| {
            self.allocator.free(node.name);
            node.name = try self.allocator.dupe(u8, name);
            node.node_type = node_type;
            node.status = .active;
        } else {
            try self.nodes.put(self.allocator, id, .{
                .id = id,
                .name = try self.allocator.dupe(u8, name),
                .node_type = node_type,
                .status = .active,
                .pub_topics = .{},
                .sub_topics = .{},
            });
        }
        self.mutex.unlock();

        if (self.bus) |bus| {
            var buf: [256]u8 = undefined;
            const payload = std.fmt.bufPrint(&buf, "{{\"type\":\"node_reg\",\"id\":{},\"name\":\"{s}\",\"node_type\":\"{any}\"}}", .{id, name, node_type}) catch "";
            if (payload.len > 0) {
                _ = bus.publish("core.system.graph.delta", payload, .Transient, 0) catch {};
            }
        }
    }

    pub fn updateSubscription(self: *SystemGraph, node_id: u32, topic: []const u8) !void {
        self.mutex.lock();
        const node = self.nodes.getPtr(node_id) orelse { self.mutex.unlock(); return error.NodeNotFound; };
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
            
            try writer.print("{{\"id\":{},\"name\":\"{s}\",\"type\":\"{any}\",\"status\":\"{any}\",\"pub\":[", 
                .{node.id, node.name, node.node_type, node.status});
            
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
