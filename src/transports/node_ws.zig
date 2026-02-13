const std = @import("std");
const transport_if = @import("../transport.zig");
const event_bus = @import("../event_bus.zig");

/// 別プロセスのNodeをWebSocket経由で接続するためのトランスポート。
/// Core ⇔ Node 間の双方向イベントブリッジとして機能します。
pub const NodeWsTransport = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    clients: std.ArrayListUnmanaged(*Client),
    mutex: std.Thread.Mutex,
    port: u16,
    running: bool,

    const Client = struct {
        node_id: u32,
        stream: std.net.Stream,
        subscriptions: std.StringHashMapUnmanaged(void),
        allocator: std.mem.Allocator,
        mutex: std.Thread.Mutex,
        registered: bool,

        fn init(allocator: std.mem.Allocator, stream: std.net.Stream, node_id: u32) *Client {
            const self = allocator.create(Client) catch unreachable;
            self.* = .{
                .node_id = node_id,
                .stream = stream,
                .subscriptions = .{},
                .allocator = allocator,
                .mutex = .{},
                .registered = false,
            };
            return self;
        }

        fn deinit(self: *Client) void {
            self.stream.close();
            var it = self.subscriptions.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
            }
            self.subscriptions.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        fn isSubscribed(self: *Client, topic: []const u8) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            
            var it = self.subscriptions.keyIterator();
            while (it.next()) |sub| {
                if (event_bus.EventBus.isMatch(sub.*, topic)) return true;
            }
            return false;
        }

        fn addSubscription(self: *Client, topic: []const u8) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.subscriptions.contains(topic)) return;
            const copy = try self.allocator.dupe(u8, topic);
            try self.subscriptions.put(self.allocator, copy, {});
        }

        fn ensureRegistered(self: *Client, bus: *event_bus.EventBus) !void {
            if (self.registered) return;
            if (bus.graph) |g| {
                var name_buf: [32]u8 = undefined;
                const node_name = std.fmt.bufPrint(&name_buf, "RemoteNode_{}", .{self.node_id}) catch "RemoteNode";
                try g.registerNode(self.node_id, node_name, .remote);
                var buf: [128]u8 = undefined;
                const payload = try std.fmt.bufPrint(&buf, "{{\"node_id\":{},\"name\":\"{s}\",\"type\":\"remote\"}}", .{ self.node_id, node_name });
                try bus.publish("core.node.registered", payload, .Transient, 0);
            }
            self.registered = true;
        }
    };

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, port: u16) !*NodeWsTransport {
        const self = try allocator.create(NodeWsTransport);
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

    pub fn deinit(self: *NodeWsTransport) void {
        self.mutex.lock();
        self.running = false;
        for (self.clients.items) |client| {
            client.deinit();
        }
        self.clients.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    pub fn run(self: *NodeWsTransport) !void {
        const address = try std.net.Address.parseIp("0.0.0.0", self.port);
        var server = try address.listen(.{ .reuse_address = true });
        defer server.deinit();

        self.running = true;
        std.debug.print("NodeWsTransport: Listening on ws://0.0.0.0:{}\n", .{self.port});

        var node_id_counter: u32 = 200;
        while (self.running) {
            const conn = server.accept() catch |err| {
                if (!self.running) break;
                std.debug.print("NodeWsTransport: Accept error: {any}\n", .{err});
                continue;
            };

            const node_id = node_id_counter;
            node_id_counter += 1;

            const client = Client.init(self.allocator, conn.stream, node_id);
            
            // ハンドシェイク
            self.handleHandshake(client.stream) catch |err| {
                std.debug.print("NodeWsTransport: Handshake failed: {any}\n", .{err});
                client.deinit();
                continue;
            };

            {
                self.mutex.lock();
                defer self.mutex.unlock();
                try self.clients.append(self.allocator, client);
            }

            // Graphに登録
            if (self.bus.graph) |g| {
                var name_buf: [32]u8 = undefined;
                const node_name = std.fmt.bufPrint(&name_buf, "RemoteNode_{}", .{node_id}) catch "RemoteNode";
                try g.registerNode(node_id, node_name, .remote);
            }

            _ = try std.Thread.spawn(.{}, clientLoop, .{ self, client });
        }
    }

    fn handleHandshake(self: *NodeWsTransport, stream: std.net.Stream) !void {
        _ = self;
        var buf: [2048]u8 = undefined;
        const n = try stream.read(&buf);
        if (n == 0) return error.EmptyRequest;
        const request = buf[0..n];

        const key_header = "Sec-WebSocket-Key: ";
        const key_idx = std.mem.indexOf(u8, request, key_header) orelse return error.NoWebSocketKey;
        const key_start = key_idx + key_header.len;
        const key_end = std.mem.indexOfPos(u8, request, key_start, "\r\n") orelse return error.InvalidRequest;
        const key = request[key_start..key_end];

        const magic = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
        var combined: [128]u8 = undefined;
        const combined_str = try std.fmt.bufPrint(&combined, "{s}{s}", .{ key, magic });
        
        var sha1_buf: [20]u8 = undefined;
        std.crypto.hash.Sha1.hash(combined_str, &sha1_buf, .{});
        
        var accept_buf: [32]u8 = undefined;
        const accept_key = std.base64.standard.Encoder.encode(&accept_buf, &sha1_buf);

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

    fn clientLoop(self: *NodeWsTransport, client: *Client) void {
        std.debug.print("NodeWsTransport: Client thread started (ID: {})\n", .{client.node_id});
        defer {
            std.debug.print("NodeWsTransport: Client thread exiting (ID: {})\n", .{client.node_id});
            if (self.bus.graph) |g| {
                g.updateNodeStatus(client.node_id, .disconnected);
                // ライフサイクルイベントのブロードキャスト
                var buf: [128]u8 = undefined;
                const payload = std.fmt.bufPrint(&buf, "{{\"node_id\":{},\"status\":\"disconnected\"}}", .{client.node_id}) catch "";
                _ = self.bus.publish("core.node.status_changed", payload, .Transient, 0) catch {};
            }
            self.removeClient(client);
            client.deinit();
        }

        while (self.running) {
            const frame = self.readFrame(client.stream, self.allocator) catch |err| {
                if (err != error.EndOfStream) {
                    std.debug.print("NodeWsTransport: Read error: {any}\n", .{err});
                }
                break;
            };
            defer self.allocator.free(frame.payload);

            switch (frame.opcode) {
                .text => self.handleTextMessage(client, frame.payload) catch |err| {
                    std.debug.print("NodeWsTransport: Message handle error: {any}\n", .{err});
                },
                .close => break,
                .ping => self.sendControlFrame(client.stream, .pong, frame.payload) catch break,
                else => {},
            }
        }
    }

    fn handleTextMessage(self: *NodeWsTransport, client: *Client, json_text: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{});
        defer parsed.deinit();

        const root = parsed.value.object;
        const msg_type = root.get("type") orelse return;
        const type_str = msg_type.string;

        if (std.mem.eql(u8, type_str, "subscribe")) {
            if (root.get("topic")) |topic| {
                try client.addSubscription(topic.string);
                std.debug.print("NodeWsTransport: Client {} subscribed to '{s}'\n", .{ client.node_id, topic.string });
                
                try client.ensureRegistered(self.bus);
                if (self.bus.graph) |g| {
                    try g.updateSubscription(client.node_id, topic.string);
                }
            }
        } else if (std.mem.eql(u8, type_str, "publish")) {
            const topic = root.get("topic") orelse return;
            const payload = root.get("payload") orelse return;
            
            try client.ensureRegistered(self.bus);
            
            // ペイロードがオブジェクトや配列なら文字列化して転送
            var payload_str: []const u8 = undefined;
            if (payload == .string) {
                payload_str = payload.string;
            } else {
                var out_buf = std.ArrayListUnmanaged(u8){};
                defer out_buf.deinit(self.allocator);
                try out_buf.writer(self.allocator).print("{f}", .{std.json.fmt(payload, .{})});
                payload_str = try self.allocator.dupe(u8, out_buf.items);
            }
            defer if (payload != .string) self.allocator.free(payload_str);

            // グラフの更新
            if (self.bus.graph) |g| {
                try g.recordPublish(client.node_id, topic.string);
            }

            // 外部ノードからの発行として指定
            try self.bus.publish(topic.string, payload_str, .Transient, client.node_id);
        }
    }

    fn removeClient(self: *NodeWsTransport, client: *Client) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.clients.items, 0..) |c, i| {
            if (c == client) {
                _ = self.clients.swapRemove(i);
                break;
            }
        }
    }

    const Opcode = enum(u4) {
        continuation = 0x0,
        text = 0x1,
        binary = 0x2,
        close = 0x8,
        ping = 0x9,
        pong = 0xA,
        _,
    };

    const Frame = struct {
        opcode: Opcode,
        payload: []u8,
    };

    fn readNoEof(stream: std.net.Stream, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try stream.read(buf[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    fn readFrame(self: *NodeWsTransport, stream: std.net.Stream, allocator: std.mem.Allocator) !Frame {
        _ = self;
        var head: [2]u8 = undefined;
        try readNoEof(stream, &head);

        const opcode: Opcode = @enumFromInt(head[0] & 0x0F);
        const masked = (head[1] & 0x80) != 0;
        var len: u64 = head[1] & 0x7F;

        if (len == 126) {
            var ext: [2]u8 = undefined;
            try readNoEof(stream, &ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try readNoEof(stream, &ext);
            len = std.mem.readInt(u64, &ext, .big);
        }

        var mask: [4]u8 = undefined;
        if (masked) {
            try readNoEof(stream, &mask);
        }

        const payload = try allocator.alloc(u8, @intCast(len));
        errdefer allocator.free(payload);
        try readNoEof(stream, payload);

        if (masked) {
            for (payload, 0..) |*b, i| {
                b.* ^= mask[i % 4];
            }
        }

        return Frame{ .opcode = opcode, .payload = payload };
    }

    fn sendControlFrame(self: *NodeWsTransport, stream: std.net.Stream, opcode: Opcode, payload: []const u8) !void {
        _ = self;
        var head: [2]u8 = undefined;
        head[0] = 0x80 | @as(u8, @intFromEnum(opcode));
        head[1] = @as(u8, @intCast(payload.len)); // Control frames are small
        try stream.writeAll(&head);
        try stream.writeAll(payload);
    }

    pub fn transport(self: *NodeWsTransport) transport_if.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .name = name,
                .deinit = deinitTransport,
            },
        };
    }

    fn send(ctx: *anyopaque, topic: []const u8, payload: []const u8, qos: event_bus.QoS) anyerror!void {
        const self: *NodeWsTransport = @ptrCast(@alignCast(ctx));
        
        var json_buf = std.ArrayListUnmanaged(u8){};
        defer json_buf.deinit(self.allocator);
        
        // 外部ノードへの通知用JSON
        try json_buf.writer(self.allocator).print("{f}", .{std.json.fmt(.{
            .type = "event",
            .topic = topic,
            .payload = payload, // 既にJSONであることを想定
            .qos = @intFromEnum(qos),
        }, .{})});

        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.clients.items) |client| {
            if (client.isSubscribed(topic)) {
                self.sendWsFrame(client.stream, json_buf.items) catch continue;
            }
        }
    }

    fn sendWsFrame(self: *NodeWsTransport, stream: std.net.Stream, data: []const u8) !void {
        _ = self;
        var header: [10]u8 = undefined;
        header[0] = 0x81; 
        
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
        return "NodeWsTransport";
    }

    fn deinitTransport(ctx: *anyopaque) void {
        _ = ctx;
    }
};
