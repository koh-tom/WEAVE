const std = @import("std");
const TcpClient = @import("../net/tcp_client.zig").TcpClient;
const EventBus = @import("../event_bus.zig").EventBus;

pub const TwitchAdapter = struct {
    allocator: std.mem.Allocator,
    bus: *EventBus,
    client: TcpClient,
    node_id: u32,
    channel: []const u8,
    running: bool = false,

    const TWITCH_HOST = "irc.chat.twitch.tv";
    const TWITCH_PORT = 6667;

    pub fn init(allocator: std.mem.Allocator, bus: *EventBus, node_id: u32, channel: []const u8) TwitchAdapter {
        return .{
            .allocator = allocator,
            .bus = bus,
            .client = TcpClient.init(allocator),
            .node_id = node_id,
            .channel = channel,
        };
    }

    pub fn deinit(self: *TwitchAdapter) void {
        self.client.deinit();
    }

    /// Twitchへの接続とメインループの開始
    pub fn run(self: *TwitchAdapter) !void {
        std.debug.print("TwitchAdapter: Connecting to {s}:{}...\n", .{ TWITCH_HOST, TWITCH_PORT });
        try self.client.connect(TWITCH_HOST, TWITCH_PORT);
        std.debug.print("TwitchAdapter: Connected. Logging in anonymously...\n", .{});

        // 匿名ログイン (PASSは不要)
        try self.client.send("NICK justinfan12345\r\n");
        // チャンネルにJOIN
        var join_buf: [256]u8 = undefined;
        const join_cmd = try std.fmt.bufPrint(&join_buf, "JOIN #{s}\r\n", .{self.channel});
        try self.client.send(join_cmd);

        self.running = true;
        while (self.running) {
            const line = try self.client.readLine(self.allocator) orelse {
                std.debug.print("TwitchAdapter: Connection closed by server.\n", .{});
                break;
            };
            defer self.allocator.free(line);

            // ログ出力（デバッグ用）
            // std.debug.print("Twitch IRC: {s}\n", .{line});

            try self.handleIrcLine(line);
        }
    }

    fn handleIrcLine(self: *TwitchAdapter, line: []const u8) !void {
        // PING への応答
        if (std.mem.startsWith(u8, line, "PING")) {
            var response_buf: [256]u8 = undefined;
            const response = try std.fmt.bufPrint(&response_buf, "PONG {s}\r\n", .{line[5..]});
            try self.client.send(response);
            return;
        }

        // PRIVMSG (チャット) の簡易パース
        // 例: :user!user@user.tmi.twitch.tv PRIVMSG #channel :message
        if (std.mem.indexOf(u8, line, " PRIVMSG ")) |idx| {
            const user_end = std.mem.indexOf(u8, line, "!") orelse return;
            const user = line[1..user_end];
            
            const msg_start_idx = std.mem.indexOfPos(u8, line, idx + 9, " :") orelse return;
            const message = line[msg_start_idx + 2 ..];

            // JSONを構築してEventBusにPublish
            // {"user": "...", "msg": "..."}
            var json_buf: [1024]u8 = undefined;
            const json_payload = try std.fmt.bufPrint(&json_buf, "{{\"user\": \"{s}\", \"msg\": \"{s}\"}}", .{ user, message });
            
            try self.bus.publish("ext.twitch.chat.message", json_payload, .BestEffort, self.node_id);
        }
    }
};
