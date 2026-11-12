//! ObsGate — 既存の配信ツールを「そのまま」WEAVE の下に置くためのラッパー (互換戦略 D)。
//!
//! OBS を操作する既存ツール (Streamer.bot の OBS 連携・Touch Portal・自作の Python スクリプトなど) は、
//! obs-websocket v5 で OBS に直接つなぐ。ツールの中身は変えられないので、WEAVE は OBS のふりをして
//! 間に入る: ツール側で変えるのは「接続先のポート (4455 → 4456) とパスワード」だけ。
//!
//!   既存ツール ──(obs-websocket v5)──▶ ObsGate (:4456) ──▶ 本物の OBS (:4455)
//!
//! - ツールごとに別のパスワードを渡す (.weave/wrap/<name>.json)。どのツールからの接続かはパスワードで分かる
//! - 要求 (Request) を 1 つずつ宣言 (allow) と照合する。宣言にない操作 (配信停止など) は OBS に届かない
//! - 操作の頻度に上限を持つ。超えたら そのツールだけ を一定時間止め、壊された画面 (表示/非表示・シーン・文字) を
//!   暴走の直前の状態に戻す
//! - ツールは SystemGraph に「wrapped」ノードとして載る。止めた操作は core.security.* (監査ログ・Inspector)、
//!   状態の変化は core.wrap.status (HealthMonitor → /status) に出る
//! - learn モード: 宣言を書かずに一度使ってみて、実際に使った操作を記録する (weave wrap lock で宣言にする)
//!
//! 応答 (RequestResponse)・イベントは本物の OBS のものをそのままツールに返す。WEAVE が止めた要求には
//! requestStatus.result=false と、理由 (comment) を返す。

const std = @import("std");
const ws = @import("../transport/ws_proto.zig");
const event_bus = @import("../core/event_bus.zig");
const ObsEgressNode = @import("obs.zig").ObsEgressNode;
const log = @import("../common/log.zig");

pub const DEFAULT_PORT: u16 = 4456;
pub const STATUS_TOPIC = "core.wrap.status";
const FIRST_NODE_ID: u32 = 300;
const MAX_FRAME = 16 * 1024 * 1024;
/// これだけ操作が途切れたら、「暴走前の状態」を取り直す (直前の正常な演出の途中ではなく、その前の落ち着いた状態に戻すため長め)
const CALM_MS: i64 = 5000;

/// .weave/wrap/<name>.json
pub const Spec = struct {
    name: []const u8,
    password: []const u8,
    description: []const u8 = "",
    /// "enforce" (宣言どおり) | "learn" (全部通して、使った操作を記録する)
    mode: []const u8 = "enforce",
    /// 許す操作。"SetInputSettings" (どの対象でも) / "SetInputSettings:OverlayText" (その対象だけ) /
    /// "SetSceneItemEnabled:Overlay#1" / "Set*" (前方一致)。状態を読むだけの Get* は常に通す
    allow: [][]const u8 = &.{},
    /// learn モードで実際に使われた requestType
    learned: [][]const u8 = &.{},
    /// 1 秒あたりの操作数の上限 (平均)。瞬間的には burst まで許す
    rate_per_sec: f64 = 10,
    burst: f64 = 20,
    /// 上限を超えたときに止める秒数
    quarantine_secs: u32 = 10,
};

/// learn モードでも通さない操作 (配信・録画を止める、OBS を落とす類)
pub const ALWAYS_ASK = [_][]const u8{ "StopStream", "ToggleStream", "StopRecord", "ToggleRecord", "StopVirtualCam", "Sleep" };

/// 要求が allow のどれかに当たるか。key は "Type" または "Type:target"
pub fn matches(allow: []const []const u8, key: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, key, ':');
    const rt = if (colon) |c| key[0..c] else key;
    for (allow) |a| {
        if (std.mem.endsWith(u8, a, "*")) {
            if (std.mem.startsWith(u8, rt, a[0 .. a.len - 1])) return true;
        } else if (std.mem.indexOfScalar(u8, a, ':') != null) {
            if (std.mem.eql(u8, a, key)) return true;
        } else if (std.mem.eql(u8, a, rt)) return true;
    }
    return false;
}

/// 要求が触る対象 (ソース名・シーンのアイテム・シーン)。対象を持たない要求は null
pub fn targetOf(buf: []u8, rt: []const u8, data: std.json.Value) ?[]const u8 {
    if (data != .object) return null;
    const o = data.object;
    if (std.mem.eql(u8, rt, "SetSceneItemEnabled") or std.mem.eql(u8, rt, "SetSceneItemTransform") or std.mem.eql(u8, rt, "SetSceneItemLocked")) {
        const scene = o.get("sceneName") orelse return null;
        const id = o.get("sceneItemId") orelse return null;
        if (scene != .string or id != .integer) return null;
        return std.fmt.bufPrint(buf, "{s}#{d}", .{ scene.string, id.integer }) catch null;
    }
    if (std.mem.eql(u8, rt, "SetCurrentProgramScene") or std.mem.eql(u8, rt, "SetCurrentPreviewScene")) {
        const scene = o.get("sceneName") orelse return null;
        return if (scene == .string) (std.fmt.bufPrint(buf, "{s}", .{scene.string}) catch null) else null;
    }
    const input = o.get("inputName") orelse o.get("sourceName") orelse return null;
    return if (input == .string) (std.fmt.bufPrint(buf, "{s}", .{input.string}) catch null) else null;
}

fn isAlwaysAsk(rt: []const u8) bool {
    for (ALWAYS_ASK) |x| if (std.mem.eql(u8, x, rt)) return true;
    return false;
}

