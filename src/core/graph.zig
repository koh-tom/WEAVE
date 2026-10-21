//! SystemGraph — 観測済みのトポロジ (ノード・所属セル・状態・pub/sub・辺)。
//!
//! 辺の判定は ACL・配送と同じ `pattern.isMatch` を使う (以前は末尾 `*` だけを見る
//! 別実装で、Inspector に出る辺と実際の配送が食い違っていた)。
//! JSON は必ず std.json で組み立てる (ノード名・トピック名の注入対策)。

const std = @import("std");
const event_bus = @import("event_bus.zig");
const pattern = @import("pattern.zig");
const NodeStatus = @import("../common/types.zig").NodeStatus;
const log = @import("../common/log.zig");

pub const NodeType = enum {
    wasm,
    native,
    remote,
};

pub const NodeInfo = struct {
    id: u32,
    name: []const u8,
    node_type: NodeType,
    cell: []const u8,
    status: NodeStatus,
    pub_topics: std.ArrayListUnmanaged([]const u8),
    sub_topics: std.ArrayListUnmanaged([]const u8),
    last_activity_ts: i64 = 0,
    last_topic: ?[]const u8 = null,
    /// active 以外 (停止・再起動中・縮退・切断) になった時刻。復帰時間 (R13) の計測に使う
    down_since_ms: ?i64 = null,
};

/// active でない状態 = 役目を果たせていない状態。starting はまだ始まっていないだけなので含めない
pub fn isDown(s: NodeStatus) bool {
    return switch (s) {
        .restarting, .quarantined, .stopped, .degraded, .disconnected => true,
        .starting, .active => false,
    };
}

