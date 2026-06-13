const std = @import("std");
const zap = @import("zap");
const event_bus = @import("../core/event_bus.zig");
const log = @import("../common/log.zig");

/// Dashboard サーバーノード
pub const DashboardNode = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    port: u16,
    
    listener: zap.HttpListener,
    thread: ?std.Thread = null,
    
    // クライアント管理
    clients: std.AutoHashMap(zap.WebSockets.WsHandle, void),
    mutex: std.Thread.Mutex,
    
    ws_settings: WsHandler.WebSocketSettings = undefined,
    
    var instance: ?*DashboardNode = null;

    const SELF = @This();

    pub fn getInstance() ?*DashboardNode {
        return instance;
    }

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, port: u16) !*SELF {
        const self = try allocator.create(SELF);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .port = port,
            .clients = std.AutoHashMap(zap.WebSockets.WsHandle, void).init(allocator),
            .mutex = .{},
            .listener = zap.HttpListener.init(.{
                .port = port,
                .on_request = handleHttpRequest,
                .on_upgrade = handleWebSocketUpgrade,
                .public_folder = "dashboard/dist",
                .log = false,
                .max_clients = 100,
            }),
        };

        self.ws_settings = .{
            .on_open = onWebsocketOpen,
            .on_message = onWebsocketMessage,
            .on_close = onWebsocketClose,
            .context = self,
        };

        instance = self;
        return self;
    }

    pub fn stop(self: *SELF) void {
        _ = self;
        zap.stop();
    }

    pub fn deinit(self: *SELF) void {
        self.stop();
        if (self.thread) |t| t.join();
        self.clients.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *SELF) !void {
        log.info("Dashboard: Starting server on port {d}...", .{self.port});
        try self.listener.listen();
        
        self.thread = try std.Thread.spawn(.{}, struct {
            fn run() void {
                zap.start(.{ .threads = 2, .workers = 0 });
            }
        }.run, .{});

        // 全トピックを購読（#はMQTT形式で「それ以降全て」）
        try self.bus.subscribe("#", self.node_id, onTraceMessage, self);
    }

    fn handleHttpRequest(r: zap.Request) anyerror!void {
        _ = r;
    }

    const WsHandler = zap.WebSockets.Handler(SELF);

    fn handleWebSocketUpgrade(r: zap.Request, protocol: []const u8) anyerror!void {
        if (std.mem.eql(u8, protocol, "websocket")) {
            try WsHandler.upgrade(r.h, &instance.?.ws_settings);
        }
    }

    fn onWebsocketOpen(context: ?*SELF, handle: zap.WebSockets.WsHandle) anyerror!void {
        const self = context orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.clients.put(handle, {});
    }

    fn onWebsocketMessage(context: ?*SELF, handle: zap.WebSockets.WsHandle, message: []const u8, is_text: bool) anyerror!void {
        _ = handle; _ = is_text;
        const self = context orelse return;
        
        const parsed = std.json.parseFromSlice(struct {
            topic: []const u8,
            payload: std.json.Value,
        }, self.allocator, message, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();

        if (std.mem.eql(u8, parsed.value.topic, "core.system.graph.request")) {
            if (self.bus.graph) |graph| {
                const json = try graph.toJsonAlloc(self.allocator);
                defer self.allocator.free(json);
                try self.bus.publish("core.system.graph.full", json, .Transient, self.node_id);
            }
        }
    }

    fn onWebsocketClose(context: ?*SELF, uuid: isize) anyerror!void {
        _ = context; _ = uuid;
    }

    fn onTraceMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *SELF = @ptrCast(@alignCast(context orelse return));
        
        var buf: [8192]u8 = undefined;
        const payload = if (msg.payload.len > 0) msg.payload else "{}";
        const json = std.fmt.bufPrint(&buf, 
            "{{\"topic\":\"{s}\",\"payload\":{s},\"origin\":{d},\"ts\":{d}}}",
            .{ msg.topic, payload, msg.source_node_id, msg.timestamp }
        ) catch return;

        self.mutex.lock();
        defer self.mutex.unlock();

        var it = self.clients.keyIterator();
        while (it.next()) |handle_ptr| {
            WsHandler.write(handle_ptr.*, json, true) catch {
                // 送信失敗したクライアント
            };
        }
    }

};
