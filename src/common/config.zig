const std = @import("std");
const LogLevel = @import("types.zig").LogLevel;

pub const WeaveEnv = enum {
    development,
    production,

    pub fn fromString(str: []const u8) WeaveEnv {
        if (std.mem.eql(u8, str, "production")) return .production;
        return .development;
    }
};

pub const CellBudget = struct { name: []const u8, eps: f64 };

pub const Config = struct {
    ws_gateway_port: u16 = 8080,
    node_ws_port: u16 = 8081,
    dashboard_port: u16 = 3030,
    twitch_channel: []const u8 = "SqLA",
    obs_host: []const u8 = "127.0.0.1",
    obs_port: u16 = 4455,
    obs_password: []const u8 = "obs-password",
    log_level: LogLevel = .info,
    plugins: std.ArrayListUnmanaged([]const u8),
    /// セルの publish 予算 (weave.json の "cell_budgets": {"plugins.bots": 50} / --cell-budget plugins.bots=50)
    cell_budgets: std.ArrayListUnmanaged(CellBudget) = .{},
    graph_full_interval_secs: u32 = 60,
    node_ws_token: ?[]const u8 = null,
    weave_env: WeaveEnv = .development,
    wasm_stack_size: u32 = 128 * 1024,
    wasm_heap_size: u32 = 64 * 1024,
    mock_obs_filepath: []const u8 = "mock_obs_received.jsonl",
    mock_obs: bool = false,
    /// OBS への送信セル (egress) を別の OS プロセス (weave-cell) で動かす (ADR-010 Level 2 段階 1)
    isolate_egress: bool = false,
    /// Wasm プラグインを 1 つずつ別の OS プロセス (weave-cell plugin) で動かす (ADR-010 段階 2)
    isolate_plugins: bool = false,
    /// 名前 (wasm のファイル名から .wasm を除いたもの) を指定して、そのプラグインだけ別プロセスにする
    /// (--isolate-plugin <name> / weave.json の "isolate_plugins": ["name", ...])。手順 2-5
    isolate_plugin_names: std.ArrayListUnmanaged([]const u8) = .{},
    mock_twitch_scenario: ?[]const u8 = null,
    no_twitch: bool = false,
    // 署名検証 (トラストアンカー Stage 1): "off" | "warn" | "strict"
    signature_mode: []const u8 = "off",
    trust_keys_path: []const u8 = ".weave/trusted_keys",
    /// 利用者による承認 (トラストアンカー Stage 0): "off" | "warn" | "strict"。`weave add` で承認した権限より増えたものを止める
    approval_mode: []const u8 = "off",
    approvals_path: []const u8 = ".weave/approved.json",
    audit_log_path: []const u8 = "audit.log",
    /// 待ち受けアドレス。既定はループバックのみ (外に開くのは --bind 0.0.0.0 で明示)
    bind: []const u8 = "127.0.0.1",
    /// Inspector (Dashboard WebSocket) のトークン。未設定なら起動時に生成して表示
    dashboard_token: ?[]const u8 = null,
    /// 観測専用のトークン (/status)。これで繋いだ端末には稼働状態 (core.health.*) しか届かず、publish もできない。
    /// 未設定なら起動時に生成して表示
    observer_token: ?[]const u8 = null,
    /// 「本来いるはずのノード」の manifest (--expect <manifest.json> / weave.json の "expect")。
    /// 起動していなければ「起動していない」と判定し、それに依存して止まる機能を core.health.summary に出す
    expect: std.ArrayListUnmanaged([]const u8) = .{},
    /// 起動時の観測レベル: off | metadata | contents
    introspection: []const u8 = "metadata",
    /// mock Twitch のシナリオを 1 回だけ再生する (e2e テスト用)
    mock_twitch_once: bool = false,
    /// `weave record` の記録から外部入力を再生する (Twitch の代わりに入力源になる)
    replay_path: ?[]const u8 = null,

    dashboard_dist: []const u8 = "dashboard/dist",
    /// 状態 (スナップショット等) の置き場
    state_dir: []const u8 = ".weave/state",
    /// 状態のスナップショットを保存する (R7)
    snapshot: bool = true,
    /// 起動時にスナップショットから復元する。Supervisor がクラッシュ後に再起動したとき
    /// (WEAVE_RESTART_COUNT >= 1) か、--restore-snapshot を指定したときだけ。
    /// 普通に起動したときに何日も前の表示状態が戻ってくる、という驚きを避けるため。
    restore_snapshot: bool = false,
    /// StreamElements Astro (互換 A)。チャンネル ID と JWT の両方があるときだけ接続する。
    /// JWT は環境変数 STREAMELEMENTS_JWT からのみ受け取る (引数は ps で見えるため)
    streamelements_channel: ?[]const u8 = null,
    streamelements_url: ?[]const u8 = null,
    streamelements_jwt: ?[]const u8 = null,
    /// Streamlabs Socket API (互換 A)。--streamlabs で有効化。トークンは環境変数 STREAMLABS_SOCKET_TOKEN のみ
    streamlabs: bool = false,
    streamlabs_url: ?[]const u8 = null,
    streamlabs_token: ?[]const u8 = null,

    pub fn parse(allocator: std.mem.Allocator) !Config {
        var self = Config{
            .plugins = .{},
            .node_ws_token = null,
            .weave_env = .development,
            .wasm_stack_size = 128 * 1024,
            .wasm_heap_size = 64 * 1024,
            .mock_obs = false,
            .mock_twitch_scenario = null,
            .no_twitch = false,
        };

        errdefer self.deinit(allocator);
        var signature_mode_set = false;
        var approval_mode_set = false;

        // デフォルト文字列を dupe して動的アロケーションに統一 (リテラルとの混在・リーク防止)
        self.twitch_channel = try allocator.dupe(u8, self.twitch_channel);
        self.obs_host = try allocator.dupe(u8, self.obs_host);
        self.obs_password = try allocator.dupe(u8, self.obs_password);
        self.mock_obs_filepath = try allocator.dupe(u8, self.mock_obs_filepath);
        self.signature_mode = try allocator.dupe(u8, self.signature_mode);
        self.trust_keys_path = try allocator.dupe(u8, self.trust_keys_path);
        self.approval_mode = try allocator.dupe(u8, self.approval_mode);
        self.approvals_path = try allocator.dupe(u8, self.approvals_path);
        self.audit_log_path = try allocator.dupe(u8, self.audit_log_path);
        self.bind = try allocator.dupe(u8, self.bind);
        self.introspection = try allocator.dupe(u8, self.introspection);
        self.dashboard_dist = try allocator.dupe(u8, self.dashboard_dist);
        self.state_dir = try allocator.dupe(u8, self.state_dir);

        // 1. 設定ファイルの読み込み (weave.json) - 任意
        if (std.fs.cwd().openFile("weave.json", .{})) |file| {
            defer file.close();
            const size = try file.getEndPos();
            const buf = try allocator.alloc(u8, size);
            defer allocator.free(buf);
            _ = try file.readAll(buf);

            // 一時的な構造体にパース
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, buf, .{}) catch |err| {
                std.debug.print("Warning: Failed to parse weave.json: {any}\n", .{err});
                return err;
            };
            defer parsed.deinit();

            if (parsed.value == .object) {
                const obj = parsed.value.object;
                if (obj.get("ws_gateway_port")) |v| self.ws_gateway_port = @intCast(v.integer);
                if (obj.get("node_ws_port")) |v| self.node_ws_port = @intCast(v.integer);
                if (obj.get("dashboard_port")) |v| self.dashboard_port = @intCast(v.integer);
                if (obj.get("twitch_channel")) |v| {
                    allocator.free(self.twitch_channel);
                    self.twitch_channel = try allocator.dupe(u8, v.string);
                }
                if (obj.get("mock_twitch_scenario")) |v| {
                    if (self.mock_twitch_scenario) |s| allocator.free(s);
                    self.mock_twitch_scenario = try allocator.dupe(u8, v.string);
                }
                if (obj.get("obs_host")) |v| {
                    allocator.free(self.obs_host);
                    self.obs_host = try allocator.dupe(u8, v.string);
                }
                if (obj.get("obs_port")) |v| self.obs_port = @intCast(v.integer);
                if (obj.get("obs_password")) |v| {
                    allocator.free(self.obs_password);
                    self.obs_password = try allocator.dupe(u8, v.string);
                }
                if (obj.get("mock_obs_filepath")) |v| {
                    allocator.free(self.mock_obs_filepath);
                    self.mock_obs_filepath = try allocator.dupe(u8, v.string);
                }
                if (obj.get("mock_obs")) |v| self.mock_obs = v.bool;
                if (obj.get("log_level")) |v| self.log_level = LogLevel.fromString(v.string);
                if (obj.get("graph_full_interval_secs")) |v| self.graph_full_interval_secs = @intCast(v.integer);
                if (obj.get("node_ws_token")) |v| self.node_ws_token = try allocator.dupe(u8, v.string);
                if (obj.get("weave_env")) |v| self.weave_env = WeaveEnv.fromString(v.string);
                if (obj.get("wasm_stack_size")) |v| self.wasm_stack_size = @intCast(v.integer);
                if (obj.get("wasm_heap_size")) |v| self.wasm_heap_size = @intCast(v.integer);
                if (obj.get("signature_mode")) |v| {
                    signature_mode_set = true;
                    allocator.free(self.signature_mode);
                    self.signature_mode = try allocator.dupe(u8, v.string);
                }
                if (obj.get("trust_keys_path")) |v| {
                    allocator.free(self.trust_keys_path);
                    self.trust_keys_path = try allocator.dupe(u8, v.string);
                }
                if (obj.get("approval_mode")) |v| {
                    approval_mode_set = true;
                    allocator.free(self.approval_mode);
                    self.approval_mode = try allocator.dupe(u8, v.string);
                }
                if (obj.get("approvals_path")) |v| {
                    allocator.free(self.approvals_path);
                    self.approvals_path = try allocator.dupe(u8, v.string);
                }
                if (obj.get("audit_log_path")) |v| {
                    allocator.free(self.audit_log_path);
                    self.audit_log_path = try allocator.dupe(u8, v.string);
                }
                if (obj.get("isolate_plugins")) |v| {
                    if (v == .array) for (v.array.items) |item| {
                        if (item == .string) try self.isolate_plugin_names.append(allocator, try allocator.dupe(u8, item.string));
                    };
                }
                if (obj.get("cell_budgets")) |v| {
                    if (v == .object) {
                        var bit = v.object.iterator();
                        while (bit.next()) |e| {
                            const eps: f64 = switch (e.value_ptr.*) {
                                .integer => |n| @floatFromInt(n),
                                .float => |f| f,
                                else => continue,
                            };
                            try self.cell_budgets.append(allocator, .{ .name = try allocator.dupe(u8, e.key_ptr.*), .eps = eps });
                        }
                    }
                }
                if (obj.get("bind")) |v| {
                    allocator.free(self.bind);
                    self.bind = try allocator.dupe(u8, v.string);
                }
                if (obj.get("dashboard_token")) |v| {
                    if (self.dashboard_token) |t| allocator.free(t);
                    self.dashboard_token = try allocator.dupe(u8, v.string);
                }
                if (obj.get("observer_token")) |v| {
                    if (self.observer_token) |t| allocator.free(t);
                    self.observer_token = try allocator.dupe(u8, v.string);
                }
                if (obj.get("expect")) |v| {
                    if (v == .array) for (v.array.items) |item| {
                        if (item == .string) try self.expect.append(allocator, try allocator.dupe(u8, item.string));
                    };
                }
                if (obj.get("introspection")) |v| {
                    allocator.free(self.introspection);
                    self.introspection = try allocator.dupe(u8, v.string);
                }
                if (obj.get("plugins")) |v| {
                    if (v == .array) {
                        for (v.array.items) |p| {
                            try self.plugins.append(allocator, try allocator.dupe(u8, p.string));
                        }
                    }
                }
            }
        } else |_| {}

        // 2. 環境変数のチェック (上書き)
        if (std.process.getEnvVarOwned(allocator, "WEAVE_LOG_LEVEL")) |val| {
            defer allocator.free(val);
            self.log_level = LogLevel.fromString(val);
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_NODE_WS_TOKEN")) |val| {
            if (self.node_ws_token) |t| allocator.free(t);
            self.node_ws_token = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_DASHBOARD_TOKEN")) |val| {
            if (self.dashboard_token) |t| allocator.free(t);
            self.dashboard_token = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_OBSERVER_TOKEN")) |val| {
            if (self.observer_token) |t| allocator.free(t);
            self.observer_token = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "STREAMELEMENTS_JWT")) |val| {
            if (self.streamelements_jwt) |t| {
                std.crypto.secureZero(u8, @constCast(t));
                allocator.free(t);
            }
            self.streamelements_jwt = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "STREAMLABS_SOCKET_TOKEN")) |val| {
            if (self.streamlabs_token) |t| {
                std.crypto.secureZero(u8, @constCast(t));
                allocator.free(t);
            }
            self.streamlabs_token = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_RESTART_COUNT")) |val| {
            defer allocator.free(val);
            if ((std.fmt.parseInt(u32, val, 10) catch 0) > 0) self.restore_snapshot = true;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_ENV")) |val| {
            defer allocator.free(val);
            self.weave_env = WeaveEnv.fromString(val);
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_SIGNATURE_MODE")) |val| {
            signature_mode_set = true;
            allocator.free(self.signature_mode);
            self.signature_mode = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_APPROVAL_MODE")) |val| {
            approval_mode_set = true;
            allocator.free(self.approval_mode);
            self.approval_mode = val;
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_WASM_STACK_SIZE")) |val| {
            defer allocator.free(val);
            self.wasm_stack_size = try std.fmt.parseInt(u32, val, 10);
        } else |_| {}

        if (std.process.getEnvVarOwned(allocator, "WEAVE_WASM_HEAP_SIZE")) |val| {
            defer allocator.free(val);
            self.wasm_heap_size = try std.fmt.parseInt(u32, val, 10);
        } else |_| {}

        const builtin = @import("builtin");
        if (builtin.is_test) {
            // テスト実行時は、テストランナーのコマンドライン引数のパースをスキップし、デフォルト値と環境変数のみで構成する
            if (self.plugins.items.len == 0) {
                try self.plugins.append(allocator, try allocator.dupe(u8, "wasm-apps/chat_node.wasm"));
            }

            try self.applyProductionDefaults(allocator, signature_mode_set, approval_mode_set);
            return self;
        }

        const args = try std.process.argsAlloc(allocator);
        defer std.process.argsFree(allocator, args);

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--ws-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.ws_gateway_port = try std.fmt.parseInt(u16, args[i], 10);
                std.debug.print("Warning: --ws-port is deprecated (the gateway is now served at /ws on the dashboard port)\n", .{});
            } else if (std.mem.eql(u8, arg, "--bind")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.bind);
                self.bind = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--dashboard-token")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.dashboard_token) |t| allocator.free(t);
                self.dashboard_token = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--observer-token")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.observer_token) |t| allocator.free(t);
                self.observer_token = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--expect")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                try self.expect.append(allocator, try allocator.dupe(u8, args[i]));
            } else if (std.mem.eql(u8, arg, "--introspection")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.introspection);
                self.introspection = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--dashboard-dist")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.dashboard_dist);
                self.dashboard_dist = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--streamelements-channel")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.streamelements_channel) |c| allocator.free(c);
                self.streamelements_channel = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--streamelements-url")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.streamelements_url) |u| allocator.free(u);
                self.streamelements_url = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--streamlabs")) {
                self.streamlabs = true;
            } else if (std.mem.eql(u8, arg, "--streamlabs-url")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.streamlabs_url) |u| allocator.free(u);
                self.streamlabs_url = try allocator.dupe(u8, args[i]);
                self.streamlabs = true;
            } else if (std.mem.eql(u8, arg, "--isolate-egress")) {
                self.isolate_egress = true;
            } else if (std.mem.eql(u8, arg, "--isolate-plugins")) {
                self.isolate_plugins = true;
            } else if (std.mem.eql(u8, arg, "--isolate-plugin")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                try self.isolate_plugin_names.append(allocator, try allocator.dupe(u8, args[i]));
            } else if (std.mem.eql(u8, arg, "--replay")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.replay_path) |p| allocator.free(p);
                self.replay_path = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--mock-twitch-once")) {
                self.mock_twitch_once = true;
            } else if (std.mem.eql(u8, arg, "--state-dir")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.state_dir);
                self.state_dir = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--no-snapshot")) {
                self.snapshot = false;
            } else if (std.mem.eql(u8, arg, "--restore-snapshot")) {
                self.restore_snapshot = true;
            } else if (std.mem.eql(u8, arg, "--supervise")) {
                // main で処理済み (Supervisor が子プロセスには渡さない)
            } else if (std.mem.eql(u8, arg, "--node-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.node_ws_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--dash-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.dashboard_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--twitch")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.twitch_channel);
                self.twitch_channel = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--mock-twitch")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                if (self.mock_twitch_scenario) |s| allocator.free(s);
                self.mock_twitch_scenario = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--no-twitch")) {
                self.no_twitch = true;
            } else if (std.mem.eql(u8, arg, "--obs-host")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.obs_host);
                self.obs_host = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--obs-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--obs-pass")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.obs_password);
                self.obs_password = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--mock-obs-file")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.mock_obs_filepath);
                self.mock_obs_filepath = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--mock-obs")) {
                self.mock_obs = true;
            } else if (std.mem.eql(u8, arg, "--real-obs")) {
                self.mock_obs = false;
            } else if (std.mem.eql(u8, arg, "--log-level")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.log_level = LogLevel.fromString(args[i]);
            } else if (std.mem.eql(u8, arg, "--graph-interval")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.graph_full_interval_secs = try std.fmt.parseInt(u32, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--signature-mode")) {
                signature_mode_set = true;
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.signature_mode);
                self.signature_mode = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--trust-keys")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.trust_keys_path);
                self.trust_keys_path = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--approval-mode")) {
                approval_mode_set = true;
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.approval_mode);
                self.approval_mode = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--approvals")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.approvals_path);
                self.approvals_path = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--cell-budget")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                const eq = std.mem.indexOfScalar(u8, args[i], '=') orelse return error.InvalidCellBudget;
                const eps = std.fmt.parseFloat(f64, args[i][eq + 1 ..]) catch return error.InvalidCellBudget;
                try self.cell_budgets.append(allocator, .{ .name = try allocator.dupe(u8, args[i][0..eq]), .eps = eps });
            } else if (std.mem.eql(u8, arg, "--audit-log")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                allocator.free(self.audit_log_path);
                self.audit_log_path = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--help")) {
                printHelp();
                std.process.exit(0);
            } else if (std.mem.startsWith(u8, arg, "-")) {
                std.debug.print("Warning: Unknown option '{s}'\n", .{arg});
            } else {
                // 位置引数はプラグインパスとみなす
                try self.plugins.append(allocator, try allocator.dupe(u8, arg));
            }
        }

        // デフォルトのプラグイン（引数も設定ファイルもない場合）
        if (self.plugins.items.len == 0) {
            try self.plugins.append(allocator, try allocator.dupe(u8, "wasm-apps/chat_node.wasm"));
        }

        try self.applyProductionDefaults(allocator, signature_mode_set, approval_mode_set);
        return self;
    }

    /// production では安全側の既定値を強制する (P1-9)。
    /// - ノード接続トークン必須
    /// - 署名モード・承認モードを明示していなければ strict
    fn applyProductionDefaults(self: *Config, allocator: std.mem.Allocator, signature_mode_set: bool, approval_mode_set: bool) !void {
        if (self.weave_env != .production) return;
        const has_token = if (self.node_ws_token) |t| t.len > 0 else false;
        if (!has_token) {
            std.debug.print("Error: Production mode requires WEAVE_NODE_WS_TOKEN to be set.\n", .{});
            return error.TokenRequiredInProduction;
        }
        if (!signature_mode_set) {
            allocator.free(self.signature_mode);
            self.signature_mode = try allocator.dupe(u8, "strict");
        }
        if (!approval_mode_set) {
            allocator.free(self.approval_mode);
            self.approval_mode = try allocator.dupe(u8, "strict");
        }
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.twitch_channel);
        allocator.free(self.obs_host);
        allocator.free(self.obs_password);
        allocator.free(self.mock_obs_filepath);
        allocator.free(self.signature_mode);
        allocator.free(self.trust_keys_path);
        allocator.free(self.approval_mode);
        allocator.free(self.approvals_path);
        allocator.free(self.audit_log_path);
        for (self.cell_budgets.items) |cb| allocator.free(cb.name);
        if (self.replay_path) |p| allocator.free(p);
        self.cell_budgets.deinit(allocator);
        allocator.free(self.bind);
        allocator.free(self.introspection);
        allocator.free(self.dashboard_dist);
        allocator.free(self.state_dir);
        if (self.dashboard_token) |t| allocator.free(t);
        if (self.observer_token) |t| allocator.free(t);
        for (self.expect.items) |e| allocator.free(e);
        self.expect.deinit(allocator);
        for (self.isolate_plugin_names.items) |n| allocator.free(n);
        self.isolate_plugin_names.deinit(allocator);
        if (self.streamelements_channel) |c| allocator.free(c);
        if (self.streamelements_url) |u| allocator.free(u);
        if (self.streamelements_jwt) |t| {
            std.crypto.secureZero(u8, @constCast(t));
            allocator.free(t);
        }
        if (self.streamlabs_url) |u| allocator.free(u);
        if (self.streamlabs_token) |t| {
            std.crypto.secureZero(u8, @constCast(t));
            allocator.free(t);
        }
        if (self.mock_twitch_scenario) |s| allocator.free(s);
        if (self.node_ws_token) |t| allocator.free(t);
        for (self.plugins.items) |p| {
            allocator.free(p);
        }
        self.plugins.deinit(allocator);
    }
};

