//! HealthMonitor — 「いま何が止まっていて、その原因はどれか」を実行中に出す (core.health.summary)。
//!
//! 監査 (`weave audit --failure`) と同じ宣言グラフ・同じ規則 (blast.computeFailureSet) を、
//! 起動前の「もし落ちたら」ではなく、いま実際に止まっているノードの集合に当てはめる。
//! - 起動時に指定したプラグインと --expect のノードは「本来いるはず」。グラフにいなければ「起動していない」
//!   (読み込みに失敗した・起動を忘れた外部ツール)
//! - ビルトイン (Twitch など) は、この構成で起動していなければ「使っていない」とみなし、止まったとは言わない
//! - 出力は観測専用の端末 (/status) にも渡すので、ノード名とトピック名だけを載せる (メッセージの中身は載せない)
//! - 中身が変わったときだけ publish する。最新値を保持するトピックなので、後から開いた端末にもすぐ届く

const std = @import("std");
const event_bus = @import("event_bus.zig");
const graph_mod = @import("graph.zig");
const SystemGraph = graph_mod.SystemGraph;
const blast = @import("../audit/blast.zig");
const log = @import("../common/log.zig");

pub const NODE_ID: u32 = 11;
pub const TOPIC = "core.health.summary";
const MAX_RECENT = 5;
const MAX_OBS_PROBLEMS = 8;