/// 状態を読むだけの要求。頻度の上限には数えるが、暴走前の状態の記録はしない
fn isRead(rt: []const u8) bool {
    return std.mem.startsWith(u8, rt, "Get");
}

/// 1 つのラップ対象 (ツール)。再接続しても状態 (止めている時間・暴走前の状態) は引き継ぐ
const Tool = struct {
    gate: *ObsGate,
    spec_path: []const u8,
    parsed: std.json.Parsed(Spec),
    node_id: u32,
    registered: bool = false,
    mutex: std.Thread.Mutex = .{},
    tokens: f64,
    last_refill_ms: i64,
    quarantine_until_ms: i64 = 0,
    last_mutation_ms: i64 = 0,
    /// 暴走前の状態: key ("item:<scene>#<id>" / "scene" / "input:<name>") → 戻すための要求 (JSON)
    originals: std.StringArrayHashMapUnmanaged([]u8) = .{},
    learned: std.StringArrayHashMapUnmanaged(void) = .{},
    forwarded: u64 = 0,
    denied: u64 = 0,
    /// 拒否の監査イベントは 1 秒に 1 件へ集約する (暴走したツールが監査ログを埋め尽くさないように)
    last_deny_emit_ms: i64 = 0,
    suppressed_denies: u32 = 0,
    window_start_ms: i64 = 0,
    window_count: u32 = 0,
    peak_per_sec: u32 = 0,

    fn spec(self: *const Tool) Spec {
        return self.parsed.value;
    }
    fn name(self: *const Tool) []const u8 {
        return self.parsed.value.name;
    }
    fn learning(self: *const Tool) bool {
        return std.mem.eql(u8, self.parsed.value.mode, "learn");
    }

    fn deinit(self: *Tool, a: std.mem.Allocator) void {
        for (self.originals.keys(), self.originals.values()) |k, v| {
            a.free(k);
            a.free(v);
        }
        self.originals.deinit(a);
        for (self.learned.keys()) |k| a.free(k);
        self.learned.deinit(a);
        self.parsed.deinit();
        a.free(self.spec_path);
    }

    /// 1 件ぶんのトークンを取る。足りなければ false
    fn take(self: *Tool, now: i64) bool {
        const s = self.spec();
        const dt = @as(f64, @floatFromInt(@max(0, now - self.last_refill_ms))) / 1000.0;
        self.tokens = @min(s.burst, self.tokens + dt * s.rate_per_sec);
        self.last_refill_ms = now;
        // 直近 1 秒の件数 (理由の表示用)
        if (now - self.window_start_ms >= 1000) {
            self.window_start_ms = now;
            self.window_count = 0;
        }
        self.window_count += 1;
        self.peak_per_sec = @max(self.peak_per_sec, self.window_count);
        if (self.tokens < 1) return false;
        self.tokens -= 1;
        return true;
    }
};

pub const Options = struct {
    bind: []const u8 = "127.0.0.1",
    port: u16 = DEFAULT_PORT,
    upstream_host: []const u8 = "127.0.0.1",
    upstream_port: u16 = 4455,
    upstream_password: ?[]const u8 = null,
    wrap_dir: []const u8 = ".weave/wrap",
};