pub const SystemGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.AutoHashMapUnmanaged(u32, NodeInfo) = .{},
    mutex: std.Thread.Mutex = .{},
    bus: ?*event_bus.EventBus = null,
    /// 1 ノードが記録する pub トピック数の上限 (任意トピックの大量発行で膨らまないように)
    max_topics_per_node: usize = 256,

    pub fn init(allocator: std.mem.Allocator) SystemGraph {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SystemGraph) void {
        var it = self.nodes.valueIterator();
        while (it.next()) |node| freeNode(self.allocator, node);
        self.nodes.deinit(self.allocator);
    }

    fn freeNode(a: std.mem.Allocator, node: *NodeInfo) void {
        a.free(node.name);
        a.free(node.cell);
        for (node.pub_topics.items) |t| a.free(t);
        for (node.sub_topics.items) |t| a.free(t);
        if (node.last_topic) |t| a.free(t);
        node.pub_topics.deinit(a);
        node.sub_topics.deinit(a);
    }

    fn emitDelta(self: *SystemGraph, value: anytype) void {
        const bus = self.bus orelse return;
        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(value, .{})}) catch return;
        bus.publish("core.system.graph.delta", w.buffered(), .BestEffort, 0) catch {};
    }

    /// 互換 API: cell を省略すると "core"
    pub fn registerNode(self: *SystemGraph, id: u32, name: []const u8, node_type: NodeType) !void {
        return self.registerNodeIn(id, name, node_type, "core");
    }

    pub fn registerNodeIn(self: *SystemGraph, id: u32, name: []const u8, node_type: NodeType, cell: []const u8) !void {
        var changed = false;
        var reactivate = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.nodes.getPtr(id)) |node| {
                if (!std.mem.eql(u8, node.name, name) or node.node_type != node_type or !std.mem.eql(u8, node.cell, cell) or node.status != .active) {
                    const new_name = try self.allocator.dupe(u8, name);
                    const new_cell = self.allocator.dupe(u8, cell) catch |e| {
                        self.allocator.free(new_name);
                        return e;
                    };
                    self.allocator.free(node.name);
                    self.allocator.free(node.cell);
                    node.name = new_name;
                    node.cell = new_cell;
                    node.node_type = node_type;
                    // 状態は下の updateNodeStatus で戻す (復帰イベントと復帰時間を出すため)
                    reactivate = node.status != .active;
                    changed = true;
                }
                node.last_activity_ts = std.time.milliTimestamp();
            } else {
                const n = try self.allocator.dupe(u8, name);
                errdefer self.allocator.free(n);
                const c = try self.allocator.dupe(u8, cell);
                errdefer self.allocator.free(c);
                try self.nodes.put(self.allocator, id, .{
                    .id = id,
                    .name = n,
                    .node_type = node_type,
                    .cell = c,
                    .status = .active,
                    .pub_topics = .{},
                    .sub_topics = .{},
                    .last_activity_ts = std.time.milliTimestamp(),
                });
                changed = true;
            }
        }
        if (changed) self.emitDelta(.{ .type = "node_reg", .id = id, .name = name, .node_type = @tagName(node_type), .cell = cell });
        if (reactivate) self.updateNodeStatus(id, .active);
    }

    pub fn updateSubscription(self: *SystemGraph, node_id: u32, topic: []const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = self.nodes.getPtr(node_id) orelse return error.NodeNotFound;
            node.last_activity_ts = std.time.milliTimestamp();
            for (node.sub_topics.items) |t| if (std.mem.eql(u8, t, topic)) return;
            const d = try self.allocator.dupe(u8, topic);
            node.sub_topics.append(self.allocator, d) catch |e| {
                self.allocator.free(d);
                return e;
            };
        }
        self.emitDelta(.{ .type = "link_sub", .id = node_id, .topic = topic });
    }

    pub fn removeSubscription(self: *SystemGraph, node_id: u32, topic: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const node = self.nodes.getPtr(node_id) orelse return;
        var i: usize = 0;
        while (i < node.sub_topics.items.len) {
            if (std.mem.eql(u8, node.sub_topics.items[i], topic)) {
                self.allocator.free(node.sub_topics.items[i]);
                _ = node.sub_topics.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn recordPublish(self: *SystemGraph, node_id: u32, topic: []const u8) !void {
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = self.nodes.getPtr(node_id) orelse return;
            node.last_activity_ts = std.time.milliTimestamp();
            for (node.pub_topics.items) |t| if (std.mem.eql(u8, t, topic)) return;
            if (node.pub_topics.items.len >= self.max_topics_per_node) return;
            const d = try self.allocator.dupe(u8, topic);
            node.pub_topics.append(self.allocator, d) catch |e| {
                self.allocator.free(d);
                return e;
            };
        }
        self.emitDelta(.{ .type = "link_pub", .id = node_id, .topic = topic });
    }

    pub fn updateNodeStatus(self: *SystemGraph, node_id: u32, status: NodeStatus) void {
        return self.updateNodeStatusAt(node_id, status, std.time.milliTimestamp());
    }

    /// 状態を変える。active から外れたら core.node.down、戻ったら core.node.recovered (停止していた時間つき) を出す (R13)。
    /// 復帰時間は Core 側で測るので、Inspector を後から開いても、開いていなくても記録が残る。
    pub fn updateNodeStatusAt(self: *SystemGraph, node_id: u32, status: NodeStatus, now_ms: i64) void {
        var name_buf: [64]u8 = undefined;
        var cell_buf: [64]u8 = undefined;
        var name: []const u8 = "";
        var cell: []const u8 = "";
        var was: NodeStatus = status;
        var down_ms: ?i64 = null;
        var went_down = false;
        {
            self.mutex.lock();
            defer self.mutex.unlock();
            const node = self.nodes.getPtr(node_id) orelse return;
            if (node.status == status) return;
            was = node.status;
            node.status = status;
            node.last_activity_ts = now_ms;
            if (isDown(status) and node.down_since_ms == null) {
                node.down_since_ms = now_ms;
                went_down = true;
            } else if (status == .active) {
                if (node.down_since_ms) |since| down_ms = @max(0, now_ms - since);
                node.down_since_ms = null;
            }
            const nl = @min(node.name.len, name_buf.len);
            @memcpy(name_buf[0..nl], node.name[0..nl]);
            name = name_buf[0..nl];
            const cl = @min(node.cell.len, cell_buf.len);
            @memcpy(cell_buf[0..cl], node.cell[0..cl]);
            cell = cell_buf[0..cl];
        }
        self.emitDelta(.{ .type = "node_status", .id = node_id, .status = @tagName(status) });
        if (went_down) {
            self.emitEvent("core.node.down", .{ .node_id = node_id, .name = name, .cell = cell, .status = @tagName(status), .ts = now_ms });
        }
        if (down_ms) |ms| {
            self.emitEvent("core.node.recovered", .{ .node_id = node_id, .name = name, .cell = cell, .from = @tagName(was), .down_ms = ms, .ts = now_ms });
            log.info("Recovery: '{s}' (cell {s}) is active again after {d} ms", .{ name, cell, ms });
        }
    }

    fn emitEvent(self: *SystemGraph, topic: []const u8, value: anytype) void {
        const bus = self.bus orelse return;
        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(value, .{})}) catch return;
        bus.publish(topic, w.buffered(), .BestEffort, 0) catch {};
    }

    pub fn nodeStatus(self: *SystemGraph, node_id: u32) ?NodeStatus {
        self.mutex.lock();
        defer self.mutex.unlock();
        const node = self.nodes.getPtr(node_id) orelse return null;
        return node.status;
    }

    /// グラフ全体を JSON でシリアライズする
    pub fn toJson(self: *SystemGraph, writer: anytype) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try writer.writeAll("{\"nodes\":[");
        var first = true;
        var it = self.nodes.valueIterator();
        while (it.next()) |node| {
            if (!first) try writer.writeAll(",");
            first = false;
            try writer.print("{f}", .{std.json.fmt(.{
                .id = node.id,
                .name = node.name,
                .type = @tagName(node.node_type),
                .cell = node.cell,
                .status = @tagName(node.status),
                .last_active = node.last_activity_ts,
                .last_topic = node.last_topic,
                .@"pub" = node.pub_topics.items,
                .sub = node.sub_topics.items,
            }, .{})});
        }
        try writer.writeAll("],\"edges\":[");
        var edge_first = true;
        var it_pub = self.nodes.valueIterator();
        while (it_pub.next()) |pub_node| {
            for (pub_node.pub_topics.items) |pub_topic| {
                var it_sub = self.nodes.valueIterator();
                while (it_sub.next()) |sub_node| {
                    if (pub_node.id == sub_node.id) continue;
                    for (sub_node.sub_topics.items) |sub_topic| {
                        if (pattern.isMatch(sub_topic, pub_topic)) {
                            if (!edge_first) try writer.writeAll(",");
                            edge_first = false;
                            try writer.print("{f}", .{std.json.fmt(.{ .source = pub_node.id, .target = sub_node.id, .topic = pub_topic }, .{})});
                            break;
                        }
                    }
                }
            }
        }
        try writer.writeAll("]}");
    }

    pub fn toJsonAlloc(self: *SystemGraph, allocator: std.mem.Allocator) ![]const u8 {
        var list: std.ArrayList(u8) = .{};
        errdefer list.deinit(allocator);
        try self.toJson(list.writer(allocator));
        return list.toOwnedSlice(allocator);
    }

    /// ある時点のノードの写し (HealthMonitor 用)。文字列はすべて複製するので、ロックの外で使ってよい
    pub const NodeSnapshot = struct {
        id: u32,
        name: []const u8,
        node_type: NodeType,
        status: NodeStatus,
        down_since_ms: ?i64,
        pub_topics: []const []const u8,
        sub_topics: []const []const u8,
    };

    /// 全ノードの写しを返す。arena で確保する前提 (個別の解放はしない)
    pub fn snapshot(self: *SystemGraph, arena: std.mem.Allocator) ![]NodeSnapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        var out = try arena.alloc(NodeSnapshot, self.nodes.count());
        var i: usize = 0;
        var it = self.nodes.valueIterator();
        while (it.next()) |node| : (i += 1) {
            const pubs = try arena.alloc([]const u8, node.pub_topics.items.len);
            for (node.pub_topics.items, 0..) |t, j| pubs[j] = try arena.dupe(u8, t);
            const subs = try arena.alloc([]const u8, node.sub_topics.items.len);
            for (node.sub_topics.items, 0..) |t, j| subs[j] = try arena.dupe(u8, t);
            out[i] = .{
                .id = node.id,
                .name = try arena.dupe(u8, node.name),
                .node_type = node.node_type,
                .status = node.status,
                .down_since_ms = node.down_since_ms,
                .pub_topics = pubs,
                .sub_topics = subs,
            };
        }
        return out;
    }
};

