const std = @import("std");
const event_bus = @import("event_bus.zig");
const EventBus = event_bus.EventBus;
const PluginManager = @import("plugin_manager.zig").PluginManager;
const TransportManager = @import("../transport/interface.zig").TransportManager;
const WasmRuntime = @import("wasm_runtime.zig").WasmRuntime;
const SystemGraph = @import("graph.zig").SystemGraph;
const signing = @import("../security/signing.zig");
const log = @import("../common/log.zig");

pub const Core = struct {
    allocator: std.mem.Allocator,
    bus: EventBus,
    pm: PluginManager,
    tm: TransportManager,
    runtime: WasmRuntime,
    graph: SystemGraph,
    // 署名検証 (トラストアンカー Stage 1)
    signature_mode: signing.VerifyMode = .off,
    /// 運用者が宣言したセルの予算 (名前 → eps)。ここに無い名前のセルにプラグインは自分から入れない
    cell_budgets: std.StringHashMapUnmanaged(f64) = .{},
    trust_store: signing.TrustStore = .{},

    pub fn init(allocator: std.mem.Allocator) !Core {
        return Core{
            .allocator = allocator,
            .bus = try EventBus.init(allocator, 1000),
            .pm = PluginManager.init(allocator),
            .tm = TransportManager.init(allocator),
            .runtime = try WasmRuntime.init(),
            .graph = SystemGraph.init(allocator),
        };
    }

    pub fn deinit(self: *Core) void {
        var it = self.cell_budgets.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.cell_budgets.deinit(self.allocator);
        self.trust_store.deinit(self.allocator);
        self.graph.deinit();
        self.tm.deinit();
        self.pm.deinit();
        self.bus.deinit();
        self.runtime.deinit();
    }

    /// 署名検証を設定する (main から呼ぶ)。mode 文字列と信頼鍵ファイルを読み込む。
    pub fn configureSignature(self: *Core, mode_str: []const u8, trust_keys_path: []const u8) !void {
        self.signature_mode = signing.VerifyMode.parse(mode_str) orelse {
            log.err("Signature: unknown mode '{s}' (expected off|warn|strict)", .{mode_str});
            return error.InvalidSignatureMode;
        };
        if (self.signature_mode == .off) return;
        self.trust_store = try signing.TrustStore.loadFile(self.allocator, trust_keys_path);
        if (self.trust_store.isEmpty()) {
            log.warn("Signature: mode={s} but trust store '{s}' is empty (no trusted keys). All plugins will be rejected in strict mode.", .{ mode_str, trust_keys_path });
        } else {
            log.info("Signature: enforcement mode={s}, {} trusted key(s) loaded from '{s}'", .{ mode_str, self.trust_store.keys.items.len, trust_keys_path });
        }
    }

    /// プラグインの署名を検証する。strict で失敗すると error を返す。
    /// 検証対象は wasm バイナリ + manifest の両方 (権限宣言の差し替えを防ぐ)。
    fn verifyPluginSignature(self: *Core, wasm_path: []const u8, wasm_buffer: []const u8, manifest: []const u8) !void {
        if (self.signature_mode == .off) return;

        var sig_path_buf: [512]u8 = undefined;
        const sig_path = try std.fmt.bufPrint(&sig_path_buf, "{s}.sig", .{wasm_path});

        const reason: []const u8 = blk: {
            const sig_hex = std.fs.cwd().readFileAlloc(self.allocator, sig_path, 4096) catch {
                break :blk "署名ファイルがありません (未署名)";
            };
            defer self.allocator.free(sig_hex);
            const sig_bytes = signing.fromHex(64, std.mem.trim(u8, sig_hex, " \t\r\n")) orelse {
                break :blk "署名の形式が不正です";
            };
            if (self.trust_store.verifyAny(sig_bytes, wasm_buffer, manifest)) {
                log.info("Signature: OK '{s}' (trusted signer, wasm+manifest intact)", .{wasm_path});
                return; // 検証成功
            }
            break :blk "改ざん or 未信頼の署名者 (署名検証に失敗)";
        };

        // ここに来たら検証失敗
        var payload_buf: [768]u8 = undefined;
        var pw = std.io.Writer.fixed(&payload_buf);
        pw.print("{f}", .{std.json.fmt(.{ .name = wasm_path, .plugin = wasm_path, .mode = @tagName(self.signature_mode), .detail = reason }, .{})}) catch {};
        _ = self.bus.publish("core.security.signature_invalid", pw.buffered(), .Transient, 0) catch {};

        if (self.signature_mode == .strict) {
            log.err("Signature: REJECTED '{s}' — {s} [strict: ロードを拒否します]", .{ wasm_path, reason });
            return error.SignatureRejected;
        } else {
            log.warn("Signature: '{s}' — {s} [warn: ロードは継続します]", .{ wasm_path, reason });
        }
    }

    /// ゲートウェイ (EventBus -> TransportManager) の ID。グラフには載せないタップ
    pub const GATEWAY_NODE_ID: u32 = 3;

    fn gatewayTap(ctx: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const tm: *TransportManager = @ptrCast(@alignCast(ctx orelse return));
        tm.broadcast(msg.topic, msg.payload, msg.qos);
    }

    /// ゲートウェイとしての橋渡し設定。
    /// 外部への送信 (遅い WebSocket クライアントなど) が他の配送を待たせないよう、
    /// 専用セル "observe" のタップとして購読する。
    pub fn setupGateway(self: *Core) !void {
        const observe = self.bus.getCell("observe") orelse try self.bus.createCell("observe", .{ .trust = .core });
        try self.bus.subscribeEx("#", GATEWAY_NODE_ID, gatewayTap, &self.tm, .{ .cell = observe, .receive_own = true, .record_graph = false });
        log.info("Core: Gateway bridge established (EventBus -> TransportManager, cell 'observe')", .{});
    }

    /// セルの予算を宣言する (main が weave.json / --cell-budget から呼ぶ)。名前は "plugin." か "plugins." で始まること
    pub fn setCellBudget(self: *Core, name: []const u8, eps: f64) !void {
        if (!isPluginCellName(name)) return error.InvalidCellName;
        const gop = try self.cell_budgets.getOrPut(self.allocator, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, name);
        gop.value_ptr.* = eps;
    }

    fn isPluginCellName(name: []const u8) bool {
        return std.mem.startsWith(u8, name, "plugin.") or std.mem.startsWith(u8, name, "plugins.");
    }

    /// プラグインの所属セルを決めて取得する (無ければ作る)。
    /// 既定は 1 プラグイン = 1 セル (`plugin.<name>`) = 1 executor なので、あるプラグインが遅延・停止しても
    /// 他のプラグインや Twitch/OBS の配送は待たされない。manifest の `cell` で束ねたい場合は、
    /// 運用者が予算を宣言したセル (`plugins.*`) にだけ入れる (プラグインが自分で core / egress 等に入ったり、
    /// 勝手に他のプラグインと executor を共有したりはできない)。
    fn pluginCell(self: *Core, m: *const @import("manifest.zig").Manifest) !*event_bus.Cell {
        var buf: [96]u8 = undefined;
        var cell_name: []const u8 = try std.fmt.bufPrint(&buf, "plugin.{s}", .{m.name});
        if (m.cell) |requested| {
            if (isPluginCellName(requested) and self.cell_budgets.contains(requested)) {
                cell_name = requested;
            } else {
                log.warn("Core: plugin '{s}' asked for cell '{s}', which the operator has not declared; using '{s}'", .{ m.name, requested, cell_name });
            }
        }
        if (self.bus.getCell(cell_name)) |c| return c;
        return self.bus.createCell(cell_name, .{ .trust = .untrusted, .budget_eps = self.cell_budgets.get(cell_name) orelse 0 });
    }

    /// Wasmプラグインをロードして初期化する
    pub fn loadPlugin(self: *Core, wasm_path: []const u8) !void {
        const wasm_buffer = try std.fs.cwd().readFileAlloc(self.allocator, wasm_path, 1024 * 1024);
        // 注意: モジュールが生きている間は wasm_buffer を解放してはいけない（WAMRの仕様）。
        // registerPlugin が所有権を取るまでの間だけ、エラー時に解放する (二重解放防止のフラグ管理)。
        var pm_owns_buffer = false;
        errdefer if (!pm_owns_buffer) self.allocator.free(wasm_buffer);

        // マニフェストパスの推測 (plugin.wasm -> plugin.json)
        var manifest_path_buf: [256]u8 = undefined;
        const manifest_path = if (std.mem.endsWith(u8, wasm_path, ".wasm"))
            try std.fmt.bufPrint(&manifest_path_buf, "{s}.json", .{wasm_path[0 .. wasm_path.len - 5]})
        else
            "wasm-apps/manifest.json";

        // manifest は 1 回だけ読み、そのバイト列で署名検証とパースの両方を行う (TOCTOU 対策)
        const manifest_bytes = try std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 1024 * 1024);
        defer self.allocator.free(manifest_bytes);

        // 署名検証 (トラストアンカー Stage 1)。strict では未署名/改ざんをここで拒否。
        try self.verifyPluginSignature(wasm_path, wasm_buffer, manifest_bytes);

        // 資源上限はインスタンス化の前に必要なので先に読む (権限の検証は registerPlugin で行う)
        const limits = blk: {
            const pre = @import("manifest.zig").Manifest.parse(self.allocator, manifest_bytes) catch break :blk @import("manifest.zig").Limits{};
            defer pre.deinit();
            break :blk pre.value.limits;
        };

        // 検証済みのバイト列からロードしたモジュールを生涯保持し、自動再起動はそこからインスタンスを作る
        // (ディスクを読み直さない。PluginManager.restartPlugin)
        const module = try self.runtime.loadModule(wasm_buffer);
        errdefer if (!pm_owns_buffer) @import("wasm_runtime.zig").wamr.wasm_runtime_unload(module);

        const module_inst = try self.runtime.instantiateLimited(module, self.pm.wasm_stack_size, self.pm.wasm_heap_size, limits.memory_pages);
        errdefer if (!pm_owns_buffer) @import("wasm_runtime.zig").wamr.wasm_runtime_deinstantiate(module_inst);

        // グラフへの登録 (Wasm) - 先に登録しておかないと初期購読(subscribe)時に NodeNotFound になる
        const node_id = self.pm.next_node_id;
        try self.graph.registerNode(node_id, wasm_path, .wasm); // 仮名

        const meta = try self.pm.registerPluginWithManifest(module, module_inst, wasm_path, manifest_path, manifest_bytes, wasm_buffer, &self.bus);
        pm_owns_buffer = true; // 以降 wasm_buffer は PluginManager が所有・解放する

        // 所属セル (プラグイン専用の executor) を割り当てる。以降の購読はこのセル宛てになる
        const name = meta.manifest_parsed.value.name;
        const cell = try self.pluginCell(&meta.manifest_parsed.value);
        if (meta.subscriber) |*sub| sub.cell = cell;

        // 名前の更新（マニフェストから正確な名前を取得）
        try self.graph.registerNodeIn(node_id, name, .wasm, cell.name);

        var reg_buf: [256]u8 = undefined;
        var reg_w = std.io.Writer.fixed(&reg_buf);
        reg_w.print("{f}", .{std.json.fmt(.{ .node_id = node_id, .name = name, .type = "wasm", .cell = cell.name }, .{})}) catch {};
        try self.bus.publish("core.node.registered", reg_w.buffered(), .Transient, 0);

        // on_init → 状態領域の検出 → 予備インスタンスの用意。購読の前に行う
        // (購読した瞬間からセルの executor が配送を始めうるので、WasmSubscriber のロックを取って行う)
        self.pm.initPlugin(meta);

        // マニフェストに基づいたSubscribe適用
        try self.pm.applyManifestSubscriptions(module_inst, &self.bus);

        std.debug.print("Core: Loaded plugin '{s}' (Node {})\n", .{ meta.manifest_parsed.value.name, meta.node_id });
    }
};

