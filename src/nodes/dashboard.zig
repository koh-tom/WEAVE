const std = @import("std");
const zap = @import("zap");
const event_bus = @import("../event_bus.zig");

/// Dashboard サーバーノード
pub const DashboardNode = struct {
    allocator: std.mem.Allocator,
    bus: *event_bus.EventBus,
    node_id: u32,
    port: u16,
    
    listener: zap.HttpListener,
    thread: ?std.Thread = null,
    
    // シングルトンインスタンス（ZAPのコールバックからアクセス用）
    var instance: ?*DashboardNode = null;

    const SELF = @This();

    pub fn init(allocator: std.mem.Allocator, bus: *event_bus.EventBus, node_id: u32, port: u16) !*SELF {
        const self = try allocator.create(SELF);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .port = port,
            .listener = zap.HttpListener.init(.{
                .port = port,
                .on_request = handleHttpRequest,
                .on_upgrade = handleWebSocketUpgrade,
                .log = false,
                .max_clients = 100,
            }),
        };
        instance = self;
        return self;
    }

    pub fn deinit(self: *SELF) void {
        zap.stop();
        if (self.thread) |t| t.detach();
        self.allocator.destroy(self);
    }

    pub fn start(self: *SELF) !void {
        std.debug.print("Dashboard: Starting server on port {d}...\n", .{self.port});
        
        try self.listener.listen();
        
        // ZAPのイベントループを別スレッドで開始
        self.thread = try std.Thread.spawn(.{}, struct {
            fn run() void {
                zap.start(.{
                    .threads = 2,
                    .workers = 1,
                });
            }
        }.run, .{});

        // 全イベントをトレースするための購読
        try self.bus.subscribe("core.system.event_traced", self.node_id, onTraceMessage, self);
        try self.bus.subscribe("core.system.log", self.node_id, onTraceMessage, self);
    }

    /// HTTPリクエストハンドラ
    fn handleHttpRequest(r: zap.Request) anyerror!void {
        if (r.path) |path| {
            if (std.mem.eql(u8, path, "/")) {
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                try r.sendBody(index_html);
                return;
            }
        }
        try r.sendBody("<h1>WEAVE Dashboard</h1><p>Connect via WebSocket at /ws</p>");
    }

    /// WebSocket用ハンドラ型
    const WsHandler = zap.WebSockets.Handler(SELF);

    /// WebSocketアップグレードハンドラ
    fn handleWebSocketUpgrade(r: zap.Request, protocol: []const u8) anyerror!void {
        if (std.mem.eql(u8, protocol, "websocket")) {
            var ws_settings: WsHandler.WebSocketSettings = .{
                .on_open = onWebsocketOpen,
                .on_message = onWebsocketMessage,
                .on_close = onWebsocketClose,
                .context = instance, // グローバルインスタンスを渡す
            };
            try WsHandler.upgrade(r.h, &ws_settings);
        }
    }

    fn onWebsocketOpen(context: ?*SELF, handle: zap.WebSockets.WsHandle) anyerror!void {
        std.debug.print("Dashboard: Client connected to WebSocket\n", .{});
        
        // 自動購読
        const SubscribeArgs = WsHandler.SubscribeArgs;
        const args = try context.?.allocator.create(SubscribeArgs);
        args.* = .{
            .channel = "dashboard",
            .context = context,
        };
        _ = try WsHandler.subscribe(handle, args);
    }

    fn onWebsocketMessage(context: ?*SELF, handle: zap.WebSockets.WsHandle, message: []const u8, is_text: bool) anyerror!void {
        _ = context; _ = handle; _ = message; _ = is_text;
    }

    fn onWebsocketClose(context: ?*SELF, uuid: isize) anyerror!void {
        _ = context;
        std.debug.print("Dashboard: Client disconnected (uuid: {d})\n", .{uuid});
    }

    /// EventBusからのトレースメッセージを受信してWebSocketに流す
    fn onTraceMessage(context: ?*anyopaque, msg: *const event_bus.EventMessage) void {
        _ = context;
        
        var buf: [4096]u8 = undefined;
        // payloadがJSON文字列であると仮定（hidden=trueなどは {"hidden":true} になっている）
        const json = std.fmt.bufPrint(&buf, 
            "{{\"topic\":\"{s}\",\"payload\":{s},\"origin\":{d}}}",
            .{ msg.topic, msg.payload, msg.source_node_id }
        ) catch return;

        WsHandler.publish(.{
            .channel = "dashboard",
            .message = json,
            .is_json = true,
        });
    }

    const index_html = 
        \\<!DOCTYPE html>
        \\<html lang="ja">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <title>WEAVE | Real-time Dashboard</title>
        \\    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;600;800&family=JetBrains+Mono&display=swap" rel="stylesheet">
        \\    <style>
        \\        :root { --bg: #0a0a0f; --surface: #16161e; --primary: #7aa2f7; --text: #c0caf5; --text-dim: #565f89; }
        \\        body { background: var(--bg); color: var(--text); font-family: 'Inter', sans-serif; margin: 0; display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
        \\        header { padding: 1rem 2rem; background: var(--surface); border-bottom: 1px solid rgba(122, 162, 247, 0.2); display: flex; justify-content: space-between; align-items: center; }
        \\        .logo { font-weight: 800; font-size: 1.5rem; color: var(--primary); }
        \\        main { flex: 1; display: grid; grid-template-columns: 300px 1fr; overflow: hidden; }
        \\        aside { background: var(--bg); padding: 1rem; border-right: 1px solid rgba(255,255,255,0.05); }
        \\        #event-stream { flex: 1; overflow-y: auto; padding: 1rem; font-family: 'JetBrains Mono', monospace; font-size: 0.8rem; }
        \\        .log-entry { margin-bottom: 0.5rem; padding: 0.4rem; background: rgba(255,255,255,0.02); border-left: 2px solid var(--primary); animation: slide 0.2s ease-out; }
        \\        @keyframes slide { from { opacity: 0; transform: translateX(5px); } to { opacity: 1; transform: translateX(0); } }
        \\        .topic { color: #ff9e64; font-weight: bold; margin-right: 0.5rem; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <header><div class="logo">WEAVE DASHBOARD</div><div id="status">CONNECTING...</div></header>
        \\    <main>
        \\        <aside><h3>Stats</h3><div id="eps">EPS: 0</div></aside>
        \\        <div id="event-stream"></div>
        \\    </main>
        \\    <script>
        \\        const stream = document.getElementById('event-stream');
        \\        const epsElem = document.getElementById('eps');
        \\        let count = 0;
        \\        function connect() {
        \\            const ws = new WebSocket(`ws://${location.host}/ws`);
        \\            ws.onopen = () => document.getElementById('status').innerText = 'LIVE';
        \\            ws.onmessage = (e) => {
        \\                const data = JSON.parse(e.data);
        \\                const div = document.createElement('div');
        \\                div.className = 'log-entry';
        \\                div.innerHTML = `<span class="topic">${data.topic}</span><span>${JSON.stringify(data.payload)}</span>`;
        \\                stream.insertBefore(div, stream.firstChild);
        \\                if (stream.childNodes.length > 50) stream.removeChild(stream.lastChild);
        \\                count++;
        \\            };
        \\            ws.onclose = () => setTimeout(connect, 2000);
        \\        }
        \\        setInterval(() => { epsElem.innerText = `EPS: ${count}`; count = 0; }, 1000);
        \\        connect();
        \\    </script>
        \\</body></html>
    ;
};
