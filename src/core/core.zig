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
        self.trust_store.deinit(self.allocator);
        self.graph.deinit();
        self.tm.deinit();
        self.pm.deinit();
        self.bus.deinit();
        self.runtime.deinit();
    }

    /// 署名検証を設定する (main から呼ぶ)。mode 文字列と信頼鍵ファイルを読み込む。
    pub fn configureSignature(self: *Core, mode_str: []const u8, trust_keys_path: []const u8) !void {
        self.signature_mode = signing.VerifyMode.fromString(mode_str);
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
    fn verifyPluginSignature(self: *Core, wasm_path: []const u8, wasm_buffer: []const u8, manifest_path: []const u8) !void {
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
            const manifest = std.fs.cwd().readFileAlloc(self.allocator, manifest_path, 1024 * 1024) catch {
                break :blk "manifest を読めません";
            };
            defer self.allocator.free(manifest);

            if (self.trust_store.verifyAny(sig_bytes, wasm_buffer, manifest)) {
                log.info("Signature: OK '{s}' (trusted signer, wasm+manifest intact)", .{wasm_path});
                return; // 検証成功
            }
            break :blk "改ざん or 未信頼の署名者 (署名検証に失敗)";
        };

        // ここに来たら検証失敗
        var payload_buf: [512]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"plugin\":\"{s}\",\"mode\":\"{s}\",\"reason\":\"{s}\"}}", .{ wasm_path, @tagName(self.signature_mode), reason }) catch "{}";
        _ = self.bus.publish("core.security.signature_invalid", payload, .Transient, 0) catch {};

        if (self.signature_mode == .strict) {
            log.err("Signature: REJECTED '{s}' — {s} [strict: ロードを拒否します]", .{ wasm_path, reason });
            return error.SignatureRejected;
        } else {
            log.warn("Signature: '{s}' — {s} [warn: ロードは継続します]", .{ wasm_path, reason });
        }
    }

    /// ゲートウェイとしての橋渡し設定
    pub fn setupGateway(self: *Core) !void {
        self.bus.global_observer = .{
            .ctx = &self.tm,
            .callback = struct {
                fn cb(ctx: *anyopaque, msg: *const event_bus.EventMessage) void {
                    const tm: *TransportManager = @ptrCast(@alignCast(ctx));
                    tm.broadcast(msg.topic, msg.payload, msg.qos);
                }
            }.cb,
        };
        std.debug.print("Core: Gateway bridge established (EventBus -> TransportManager)\n", .{});
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

        // 署名検証 (トラストアンカー Stage 1)。strict では未署名/改ざんをここで拒否。
        try self.verifyPluginSignature(wasm_path, wasm_buffer, manifest_path);

        const module = try self.runtime.loadModule(wasm_buffer);
        // 注意: モジュールはランタイムが管理するが、個別のアンロード戦略は将来課題

        const module_inst = try self.runtime.instantiate(module, self.pm.wasm_stack_size, self.pm.wasm_heap_size);

        // グラフへの登録 (Wasm) - 先に登録しておかないと初期購読(subscribe)時に NodeNotFound になる
        const node_id = self.pm.next_node_id;
        try self.graph.registerNode(node_id, wasm_path, .wasm); // 仮名

        const meta = try self.pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &self.bus);
        pm_owns_buffer = true; // 以降 wasm_buffer は PluginManager が所有・解放する

        // 名前の更新（マニフェストから正確な名前を取得）
        try self.graph.registerNode(node_id, meta.manifest_parsed.value.name, .wasm);

        try self.bus.publish("core.node.registered", "{\"type\":\"wasm\"}", .Transient, 0);

        // on_init 呼び出し
        const wamr = @import("wasm_runtime.zig").wamr;
        if (wamr.wasm_runtime_lookup_function(module_inst, "on_init")) |func| {
            const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
            defer wamr.wasm_runtime_destroy_exec_env(env);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
        }

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
    try core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_path);

    // 2. manifest を改ざん → strict で拒否
    try std.fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = manifest_evil });
    try std.testing.expectError(error.SignatureRejected, core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_path));

    // 3. 署名ファイルを消す (未署名) → strict で拒否
    std.fs.cwd().deleteFile(sig_path) catch {};
    try std.testing.expectError(error.SignatureRejected, core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_path));

    // 4. warn モードは、改ざん/未署名でもロードを止めない (エラーを返さない)
    core.signature_mode = .warn;
    try core.verifyPluginSignature(wasm_path, wasm_buffer, manifest_path);
}
