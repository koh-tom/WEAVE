//! A1: 起動前の予測 (weave audit) と、実際に動かしたときの観測が一致すること。
//!
//! 予測: manifest だけから blast.computeBlast で「侵害されたら書けるトピック」「届く実世界シンク」を計算する。
//! 観測: 同じプラグインを Core に載せて攻撃的な振る舞いをさせ、バスを全部見る。
//!   (1) そのノードが実際に発行できたトピックは、全て予測した書き込み範囲に入っている
//!   (2) 監査ログに acl_denied として残った試みは、全て予測した範囲の外
//!   (3) 実世界シンクに届かないと予測したノードからは、OBS への要求が 1 件も出ていない。
//!       届くと予測したノードは実際に届き、そのシンクが予測に含まれている
//! 予測は上限なので「予測したが観測されなかった」は許す。逆 (予測外の観測) が 1 件でもあれば失敗。

const std = @import("std");
const Core = @import("../core/core.zig").Core;
const event_bus = @import("../core/event_bus.zig");
const blast = @import("../audit/blast.zig");
const pattern = @import("../core/pattern.zig");

const Observed = struct {
    mutex: std.Thread.Mutex = .{},
    /// (source_node_id, topic) — 実際にバスに乗ったもの
    published: std.ArrayListUnmanaged(struct { src: u32, topic: []u8 }) = .{},
    /// (node_id, topic) — acl_denied として監査されたもの
    denied: std.ArrayListUnmanaged(struct { node: u32, topic: []u8 }) = .{},

    fn onAny(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *Observed = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = std.heap.page_allocator;
        if (std.mem.eql(u8, msg.topic, "core.security.acl_denied")) {
            const P = struct { node_id: u32, topic: []const u8 };
            const p = std.json.parseFromSlice(P, a, msg.payload, .{ .ignore_unknown_fields = true }) catch return;
            defer p.deinit();
            self.denied.append(a, .{ .node = p.value.node_id, .topic = a.dupe(u8, p.value.topic) catch return }) catch {};
            return;
        }
        if (msg.source_node_id < 100) return; // Core や組み込みノードの発行は対象外
        // Core がプラグインに代わって出すテレメトリ (送信元はそのノードの id になっている) は、
        // プラグインが書いたものではないので対象外 (WasmSubscriber が発行する)
        if (std.mem.eql(u8, msg.topic, "core.node.metrics") or std.mem.eql(u8, msg.topic, "core.node.fault")) return;
        self.published.append(a, .{ .src = msg.source_node_id, .topic = a.dupe(u8, msg.topic) catch return }) catch {};
    }
};

fn covered(patterns: []const []const u8, topic: []const u8) bool {
    for (patterns) |p| if (pattern.isMatch(p, topic)) return true;
    return false;
}

