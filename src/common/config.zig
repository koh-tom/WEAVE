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
    graph_full_interval_secs: u32 = 60,
    node_ws_token: ?[]const u8 = null,
    weave_env: WeaveEnv = .development,
    wasm_stack_size: u32 = 128 * 1024,
    wasm_heap_size: u32 = 64 * 1024,

    pub fn parse(allocator: std.mem.Allocator) !Config {
        var self = Config{
            .plugins = .{},
            .node_ws_token = null,
            .weave_env = .development,
            .wasm_stack_size = 128 * 1024,
            .wasm_heap_size = 64 * 1024,
        };

        errdefer self.deinit(allocator);

        // デフォルト文字列を dupe して動的アロケーションに統一 (リテラルとの混在・リーク防止)
        self.twitch_channel = try allocator.dupe(u8, self.twitch_channel);
        self.obs_host = try allocator.dupe(u8, self.obs_host);
        self.obs_password = try allocator.dupe(u8, self.obs_password);

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
                if (obj.get("obs_host")) |v| {
                    allocator.free(self.obs_host);
                    self.obs_host = try allocator.dupe(u8, v.string);
                }
                if (obj.get("obs_port")) |v| self.obs_port = @intCast(v.integer);
                if (obj.get("obs_password")) |v| {
                    allocator.free(self.obs_password);
                    self.obs_password = try allocator.dupe(u8, v.string);
                }
                if (obj.get("log_level")) |v| self.log_level = LogLevel.fromString(v.string);
                if (obj.get("graph_full_interval_secs")) |v| self.graph_full_interval_secs = @intCast(v.integer);
                if (obj.get("node_ws_token")) |v| self.node_ws_token = try allocator.dupe(u8, v.string);
                if (obj.get("weave_env")) |v| self.weave_env = WeaveEnv.fromString(v.string);
                if (obj.get("wasm_stack_size")) |v| self.wasm_stack_size = @intCast(v.integer);
                if (obj.get("wasm_heap_size")) |v| self.wasm_heap_size = @intCast(v.integer);
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

        if (std.process.getEnvVarOwned(allocator, "WEAVE_ENV")) |val| {
            defer allocator.free(val);
            self.weave_env = WeaveEnv.fromString(val);
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

            // Production モードのバリデーションチェック
            if (self.weave_env == .production) {
                const has_token = if (self.node_ws_token) |t| t.len > 0 else false;
                if (!has_token) {
                    std.debug.print("Error: Production mode requires WEAVE_NODE_WS_TOKEN to be set.\n", .{});
                    return error.TokenRequiredInProduction;
                }
            }
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
            } else if (std.mem.eql(u8, arg, "--log-level")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.log_level = LogLevel.fromString(args[i]);
            } else if (std.mem.eql(u8, arg, "--graph-interval")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.graph_full_interval_secs = try std.fmt.parseInt(u32, args[i], 10);
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

        // Production モードのバリデーションチェック
        if (self.weave_env == .production) {
            const has_token = if (self.node_ws_token) |t| t.len > 0 else false;
            if (!has_token) {
                std.debug.print("Error: Production mode requires WEAVE_NODE_WS_TOKEN to be set.\n", .{});
                return error.TokenRequiredInProduction;
            }
        }

        return self;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        allocator.free(self.twitch_channel);
        allocator.free(self.obs_host);
        allocator.free(self.obs_password);
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
        \\  --ws-port <port>     Port for WebSocket Gateway (default: 8080)
        \\  --node-port <port>   Port for Node WebSocket Transport (default: 8081)
        \\  --dash-port <port>   Port for Dashboard HTTP Server (default: 3030)
        \\  --twitch <channel>   Twitch channel to join (default: SqLA)
        \\  --obs-host <host>    OBS WebSocket host (default: 127.0.0.1)
        \\  --obs-port <port>    OBS WebSocket port (default: 4455)
        \\  --obs-pass <pass>    OBS WebSocket password (default: obs-password)
        \\  --graph-interval <s> Full topology publish interval in seconds (default: 60)
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