pub const HealthMonitor = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    graph: *SystemGraph,
    /// 宣言 (起動中ずっと使う)
    decl_arena: std.heap.ArenaAllocator,
    declared: std.ArrayListUnmanaged(Declared) = .{},
    lint_issues: []const blast.LintIssue = &.{},
    started_ms: i64,
    stopped: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 計算と publish を 1 つずつにする (tick と状態変化の通知は同じセルだが、start() は別スレッドから呼ぶ)
    mutex: std.Thread.Mutex = .{},
    last_body: std.ArrayListUnmanaged(u8) = .{},
    recent: [MAX_RECENT]Recent = undefined,
    recent_len: usize = 0,
    /// OBS に断られている要求 (core.obs.problem)。同じ要求が通ったら消える
    obs_problems: std.ArrayListUnmanaged(ObsProblem) = .{},
    /// 入力から OBS に送るまでの時間 (core.obs.latency)。0.1 ms 単位に丸めて持つ (細かい揺れで /status を更新しない)
    latency: ?Latency = null,
    /// ラップした既存ツール (ObsGate) を止めている理由。名前 → 理由 (core.wrap.status)
    wrap_reasons: std.StringHashMapUnmanaged([]u8) = .{},

    const Latency = struct { p50_ms: f64 = 0, p99_ms: f64 = 0, max_ms: f64 = 0 };

    const ObsProblem = struct {
        node_id: u32,
        request: []u8,
        target: []u8,
        target_kind: []u8,
        code: i64,
        comment: []u8,
        suggestion: ?[]u8,
        count: u32 = 1,
        ts: i64,

        fn free(self: *ObsProblem, a: std.mem.Allocator) void {
            a.free(self.request);
            a.free(self.target);
            a.free(self.target_kind);
            a.free(self.comment);
            if (self.suggestion) |x| a.free(x);
        }
    };

    pub const Declared = struct {
        node: blast.Node,
        /// 起動時に指定された / --expect で宣言された。グラフにいなければ「起動していない」
        expected: bool,
        /// ビルトイン。登録されていなければ「この構成では使っていない」
        builtin: bool,
        /// 起動時に読み込みを拒否した理由 (例: "approval_required")。起動していないときは missing の代わりにこれを出す
        blocked: ?[]const u8 = null,
        /// プラグインの wasm のパス (「weave add <path>」のように、どうすればいいかを示すため)
        wasm_path: ?[]const u8 = null,
    };

    const Recent = struct {
        name_buf: [64]u8 = undefined,
        name_len: usize = 0,
        down_ms: i64 = 0,
        ts: i64 = 0,
        fn name(self: *const Recent) []const u8 {
            return self.name_buf[0..self.name_len];
        }
    };

    pub fn create(allocator: std.mem.Allocator, bus: *event_bus.EventBus, graph: *SystemGraph) !*HealthMonitor {
        const self = try allocator.create(HealthMonitor);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .graph = graph,
            .decl_arena = std.heap.ArenaAllocator.init(allocator),
            .started_ms = std.time.milliTimestamp(),
        };
        return self;
    }

    pub fn destroy(self: *HealthMonitor) void {
        self.stopped.store(true, .release);
        self.mutex.lock();
        self.last_body.deinit(self.allocator);
        for (self.obs_problems.items) |*o| o.free(self.allocator);
        self.obs_problems.deinit(self.allocator);
        var wit = self.wrap_reasons.iterator();
        while (wit.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.wrap_reasons.deinit(self.allocator);
        self.mutex.unlock();
        self.decl_arena.deinit();
        self.allocator.destroy(self);
    }

    pub fn addBuiltins(self: *HealthMonitor) !void {
        const nodes = try blast.builtinNodes(self.decl_arena.allocator());
        for (nodes) |n| try self.declared.append(self.decl_arena.allocator(), .{ .node = n, .expected = false, .builtin = true });
    }

    /// manifest を「本来いるはずのノード」として加える (起動時に指定したプラグイン / --expect)
    pub fn addManifest(self: *HealthMonitor, path: []const u8, declared_cells: []const []const u8) !void {
        const a = self.decl_arena.allocator();
        const node = try blast.loadManifestNodeIn(a, path, declared_cells);
        const wasm_path: ?[]const u8 = if (std.mem.endsWith(u8, path, ".json")) try std.fmt.allocPrint(a, "{s}.wasm", .{path[0 .. path.len - 5]}) else null;
        for (self.declared.items) |*d| {
            if (std.mem.eql(u8, d.node.name, node.name)) {
                d.expected = true;
                return;
            }
        }
        try self.declared.append(a, .{ .node = node, .expected = true, .builtin = false, .wasm_path = wasm_path });
    }

    /// 起動時に読み込みを拒否したプラグイン (未承認・権限の増加など)。「起動していない」の代わりに理由を出す
    pub fn addBlockedManifest(self: *HealthMonitor, path: []const u8, declared_cells: []const []const u8, reason: []const u8) !void {
        try self.addManifest(path, declared_cells);
        const node = try blast.loadManifestNodeIn(self.decl_arena.allocator(), path, declared_cells);
        for (self.declared.items) |*d| {
            if (std.mem.eql(u8, d.node.name, node.name)) d.blocked = try self.decl_arena.allocator().dupe(u8, reason);
        }
    }

    /// 設定ミス (誰も出していないトピックの購読で、近い名前があるもの) を調べる。結果は summary にも載る
    pub fn runLint(self: *HealthMonitor) ![]const blast.LintIssue {
        const a = self.decl_arena.allocator();
        const nodes = try a.alloc(blast.Node, self.declared.items.len);
        for (self.declared.items, 0..) |d, i| nodes[i] = d.node;
        self.lint_issues = try blast.lint(a, nodes);
        return self.lint_issues;
    }

    pub fn start(self: *HealthMonitor) !void {
        const observe = self.bus.getCell("observe") orelse try self.bus.createCell("observe", .{ .trust = .core });
        const opts: event_bus.EventBus.SubscribeOptions = .{ .cell = observe, .record_graph = false };
        for ([_][]const u8{ "core.system.tick", "core.node.down", "core.node.recovered", "core.node.registered", "core.system.graph.delta", "core.obs.problem", "core.obs.latency", "core.wrap.status" }) |t| {
            try self.bus.subscribeEx(t, NODE_ID, onBusMessage, self, opts);
        }
        self.recompute();
    }

    fn onBusMessage(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *HealthMonitor = @ptrCast(@alignCast(ctx orelse return));
        if (self.stopped.load(.acquire)) return;
        if (std.mem.eql(u8, msg.topic, "core.node.recovered")) self.noteRecovered(msg.payload);
        if (std.mem.eql(u8, msg.topic, "core.obs.problem")) self.noteObsProblem(msg.payload);
        if (std.mem.eql(u8, msg.topic, "core.obs.latency")) self.noteLatency(msg.payload);
        if (std.mem.eql(u8, msg.topic, "core.wrap.status")) self.noteWrap(msg.payload);
        self.recompute();
    }

    /// ラップした既存ツールを止めた / 戻した (ObsGate)。止めている間は理由を「どうすれば」に出す
    pub fn noteWrap(self: *HealthMonitor, payload: []const u8) void {
        const P = struct { name: []const u8 = "", state: []const u8 = "", reason: []const u8 = "" };
        const parsed = std.json.parseFromSlice(P, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const v = parsed.value;
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = self.allocator;
        if (self.wrap_reasons.fetchRemove(v.name)) |old| {
            a.free(old.key);
            a.free(old.value);
        }
        if (!std.mem.eql(u8, v.state, "quarantined")) return;
        const k = a.dupe(u8, v.name) catch return;
        const r = std.fmt.allocPrint(a, "{s}。止めている間も配信と他のツールはそのまま動きます。時間が過ぎると自動で戻します", .{v.reason}) catch {
            a.free(k);
            return;
        };
        self.wrap_reasons.put(a, k, r) catch {
            a.free(k);
            a.free(r);
        };
    }

    pub fn noteLatency(self: *HealthMonitor, payload: []const u8) void {
        const P = struct { p50_us: u32 = 0, p99_us: u32 = 0, max_us: u32 = 0 };
        const parsed = std.json.parseFromSlice(P, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const q = struct {
            fn ms(us: u32) f64 {
                return @round(@as(f64, @floatFromInt(us)) / 100.0) / 10.0;
            }
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        // 件数は持たない (件数が増えるたびに /status を更新しない。分位点が 0.1 ms 動いたときだけ変わる)
        self.latency = .{ .p50_ms = q.ms(parsed.value.p50_us), .p99_ms = q.ms(parsed.value.p99_us), .max_ms = q.ms(parsed.value.max_us) };
    }

    pub fn noteObsProblem(self: *HealthMonitor, payload: []const u8) void {
        const P = struct { node_id: u32 = 0, request: []const u8 = "", target: []const u8 = "", target_kind: []const u8 = "other", code: i64 = 0, comment: []const u8 = "", suggestion: ?[]const u8 = null, resolved: bool = false };
        const parsed = std.json.parseFromSlice(P, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const v = parsed.value;
        self.mutex.lock();
        defer self.mutex.unlock();
        const a = self.allocator;
        for (self.obs_problems.items, 0..) |*o, i| {
            if (o.node_id == v.node_id and std.mem.eql(u8, o.request, v.request) and std.mem.eql(u8, o.target, v.target)) {
                if (v.resolved) {
                    o.free(a);
                    _ = self.obs_problems.orderedRemove(i);
                } else {
                    o.count += 1;
                    o.ts = std.time.milliTimestamp();
                }
                return;
            }
        }
        if (v.resolved) return;
        if (self.obs_problems.items.len >= MAX_OBS_PROBLEMS) {
            var old = self.obs_problems.orderedRemove(0);
            old.free(a);
        }
        const o = ObsProblem{
            .node_id = v.node_id,
            .request = a.dupe(u8, v.request) catch return,
            .target = a.dupe(u8, v.target) catch return,
            .target_kind = a.dupe(u8, v.target_kind) catch return,
            .code = v.code,
            .comment = a.dupe(u8, v.comment) catch return,
            .suggestion = if (v.suggestion) |x| (a.dupe(u8, x) catch null) else null,
            .ts = std.time.milliTimestamp(),
        };
        self.obs_problems.append(a, o) catch {};
    }

    fn noteRecovered(self: *HealthMonitor, payload: []const u8) void {
        const parsed = std.json.parseFromSlice(struct { name: []const u8 = "", down_ms: i64 = 0, ts: i64 = 0 }, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        self.mutex.lock();
        defer self.mutex.unlock();
        // 新しい順に並べる (先頭が最新)
        if (self.recent_len < MAX_RECENT) self.recent_len += 1;
        var i: usize = self.recent_len - 1;
        while (i > 0) : (i -= 1) self.recent[i] = self.recent[i - 1];
        var r = Recent{ .down_ms = parsed.value.down_ms, .ts = parsed.value.ts };
        r.name_len = @min(parsed.value.name.len, r.name_buf.len);
        @memcpy(r.name_buf[0..r.name_len], parsed.value.name[0..r.name_len]);
        self.recent[0] = r;
    }

    const Model = struct {
        nodes: []blast.Node,
        status: [][]const u8,
        since: []?i64,
        expected: []bool,
    };

    /// 宣言とグラフの写しから、計算に使うノードと状態を組み立てる
    fn buildModel(self: *HealthMonitor, arena: std.mem.Allocator) !Model {
        const snap = try self.graph.snapshot(arena);
        var nodes = std.ArrayListUnmanaged(blast.Node){};
        var status = std.ArrayListUnmanaged([]const u8){};
        var since = std.ArrayListUnmanaged(?i64){};
        var expected = std.ArrayListUnmanaged(bool){};
        var used = try arena.alloc(bool, snap.len);
        @memset(used, false);

        for (self.declared.items) |d| {
            if (std.mem.eql(u8, d.node.name, "Core")) {
                // Core 自身は止まっていれば何も出せないので、常に動いているものとして扱う
                try nodes.append(arena, d.node);
                try status.append(arena, "active");
                try since.append(arena, null);
                try expected.append(arena, false);
                continue;
            }
            const found: ?usize = for (snap, 0..) |s, i| {
                if (!used[i] and std.mem.eql(u8, s.name, d.node.name)) break i;
            } else null;
            if (found) |i| {
                used[i] = true;
                try nodes.append(arena, d.node);
                try status.append(arena, @tagName(snap[i].status));
                try since.append(arena, snap[i].down_since_ms);
                try expected.append(arena, d.expected);
            } else if (d.expected) {
                try nodes.append(arena, d.node);
                try status.append(arena, d.blocked orelse "missing");
                try since.append(arena, self.started_ms);
                try expected.append(arena, true);
            }
            // ビルトインで登録されていないもの (--no-twitch の Twitch など) は、この構成では使っていない
        }

        // 宣言に無いがグラフにいるノード (外部ノードなど) は、観測した pub/sub で扱う。並びは名前順で固定する
        var extra = std.ArrayListUnmanaged(usize){};
        for (snap, 0..) |s, i| {
            if (!used[i] and !std.mem.endsWith(u8, s.name, ".wasm")) try extra.append(arena, i);
        }
        std.mem.sort(usize, extra.items, @as([]const SystemGraph.NodeSnapshot, snap), struct {
            fn lt(sn: []const SystemGraph.NodeSnapshot, a: usize, b: usize) bool {
                return std.mem.lessThan(u8, sn[a].name, sn[b].name);
            }
        }.lt);
        for (extra.items) |i| {
            const s = snap[i];
            try nodes.append(arena, .{
                .name = s.name,
                .kind = @tagName(s.node_type),
                .pub_patterns = @constCast(s.pub_topics),
                .sub_patterns = @constCast(s.sub_topics),
            });
            try status.append(arena, @tagName(s.status));
            try since.append(arena, s.down_since_ms);
            try expected.append(arena, false);
        }
        return .{ .nodes = nodes.items, .status = status.items, .since = since.items, .expected = expected.items };
    }

    /// 状態ごとの「どうすればいいか」(配信の現場の言葉で)
    fn actionFor(arena: std.mem.Allocator, status: []const u8, node: []const u8, wasm_path: ?[]const u8) ![]const u8 {
        const eq = std.mem.eql;
        if (eq(u8, status, "approval_required"))
            return std.fmt.allocPrint(arena, "PC で weave add {s} を実行し、権限を確認して承認してください", .{wasm_path orelse node});
        if (eq(u8, status, "missing"))
            return std.fmt.allocPrint(arena, "{s} が起動していません。起動コマンドに入れてください (weave add 済みなら weave run だけで起動します)", .{node});
        if (eq(u8, status, "restarting")) return arena.dupe(u8, "自動で作り直しています。数秒で戻ります");
        if (eq(u8, status, "quarantined")) return arena.dupe(u8, "何度も落ちたため止めています。直前の操作を確かめてから WEAVE を起動し直してください");
        if (eq(u8, status, "disconnected")) return arena.dupe(u8, "接続先 (OBS など) が起動しているか確かめてください。戻れば自動でつながり、表示も元に戻ります");
        return arena.dupe(u8, "");
    }

    fn isDownLabel(s: []const u8) bool {
        if (std.mem.eql(u8, s, "missing") or std.mem.eql(u8, s, "approval_required")) return true;
        const st = std.meta.stringToEnum(@import("../common/types.zig").NodeStatus, s) orelse return false;
        return graph_mod.isDown(st);
    }

    /// 本文 (updated を除く) を JSON で書く。テストと publish で共通
    pub fn writeBody(self: *HealthMonitor, arena: std.mem.Allocator, w: anytype) !void {
        const m = try self.buildModel(arena);

        var down = std.ArrayListUnmanaged([]const u8){};
        const JNode = struct { name: []const u8, kind: []const u8, status: []const u8 };
        const JProblem = struct { node: []const u8, status: []const u8, since: ?i64, expected: bool, action: []const u8 };
        var jnodes = std.ArrayListUnmanaged(JNode){};
        var problems = std.ArrayListUnmanaged(JProblem){};
        for (m.nodes, 0..) |n, i| {
            if (std.mem.eql(u8, n.name, "Core")) continue;
            try jnodes.append(arena, .{ .name = n.name, .kind = n.kind, .status = m.status[i] });
            if (isDownLabel(m.status[i])) {
                try down.append(arena, n.name);
                const wasm_path: ?[]const u8 = for (self.declared.items) |d| {
                    if (std.mem.eql(u8, d.node.name, n.name)) break d.wasm_path;
                } else null;
                const action = if (self.wrap_reasons.get(n.name)) |r| try arena.dupe(u8, r) else try actionFor(arena, m.status[i], n.name, wasm_path);
                try problems.append(arena, .{ .node = n.name, .status = m.status[i], .since = m.since[i], .expected = m.expected[i], .action = action });
            }
        }
        const report = try blast.computeFailureSet(arena, m.nodes, down.items);

        const JImpact = struct { node: []const u8, effect: []const u8, because: [][]const u8, lost: [][]const u8 };
        var impacts = try arena.alloc(JImpact, report.impacts.len);
        for (report.impacts, 0..) |im, i| impacts[i] = .{ .node = im.node, .effect = @tagName(im.effect), .because = im.because, .lost = im.lost };

        const JWarn = struct { node: []const u8, topic: []const u8, suggestion: []const u8, from: []const u8 };
        var warns = try arena.alloc(JWarn, self.lint_issues.len);
        for (self.lint_issues, 0..) |l, i| warns[i] = .{ .node = l.node, .topic = l.topic, .suggestion = l.suggestion, .from = l.suggestion_from };

        const JRecent = struct { node: []const u8, down_ms: i64, ts: i64 };
        var recent = try arena.alloc(JRecent, self.recent_len);
        for (self.recent[0..self.recent_len], 0..) |*r, i| recent[i] = .{ .node = try arena.dupe(u8, r.name()), .down_ms = r.down_ms, .ts = r.ts };

        // OBS に断られている要求。送り主はノード ID → 名前に直す
        const JObs = struct { plugin: []const u8, request: []const u8, target: []const u8, target_kind: []const u8, code: i64, comment: []const u8, suggestion: ?[]const u8, count: u32, ts: i64, action: []const u8 };
        const snap = try self.graph.snapshot(arena);
        var obs = try arena.alloc(JObs, self.obs_problems.items.len);
        for (self.obs_problems.items, 0..) |o, i| {
            const plugin: []const u8 = for (snap) |sn| {
                if (sn.id == o.node_id) break sn.name;
            } else if (o.node_id == 0) "WEAVE" else try std.fmt.allocPrint(arena, "node {d}", .{o.node_id});
            const what: []const u8 = if (std.mem.eql(u8, o.target_kind, "scene")) "シーン" else "ソース";
            const action = if (o.code != 600)
                try std.fmt.allocPrint(arena, "OBS が断りました: {s}", .{o.comment})
            else if (o.suggestion) |sg|
                try std.fmt.allocPrint(arena, "OBS に「{s}」という{s}がありません。もしかして「{s}」? 指定した名前を「{s}」に直すか、OBS 側の名前を「{s}」に変えると動きます", .{ o.target, what, sg, sg, o.target })
            else
                try std.fmt.allocPrint(arena, "OBS に「{s}」という{s}がありません。OBS で「{s}」という名前の{s}を作ってください", .{ o.target, what, o.target, what });
            obs[i] = .{ .plugin = plugin, .request = o.request, .target = o.target, .target_kind = o.target_kind, .code = o.code, .comment = o.comment, .suggestion = o.suggestion, .count = o.count, .ts = o.ts, .action = action };
        }

        const overall: []const u8 = if (problems.items.len > 0 or report.sinks_stopped.len > 0 or obs.len > 0) "trouble" else if (warns.len > 0) "warn" else "ok";
        try w.print("{f}", .{std.json.fmt(.{
            .overall = overall,
            .nodes = jnodes.items,
            .problems = problems.items,
            .impacts = impacts,
            .sinks = report.sink_effects,
            .sinks_stopped = report.sinks_stopped,
            .warnings = warns,
            .recent = recent,
            .obs_problems = obs,
            .latency = self.latency,
        }, .{})});
    }

    pub fn recompute(self: *HealthMonitor) void {
        if (self.stopped.load(.acquire)) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        var arena_inst = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_inst.deinit();
        const arena = arena_inst.allocator();

        var body = std.ArrayListUnmanaged(u8){};
        self.writeBody(arena, body.writer(arena)) catch |err| {
            log.warn("Health: failed to compute: {any}", .{err});
            return;
        };
        if (std.mem.eql(u8, body.items, self.last_body.items)) return;
        self.last_body.clearRetainingCapacity();
        self.last_body.appendSlice(self.allocator, body.items) catch return;

        // {"updated":<ms>, ...本文} (本文は必ず 1 つ以上のフィールドを持つオブジェクト)
        var out = std.ArrayListUnmanaged(u8){};
        out.writer(arena).print("{{\"updated\":{d},", .{std.time.milliTimestamp()}) catch return;
        out.appendSlice(arena, body.items[1..]) catch return;
        self.bus.publish(TOPIC, out.items, .Transient, 0) catch |err| log.warn("Health: publish failed: {any}", .{err});
    }
};

// ============================================================
// テスト
// ============================================================

fn writeManifest(dir: std.fs.Dir, name: []const u8, json: []const u8) !void {
    try dir.writeFile(.{ .sub_path = name, .data = json });
}

test "HealthMonitor: a forgotten tool is reported as missing, and the overlay that depends on it as stalled" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(a);
    defer graph.deinit();
    graph.bus = &bus;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir, "score_tool.json", "{\"name\":\"score_tool\",\"permissions\":{\"publish\":[\"ext.score.update\"],\"subscribe\":[\"ext.twitch.chat.message\"]}}");
    try writeManifest(tmp.dir, "scoreboard.json", "{\"name\":\"scoreboard\",\"permissions\":{\"publish\":[\"core.obs.request.SetInputSettings\"],\"subscribe\":[\"ext.score.update\"]}}");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var p1: [std.fs.max_path_bytes]u8 = undefined;
    var p2: [std.fs.max_path_bytes]u8 = undefined;

    const hm = try HealthMonitor.create(a, &bus, &graph);
    defer hm.destroy();
    try hm.addBuiltins();
    try hm.addManifest(try std.fmt.bufPrint(&p1, "{s}/score_tool.json", .{dir_path}), &.{});
    try hm.addManifest(try std.fmt.bufPrint(&p2, "{s}/scoreboard.json", .{dir_path}), &.{});

    // scoreboard と OBS は動いている。score_tool は起動していない (グラフにいない)
    try graph.registerNodeIn(100, "scoreboard", .wasm, "plugin.scoreboard");
    try graph.registerNodeIn(2, "ObsEgress", .native, "egress");

    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    try hm.writeBody(arena_inst.allocator(), out.writer(arena_inst.allocator()));
    const body = out.items;

    try std.testing.expect(std.mem.indexOf(u8, body, "\"overall\":\"trouble\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"node\":\"score_tool\",\"status\":\"missing\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"node\":\"scoreboard\",\"effect\":\"stalled\",\"because\":[\"score_tool\"]") != null);
    // Twitch は起動していない (--no-twitch 相当) が、使っていないだけなので問題には出さない
    try std.testing.expect(std.mem.indexOf(u8, body, "TwitchAdapter") == null);
}

test "HealthMonitor: a plugin refused for lack of approval says so, and what stalls because of it" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(a);
    defer graph.deinit();
    graph.bus = &bus;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeManifest(tmp.dir, "scoreboard.json", "{\"name\":\"scoreboard\",\"permissions\":{\"publish\":[\"core.obs.request.SetInputSettings\"],\"subscribe\":[\"ext.score.update\"]}}");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = try tmp.dir.realpath(".", &path_buf);
    var p1: [std.fs.max_path_bytes]u8 = undefined;

    const hm = try HealthMonitor.create(a, &bus, &graph);
    defer hm.destroy();
    try hm.addBuiltins();
    try hm.addBlockedManifest(try std.fmt.bufPrint(&p1, "{s}/scoreboard.json", .{dir_path}), &.{}, "approval_required");
    try graph.registerNodeIn(2, "ObsEgress", .native, "egress");

    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    try hm.writeBody(arena_inst.allocator(), out.writer(arena_inst.allocator()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "{\"node\":\"scoreboard\",\"status\":\"approval_required\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"overall\":\"trouble\"") != null);
}

test "HealthMonitor: everything running → ok, and a plugin that restarts shows up in recent" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(a);
    defer graph.deinit();
    graph.bus = &bus;

    const hm = try HealthMonitor.create(a, &bus, &graph);
    defer hm.destroy();
    try hm.addBuiltins();
    try graph.registerNodeIn(2, "ObsEgress", .native, "egress");
    hm.noteRecovered("{\"name\":\"loop_node\",\"down_ms\":2,\"ts\":123}");

    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    try hm.writeBody(arena_inst.allocator(), out.writer(arena_inst.allocator()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"overall\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"recent\":[{\"node\":\"loop_node\",\"down_ms\":2,\"ts\":123}]") != null);
}

test "HealthMonitor: OBS disconnected → the sink is reported as stopped" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(a);
    defer graph.deinit();
    graph.bus = &bus;

    const hm = try HealthMonitor.create(a, &bus, &graph);
    defer hm.destroy();
    try hm.addBuiltins();
    try graph.registerNodeIn(2, "ObsEgress", .native, "egress");
    graph.updateNodeStatus(2, .degraded);

    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    try hm.writeBody(arena_inst.allocator(), out.writer(arena_inst.allocator()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"overall\":\"trouble\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"sinks_stopped\":[\"ObsEgress\"]") != null);
}