test "A1: weave audit's prediction matches what the plugins actually did" {
    const allocator = std.testing.allocator;
    const host_api = @import("../api/host_api.zig");

    // --- 予測 (起動前, manifest のみ) ---
    var arena_inst = std.heap.ArenaAllocator.init(allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const plugins = [_][]const u8{ "malicious_plugin", "spam_node", "limits_node", "kusa_node" };
    var nodes: std.ArrayListUnmanaged(blast.Node) = .{};
    try nodes.appendSlice(arena, try blast.builtinNodes(arena));
    for (plugins) |name| {
        try nodes.append(arena, try blast.loadManifestNode(arena, try std.fmt.allocPrint(arena, "wasm-apps/{s}.json", .{name})));
    }
    var reports: [plugins.len]blast.BlastReport = undefined;
    var manifest_names: [plugins.len][]const u8 = undefined;
    for (plugins, 0..) |_, i| {
        manifest_names[i] = nodes.items[nodes.items.len - plugins.len + i].name;
        reports[i] = try blast.computeBlast(arena, nodes.items, manifest_names[i]);
    }

    // --- 観測 (同じプラグインを実際に動かす) ---
    var core = try Core.init(allocator);
    defer core.deinit();
    core.bus.verbose = false;
    core.pm.runtime = &core.runtime;
    host_api.global_bus = &core.bus;
    host_api.global_plugin_manager = &core.pm;
    host_api.enable_log = false;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
        host_api.enable_log = true;
    }
    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);

    var obs = Observed{};
    defer {
        for (obs.published.items) |p| std.heap.page_allocator.free(p.topic);
        obs.published.deinit(std.heap.page_allocator);
        for (obs.denied.items) |d| std.heap.page_allocator.free(d.topic);
        obs.denied.deinit(std.heap.page_allocator);
    }
    const observe = try core.bus.createCell("observe.test", .{});
    try core.bus.subscribeEx("#", 95, Observed.onAny, &obs, .{ .cell = observe, .receive_own = true, .record_graph = false });
    try core.bus.start();

    var node_ids: [plugins.len]u32 = undefined;
    for (plugins, 0..) |name, i| {
        node_ids[i] = core.pm.next_node_id;
        try core.loadPlugin(try std.fmt.allocPrint(arena, "wasm-apps/{s}.wasm", .{name}));
    }

    // 攻撃・暴走・正常動作を起こす
    var k: usize = 0;
    while (k < 12) : (k += 1) try core.bus.publish("ext.twitch.chat.message", "{\"user\":\"v\",\"message\":\"草\"}", .BestEffort, 0);
    try core.bus.publish("core.system.tick", "{}", .BestEffort, 0);
    try core.bus.publish("ext.limits.cmd", "topics:8", .Reliable, 0);
    core.bus.waitIdle();

    obs.mutex.lock();
    defer obs.mutex.unlock();
    for (plugins, 0..) |name, i| {
        const r = reports[i];
        const id = node_ids[i];
        var published_n: usize = 0;
        var obs_requests: usize = 0;
        for (obs.published.items) |p| {
            if (p.src != id) continue;
            published_n += 1;
            // (1) 観測された発行は予測した範囲内
            if (!covered(r.writable, p.topic)) {
                std.debug.print("A1 mismatch: {s} published '{s}' outside the predicted write set\n", .{ name, p.topic });
                return error.PredictionViolated;
            }
            if (std.mem.startsWith(u8, p.topic, "core.obs.request.")) obs_requests += 1;
        }
        // (2) 拒否されたものは予測の範囲外
        var denied_n: usize = 0;
        for (obs.denied.items) |d| {
            if (d.node != id) continue;
            denied_n += 1;
            if (covered(r.writable, d.topic)) {
                std.debug.print("A1 mismatch: {s} was denied '{s}' although it was predicted writable\n", .{ name, d.topic });
                return error.PredictionViolated;
            }
        }
        // (3) 実世界シンクへの到達
        if (r.reachable_sinks.len == 0) {
            try std.testing.expectEqual(@as(usize, 0), obs_requests);
        } else if (obs_requests > 0) {
            var has_obs = false;
            for (r.reachable_sinks) |s| {
                if (std.mem.eql(u8, s.node_name, "ObsEgress")) has_obs = true;
            }
            try std.testing.expect(has_obs);
        }
        std.debug.print("[A1] {s}: predicted write {d} pattern(s), sinks {d} | observed {d} publish(es), {d} denied, {d} OBS request(s)\n", .{ name, r.writable.len, r.reachable_sinks.len, published_n, denied_n, obs_requests });
        // 予測が空振りでないこと (各プラグインは実際に何か出している)
        try std.testing.expect(published_n > 0);
    }
    // 攻撃 3 (core.system.shutdown) は拒否され監査されている
    var shutdown_denied = false;
    for (obs.denied.items) |d| {
        if (d.node == node_ids[0] and std.mem.eql(u8, d.topic, "core.system.shutdown")) shutdown_denied = true;
    }
    try std.testing.expect(shutdown_denied);
}
