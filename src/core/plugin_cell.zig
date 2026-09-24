//! PluginCell — Wasm プラグインを別の OS プロセス (weave-cell plugin) で動かす (ADR-010 段階 2)。
//!
//! 子プロセスの中では、今の部品 (バス・PluginManager・WasmSubscriber) がそのまま動くので、trap からの復帰・
//! 毒メッセージの隔離・予備インスタンス・状態のコミット・breaker (R2〜R5/R8) は子の中で今までどおり働く。
//! 違うのは Host API で、子は publish / subscribe を判定せずに Core へ問い合わせる。Core はここで、同じプロセスで
//! 動くプラグインと**まったく同じ検査** (host_api.publishChecked / subscribeAllowed) を通す。強制点は Core に 1 つ。
//!
//! 配送: Core のバスで購読を張り、届いたメッセージを子に渡し、子が処理を終える ("done") まで待つ。
//!       待っている間に来る子からの問い合わせ (pub / sub / unsub / tele) に答える。順序と背圧は同じプロセスの時と同じ。
//! 障害: 子のプロセスごと落ちたら (kill -9・WAMR の不具合など)、処理中だったメッセージを**Core 側で**毒として隔離し、
//!       子を起動し直して検証済みの wasm を渡し直す。短時間に落ち続けたら manifest の restart に従って隔離する。
//! wasm: 署名を検証した Core が、そのバイト列をソケットで子に渡す。子はディスクを読まない。
//!
//! プロトコル (ws_proto のフレーム):
//!   子 → Core : {"hello":"plugin","token":".."}                 最初の 1 通
//!   Core → 子 : {"op":"load","node_id":N} + binary(manifest) + binary(wasm)
//!   子 → Core : {"op":"ready"}
//!   Core → 子 : {"op":"msg","id":..,"t":"..","p":"..","ts":..,"qos":..}
//!   子 → Core : {"op":"pub","t":"..","p":"..","qos":..} / {"op":"sub","t":".."} / {"op":"unsub","t":".."}  → Core: {"op":"ret","code":..}
//!   子 → Core : {"op":"tele","t":"core.node.metrics|fault|poison","p":".."}   (payload の node_id は自分のものに限る)
//!   子 → Core : {"op":"done","state":"<hex>"}   (state はコミット済みの状態が変わった時だけ。Core が保持する)
//!   Core → 子 : {"op":"restore","state":"<hex>"} → 子 : {"op":"restored"}   (起動し直した時に状態を書き戻す)
const std = @import("std");
const event_bus = @import("event_bus.zig");
const ws = @import("../transport/ws_proto.zig");
const log = @import("../common/log.zig");
const host_api = @import("../api/host_api.zig");
const plugin_manager = @import("plugin_manager.zig");
const fingerprint = @import("wasm_subscriber.zig").fingerprint;
const cgroup = @import("../security/cgroup.zig");

