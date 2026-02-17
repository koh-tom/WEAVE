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
    fn handleHttpRequest(r: zap.Request) anyerror!void {
        try r.sendBody("<h1>WEAVE Dashboard</h1><p>Connect via WebSocket at /ws</p>");
    }

    /// WebSocket用ハンドラ型
    const WsHandler = zap.WebSockets.Handler(DashboardNode);

    var ws_settings: WsHandler.WebSocketSettings = .{
        .on_open = onWebsocketOpen,
        .on_message = onWebsocketMessage,
        .on_close = onWebsocketClose,
    };

    /// WebSocketアップグレードハンドラ
    fn handleWebSocketUpgrade(r: zap.Request, protocol: []const u8) anyerror!void {
        if (std.mem.eql(u8, protocol, "websocket")) {
            // Contextを渡す場合はsettings.contextを設定
            // 今回はシングルトン的に全WebSocketへブロードキャストするので一旦contextは不要でも動く
            try WsHandler.upgrade(r.h, &ws_settings);
        }
    }

    fn onWebsocketOpen(context: ?*DashboardNode, handle: zap.WebSockets.WsHandle) anyerror!void {
        _ = context;
        std.debug.print("Dashboard: Client connected to WebSocket (handle: {any})\n", .{handle});
    }

    fn onWebsocketMessage(context: ?*DashboardNode, handle: zap.WebSockets.WsHandle, message: []const u8, is_text: bool) anyerror!void {
        _ = context;
        _ = handle;
        _ = message;
        _ = is_text;
    }

    fn onWebsocketClose(context: ?*DashboardNode, uuid: isize) anyerror!void {
        _ = context;
        std.debug.print("Dashboard: Client disconnected (uuid: {d})\n", .{uuid});
    }

    /// EventBusからのトレースメッセージを受信してWebSocketに流す
    fn onTraceMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        _ = context; // 現時点ではselfを使用しない
        
        // JSONメッセージの構築
        var buf: [4096]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, 
            "{{\"topic\":\"{s}\",\"payload\":\"{s}\",\"origin\":{d}}}",
            .{ msg.topic, msg.payload, msg.source_node_id }
        ) catch return;

        // 全クライアントにブロードキャスト（ZAP v0.10+のpublishを使用）
        WsHandler.publish(.{
            .channel = "dashboard", // ブロードキャスト用のチャンネル名（登録が必要かもしれません）
            .message = json,
            .is_json = true,
        });
    }
};