pub const ObsGate = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    opts: Options,
    tools: std.ArrayListUnmanaged(*Tool) = .{},
    server: ?std.net.Server = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    accept_thread: ?std.Thread = null,
    watch_thread: ?std.Thread = null,
    conns_mutex: std.Thread.Mutex = .{},
    conns: std.ArrayListUnmanaged(*Conn) = .{},

    /// .weave/wrap/*.json を読む。1 つも無ければ null (ゲートを開かない)
    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, opts: Options) !?*ObsGate {
        var dir = std.fs.cwd().openDir(opts.wrap_dir, .{ .iterate = true }) catch return null;
        defer dir.close();
        const self = try allocator.create(ObsGate);
        self.* = .{ .allocator = allocator, .bus = bus, .opts = opts };
        errdefer self.deinit();
        var it = dir.iterate();
        var next_id = FIRST_NODE_ID;
        const now = std.time.milliTimestamp();
        while (try it.next()) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
            const path = try std.fs.path.join(allocator, &.{ opts.wrap_dir, e.name });
            const bytes = dir.readFileAlloc(allocator, e.name, 1 << 20) catch |err| {
                log.warn("cannot read {s}: {any}", .{ path, err });
                allocator.free(path);
                continue;
            };
            defer allocator.free(bytes);
            const parsed = std.json.parseFromSlice(Spec, allocator, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
                log.warn("invalid wrap spec {s}: {any}", .{ path, err });
                allocator.free(path);
                continue;
            };
            const t = try allocator.create(Tool);
            t.* = .{ .gate = self, .spec_path = path, .parsed = parsed, .node_id = next_id, .tokens = parsed.value.burst, .last_refill_ms = now };
            for (parsed.value.learned) |l| try t.learned.put(allocator, try allocator.dupe(u8, l), {});
            next_id += 1;
            try self.tools.append(allocator, t);
        }
        if (self.tools.items.len == 0) {
            self.deinit();
            return null;
        }
        return self;
    }

    pub fn deinit(self: *ObsGate) void {
        const a = self.allocator;
        for (self.tools.items) |t| {
            t.deinit(a);
            a.destroy(t);
        }
        self.tools.deinit(a);
        self.conns.deinit(a);
        a.destroy(self);
    }

    pub fn start(self: *ObsGate) !void {
        const addr = try std.net.Address.parseIp(self.opts.bind, self.opts.port);
        self.server = try ws.listenExclusive(addr);
        self.running.store(true, .release);
        // ツールをグラフに載せる (まだ接続していなくても「宣言上はここにいる」)
        for (self.tools.items) |t| self.register(t);
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        self.watch_thread = try std.Thread.spawn(.{}, watchLoop, .{self});
        log.info("ObsGate: listening on ws://{s}:{d} for {d} wrapped tool(s) → OBS {s}:{d}", .{ self.opts.bind, self.opts.port, self.tools.items.len, self.opts.upstream_host, self.opts.upstream_port });
    }

    pub fn stop(self: *ObsGate) void {
        if (!self.running.swap(false, .acq_rel)) return;
        // accept で待っているスレッドを、自分に接続して起こす (待ち受けソケットの shutdown では起きない環境がある)
        if (self.server) |s| {
            var wake = s.listen_address;
            if (wake.any.family == std.posix.AF.INET and wake.in.sa.addr == 0) wake = std.net.Address.parseIp("127.0.0.1", wake.getPort()) catch wake;
            if (std.net.tcpConnectToAddress(wake)) |c| c.close() else |_| {}
        }
        self.conns_mutex.lock();
        for (self.conns.items) |c| c.shutdown();
        self.conns_mutex.unlock();
        if (self.accept_thread) |t| t.join();
        if (self.watch_thread) |t| t.join();
        // 接続スレッドが全部抜けるのを待つ
        var waited: u32 = 0;
        while (waited < 100) : (waited += 1) {
            self.conns_mutex.lock();
            const n = self.conns.items.len;
            self.conns_mutex.unlock();
            if (n == 0) break;
            std.Thread.sleep(20 * std.time.ns_per_ms);
        }
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    fn register(self: *ObsGate, t: *Tool) void {
        const g = self.bus.graph orelse return;
        if (!t.registered) {
            g.registerNodeIn(t.node_id, t.name(), .wrapped, "wrap") catch return;
            t.registered = true;
            // 宣言した操作を「出すもの」としてグラフに載せる (影響範囲の計算と Inspector の辺に使う)
            for (t.spec().allow) |a| {
                if (isRead(a)) continue;
                const rt = if (std.mem.indexOfScalar(u8, a, ':')) |c| a[0..c] else a;
                var buf: [160]u8 = undefined;
                const topic = std.fmt.bufPrint(&buf, "core.obs.request.{s}", .{rt}) catch continue;
                g.recordPublish(t.node_id, topic) catch {};
            }
        }
        g.updateNodeStatus(t.node_id, .starting);
    }

    fn findTool(self: *ObsGate, salt: []const u8, challenge: []const u8, auth: []const u8) ?*Tool {
        for (self.tools.items) |t| {
            const expected = ObsEgressNode.authString(t.spec().password, salt, challenge);
            if (ws.constantTimeEql(&expected, auth)) return t;
        }
        return null;
    }

    fn publishStatus(self: *ObsGate, t: *Tool, state: []const u8, reason: []const u8, until_ms: i64) void {
        var buf: [1024]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{ .node_id = t.node_id, .name = t.name(), .state = state, .reason = reason, .until_ms = until_ms, .forwarded = t.forwarded, .denied = t.denied }, .{})}) catch return;
        self.bus.publish(STATUS_TOPIC, w.buffered(), .BestEffort, 0) catch {};
    }

    fn acceptLoop(self: *ObsGate) void {
        while (self.running.load(.acquire)) {
            const conn = (self.server orelse return).accept() catch |err| {
                if (!self.running.load(.acquire)) return;
                log.warn("ObsGate: accept failed: {any}", .{err});
                std.Thread.sleep(50 * std.time.ns_per_ms);
                continue;
            };
            const c = self.allocator.create(Conn) catch {
                conn.stream.close();
                continue;
            };
            noDelay(conn.stream);
            c.* = .{ .gate = self, .client = conn.stream };
            self.conns_mutex.lock();
            self.conns.append(self.allocator, c) catch {
                self.conns_mutex.unlock();
                conn.stream.close();
                self.allocator.destroy(c);
                continue;
            };
            self.conns_mutex.unlock();
            const th = std.Thread.spawn(.{}, Conn.run, .{c}) catch {
                self.dropConn(c);
                continue;
            };
            th.detach();
        }
    }

    fn dropConn(self: *ObsGate, c: *Conn) void {
        self.conns_mutex.lock();
        for (self.conns.items, 0..) |x, i| if (x == c) {
            _ = self.conns.swapRemove(i);
            break;
        };
        self.conns_mutex.unlock();
        self.allocator.destroy(c);
    }

    /// 止めている時間が過ぎたツールを戻す
    fn watchLoop(self: *ObsGate) void {
        while (self.running.load(.acquire)) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            const now = std.time.milliTimestamp();
            for (self.tools.items) |t| {
                t.mutex.lock();
                const expired = t.quarantine_until_ms != 0 and now >= t.quarantine_until_ms;
                if (expired) {
                    t.quarantine_until_ms = 0;
                    t.tokens = t.spec().burst;
                    t.peak_per_sec = 0;
                }
                const connected = self.isConnected(t);
                t.mutex.unlock();
                if (expired) {
                    if (self.bus.graph) |g| g.updateNodeStatus(t.node_id, if (connected) .active else .starting);
                    self.publishStatus(t, "active", "止めていた時間が過ぎたので、操作を再び通します", 0);
                    log.info("ObsGate: {s} released", .{t.name()});
                }
            }
        }
    }

    fn isConnected(self: *ObsGate, t: *Tool) bool {
        self.conns_mutex.lock();
        defer self.conns_mutex.unlock();
        for (self.conns.items) |c| if (c.tool == t and c.identified) return true;
        return false;
    }

    /// learn モードで使われた操作をファイルに書き戻す
    fn saveLearned(self: *ObsGate, t: *Tool) void {
        const a = self.allocator;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var v = t.spec();
        v.learned = t.learned.keys();
        const out = std.fmt.allocPrint(arena.allocator(), "{f}\n", .{std.json.fmt(v, .{ .whitespace = .indent_2 })}) catch return;
        std.fs.cwd().writeFile(.{ .sub_path = t.spec_path, .data = out }) catch |err| log.warn("ObsGate: cannot save {s}: {any}", .{ t.spec_path, err });
    }
};