fn printHelp() void {
    std.debug.print(
        \\Usage: WEAVE [options] [plugin.wasm ...]
        \\Options:
        \\  --ws-port <port>     (deprecated) the gateway is served at /ws on the dashboard port
        \\  --node-port <port>   Port for Node WebSocket Transport (default: 8081)
        \\  --dash-port <port>   Port for Dashboard HTTP Server (default: 3030)
        \\  --twitch <channel>   Twitch channel to join (default: SqLA)
        \\  --mock-twitch <path> Path to mock Twitch jsonl scenario (replaces real Twitch IRC)
        \\  --no-twitch          Disable Twitch entirely (button-only demo mode)
        \\  --obs-host <host>    OBS WebSocket host (default: 127.0.0.1)
        \\  --obs-port <port>    OBS WebSocket port (default: 4455)
        \\  --obs-pass <pass>    OBS WebSocket password (default: obs-password)
        \\  --mock-obs-file <path> Path to mock OBS jsonl output (default: mock_obs_received.jsonl)
        \\  --mock-obs            Use mock OBS node instead of real WebSocket client
        \\  --real-obs            Use real OBS WebSocket client (default)
        \\  --graph-interval <s> Full topology publish interval in seconds (default: 60)
        \\  --signature-mode <m> Plugin signature enforcement: off|warn|strict (default: off)
        \\  --trust-keys <path>  Trusted public keys file (default: .weave/trusted_keys)
        \\  --approval-mode <m>  User approval of plugin permissions (weave add): off|warn|strict (default: off)
        \\  --approvals <path>   Approval record (default: .weave/approved.json)
        \\  --audit-log <path>   Security audit log (JSON Lines, default: audit.log)
        \\  --cell-budget <cell>=<eps>  Shared publish budget for a plugin cell (e.g. plugins.bots=50).
        \\                       Plugins join such a cell with "cell" in their manifest
        \\  --bind <addr>        Listen address for dashboard / node servers (default: 127.0.0.1)
        \\  --dashboard-token <t> Token for the Inspector WebSocket (default: generated)
        \\  --observer-token <t> Token for the read-only status page /status (default: generated).
        \\                       Devices using it only receive core.health.* and cannot publish
        \\  --expect <manifest>  A node that should be running (repeatable). If it is not, the nodes that
        \\                       depend on it are reported in core.health.summary (e.g. a forgotten tool)
        \\  --streamelements-channel <id>  StreamElements channel id (JWT via env STREAMELEMENTS_JWT)
        \\  --streamelements-url <url>     Astro endpoint (default: wss://astro.streamelements.com/)
        \\  --streamlabs                   Connect to the Streamlabs Socket API (token via env STREAMLABS_SOCKET_TOKEN)
        \\  --streamlabs-url <url>         Socket API endpoint (implies --streamlabs)
        \\  --introspection <l> off|metadata|contents (default: metadata)
        \\  --mock-twitch-once   Play the mock Twitch scenario once (no loop)
        \\  --isolate-egress     Run the OBS egress cell as a separate process (weave-cell). If it crashes
        \\                       it is restarted and the intended OBS state is re-sent; Core keeps running
        \\  --isolate-plugin <name>  Run only this plugin (file name without .wasm) in its own process (repeatable)
        \\  --isolate-plugins    Run each Wasm plugin in its own process (weave-cell plugin). Its host calls
        \\                       are still checked by Core; if the process dies it is restarted
        \\  --replay <file>      Replay the external inputs and ticks recorded by `weave record` with the
        \\                       original timing, so plugins make the same decisions. Replaces Twitch as the input
        \\  --dashboard-dist <d> Directory of the built dashboard (default: dashboard/dist)
        \\  --state-dir <dir>    Where snapshots are kept (default: .weave/state)
        \\  --no-snapshot        Do not save state snapshots
        \\  --restore-snapshot   Restore the last snapshot at startup (automatic after a supervised crash restart)
        \\  --supervise          Run the core under a supervisor that restarts it on crash
        \\  --help               Show this help
        \\
    , .{});
}

extern fn setenv(name: [*c]const u8, value: [*c]const u8, overwrite: i32) i32;
extern fn unsetenv(name: [*c]const u8) i32;

fn setEnv(name: []const u8, value: []const u8) !void {
    var name_buf: [128]u8 = undefined;
    var val_buf: [128]u8 = undefined;
    if (name.len >= 127 or value.len >= 127) return error.NameOrValueTooLong;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    @memcpy(val_buf[0..value.len], value);
    val_buf[value.len] = 0;
    _ = setenv(&name_buf, &val_buf, 1);
}

fn deleteEnv(name: []const u8) void {
    var name_buf: [128]u8 = undefined;
    if (name.len >= 127) return;
    @memcpy(name_buf[0..name.len], name);
    name_buf[name.len] = 0;
    _ = unsetenv(&name_buf);
}

test "Config: WeaveEnv and Token validation" {
    const allocator = std.testing.allocator;

    // 1. 環境変数がない場合のデフォルトパースの検証
    var conf = try Config.parse(allocator);
    defer conf.deinit(allocator);

    try std.testing.expectEqual(WeaveEnv.development, conf.weave_env);
    try std.testing.expect(conf.node_ws_token == null);
}

test "Config: Production mode requirements" {
    const allocator = std.testing.allocator;

    // 一時的に環境変数をセット
    try setEnv("WEAVE_ENV", "production");
    defer deleteEnv("WEAVE_ENV");

    // 1. トークン未設定状態で parse -> error.TokenRequiredInProduction が返るはず
    try std.testing.expectError(error.TokenRequiredInProduction, Config.parse(allocator));

    // 2. トークンをセットした状態にする
    try setEnv("WEAVE_NODE_WS_TOKEN", "prod-secret-token");
    defer deleteEnv("WEAVE_NODE_WS_TOKEN");

    // トークンがセットされているので、正常にパースできるはず
    var conf = try Config.parse(allocator);
    defer conf.deinit(allocator);

    try std.testing.expectEqual(WeaveEnv.production, conf.weave_env);
    try std.testing.expectEqualStrings("prod-secret-token", conf.node_ws_token.?);
    // production では署名モードを明示しなければ strict (P1-9)
    try std.testing.expectEqualStrings("strict", conf.signature_mode);
    // 承認も同じ: 明示しなければ strict (承認していない・権限が増えたプラグインは動かさない)
    try std.testing.expectEqualStrings("strict", conf.approval_mode);
}

test "Config: Wasm stack and heap sizes overrides" {
    const allocator = std.testing.allocator;

    // 一時的に環境変数をセット
    try setEnv("WEAVE_WASM_STACK_SIZE", "65536");
    defer deleteEnv("WEAVE_WASM_STACK_SIZE");

    try setEnv("WEAVE_WASM_HEAP_SIZE", "32768");
    defer deleteEnv("WEAVE_WASM_HEAP_SIZE");

    var conf = try Config.parse(allocator);
    defer conf.deinit(allocator);

    try std.testing.expectEqual(@as(u32, 65536), conf.wasm_stack_size);
    try std.testing.expectEqual(@as(u32, 32768), conf.wasm_heap_size);
}

test "Config: snapshot is restored only after a supervised crash restart" {
    const allocator = std.testing.allocator;
    {
        var conf = try Config.parse(allocator);
        defer conf.deinit(allocator);
        try std.testing.expect(!conf.restore_snapshot); // 普通の起動では古い状態を戻さない
    }
    try setEnv("WEAVE_RESTART_COUNT", "0");
    {
        var conf = try Config.parse(allocator);
        defer conf.deinit(allocator);
        try std.testing.expect(!conf.restore_snapshot); // Supervisor 配下の初回起動も戻さない
    }
    try setEnv("WEAVE_RESTART_COUNT", "1");
    defer deleteEnv("WEAVE_RESTART_COUNT");
    var conf = try Config.parse(allocator);
    defer conf.deinit(allocator);
    try std.testing.expect(conf.restore_snapshot); // クラッシュからの再起動では戻す
}