test "HealthMonitor: OBS refusing a name shows which plugin, the closest name, and clears once it works" {
    const a = std.testing.allocator;
    var bus = try event_bus.EventBus.init(a, 16);
    defer bus.deinit();
    bus.verbose = false;
    var graph = SystemGraph.init(a);
    defer graph.deinit();
    graph.bus = &bus;
    const hm = try HealthMonitor.create(a, &bus, &graph);
    defer hm.destroy();
    try graph.registerNodeIn(105, "scoreboard", .wasm, "plugin.scoreboard");

    const p = "{\"node_id\":105,\"request\":\"SetInputSettings\",\"target\":\"Scoreboard\",\"target_kind\":\"input\",\"code\":600,\"comment\":\"No source\",\"suggestion\":\"Score Board\",\"resolved\":false}";
    hm.noteObsProblem(p);
    hm.noteObsProblem(p);
    var arena_inst = std.heap.ArenaAllocator.init(a);
    defer arena_inst.deinit();
    var out = std.ArrayListUnmanaged(u8){};
    try hm.writeBody(arena_inst.allocator(), out.writer(arena_inst.allocator()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"plugin\":\"scoreboard\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "もしかして「Score Board」") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"count\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"overall\":\"trouble\"") != null);

    hm.noteObsProblem("{\"node_id\":105,\"request\":\"SetInputSettings\",\"target\":\"Scoreboard\",\"resolved\":true}");
    out.clearRetainingCapacity();
    try hm.writeBody(arena_inst.allocator(), out.writer(arena_inst.allocator()));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"obs_problems\":[]") != null);
}