test "signature enforcement: strict accepts valid signer, rejects tampered manifest; warn does not block" {
    const allocator = std.testing.allocator;
    const Ed25519 = std.crypto.sign.Ed25519;

    const wasm_buffer = "\x00asm plugin body bytes for signature test";
    const manifest_good = "{\"name\":\"t\",\"version\":\"1\",\"permissions\":{\"publish\":[\"core.obs.request.*\"],\"subscribe\":[]}}";
    const manifest_evil = "{\"name\":\"t\",\"version\":\"1\",\"permissions\":{\"publish\":[\"#\"],\"subscribe\":[]}}";

    const kp = Ed25519.KeyPair.generate();
    const sig = try signing.sign(kp, wasm_buffer, manifest_good);
    const sig_hex = try signing.toHex(allocator, &sig);
    defer allocator.free(sig_hex);
    var pkb = kp.public_key.toBytes();
    const pub_hex = try signing.toHex(allocator, &pkb);
    defer allocator.free(pub_hex);

    const wasm_path = "test_sigenf_plugin.wasm";
    const sig_path = "test_sigenf_plugin.wasm.sig";
    const manifest_path = "test_sigenf_plugin.json";
    const trust_path = "test_sigenf_trusted";
    try std.fs.cwd().writeFile(.{ .sub_path = sig_path, .data = sig_hex });
    try std.fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = manifest_good });
    try std.fs.cwd().writeFile(.{ .sub_path = trust_path, .data = pub_hex });
    defer {
        std.fs.cwd().deleteFile(sig_path) catch {};
        std.fs.cwd().deleteFile(manifest_path) catch {};
        std.fs.cwd().deleteFile(trust_path) catch {};
    }

    var core = try Core.init(allocator);
    defer core.deinit();
    core.bus.verbose = false;
    try core.configureSignature("strict", trust_path);

    // 1. 正規署名 + 未改ざん → 受理 (エラーなし)
    try core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_good);

    // 2. manifest を改ざん → strict で拒否
    try std.testing.expectError(error.SignatureRejected, core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_evil));

    // 3. 署名ファイルを消す (未署名) → strict で拒否
    std.fs.cwd().deleteFile(sig_path) catch {};
    try std.testing.expectError(error.SignatureRejected, core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_good));

    // 4. warn モードは、改ざん/未署名でもロードを止めない (エラーを返さない)
    core.signature_mode = .warn;
    try core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_evil);
}

