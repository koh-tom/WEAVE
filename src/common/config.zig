const std = @import("std");
const LogLevel = @import("types.zig").LogLevel;

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

    pub fn parse(allocator: std.mem.Allocator) !Config {
        var self = Config{
            .plugins = .{},
        };

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
                if (obj.get("twitch_channel")) |v| self.twitch_channel = try allocator.dupe(u8, v.string);
                if (obj.get("obs_host")) |v| self.obs_host = try allocator.dupe(u8, v.string);
                if (obj.get("obs_port")) |v| self.obs_port = @intCast(v.integer);
                if (obj.get("obs_password")) |v| self.obs_password = try allocator.dupe(u8, v.string);
                if (obj.get("log_level")) |v| self.log_level = LogLevel.fromString(v.string);
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
                self.twitch_channel = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--obs-host")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_host = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--obs-port")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_port = try std.fmt.parseInt(u16, args[i], 10);
            } else if (std.mem.eql(u8, arg, "--obs-pass")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.obs_password = try allocator.dupe(u8, args[i]);
            } else if (std.mem.eql(u8, arg, "--log-level")) {
                i += 1;
                if (i >= args.len) return error.ArgumentMissing;
                self.log_level = LogLevel.fromString(args[i]);
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

        return self;
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
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
        \\  --help               Show this help
        \\
    , .{});
}
