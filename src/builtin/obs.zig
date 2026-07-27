const std = @import("std");
const event_bus = @import("../core/event_bus.zig");
const log = @import("../common/log.zig");

/// OBS WebSocket v5 制御用ノード
/// core.obs.request.* トピックを監視し、OBSを操作します。
pub const ObsEgressNode = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    stream: ?std.net.Stream,
    node_id: u32,
    password: ?[]const u8,
    running: bool,
    mutex: std.Thread.Mutex,
    thread: ?std.Thread,
    host: ?[]const u8,
    port: u16,

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, password: ?[]const u8) !*ObsEgressNode {
        const self = try allocator.create(ObsEgressNode);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .stream = null,
            .node_id = node_id,
            .password = if (password) |p| try allocator.dupe(u8, p) else null,
            .running = false,
            .mutex = .{},
            .thread = null,
            .host = null,
            .port = 0,
        };
        return self;
    }

    pub fn stop(self: *ObsEgressNode) void {
        self.running = false;
        if (self.stream) |s| s.close();
    }

    pub fn deinit(self: *ObsEgressNode) void {
        self.stop();
        if (self.thread) |t| t.join();
        if (self.password) |p| self.allocator.free(p);
        if (self.host) |h| self.allocator.free(h);
        self.allocator.destroy(self);
    }

    /// OBSへの接続と認証プロセスをバックグラウンドで開始する
    pub fn connect(self: *ObsEgressNode, host: []const u8, port: u16) !void {
        self.host = try self.allocator.dupe(u8, host);
        self.port = port;
        self.running = true;

        // 購読開始（接続前でも行っておく）
        try self.bus.subscribe("core.obs.request.*", self.node_id, ObsEgressNode.onMessage, self);

        // グラフ登録
        if (self.bus.graph) |g| {
            try g.registerNode(self.node_id, "ObsEgress", .native);
        }

        self.thread = try std.Thread.spawn(.{}, ObsEgressNode.runRetryLoop, .{self});
    }

    fn runRetryLoop(self: *ObsEgressNode) void {
        var retry_count: u32 = 0;
        while (self.running) {
            self.doConnectAndReceive(&retry_count) catch |err| {
                if (err != error.EndOfStream) {
                    log.err("ObsEgress: Connection failed: {any}", .{err});
                }
            };

            if (!self.running) break;

            const shift = @as(u6, @intCast(@min(10, retry_count)));
            const backoff: u64 = @min(30, @as(u64, 1) << shift);
            log.info("ObsEgress: Retrying in {d} seconds...", .{backoff});
            var slept_ns: u64 = 0;
            const target_ns = backoff * std.time.ns_per_s;
            while (slept_ns < target_ns and self.running) {
                std.Thread.sleep(100 * std.time.ns_per_ms);
                slept_ns += 100 * std.time.ns_per_ms;
            }
            retry_count += 1;
        }
    }

    fn doConnectAndReceive(self: *ObsEgressNode, retry_count: *u32) !void {
        const host = self.host orelse return;
        const address = try std.net.Address.parseIp(host, self.port);

        const stream = try std.net.tcpConnectToAddress(address);

        self.mutex.lock();
        if (self.stream) |s| s.close();
        self.stream = stream;
        self.mutex.unlock();

        log.info("ObsEgress: Connected to OBS. Starting handshake...", .{});
        try self.clientHandshake(host, self.port);
        log.info("ObsEgress: WebSocket handshake completed.", .{});

        // 接続とハンドシェイクが成功したらリトライ回数をリセット
        retry_count.* = 0;

        try self.receiverLoop();
    }

    fn clientHandshake(self: *ObsEgressNode, host: []const u8, port: u16) !void {
        var buf: [1024]u8 = undefined;
        const request = try std.fmt.bufPrint(&buf, "GET / HTTP/1.1\r\n" ++
            "Host: {s}:{}\r\n" ++
            "Upgrade: websocket\r\n" ++
            "Connection: Upgrade\r\n" ++
            "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" ++
            "Sec-WebSocket-Version: 13\r\n\r\n", .{ host, port });
        try self.stream.?.writeAll(request);

        var resp_buf: [1024]u8 = undefined;
        const n = try self.stream.?.read(&resp_buf);
        if (n == 0) return error.HandshakeFailed;
        if (std.mem.indexOf(u8, resp_buf[0..n], "101 Switching Protocols") == null) {
            return error.HandshakeRejected;
        }
    }

    fn receiverLoop(self: *ObsEgressNode) !void {
        while (self.running) {
            const frame = try self.readFrame();
            defer self.allocator.free(frame.payload);

            if (frame.opcode == 0x8) break; // Close

            const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, frame.payload, .{}) catch continue;
            defer parsed.deinit();

            const op = parsed.value.object.get("op") orelse continue;
            switch (op) {
                .integer => |op_int| {
                    if (op_int == 0) { // Hello
                        self.handleHello(parsed.value.object) catch |err| {
                            log.err("ObsEgress: Auth failed: {any}", .{err});
                            return err;
                        };
                    } else if (op_int == 2) { // Identified
                        log.info("ObsEgress: Successfully identified with OBS", .{});
                        // NOTE: 旧実装は起動時に sceneItemId 1..5 を強制的に false へリセット
                        // していたが、Image 以外のソース (Screen Capture 等) まで消してしまう
                        // ため削除。OBS 側で望む初期状態を設定してください。
                    } else if (op_int == 7) { // RequestResponse
                        if (parsed.value.object.get("d")) |d| {
                            const req_type = if (d.object.get("requestType")) |v| v.string else "?";
                            var ok = true;
                            if (d.object.get("requestStatus")) |status| {
                                if (status.object.get("result")) |r| {
                                    if (r == .bool) ok = r.bool;
                                }
                                if (!ok) {
                                    const code = if (status.object.get("code")) |c| c.integer else 0;
                                    const comment = if (status.object.get("comment")) |c| c.string else "";
                                    log.err("ObsEgress: ❌ OBS rejected {s} (code={d}): {s}", .{ req_type, code, comment });
                                } else {
                                    log.debug("ObsEgress: ✓ {s} succeeded", .{req_type});
                                }
                            }
                        }
                    } else if (op_int == 5) { // Event
                        if (parsed.value.object.get("d")) |d| {
                            if (d.object.get("eventType")) |event_type| {
                                var topic_buf: [128]u8 = undefined;
                                if (std.fmt.bufPrint(&topic_buf, "core.obs.event.{s}", .{event_type.string})) |topic| {
                                    self.bus.publish(topic, frame.payload, .Transient, self.node_id) catch |err| {
                                        log.err("ObsEgress: Failed to publish OBS event: {any}", .{err});
                                    };
                                } else |_| {}
                            }
                        }
                    }
                },
                else => continue,
            }
        }
    }

    fn handleHello(self: *ObsEgressNode, hello: std.json.ObjectMap) !void {
        const d = hello.get("d") orelse return error.InvalidHello;
        const auth_ptr = d.object.get("authentication");
        var buf: [512]u8 = undefined;
        var msg: []const u8 = undefined;
        if (auth_ptr) |auth| {
            // 認証が必要
            const challenge = auth.object.get("challenge").?.string;
            const salt = auth.object.get("salt").?.string;
            const password = self.password orelse return error.PasswordRequired;

            // hash = base64(sha256(base64(sha256(password + salt)) + challenge))
            var h1_out: [32]u8 = undefined;
            var h1 = std.crypto.hash.sha2.Sha256.init(.{});
            h1.update(password);
            h1.update(salt);
            h1.final(&h1_out);

            var b1_buf: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
            const b1 = std.base64.standard.Encoder.encode(&b1_buf, &h1_out);

            var h2_out: [32]u8 = undefined;
            var h2 = std.crypto.hash.sha2.Sha256.init(.{});
            h2.update(b1);
            h2.update(challenge);
            h2.final(&h2_out);

            var b2_buf: [std.base64.standard.Encoder.calcSize(32)]u8 = undefined;
            const b2 = std.base64.standard.Encoder.encode(&b2_buf, &h2_out);

            msg = try std.fmt.bufPrint(&buf, "{{\"op\":1,\"d\":{{\"rpcVersion\":1,\"authentication\":\"{s}\"}}}}", .{b2});
        } else {
            // 認証なし
            msg = try std.fmt.bufPrint(&buf, "{{\"op\":1,\"d\":{{\"rpcVersion\":1}}}}", .{});
        }

        try self.sendFrame(msg);
    }

    fn readFrame(self: *ObsEgressNode) !struct { opcode: u4, payload: []u8 } {
        var head: [2]u8 = undefined;
        try self.readExact(&head);
        const opcode: u4 = @intCast(head[0] & 0x0F);
        var len: u64 = head[1] & 0x7F;
        if (len == 126) {
            var ext: [2]u8 = undefined;
            try self.readExact(&ext);
            len = std.mem.readInt(u16, &ext, .big);
        } else if (len == 127) {
            var ext: [8]u8 = undefined;
            try self.readExact(&ext);
            len = std.mem.readInt(u64, &ext, .big);
        }
        const payload = try self.allocator.alloc(u8, @intCast(len));
        try self.readExact(payload);
        return .{ .opcode = opcode, .payload = payload };
    }

    fn readExact(self: *ObsEgressNode, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.stream.?.read(buf[total..]);
            if (n == 0) return error.EndOfStream;
            total += n;
        }
    }

    fn sendFrame(self: *ObsEgressNode, data: []const u8) !void {
        var head: [14]u8 = undefined; // max: 1 opcode + 1 len + 8 ext_len + 4 mask_key
        head[0] = 0x81; // Text, Final
        var h_len: usize = 2;
        if (data.len <= 125) {
            head[1] = @as(u8, @intCast(data.len)) | 0x80; // MASK bit set
        } else if (data.len <= 65535) {
            head[1] = 126 | 0x80; // MASK bit set
            std.mem.writeInt(u16, head[2..4], @intCast(data.len), .big);
            h_len = 4;
        } else {
            head[1] = 127 | 0x80; // MASK bit set
            std.mem.writeInt(u64, head[2..10], data.len, .big);
            h_len = 10;
        }

        // RFC 6455 §5.3: Client MUST mask all frames sent to the server
        const mask_key = [4]u8{ 0x37, 0xFA, 0x21, 0x3D };
        head[h_len] = mask_key[0];
        head[h_len + 1] = mask_key[1];
        head[h_len + 2] = mask_key[2];
        head[h_len + 3] = mask_key[3];
        h_len += 4;

        // XOR payload with mask key
        const masked = self.allocator.alloc(u8, data.len) catch return error.OutOfMemory;
        defer self.allocator.free(masked);
        for (data, 0..) |byte, i| {
            masked[i] = byte ^ mask_key[i % 4];
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const s = self.stream orelse return error.NotConnected;
        try s.writeAll(head[0..h_len]);
        try s.writeAll(masked);
    }

    fn onMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *ObsEgressNode = @ptrCast(@alignCast(context));

        if (std.mem.startsWith(u8, msg.topic, "core.obs.request.")) {
            const req_type = msg.topic["core.obs.request.".len..];
            if (std.mem.indexOf(u8, msg.payload, "\"op\"") != null) {
                self.sendFrame(msg.payload) catch |err| {
                    std.debug.print("ObsEgress: Failed to send raw frame to OBS: {any}\n", .{err});
                };
                return;
            }

            if (std.mem.eql(u8, req_type, "SetSceneItemEnabled")) {
                // payload から scene 名 / sceneItemId / sceneItemEnabled を抽出し、
                // 指定された 1 件だけへ SetSceneItemEnabled を送る。
                // 旧実装は id 1..5 を総当たりしていたため、Image 以外の
                // シーンアイテム (Screen Capture 等) まで一緒に切り替わっていた。
                const Payload = struct {
                    sceneName: []const u8 = "Overlay",
                    sceneItemId: i64 = 1,
                    sceneItemEnabled: bool = true,
                };
                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();
                const parsed = std.json.parseFromSliceLeaky(Payload, arena.allocator(), msg.payload, .{
                    .ignore_unknown_fields = true,
                }) catch |err| {
                    log.err("ObsEgress: Failed to parse SetSceneItemEnabled payload: {any}", .{err});
                    return;
                };

                const enabled_str = if (parsed.sceneItemEnabled) "true" else "false";
                var buf: [512]u8 = undefined;
                if (std.fmt.bufPrint(&buf, "{{\"op\":6,\"d\":{{\"requestType\":\"SetSceneItemEnabled\",\"requestId\":\"weave-{d}\",\"requestData\":{{\"sceneName\":\"{s}\",\"sceneItemId\":{d},\"sceneItemEnabled\":{s}}}}}}}", .{ msg.id, parsed.sceneName, parsed.sceneItemId, enabled_str })) |req_json| {
                    log.info("ObsEgress: → SetSceneItemEnabled scene='{s}' id={d} enabled={s}", .{ parsed.sceneName, parsed.sceneItemId, enabled_str });
                    self.sendFrame(req_json) catch |err| {
                        log.err("ObsEgress: Failed to send frame: {any}", .{err});
                    };
                } else |_| {}
                return;
            }

            var buf: [4096]u8 = undefined;
            const req_json = std.fmt.bufPrint(&buf, "{{\"op\":6,\"d\":{{\"requestType\":\"{s}\",\"requestId\":\"weave-{d}\",\"requestData\":{s}}}}}", .{ req_type, msg.id, msg.payload }) catch return;

            self.sendFrame(req_json) catch |err| {
                std.debug.print("ObsEgress: Failed to send wrapped frame to OBS: {any}\n", .{err});
            };
        } else {
            self.sendFrame(msg.payload) catch |err| {
                std.debug.print("ObsEgress: Failed to send frame to OBS: {any}\n", .{err});
            };
        }
    }

    fn onSubscribeAck(ctx: *anyopaque, topic: []const u8) void {
        _ = ctx;
        _ = topic;
    }
};