test "restart rebuilds from the verified bytes, not from the file on disk" {
    const allocator = std.testing.allocator;
    const host_api = @import("../api/host_api.zig");

    // 検証・ロードした後にファイルを差し替えられても、自動再起動で差し替え後のコードが動かないこと。
    // (以前は再起動で wasm をディスクから読み直し、署名を確かめていなかった)
    const wasm_path = "test_restart_verified.wasm";
    const manifest_path = "test_restart_verified.json";
    try std.fs.cwd().copyFile("wasm-apps/chat_node.wasm", std.fs.cwd(), wasm_path, .{});
    try std.fs.cwd().copyFile("wasm-apps/chat_node.json", std.fs.cwd(), manifest_path, .{});
    defer {
        std.fs.cwd().deleteFile(wasm_path) catch {};
        std.fs.cwd().deleteFile(manifest_path) catch {};
    }

    var core = try Core.init(allocator);
    defer core.deinit();
    core.bus.verbose = false;
    core.pm.runtime = &core.runtime;
    host_api.global_bus = &core.bus;
    host_api.global_plugin_manager = &core.pm;
    defer {
        host_api.global_bus = null;
        host_api.global_plugin_manager = null;
    }
    var symbols = host_api.getNativeSymbols();
    try core.runtime.registerNatives("env", &symbols);
    try core.bus.start();

    try core.loadPlugin(wasm_path);
    const node_id = core.pm.next_node_id - 1;

    // ロード後にディスク上の wasm を壊す (差し替えの代わり)
    try std.fs.cwd().writeFile(.{ .sub_path = wasm_path, .data = "not a wasm module" });

    // 再起動はロード済みのモジュール (検証済みのバイト列) から作るので成功する (ディスクを読んでいたら ModuleLoadFailed)
    try core.pm.restartPlugin(node_id, &core.bus);
    const meta = core.pm.findByNodeIdLocked(node_id) orelse return error.MetaNotFound;
    try std.testing.expect(meta.spare != null); // 次の再起動用の予備も同じモジュールから作られている
    try std.testing.expect(std.mem.startsWith(u8, meta.wasm_buffer, "\x00asm"));
    core.bus.waitIdle();
}

