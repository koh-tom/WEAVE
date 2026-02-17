const std = @import("std");
const zap = @import("zap");
const event_bus = @import("../event_bus.zig");

/// Dashboard サーバーノード
/// 外部のブラウザ向けに WebSocket でイベントとログを配信します。
pub const DashboardNode = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    
    // ZAP関連
    listener: zap.HttpListener,
    
    const SELF = @This();

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, port: u32) !*SELF {
        const self = try allocator.create(SELF);
        
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .listener = zap.HttpListener.init(.{
                .port = port,
                .on_request = handleHttpRequest,
                .on_upgrade = handleWebSocketUpgrade,
                .log = true,
                .max_clients = 100,
            }),
        };

        return self;
    }

    pub fn deinit(self: *SELF) void {
        self.allocator.destroy(self);
    }

    pub fn start(self: *SELF) !void {
        std.debug.print("Dashboard: Starting server on port {d}...\n", .{self.listener.settings.port});
        try self.listener.listen();
        
        // 全イベントをトレースするための購読
        try self.bus.subscribe("core.system.event_traced", self.node_id, onTraceMessage, self);
        // ログトピックの購読
        try self.bus.subscribe("core.system.log", self.node_id, onTraceMessage, self);
    }

    /// HTTPリクエストハンドラ
    fn handleHttpRequest(r: zap.Request) void {
        r.sendBody("<h1>WEAVE Dashboard</h1><p>Connect via WebSocket at /ws</p>") catch return;
    }

    /// WebSocketアップグレードハンドラ
    fn handleWebSocketUpgrade(r: zap.Request, protocol: []const u8) void {
        if (std.mem.eql(u8, protocol, "websocket")) {
            _ = zap.WebsocketUpgrade.upgrade(r.h, &websocket_handler, null) catch return;
        }
    }

    /// WebSocketの各種イベントコールバック
    var websocket_handler = zap.WebsocketHandler{
        .on_open = onWebsocketOpen,
        .on_message = onWebsocketMessage,
        .on_close = onWebsocketClose,
    };

    fn onWebsocketOpen(context: ?*anyopaque, handle: zap.WebsocketHandle) void {
        _ = context;
        std.debug.print("Dashboard: Client connected to WebSocket (handle: {d})\n", .{handle});
    }

    fn onWebsocketMessage(context: ?*anyopaque, handle: zap.WebsocketHandle, message: []const u8, is_binary: bool) void {
        _ = context;
        _ = handle;
        _ = message;
        _ = is_binary;
    }

    fn onWebsocketClose(context: ?*anyopaque, handle: zap.WebsocketHandle) void {
        _ = context;
        _ = handle;
        std.debug.print("Dashboard: Client disconnected\n");
    }

    /// EventBusからのトレースメッセージを受信してWebSocketに流す
    fn onTraceMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        const self: *SELF = @ptrCast(@alignCast(context));
        
        // JSONメッセージの構築
        // format: { "topic": "...", "payload": "...", "origin": 0 }
        var buf: [4096]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, 
            "{{\"topic\":\"{s}\",\"payload\":\"{s}\",\"origin\":{d}}}",
            .{ msg.topic, msg.payload, msg.origin_node_id }
        ) catch return;

        // 全クライアントにブロードキャスト
        zap.WebsocketHandler.broadcast(json, false) catch |err| {
            std.debug.print("Dashboard: Broadcast error: {any}\n", .{err});
        };
    }
};
