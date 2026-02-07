const std = @import("std");
const transport_if = @import("../transport.zig");
const event_bus = @import("../event_bus.zig");

/// Dashboard/開発ツール向けのWebSocket Gatewayトランスポート。
/// 全てのバスイベントをJSON形式で接続中のクライアントにブロードキャストします。
pub const WsGateway = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    clients: std.ArrayListUnmanaged(std.net.Stream),
    mutex: std.Thread.Mutex,
    port: u16,
    running: bool,

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, port: u16) !*WsGateway {
        const self = try allocator.create(WsGateway);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .clients = .{},
            .mutex = .{},
            .port = port,
            .running = false,
        };
        return self;
    }

    pub fn deinit(self: *WsGateway) void {
        self.mutex.lock();
        self.running = false;
        for (self.clients.items) |client| {
            client.close();
        }
        self.clients.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    /// 接続待ち受けループ（別スレッドで実行することを想定）
    pub fn run(self: *WsGateway) !void {
        const address = try std.net.Address.parseIp("0.0.0.0", self.port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        self.running = true;
        std.debug.print("WsGateway: Listening on ws://0.0.0.0:{}\n", .{self.port});

        while (self.running) {
            const conn = server.accept() catch |err| {
                if (!self.running) break;
                std.debug.print("WsGateway: Accept error: {any}\n", .{err});
                continue;
            };

            // ハンドシェイクの実行
            self.handleHandshake(conn.stream) catch |err| {
                std.debug.print("WsGateway: Handshake failed for {any}: {any}\n", .{ conn.address, err });
                conn.stream.close();
                continue;
            };

            std.debug.print("WsGateway: New dashboard connected from {any}\n", .{conn.address});

            self.mutex.lock();
            try self.clients.append(self.allocator, conn.stream);
            self.mutex.unlock();
        }
    }

    fn handleHandshake(self: *WsGateway, stream: std.net.Stream) !void {
        _ = self;
        var buf: [2048]u8 = undefined;
        const n = try stream.read(&buf);
        const request = buf[0..n];

        // Sec-WebSocket-Key ヘッダーの抽出
        const key_header = "Sec-WebSocket-Key: ";
        const key_idx = std.mem.indexOf(u8, request, key_header) orelse return error.NoWebSocketKey;
        const key_start = key_idx + key_header.len;
        const key_end = std.mem.indexOfPos(u8, request, key_start, "\r\n") orelse return error.InvalidRequest;
        const key = request[key_start..key_end];

        // WebSocket Accept Key の計算 (RFC 6455)
        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var combined: [128]u8 = undefined;
        const combined_str = try std.fmt.bufPrint(&combined, "{s}{s}", .{ key, magic });
        
        var sha1_buf: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(combined_str, &sha1_buf, .{});
        
        var accept_buf: [32]u8 = undefined;
        const accept_key = std.base64.standard.Encoder.encode(&accept_buf, &sha1_buf);

        // レスポンスの送信
        var response_buf: [1024]u8 = undefined;
        const response = try std.fmt.bufPrint(&response_buf,
            "HTTP/1.1 101 Switching Protocols\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Accept: {s}\r\n\r\n",
            .{accept_key}
        );
        try stream.writeAll(response);
    }

    pub fn transport(self: *WsGateway) transport_if.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .name = name,
                .deinit = deinitTransport,
            },
        };
    }

    /// EventBusからのメッセージを受信し、全てのWSクライアントにブロードキャストする
    fn send(ctx: *anyopaque, topic: []const u8, payload: []const u8, qos: event_bus.QoS) anyerror!void {
        const self: *WsGateway = @ptrCast(@alignCast(ctx));
        
        const level = self.bus.introspection_level;
        if (level == .off) return;

        // JSONメッセージの構築
        var json_buf: [4096]u8 = undefined;
        const json = switch (level) {
            .off => return,
            .metadata => std.fmt.bufPrint(&json_buf, 
                "{{\"topic\":\"{s}\",\"payload\":{{\"size\":{}}},\"qos\":{}}}",
                .{ topic, payload.len, @intFromEnum(qos) }
            ),
            .contents => std.fmt.bufPrint(&json_buf, 
                "{{\"topic\":\"{s}\",\"payload\":{s},\"qos\":{}}}",
                .{ topic, payload, @intFromEnum(qos) }
            ),
        } catch |err| {
            // ペイロードが大きすぎる場合はエラーを返さずスキップ（ゲートウェイの安全のため）
            std.debug.print("WsGateway: Payload too large for gateway buffer: {any}\n", .{err});
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 0;
        while (i < self.clients.items.len) {
            const client = self.clients.items[i];
            self.sendWsFrame(client, json) catch {
                // 送信失敗（切断）したクライアントをリストから削除
                std.debug.print("WsGateway: Dashboard disconnected.\n", .{});
                client.close();
                _ = self.clients.swapRemove(i);
                continue;
            };
            i += 1;
        }
    }

    /// WebSocketテキストフレームの送信
    fn sendWsFrame(self: *WsGateway, stream: std.net.Stream, data: []const u8) !void {
        _ = self;
        var header: [10]u8 = undefined;
        header[0] = 0x81; // FIN + Text Opcode
        
        var header_len: usize = 2;
        if (data.len <= 125) {
            header[1] = @as(u8, @intCast(data.len));
        } else if (data.len <= 65535) {
            header[1] = 126;
            std.mem.writeInt(u16, header[2..4], @as(u16, @intCast(data.len)), .big);
            header_len = 4;
        } else {
            header[1] = 127;
            std.mem.writeInt(u64, header[2..10], data.len, .big);
            header_len = 10;
        }

        try stream.writeAll(header[0..header_len]);
        try stream.writeAll(data);
    }

    fn name(ctx: *anyopaque) []const u8 {
        _ = ctx;
        return "WsGateway";
    }

    fn deinitTransport(ctx: *anyopaque) void {
        _ = ctx;
        // WsGateway自体はCoreが管理するため、ここでは何もしない
    }
};