test "cell budget: plugins in an operator-declared cell share one publish budget; undeclared cells are refused" {
    const allocator = std.testing.allocator;
    const host_api = @import("../api/host_api.zig");

    const names = [_][]const u8{ "test_cell_a", "test_cell_b", "test_cell_c" };
    const cells = [_][]const u8{ "plugins.shared", "plugins.shared", "plugins.undeclared" };
    for (names, cells) |n, c| {
        var pbuf: [64]u8 = undefined;
        try std.fs.cwd().copyFile("wasm-apps/counter_node.wasm", std.fs.cwd(), try std.fmt.bufPrint(&pbuf, "{s}.wasm", .{n}), .{});
        var mbuf: [512]u8 = undefined;
        const m = try std.fmt.bufPrint(&mbuf, "{{\"name\":\"{s}\",\"version\":\"1\",\"cell\":\"{s}\",\"permissions\":{{\"publish\":[\"ext.counter.value\"],\"subscribe\":[\"ext.counter.inc\"]}}}}", .{ n, c });
        try std.fs.cwd().writeFile(.{ .sub_path = try std.fmt.bufPrint(&pbuf, "{s}.json", .{n}), .data = m });
    }
    defer for (names) |n| {
        var pbuf: [64]u8 = undefined;
        std.fs.cwd().deleteFile(std.fmt.bufPrint(&pbuf, "{s}.wasm", .{n}) catch unreachable) catch {};
        std.fs.cwd().deleteFile(std.fmt.bufPrint(&pbuf, "{s}.json", .{n}) catch unreachable) catch {};
    };

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

    try std.testing.expectError(error.InvalidCellName, core.setCellBudget("egress", 1000));
    try core.setCellBudget("plugins.shared", 2);

    const C = struct {
        var values = std.atomic.Value(u32).init(0);
        var limited = std.atomic.Value(u32).init(0);
        fn onValue(_: ?*anyopaque, _: *const event_bus.EventMessage) void {
            _ = values.fetchAdd(1, .monotonic);
        }
        fn onLimited(_: ?*anyopaque, msg: *const event_bus.EventMessage) void {
            if (std.mem.indexOf(u8, msg.payload, "plugins.shared") != null) _ = limited.fetchAdd(1, .monotonic);
        }
    };
    C.values.store(0, .monotonic);
    C.limited.store(0, .monotonic);
    try core.bus.subscribe("ext.counter.value", 90, C.onValue, null);
    try core.bus.subscribe("core.security.rate_limited", 91, C.onLimited, null);
    try core.bus.start();

    try core.loadPlugin("test_cell_a.wasm");
    try core.loadPlugin("test_cell_b.wasm");
    try core.loadPlugin("test_cell_c.wasm");

    // a と b は同じセル、c は宣言されていないセルを求めたので自分専用のセル
    const cell_a = core.pm.findByNodeIdLocked(100).?.subscriber.?.cell.?;
    const cell_b = core.pm.findByNodeIdLocked(101).?.subscriber.?.cell.?;
    const cell_c = core.pm.findByNodeIdLocked(102).?.subscriber.?.cell.?;
    try std.testing.expectEqual(cell_a, cell_b);
    try std.testing.expectEqualStrings("plugins.shared", cell_a.name);
    try std.testing.expectEqualStrings("plugin.test_cell_c", cell_c.name);

    // 5 回 inc → 3 ノードがそれぞれ publish しようとする。c は無制限で 5 件、
    // a と b は 2 人合わせて予算 (2 eps, 最初の 2 件 + わずかな補充) しか出せない
    var i: usize = 0;
    while (i < 5) : (i += 1) try core.bus.publish("ext.counter.inc", "{}", .Reliable, 0);
    core.bus.waitIdle();
    const shared_out = C.values.load(.monotonic) - 5;
    try std.testing.expect(shared_out >= 2 and shared_out <= 3);
    try std.testing.expect(C.limited.load(.monotonic) >= 1);
    try std.testing.expect(cell_a.budget_denied.load(.monotonic) >= 7);
}