pub const PluginCell = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    /// Core 側の身元 (manifest・流量・トピック数の記録)。インスタンスは持たない
    meta: *plugin_manager.PluginMetadata,
    cell: *event_bus.Cell,
    manifest_bytes: []u8,
    socket_path: []u8,
    child_argv: [4][]const u8 = undefined,
    token: [32]u8 = undefined,

    server: ?std.net.Server = null,
    stream: ?std.net.Stream = null,
    child: ?std.process.Child = null,
    /// 子とのやり取りは 1 つずつ (配送はセルの executor 1 本から来る)
    mutex: std.Thread.Mutex = .{},
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// 停止時にロックを取らずに子を止め、待っている読み込みを中断させるための控え
    child_pid: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    stream_fd: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    // 処理中のメッセージ (子からの publish の parent / 深さ)
    inflight_id: u64 = 0,
    inflight_hops: u8 = 0,

    // 子のプロセスごとの障害 (R2 を Core 側で / breaker)
    poison: std.AutoHashMapUnmanaged(u64, void) = .{},
    crash_times: [8]i64 = [_]i64{0} ** 8,
    crash_pos: usize = 0,
    quarantined_until: i64 = 0,
    crashes: u32 = 0,
    /// 資源の上限 (段階 3)。Core が持つ共有の cgroup 管理 (null なら掛けない)
    cgroups: ?*cgroup.Cgroups = null,
    cg_dir: ?[]u8 = null,
    /// 子がコミットした状態 (R5) の最新値。子のプロセスごと消えても、起動し直した子に書き戻す (手順 2-3)
    state: ?[]u8 = null,
    /// state だけのロック (スナップショットのスレッドが、長い配送の間も待たされずに読めるように)
    state_mutex: std.Thread.Mutex = .{},

    pub fn create(allocator: std.mem.Allocator, bus: *event_bus.EventBus, meta: *plugin_manager.PluginMetadata, cell: *event_bus.Cell, manifest_bytes: []const u8, cell_exe: []const u8, socket_path: []const u8) !*PluginCell {
        const self = try allocator.create(PluginCell);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .meta = meta,
            .cell = cell,
            .manifest_bytes = try allocator.dupe(u8, manifest_bytes),
            .socket_path = try allocator.dupe(u8, socket_path),
        };
        self.child_argv = .{ try allocator.dupe(u8, cell_exe), "plugin", "--socket", self.socket_path };
        var raw: [16]u8 = undefined;
        std.crypto.random.bytes(&raw);
        _ = std.fmt.bufPrint(&self.token, "{x}", .{&raw}) catch unreachable;
        return self;
    }

    pub fn destroy(self: *PluginCell) void {
        self.stop();
        self.poison.deinit(self.allocator);
        if (self.state) |st| self.allocator.free(st);
        self.allocator.free(self.child_argv[0]);
        self.allocator.free(self.manifest_bytes);
        self.allocator.free(self.socket_path);
        self.allocator.destroy(self);
    }

    fn name(self: *PluginCell) []const u8 {
        return self.meta.manifest_parsed.value.name;
    }

    /// 待ち受けを開き、manifest の購読を Core のバスに張り、子を起動して読み込ませる
    pub fn start(self: *PluginCell) !void {
        if (std.fs.path.dirname(self.socket_path)) |d| try std.fs.cwd().makePath(d);
        std.fs.cwd().deleteFile(self.socket_path) catch {};
        const addr = try std.net.Address.initUnix(self.socket_path);
        self.server = try addr.listen(.{});
        std.posix.fchmodat(std.fs.cwd().fd, self.socket_path, 0o600, 0) catch {};
        self.running.store(true, .release);

        self.mutex.lock();
        defer self.mutex.unlock();
        self.spawnAndLoad() catch |err| {
            log.err("PluginCell: '{s}' could not start its process: {any}", .{ self.name(), err });
            return err;
        };
        for (self.meta.manifest_parsed.value.permissions.subscribe) |pat| {
            try self.bus.subscribeEx(pat, self.meta.node_id, callback, self, .{ .cell = self.cell });
        }
        log.info("PluginCell: '{s}' (node {d}) runs in its own process (ADR-010 stage 2)", .{ self.name(), self.meta.node_id });
    }

    pub fn stop(self: *PluginCell) void {
        if (!self.running.swap(false, .acq_rel)) return;
        // 配送中 (子が長いループの最中など) はコールバックがロックを持って子の返事を待っている。
        // ロックを取る前に子を止めてソケットを閉じ側にし、待っている読み込みを中断させる
        const pid = self.child_pid.load(.acquire);
        if (pid > 0) std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        const fd = self.stream_fd.load(.acquire);
        if (fd >= 0) std.posix.shutdown(fd, .both) catch {};
        self.mutex.lock();
        defer self.mutex.unlock();
        self.dropChild(false);
        if (self.server) |*s| s.deinit();
        self.server = null;
        std.fs.cwd().deleteFile(self.socket_path) catch {};
    }

    fn dropChild(self: *PluginCell, kill: bool) void {
        if (self.stream) |s| {
            if (!kill) ws.writeFrame(s, .close, "", false) catch {};
            std.posix.shutdown(s.handle, .both) catch {};
            self.stream_fd.store(-1, .release);
            s.close();
            self.stream = null;
        }
        if (self.child) |*c| {
            if (!kill) {
                // 閉じたことに気づいて自分で終わるのを少しだけ待つ。処理の途中 (長いループなど) で終わらなければ止める
                var waited: u32 = 0;
                while (waited < 500) : (waited += 10) {
                    if (std.posix.waitpid(c.id, std.posix.W.NOHANG).pid == c.id) break;
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                } else {
                    std.posix.kill(c.id, std.posix.SIG.KILL) catch {};
                    _ = std.posix.waitpid(c.id, 0);
                }
            } else {
                std.posix.kill(c.id, std.posix.SIG.KILL) catch {};
                _ = std.posix.waitpid(c.id, 0);
            }
            self.child = null;
            self.child_pid.store(0, .release);
        }
        if (self.cg_dir) |d| {
            if (self.cgroups) |cg| cg.remove(d);
            self.cg_dir = null;
        }
    }

    fn send(self: *PluginCell, value: anytype) !void {
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        try out.writer(self.allocator).print("{f}", .{std.json.fmt(value, .{})});
        try ws.writeFrame(self.stream.?, .text, out.items, false);
    }

    /// 子を起動し、名乗りを確かめ、検証済みの manifest と wasm を渡して読み込ませる (mutex を持って呼ぶ)
    fn spawnAndLoad(self: *PluginCell) !void {
        var env = try std.process.getEnvMap(self.allocator);
        defer env.deinit();
        try env.put("WEAVE_CELL_TOKEN", &self.token);
        var child = std.process.Child.init(&self.child_argv, self.allocator);
        child.env_map = &env;
        child.stdin_behavior = .Ignore;
        try child.spawn();
        self.child = child;
        self.child_pid.store(child.id, .release);
        errdefer self.dropChild(true);
        if (self.cgroups) |cg| {
            var nbuf: [48]u8 = undefined;
            const cg_name = std.fmt.bufPrint(&nbuf, "cell-{d}-{d}", .{ self.meta.node_id, child.id }) catch "cell";
            const lim = self.meta.manifest_parsed.value.limits;
            // 線形メモリの上限 (現用 + 予備インスタンス) に、WAMR とバスの分を足す
            const mem: u64 = @as(u64, lim.memory_pages) * 65536 * 2 + 64 * 1024 * 1024;
            self.cg_dir = cg.place(cg_name, child.id, .{ .memory_bytes = mem }) catch |err| blk: {
                log.warn("PluginCell: '{s}': cgroup limits not applied ({any})", .{ self.name(), err });
                break :blk null;
            };
        }

        var server = &(self.server orelse return error.NotListening);
        const conn = try server.accept();
        self.stream = conn.stream;
        self.stream_fd.store(conn.stream.handle, .release);
        const hello = try ws.readMessage(conn.stream, self.allocator, 4096);
        defer self.allocator.free(hello.payload);
        const H = struct { hello: []const u8 = "", token: []const u8 = "" };
        const h = try std.json.parseFromSlice(H, self.allocator, hello.payload, .{ .ignore_unknown_fields = true });
        defer h.deinit();
        if (!std.mem.eql(u8, h.value.hello, "plugin") or !ws.constantTimeEql(h.value.token, &self.token)) return error.BadHello;

        try self.send(.{ .op = "load", .node_id = self.meta.node_id });
        try ws.writeFrame(conn.stream, .binary, self.manifest_bytes, false);
        try ws.writeFrame(conn.stream, .binary, self.meta.wasm_buffer, false);
        self.inflight_id = 0;
        self.inflight_hops = 0;
        try self.pump("ready");
        const st_copy: ?[]u8 = blk: {
            self.state_mutex.lock();
            defer self.state_mutex.unlock();
            break :blk if (self.state) |st| try self.allocator.dupe(u8, st) else null;
        };
        defer if (st_copy) |c| self.allocator.free(c);
        if (st_copy) |st| {
            const hex = try std.fmt.allocPrint(self.allocator, "{x}", .{st});
            defer self.allocator.free(hex);
            try self.send(.{ .op = "restore", .state = hex });
            try self.pump("restored");
        }
        if (self.bus.graph) |g| g.updateNodeStatus(self.meta.node_id, .active);
    }

    /// 子の問い合わせに答えながら、`until` ("ready" / "done") が来るまで待つ (mutex を持って呼ぶ)
    fn pump(self: *PluginCell, until: []const u8) !void {
        const s = self.stream orelse return error.NoChild;
        while (true) {
            const f = try ws.readMessage(s, self.allocator, 2 << 20);
            defer self.allocator.free(f.payload);
            if (f.opcode == .close) return error.ChildClosed;
            if (f.opcode != .text) continue;
            const M = struct { op: []const u8 = "", t: []const u8 = "", p: []const u8 = "", qos: u32 = 0, state: ?[]const u8 = null };
            const m = std.json.parseFromSlice(M, self.allocator, f.payload, .{ .ignore_unknown_fields = true }) catch continue;
            defer m.deinit();
            const op = m.value.op;
            if (std.mem.eql(u8, op, until)) {
                if (m.value.state) |hex| self.keepState(hex);
                return;
            }
            if (std.mem.eql(u8, op, "pub")) {
                const hops: u8 = if (self.inflight_id != 0) self.inflight_hops +| 1 else 0;
                const code = host_api.publishChecked(self.bus, self.allocator, self.meta, self.cell, m.value.t, m.value.p, m.value.qos, self.inflight_id, hops);
                try self.send(.{ .op = "ret", .code = code });
            } else if (std.mem.eql(u8, op, "sub")) {
                var code = host_api.subscribeAllowed(self.bus, self.meta, m.value.t);
                if (code == 0) self.bus.subscribeEx(m.value.t, self.meta.node_id, callback, self, .{ .cell = self.cell }) catch {
                    code = 8; // ERROR_INVALID_TOPIC
                };
                try self.send(.{ .op = "ret", .code = code });
            } else if (std.mem.eql(u8, op, "unsub")) {
                self.bus.unsubscribe(self.meta.node_id, m.value.t);
                try self.send(.{ .op = "ret", .code = @as(i32, 0) });
            } else if (std.mem.eql(u8, op, "tele")) {
                self.acceptTelemetry(m.value.t, m.value.p);
            }
        }
    }

    fn keepState(self: *PluginCell, hex: []const u8) void {
        if (hex.len % 2 != 0 or hex.len > 2 * self.meta.manifest_parsed.value.limits.state_bytes) return;
        const bytes = self.allocator.alloc(u8, hex.len / 2) catch return;
        _ = std.fmt.hexToBytes(bytes, hex) catch {
            self.allocator.free(bytes);
            return;
        };
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        if (self.state) |old| self.allocator.free(old);
        self.state = bytes;
    }

    /// スナップショット用: 預かっている状態の複製 (R7)
    pub fn copyState(self: *PluginCell, a: std.mem.Allocator) !?[]u8 {
        self.state_mutex.lock();
        defer self.state_mutex.unlock();
        return if (self.state) |st| try a.dupe(u8, st) else null;
    }

    /// スナップショットから戻す (Core の起動直後): 預かり、動いている子にも書き戻す
    pub fn restoreState(self: *PluginCell, bytes: []const u8) bool {
        const hex = std.fmt.allocPrint(self.allocator, "{x}", .{bytes}) catch return false;
        defer self.allocator.free(hex);
        self.keepState(hex);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stream == null) return true; // 次に起動した時に書き戻される
        self.send(.{ .op = "restore", .state = hex }) catch return false;
        self.pump("restored") catch return false;
        return true;
    }

    pub fn pluginName(self: *PluginCell) []const u8 {
        return self.name();
    }

    /// 子が中で出した障害・メトリクス・毒の通知を、自分のノードのものに限って Core のバスに出す
    fn acceptTelemetry(self: *PluginCell, topic: []const u8, payload: []const u8) void {
        const allowed = std.mem.eql(u8, topic, "core.node.metrics") or std.mem.eql(u8, topic, "core.node.fault") or std.mem.eql(u8, topic, "core.node.poison");
        const P = struct { node_id: u32 = 0 };
        const ok = allowed and blk: {
            const p = std.json.parseFromSlice(P, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch break :blk false;
            defer p.deinit();
            break :blk p.value.node_id == self.meta.node_id;
        };
        if (!ok) {
            host_api.emitSecurity(self.bus, "acl_denied", self.meta.node_id, self.name(), "telemetry", topic);
            return;
        }
        const qos: event_bus.QoS = if (std.mem.eql(u8, topic, "core.node.metrics")) .BestEffort else .Transient;
        self.bus.publish(topic, payload, qos, self.meta.node_id) catch {};
    }

    /// Core のバスからの配送 (このプラグインのセルの executor 上)
    fn callback(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *PluginCell = @ptrCast(@alignCast(ctx.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.running.load(.acquire)) return;
        const fp = fingerprint(msg.topic, msg.payload);
        if (self.poison.contains(fp)) return;
        const now = std.time.milliTimestamp();
        if (now < self.quarantined_until) return;
        if (self.stream != null and !self.childAlive()) {
            // 何も処理していない間に落ちていた (kill -9 など)。このメッセージのせいではないので隔離せず、
            // 起動し直してから配送する
            log.warn("PluginCell: '{s}' process exited while idle; restarting it", .{self.name()});
            self.dropChild(true);
            self.crashes += 1;
            if (self.bus.graph) |g| g.updateNodeStatus(self.meta.node_id, .restarting);
        }
        if (self.stream == null) {
            // 隔離が明けた / 前回の起動に失敗した / 待機中に落ちていた: 起動し直す
            self.spawnAndLoad() catch |err| {
                log.err("PluginCell: '{s}' restart failed: {any}", .{ self.name(), err });
                self.dropChild(true);
                return;
            };
        }
        self.inflight_id = msg.id;
        self.inflight_hops = msg.hops;
        defer self.inflight_id = 0;
        const sent = self.send(.{ .op = "msg", .id = msg.id, .t = msg.topic, .p = msg.payload, .ts = msg.timestamp, .qos = @intFromEnum(msg.qos) });
        if (sent) |_| {
            if (self.pump("done")) |_| return else |_| {}
        } else |_| {}
        self.onChildCrash(msg, fp);
    }

    /// 子のプロセスがまだ生きているか (終了していれば回収する)
    fn childAlive(self: *PluginCell) bool {
        const c = self.child orelse return false;
        const r = std.posix.waitpid(c.id, std.posix.W.NOHANG);
        if (r.pid == c.id) {
            self.child = null; // 回収済み
            return false;
        }
        return true;
    }

    /// 子のプロセスが落ちた: 処理中のメッセージを隔離し、障害を知らせ、起動し直す (breaker 付き)
    fn onChildCrash(self: *PluginCell, msg: *const event_bus.EventMessage, fp: u64) void {
        self.dropChild(true);
        // 停止のために中断されたのなら障害ではない (隔離も再起動もしない)
        if (!self.running.load(.acquire)) return;
        self.crashes += 1;
        self.poison.put(self.allocator, fp, {}) catch {};
        var buf: [512]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{ .node_id = self.meta.node_id, .exception = "cell process exited", .topic = msg.topic }, .{})}) catch {};
        self.bus.publish("core.node.fault", w.buffered(), .Transient, self.meta.node_id) catch {};
        var w2 = std.io.Writer.fixed(&buf);
        w2.print("{f}", .{std.json.fmt(.{ .node_id = self.meta.node_id, .topic = msg.topic, .fingerprint = fp, .exception = "cell process exited" }, .{})}) catch {};
        self.bus.publish("core.node.poison", w2.buffered(), .Transient, 0) catch {};
        if (self.bus.graph) |g| g.updateNodeStatus(self.meta.node_id, .restarting);
        log.warn("PluginCell: '{s}' process exited while handling '{s}'; message quarantined, restarting the process", .{ self.name(), msg.topic });

        const now = std.time.milliTimestamp();
        self.crash_times[self.crash_pos] = now;
        self.crash_pos = (self.crash_pos + 1) % self.crash_times.len;
        const r = self.meta.manifest_parsed.value.restart;
        var recent: u32 = 0;
        for (self.crash_times) |t| {
            if (t != 0 and now - t <= @as(i64, r.window_secs) * 1000) recent += 1;
        }
        if (r.policy == .never) {
            self.quarantined_until = std.math.maxInt(i64);
            if (self.bus.graph) |g| g.updateNodeStatus(self.meta.node_id, .stopped);
            return;
        }
        if (recent >= @max(1, r.max_faults)) {
            self.quarantined_until = now + @as(i64, r.quarantine_secs) * 1000;
            if (self.bus.graph) |g| g.updateNodeStatus(self.meta.node_id, .quarantined);
            log.err("PluginCell: '{s}' process crashed {d} times; quarantined for {d} s", .{ self.name(), recent, r.quarantine_secs });
            return;
        }
        self.spawnAndLoad() catch |err| {
            log.err("PluginCell: '{s}' restart failed: {any}", .{ self.name(), err });
            self.dropChild(true);
        };
    }
};