/// ツール 1 接続 = 上流 (本物の OBS) 1 接続
const Conn = struct {
    gate: *ObsGate,
    client: std.net.Stream,
    upstream: ?std.net.Stream = null,
    tool: ?*Tool = null,
    identified: bool = false,
    client_mutex: std.Thread.Mutex = .{},
    up_mutex: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // WEAVE 自身が上流に出す要求 (暴走前の状態を読む・戻す) の応答待ち
    wait_mutex: std.Thread.Mutex = .{},
    wait_cond: std.Thread.Condition = .{},
    wait_id: [32]u8 = undefined,
    wait_id_len: usize = 0,
    wait_result: ?[]u8 = null,
    seq: u32 = 0,

    fn shutdown(self: *Conn) void {
        std.posix.shutdown(self.client.handle, .both) catch {};
        if (self.upstream) |u| std.posix.shutdown(u.handle, .both) catch {};
    }

    fn sendClient(self: *Conn, data: []const u8) !void {
        self.client_mutex.lock();
        defer self.client_mutex.unlock();
        try ws.writeFrame(self.client, .text, data, false);
    }

    fn sendUp(self: *Conn, data: []const u8) !void {
        const u = self.upstream orelse return error.NotConnected;
        self.up_mutex.lock();
        defer self.up_mutex.unlock();
        try ws.writeFrame(u, .text, data, true);
    }

    fn sendJsonClient(self: *Conn, value: anytype) !void {
        var buf: [4096]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        try w.print("{f}", .{std.json.fmt(value, .{})});
        try self.sendClient(w.buffered());
    }

    fn run(self: *Conn) void {
        const gate = self.gate;
        const a = gate.allocator;
        defer {
            self.closed.store(true, .release);
            self.client.close();
            if (self.upstream) |u| u.close();
            if (self.tool) |t| if (self.identified) {
                self.identified = false;
                if (!gate.isConnected(t)) {
                    t.mutex.lock();
                    const q = t.quarantine_until_ms != 0;
                    t.mutex.unlock();
                    if (gate.bus.graph) |g| if (!q) g.updateNodeStatus(t.node_id, .starting);
                }
                log.info("ObsGate: {s} disconnected", .{t.name()});
            };
            gate.dropConn(self);
        }
        self.handshake() catch |err| {
            if (err != error.EndOfStream) log.warn("ObsGate: handshake failed: {any}", .{err});
            return;
        };
        const t = self.tool.?;
        const reader = std.Thread.spawn(.{}, upstreamLoop, .{self}) catch return;
        defer {
            if (self.upstream) |u| std.posix.shutdown(u.handle, .both) catch {};
            reader.join();
        }
        log.info("ObsGate: {s} connected ({s})", .{ t.name(), if (t.learning()) "learn" else "enforce" });
        if (gate.bus.graph) |g| {
            t.mutex.lock();
            const q = t.quarantine_until_ms != 0;
            t.mutex.unlock();
            if (!q) g.updateNodeStatus(t.node_id, .active);
        }
        gate.publishStatus(t, "active", if (t.learning()) "学習中: 使った操作を記録しています" else "接続しました", 0);

        while (gate.running.load(.acquire)) {
            const frame = ws.readMessage(self.client, a, MAX_FRAME) catch return;
            defer a.free(frame.payload);
            switch (frame.opcode) {
                .close => return,
                .ping => {
                    self.client_mutex.lock();
                    ws.writeFrame(self.client, .pong, frame.payload, false) catch {};
                    self.client_mutex.unlock();
                    continue;
                },
                .text => {},
                else => continue,
            }
            var parsed = std.json.parseFromSlice(std.json.Value, a, frame.payload, .{}) catch continue;
            defer parsed.deinit();
            if (parsed.value != .object) continue;
            const op = parsed.value.object.get("op") orelse continue;
            const d = parsed.value.object.get("d") orelse continue;
            if (op != .integer or d != .object) continue;
            switch (op.integer) {
                6 => self.onRequest(d.object, frame.payload) catch return,
                8 => self.onBatch(d.object, frame.payload) catch return,
                3 => self.sendUp(frame.payload) catch return,
                else => {},
            }
        }
    }

    /// ツールとの Hello/Identify (パスワードでツールを見分ける) と、本物の OBS との Hello/Identify
    fn handshake(self: *Conn) !void {
        const gate = self.gate;
        const a = gate.allocator;
        var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
        const head = try ws.readHead(self.client, &head_buf);
        const req = try ws.parseRequest(head);
        try ws.writeUpgrade(self.client, req.ws_key orelse return error.BadRequest);

        var salt_raw: [16]u8 = undefined;
        var challenge_raw: [16]u8 = undefined;
        std.crypto.random.bytes(&salt_raw);
        std.crypto.random.bytes(&challenge_raw);
        var salt_buf: [24]u8 = undefined;
        var challenge_buf: [24]u8 = undefined;
        const salt = std.base64.standard.Encoder.encode(&salt_buf, &salt_raw);
        const challenge = std.base64.standard.Encoder.encode(&challenge_buf, &challenge_raw);
        try self.sendJsonClient(.{ .op = 0, .d = .{ .obsWebSocketVersion = "5.5.0", .rpcVersion = 1, .authentication = .{ .challenge = challenge, .salt = salt } } });

        // Identify
        const frame = try ws.readMessage(self.client, a, 64 * 1024);
        defer a.free(frame.payload);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, frame.payload, .{});
        defer parsed.deinit();
        const d = (if (parsed.value == .object) parsed.value.object.get("d") else null) orelse return error.BadIdentify;
        if (d != .object) return error.BadIdentify;
        const auth = d.object.get("authentication") orelse .null;
        const tool = if (auth == .string) gate.findTool(salt, challenge, auth.string) else null;
        const t = tool orelse {
            log.warn("ObsGate: unknown tool (password does not match any .weave/wrap/*.json)", .{});
            self.client_mutex.lock();
            var cbuf: [64]u8 = undefined;
            std.mem.writeInt(u16, cbuf[0..2], 4009, .big);
            const reason = "Authentication failed (WEAVE: unknown tool)";
            @memcpy(cbuf[2 .. 2 + reason.len], reason);
            ws.writeFrame(self.client, .close, cbuf[0 .. 2 + reason.len], false) catch {};
            self.client_mutex.unlock();
            return error.UnknownTool;
        };
        self.tool = t;
        const subs: i64 = if (d.object.get("eventSubscriptions")) |v| (if (v == .integer) v.integer else 1023) else 1023;

        // 本物の OBS へ
        const addr = try std.net.Address.resolveIp(gate.opts.upstream_host, gate.opts.upstream_port);
        const up = std.net.tcpConnectToAddress(addr) catch |err| {
            log.warn("ObsGate: cannot reach OBS at {s}:{d}: {any}", .{ gate.opts.upstream_host, gate.opts.upstream_port, err });
            return err;
        };
        noDelay(up);
        self.upstream = up;
        try ws.clientHandshake(up, gate.opts.upstream_host, gate.opts.upstream_port, "/", "");
        const hello = try ws.readMessage(up, a, 64 * 1024);
        defer a.free(hello.payload);
        var hp = try std.json.parseFromSlice(std.json.Value, a, hello.payload, .{});
        defer hp.deinit();
        const hd = (if (hp.value == .object) hp.value.object.get("d") else null) orelse return error.BadHello;
        var ibuf: [512]u8 = undefined;
        var iw = std.io.Writer.fixed(&ibuf);
        if (hd == .object and hd.object.get("authentication") != null) {
            const au = hd.object.get("authentication").?;
            const ch = au.object.get("challenge") orelse return error.BadHello;
            const sa = au.object.get("salt") orelse return error.BadHello;
            const pw = gate.opts.upstream_password orelse return error.PasswordRequired;
            const secret = ObsEgressNode.authString(pw, sa.string, ch.string);
            try iw.print("{f}", .{std.json.fmt(.{ .op = 1, .d = .{ .rpcVersion = 1, .authentication = secret[0..], .eventSubscriptions = subs } }, .{})});
        } else {
            try iw.print("{f}", .{std.json.fmt(.{ .op = 1, .d = .{ .rpcVersion = 1, .eventSubscriptions = subs } }, .{})});
        }
        try self.sendUp(iw.buffered());
        const ident = try ws.readMessage(up, a, 64 * 1024);
        defer a.free(ident.payload);
        if (ident.opcode == .close) return error.UpstreamAuthFailed;
        // Identified をツールにそのまま返す
        try self.sendClient(ident.payload);
        self.identified = true;
    }

    /// 本物の OBS → ツール。WEAVE 自身の要求への応答だけは横取りする
    fn upstreamLoop(self: *Conn) void {
        const a = self.gate.allocator;
        const up = self.upstream orelse return;
        while (!self.closed.load(.acquire)) {
            const frame = ws.readMessage(up, a, MAX_FRAME) catch break;
            defer a.free(frame.payload);
            switch (frame.opcode) {
                .close => break,
                .ping => {
                    self.up_mutex.lock();
                    ws.writeFrame(up, .pong, frame.payload, true) catch {};
                    self.up_mutex.unlock();
                    continue;
                },
                .text => {},
                else => continue,
            }
            if (std.mem.indexOf(u8, frame.payload, "\"weave-gate-") != null) {
                self.wait_mutex.lock();
                const id = self.wait_id[0..self.wait_id_len];
                if (self.wait_id_len > 0 and std.mem.indexOf(u8, frame.payload, id) != null) {
                    self.wait_result = a.dupe(u8, frame.payload) catch null;
                    self.wait_cond.signal();
                }
                self.wait_mutex.unlock();
                continue;
            }
            self.sendClient(frame.payload) catch break;
        }
        // 上流が切れたらツールとの接続も閉じる (ツール側は OBS が落ちたときと同じように再接続する)
        std.posix.shutdown(self.client.handle, .both) catch {};
    }

    /// WEAVE 自身が上流に要求を出し、応答 (の JSON 全体) を待つ。呼び出し側が free する
    fn call(self: *Conn, request_type: []const u8, data: anytype) ?[]u8 {
        self.seq += 1;
        var idb: [32]u8 = undefined;
        const id = std.fmt.bufPrint(&idb, "weave-gate-{d}", .{self.seq}) catch return null;
        var buf: [8192]u8 = undefined;
        var w = std.io.Writer.fixed(&buf);
        w.print("{f}", .{std.json.fmt(.{ .op = 6, .d = .{ .requestType = request_type, .requestId = id, .requestData = data } }, .{})}) catch return null;
        self.wait_mutex.lock();
        @memcpy(self.wait_id[0..id.len], id);
        self.wait_id_len = id.len;
        self.wait_result = null;
        self.wait_mutex.unlock();
        const sent = if (self.sendUp(w.buffered())) true else |_| false;
        self.wait_mutex.lock();
        defer self.wait_mutex.unlock();
        if (sent) {
            const deadline = std.time.nanoTimestamp() + 800 * std.time.ns_per_ms;
            while (self.wait_result == null) {
                const now = std.time.nanoTimestamp();
                if (now >= deadline) break;
                self.wait_cond.timedWait(&self.wait_mutex, @intCast(deadline - now)) catch {};
            }
        }
        self.wait_id_len = 0;
        const r = self.wait_result;
        self.wait_result = null;
        return r;
    }

    fn reply(self: *Conn, rt: []const u8, rid: []const u8, code: i64, comment: []const u8) !void {
        try self.sendJsonClient(.{ .op = 7, .d = .{ .requestType = rt, .requestId = rid, .requestStatus = .{ .result = false, .code = code, .comment = comment } } });
    }

    const Verdict = union(enum) { ok, denied: []const u8, quarantined: []const u8, tripped: []const u8 };

    /// 1 件の要求を判定する (トークンも消費する)
    fn judge(self: *Conn, t: *Tool, rt: []const u8, target: ?[]const u8, now: i64, msg_buf: []u8) Verdict {
        const gate = self.gate;
        const s = t.spec();
        if (t.quarantine_until_ms > now) {
            const left = @divFloor(t.quarantine_until_ms - now + 999, 1000);
            return .{ .quarantined = std.fmt.bufPrint(msg_buf, "WEAVE: {s} は操作が多すぎたため一時停止中です (あと {d} 秒)", .{ s.name, left }) catch "WEAVE: paused" };
        }
        var kb: [256]u8 = undefined;
        const key = if (target) |tg| (std.fmt.bufPrint(&kb, "{s}:{s}", .{ rt, tg }) catch rt) else rt;
        const allowed = if (isRead(rt)) true else if (t.learning()) !isAlwaysAsk(rt) else matches(s.allow, key);
        if (!allowed) {
            t.denied += 1;
            if (now - t.last_deny_emit_ms >= 1000) {
                var tb: [320]u8 = undefined;
                const topic = if (t.suppressed_denies > 0)
                    std.fmt.bufPrint(&tb, "core.obs.request.{s} (ほか {d} 件)", .{ key, t.suppressed_denies }) catch rt
                else
                    std.fmt.bufPrint(&tb, "core.obs.request.{s}", .{key}) catch rt;
                emitSecurity(gate.bus, "acl_denied", t.node_id, s.name, "obs_request", topic);
                t.last_deny_emit_ms = now;
                t.suppressed_denies = 0;
            } else t.suppressed_denies += 1;
            return .{ .denied = std.fmt.bufPrint(msg_buf, "WEAVE: {s} には {s} の権限がありません (.weave/wrap/{s}.json の allow に無い操作)", .{ s.name, key, s.name }) catch "WEAVE: denied" };
        }
        if (!t.take(now)) {
            t.quarantine_until_ms = now + @as(i64, s.quarantine_secs) * 1000;
            t.denied += 1;
            var rb: [256]u8 = undefined;
            const reason = std.fmt.bufPrint(&rb, "1 秒に {d} 回の操作 (上限 {d} 回)。{s} からの OBS 操作だけを {d} 秒止め、画面を暴走の前に戻しました", .{ t.peak_per_sec, @as(u32, @intFromFloat(s.rate_per_sec)), s.name, s.quarantine_secs }) catch "too many requests";
            emitSecurity(gate.bus, "limit_exceeded", t.node_id, s.name, "obs_rate", reason);
            if (gate.bus.graph) |g| g.updateNodeStatus(t.node_id, .quarantined);
            gate.publishStatus(t, "quarantined", reason, t.quarantine_until_ms);
            log.warn("ObsGate: {s} quarantined: {s}", .{ s.name, reason });
            return .{ .tripped = std.fmt.bufPrint(msg_buf, "WEAVE: {s}", .{reason}) catch "WEAVE: paused" };
        }
        if (t.learning() and !isRead(rt) and !t.learned.contains(key)) {
            if (gate.allocator.dupe(u8, key)) |k| {
                t.learned.put(gate.allocator, k, {}) catch gate.allocator.free(k);
                gate.saveLearned(t);
            } else |_| {}
        }
        return .ok;
    }

    fn onRequest(self: *Conn, d: std.json.ObjectMap, raw: []const u8) !void {
        const gate = self.gate;
        const t = self.tool.?;
        const rt_v = d.get("requestType") orelse return;
        if (rt_v != .string) return;
        const rt = rt_v.string;
        const rid: []const u8 = if (d.get("requestId")) |v| (if (v == .string) v.string else "") else "";
        const data = d.get("requestData") orelse .null;
        const now = std.time.milliTimestamp();

        var msg_buf: [512]u8 = undefined;
        var tgb: [192]u8 = undefined;
        const target = targetOf(&tgb, rt, data);
        t.mutex.lock();
        const verdict = self.judge(t, rt, target, now, &msg_buf);
        t.mutex.unlock();

        switch (verdict) {
            .denied => |m| return self.reply(rt, rid, 205, m),
            .quarantined => |m| return self.reply(rt, rid, 207, m),
            .tripped => |m| {
                self.restoreOriginals(t);
                return self.reply(rt, rid, 207, m);
            },
            .ok => {},
        }
        if (!isRead(rt)) self.rememberOriginal(t, rt, data, now);
        try self.sendUp(raw);
        t.mutex.lock();
        t.forwarded += 1;
        t.mutex.unlock();
        if (!isRead(rt)) if (gate.bus.graph) |g| {
            var tb: [160]u8 = undefined;
            if (std.fmt.bufPrint(&tb, "core.obs.request.{s}", .{rt})) |topic| g.recordPublish(t.node_id, topic) catch {} else |_| {}
        };
    }

    fn onBatch(self: *Conn, d: std.json.ObjectMap, raw: []const u8) !void {
        const t = self.tool.?;
        const rid: []const u8 = if (d.get("requestId")) |v| (if (v == .string) v.string else "") else "";
        const reqs = d.get("requests") orelse return;
        if (reqs != .array) return;
        const now = std.time.milliTimestamp();
        var msg_buf: [512]u8 = undefined;
        var fail: ?[]const u8 = null;
        var code: i64 = 205;
        t.mutex.lock();
        for (reqs.array.items) |r| {
            if (r != .object) continue;
            const rt = r.object.get("requestType") orelse continue;
            if (rt != .string) continue;
            var tgb: [192]u8 = undefined;
            const target = targetOf(&tgb, rt.string, r.object.get("requestData") orelse .null);
            switch (self.judge(t, rt.string, target, now, &msg_buf)) {
                .ok => {},
                .denied => |m| fail = m,
                .quarantined, .tripped => |m| {
                    fail = m;
                    code = 207;
                },
            }
            if (fail != null) break;
        }
        if (fail == null) t.forwarded += reqs.array.items.len;
        t.mutex.unlock();
        if (fail) |m| {
            var buf: [8192]u8 = undefined;
            var w = std.io.Writer.fixed(&buf);
            try w.writeAll("{\"op\":9,\"d\":{\"requestId\":");
            try w.print("{f}", .{std.json.fmt(rid, .{})});
            try w.writeAll(",\"results\":[");
            for (reqs.array.items, 0..) |r, i| {
                if (i > 0) try w.writeAll(",");
                const rt: []const u8 = if (r == .object) (if (r.object.get("requestType")) |v| (if (v == .string) v.string else "") else "") else "";
                try w.print("{f}", .{std.json.fmt(.{ .requestType = rt, .requestStatus = .{ .result = false, .code = code, .comment = m } }, .{})});
            }
            try w.writeAll("]}}");
            return self.sendClient(w.buffered());
        }
        try self.sendUp(raw);
    }

    /// 書き換える前の状態を、暴走が始まる前に 1 回だけ読んでおく (落ち着いた状態 = 2 秒操作が無かったら取り直す)
    fn rememberOriginal(self: *Conn, t: *Tool, rt: []const u8, data: std.json.Value, now: i64) void {
        const a = self.gate.allocator;
        t.mutex.lock();
        if (now - t.last_mutation_ms > CALM_MS) {
            for (t.originals.keys(), t.originals.values()) |k, v| {
                a.free(k);
                a.free(v);
            }
            t.originals.clearRetainingCapacity();
        }
        t.last_mutation_ms = now;
        t.mutex.unlock();
        if (data != .object) return;
        const obj = data.object;
        var kb: [256]u8 = undefined;
        if (std.mem.eql(u8, rt, "SetSceneItemEnabled")) {
            const scene = obj.get("sceneName") orelse return;
            const id = obj.get("sceneItemId") orelse return;
            if (scene != .string or id != .integer) return;
            const key = std.fmt.bufPrint(&kb, "item:{s}#{d}", .{ scene.string, id.integer }) catch return;
            if (self.known(t, key)) return;
            const res = self.call("GetSceneItemEnabled", .{ .sceneName = scene.string, .sceneItemId = id.integer }) orelse return;
            defer a.free(res);
            const en = responseField(a, res, "sceneItemEnabled") orelse return;
            defer a.free(en);
            const restore = std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .t = "SetSceneItemEnabled", .d = .{ .sceneName = scene.string, .sceneItemId = id.integer, .sceneItemEnabled = std.mem.eql(u8, en, "true") } }, .{})}) catch return;
            self.store(t, key, restore);
        } else if (std.mem.eql(u8, rt, "SetCurrentProgramScene")) {
            if (self.known(t, "scene")) return;
            const res = self.call("GetCurrentProgramScene", .{}) orelse return;
            defer a.free(res);
            const name = responseField(a, res, "currentProgramSceneName") orelse return;
            defer a.free(name);
            const restore = std.fmt.allocPrint(a, "{f}", .{std.json.fmt(.{ .t = "SetCurrentProgramScene", .d = .{ .sceneName = std.mem.trim(u8, name, "\"") } }, .{})}) catch return;
            self.store(t, "scene", restore);
        } else if (std.mem.eql(u8, rt, "SetInputSettings")) {
            const input = obj.get("inputName") orelse return;
            if (input != .string) return;
            const key = std.fmt.bufPrint(&kb, "input:{s}", .{input.string}) catch return;
            if (self.known(t, key)) return;
            const res = self.call("GetInputSettings", .{ .inputName = input.string }) orelse return;
            defer a.free(res);
            const settings = responseField(a, res, "inputSettings") orelse return;
            defer a.free(settings);
            // inputSettings は JSON のまま埋め込む
            const prefix = std.fmt.allocPrint(a, "{f}", .{std.json.fmt(input.string, .{})}) catch return;
            defer a.free(prefix);
            const restore = std.fmt.allocPrint(a, "{{\"t\":\"SetInputSettings\",\"d\":{{\"inputName\":{s},\"inputSettings\":{s},\"overlay\":true}}}}", .{ prefix, settings }) catch return;
            self.store(t, key, restore);
        }
    }

    fn known(self: *Conn, t: *Tool, key: []const u8) bool {
        _ = self;
        t.mutex.lock();
        defer t.mutex.unlock();
        return t.originals.contains(key);
    }

    fn store(self: *Conn, t: *Tool, key: []const u8, value: []u8) void {
        const a = self.gate.allocator;
        t.mutex.lock();
        defer t.mutex.unlock();
        if (t.originals.contains(key)) {
            a.free(value);
            return;
        }
        const k = a.dupe(u8, key) catch {
            a.free(value);
            return;
        };
        t.originals.put(a, k, value) catch {
            a.free(k);
            a.free(value);
        };
    }

    /// 止めた瞬間に、そのツールが書き換えたものを暴走前の状態に戻す
    fn restoreOriginals(self: *Conn, t: *Tool) void {
        const a = self.gate.allocator;
        t.mutex.lock();
        var list = std.ArrayListUnmanaged([]u8){};
        defer {
            for (list.items) |x| a.free(x);
            list.deinit(a);
        }
        for (t.originals.values()) |v| list.append(a, a.dupe(u8, v) catch continue) catch {};
        t.mutex.unlock();
        var n: usize = 0;
        for (list.items) |entry| {
            var parsed = std.json.parseFromSlice(std.json.Value, a, entry, .{}) catch continue;
            defer parsed.deinit();
            const rt = parsed.value.object.get("t") orelse continue;
            const d = parsed.value.object.get("d") orelse continue;
            if (self.call(rt.string, d)) |res| {
                a.free(res);
                n += 1;
            }
        }
        log.info("ObsGate: restored {d} item(s) of {s}", .{ n, t.name() });
    }
};