test "SystemGraph: idempotent registerNode" {
    const allocator = std.testing.allocator;
    var bus = try event_bus.EventBus.init(allocator, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(allocator);
    defer graph.deinit();
    graph.bus = &bus;

    const S = struct {
        var count = std.atomic.Value(u32).init(0);
        fn cb(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = count.fetchAdd(1, .monotonic);
        }
    };
    S.count.store(0, .monotonic);
    try bus.subscribe("core.system.graph.delta", 1, S.cb, null);
    try bus.start();
    try graph.registerNode(42, "test_node", .wasm);
    try graph.registerNode(42, "test_node", .wasm);
    try graph.registerNode(42, "updated_node", .wasm);
    bus.waitIdle();
    try std.testing.expectEqual(@as(u32, 2), S.count.load(.monotonic));
}

test "SystemGraph: down / recovered events carry the measured downtime (R13)" {
    const allocator = std.testing.allocator;
    var bus = try event_bus.EventBus.init(allocator, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(allocator);
    defer graph.deinit();
    graph.bus = &bus;

    const S = struct {
        var mutex: std.Thread.Mutex = .{};
        var downs: u32 = 0;
        var last: [512]u8 = undefined;
        var last_len: usize = 0;
        fn down(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            mutex.lock();
            defer mutex.unlock();
            downs += 1;
        }
        fn rec(_: ?*anyopaque, m: *const event_bus.EventMessage) void {
            mutex.lock();
            defer mutex.unlock();
            last_len = @min(m.payload.len, last.len);
            @memcpy(last[0..last_len], m.payload[0..last_len]);
        }
    };
    S.downs = 0;
    S.last_len = 0;
    try bus.subscribe("core.node.down", 1, S.down, null);
    try bus.subscribe("core.node.recovered", 1, S.rec, null);
    try bus.start();
    try graph.registerNodeIn(7, "ObsEgress", .native, "egress");

    // degraded → disconnected → active: 停止の起点は最初の down、復帰時間は 1200 ms
    graph.updateNodeStatusAt(7, .degraded, 1_000);
    graph.updateNodeStatusAt(7, .disconnected, 1_500);
    graph.updateNodeStatusAt(7, .active, 2_200);
    bus.waitIdle();

    S.mutex.lock();
    defer S.mutex.unlock();
    try std.testing.expectEqual(@as(u32, 1), S.downs);
    var p = try std.json.parseFromSlice(std.json.Value, allocator, S.last[0..S.last_len], .{});
    defer p.deinit();
    try std.testing.expectEqual(@as(i64, 1200), p.value.object.get("down_ms").?.integer);
    try std.testing.expectEqualStrings("disconnected", p.value.object.get("from").?.string);
    try std.testing.expectEqualStrings("egress", p.value.object.get("cell").?.string);
    try std.testing.expect(graph.nodes.get(7).?.down_since_ms == null);
}

test "SystemGraph: edges use the same matcher as delivery" {
    const allocator = std.testing.allocator;
    var graph = SystemGraph.init(allocator);
    defer graph.deinit();
    try graph.registerNodeIn(1, "Twitch", .native, "ingress");
    try graph.registerNodeIn(2, "kusa", .wasm, "plugins.trusted");
    try graph.registerNodeIn(3, "Obs", .native, "egress");
    try graph.recordPublish(1, "ext.twitch.chat.message");
    try graph.recordPublish(2, "core.obs.request.SetSceneItemEnabled");
    try graph.updateSubscription(2, "ext.twitch.#"); // 旧実装では辺にならなかった
    try graph.updateSubscription(3, "core.obs.request.*");

    const json = try graph.toJsonAlloc(allocator);
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(struct { nodes: []std.json.Value, edges: []struct { source: u32, target: u32, topic: []const u8 } }, allocator, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 3), parsed.value.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.edges.len);
}

test "SystemGraph: names are JSON-escaped" {
    const allocator = std.testing.allocator;
    var graph = SystemGraph.init(allocator);
    defer graph.deinit();
    try graph.registerNode(7, "evil\"name", .remote);
    const json = try graph.toJsonAlloc(allocator);
    defer allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    parsed.deinit();
}

test "SystemGraph: toJson performance (50 nodes, 200 edges)" {
    const allocator = std.testing.allocator;
    var graph = SystemGraph.init(allocator);
    defer graph.deinit();
    var i: u32 = 1;
    while (i <= 50) : (i += 1) {
        var name_buf: [32]u8 = undefined;
        try graph.registerNode(i, try std.fmt.bufPrint(&name_buf, "node_{}", .{i}), .wasm);
    }
    for ([_][]const u8{ "t1", "t2", "t3", "t4" }) |t| try graph.recordPublish(1, t);
    i = 2;
    while (i <= 50) : (i += 1) {
        for ([_][]const u8{ "t1", "t2", "t3", "t4" }) |t| try graph.updateSubscription(i, t);
    }
    try graph.recordPublish(2, "t5");
    for ([_]u32{ 3, 4, 5, 6 }) |n| try graph.updateSubscription(n, "t5");

    var list: std.ArrayList(u8) = .{};
    defer list.deinit(allocator);
    const t0 = std.time.nanoTimestamp();
    try graph.toJson(list.writer(allocator));
    const ms = @as(f64, @floatFromInt(std.time.nanoTimestamp() - t0)) / 1e6;
    try std.testing.expect(ms < 50.0);
    var parsed = try std.json.parseFromSlice(struct { nodes: []std.json.Value, edges: []std.json.Value }, allocator, list.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 200), parsed.value.edges.len);
}