/// フレームはヘッダと本体を別々に書くので、Nagle で 1 要求ごとに数十 ms 待たされないようにする
fn noDelay(s: std.net.Stream) void {
    const one: c_int = 1;
    std.posix.setsockopt(s.handle, std.posix.IPPROTO.TCP, std.posix.TCP.NODELAY, std.mem.asBytes(&one)) catch {};
}

/// core.security.* に発行する (host_api.emitSecurity と同じ形。CLI からも読むので WAMR に依存させない)
fn emitSecurity(bus: *event_bus.EventBus, subtopic: []const u8, node_id: u32, name: []const u8, action: []const u8, topic: []const u8) void {
    var topic_buf: [96]u8 = undefined;
    const full_topic = std.fmt.bufPrint(&topic_buf, "core.security.{s}", .{subtopic}) catch return;
    var buf: [768]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    w.print("{f}", .{std.json.fmt(.{ .node_id = node_id, .name = name, .action = action, .topic = topic }, .{})}) catch return;
    _ = bus.publish(full_topic, w.buffered(), .Transient, 0) catch {};
}

/// RequestResponse の responseData.<field> を JSON 文字列として返す
fn responseField(a: std.mem.Allocator, res: []const u8, field: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, a, res, .{}) catch return null;
    defer parsed.deinit();
    const d = parsed.value.object.get("d") orelse return null;
    if (d != .object) return null;
    const rd = d.object.get("responseData") orelse return null;
    if (rd != .object) return null;
    const v = rd.object.get(field) orelse return null;
    return std.fmt.allocPrint(a, "{f}", .{std.json.fmt(v, .{})}) catch null;
}

test "allow の照合: 完全一致と末尾 * の前方一致" {
    var allow = [_][]const u8{ "SetSceneItemEnabled", "Get*" };
    try std.testing.expect(matches(&allow, "SetSceneItemEnabled"));
    try std.testing.expect(matches(&allow, "SetSceneItemEnabled:Overlay#3"));
    try std.testing.expect(matches(&allow, "GetSceneList"));
    try std.testing.expect(!matches(&allow, "StopStream"));
    try std.testing.expect(!matches(&allow, "SetSceneItemEnabledX"));
}

test "allow の照合: 対象つきの宣言は、その対象だけを許す" {
    var allow = [_][]const u8{ "SetInputSettings:OverlayText", "SetSceneItemEnabled:Overlay#1" };
    try std.testing.expect(matches(&allow, "SetInputSettings:OverlayText"));
    try std.testing.expect(!matches(&allow, "SetInputSettings:番組名"));
    try std.testing.expect(!matches(&allow, "SetInputSettings"));
    try std.testing.expect(matches(&allow, "SetSceneItemEnabled:Overlay#1"));
    try std.testing.expect(!matches(&allow, "SetSceneItemEnabled:Overlay#3"));
}

test "対象の取り出し" {
    var buf: [64]u8 = undefined;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"sceneName\":\"Overlay\",\"sceneItemId\":3,\"sceneItemEnabled\":false}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Overlay#3", targetOf(&buf, "SetSceneItemEnabled", parsed.value).?);
    var p2 = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"inputName\":\"OverlayText\",\"inputSettings\":{}}", .{});
    defer p2.deinit();
    try std.testing.expectEqualStrings("OverlayText", targetOf(&buf, "SetInputSettings", p2.value).?);
    try std.testing.expect(targetOf(&buf, "StopStream", .null) == null);
}

test "learn モードでも配信停止は通さない" {
    try std.testing.expect(isAlwaysAsk("StopStream"));
    try std.testing.expect(!isAlwaysAsk("SetCurrentProgramScene"));
}
