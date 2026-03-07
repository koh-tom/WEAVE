const std = @import("std");
const zap = @import("zap");
const event_bus = @import("../core/event_bus.zig");

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

    pub fn deinit(self: *SELF) void {
        zap.stop();
        if (self.thread) |t| t.detach();
        self.clients.deinit();
        self.allocator.destroy(self);
    }

    pub fn start(self: *SELF) !void {
        std.debug.print("Dashboard: Starting server on port {d}...\n", .{self.port});
        try self.listener.listen();
        
        self.thread = try std.Thread.spawn(.{}, struct {
            fn run() void {
                zap.start(.{ .threads = 2, .workers = 1 });
            }
        }.run, .{});

        // 全トピックを購読（#はMQTT形式で「それ以降全て」）
        try self.bus.subscribe("#", self.node_id, onTraceMessage, self);
    }

    fn handleHttpRequest(r: zap.Request) anyerror!void {
        if (r.path) |path| {
            if (std.mem.eql(u8, path, "/")) {
                r.setStatus(.ok);
                r.setContentType(.HTML) catch return;
                try r.sendBody(index_html);
                return;
            }
        }
        try r.sendBody("<h1>WEAVE Dashboard</h1>");
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
        // std.debug.print("Dashboard: Client connected\n", .{});
    }

    fn onWebsocketMessage(context: ?*SELF, handle: zap.WebSockets.WsHandle, message: []const u8, is_text: bool) anyerror!void {
        _ = context; _ = handle; _ = message; _ = is_text;
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
                // 送信失敗したクライアントは本来ここで消すべきだが、
                // 次のループや定期クリーンアップで対応可能
            };
        }
    }

    const index_html = 
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\    <meta charset="UTF-8">
        \\    <meta name="viewport" content="width=device-width, initial-scale=1.0">
        \\    <title>WEAVE | Command & Control</title>
        \\    <link href="https://fonts.googleapis.com/css2?family=Outfit:wght@300;600;800&family=JetBrains+Mono&display=swap" rel="stylesheet">
        \\    <style>
        \\        :root { --bg: #050508; --surface: #0d0d16; --primary: #7aa2f7; --secondary: #bb9af7; --accent: #9ece6a; --text: #c0caf5; --text-dim: #565f89; --danger: #f7768e; }
        \\        * { box-sizing: border-box; }
        \\        body { background: var(--bg); color: var(--text); font-family: 'Outfit', sans-serif; margin: 0; display: flex; height: 100vh; overflow: hidden; }
        \\        aside { width: 280px; background: var(--surface); border-right: 1px solid rgba(122,162,247,0.1); display: flex; flex-direction: column; padding: 2rem 1.5rem; }
        \\        .logo { font-weight: 800; font-size: 1.5rem; color: var(--primary); letter-spacing: -0.5px; margin-bottom: 2rem; display: flex; align-items: center; gap: 10px; }
        \\        .logo::before { content: ''; display: block; width: 12px; height: 12px; background: var(--primary); border-radius: 2px; box-shadow: 0 0 15px var(--primary); }
        \\        .nav-label { font-size: 0.7rem; font-weight: 600; text-transform: uppercase; color: var(--text-dim); letter-spacing: 1px; margin-bottom: 1rem; }
        \\        .stat-card { background: rgba(255,255,255,0.03); padding: 1.2rem; border-radius: 12px; margin-bottom: 1rem; border: 1px solid rgba(255,255,255,0.05); }
        \\        .stat-value { font-size: 1.8rem; font-weight: 800; color: var(--accent); }
        \\        .stat-label { font-size: 0.8rem; color: var(--text-dim); }
        \\        main { flex: 1; display: flex; flex-direction: column; overflow: hidden; position: relative; }
        \\        header { height: 70px; display: flex; align-items: center; padding: 0 2rem; border-bottom: 1px solid rgba(255,255,255,0.05); justify-content: space-between; }
        \\        #status-pill { padding: 0.4rem 1rem; border-radius: 20px; font-size: 0.75rem; font-weight: 600; background: rgba(247,118,142,0.1); color: var(--danger); border: 1px solid var(--danger); }
        \\        #status-pill.online { background: rgba(158,206,106,0.1); color: var(--accent); border-color: var(--accent); }
        \\        #stream { flex: 1; overflow-y: auto; padding: 1.5rem; display: flex; flex-direction: column; gap: 0.5rem; background: radial-gradient(circle at top right, rgba(122,162,247,0.03), transparent); }
        \\        .msg { font-family: 'JetBrains Mono', monospace; font-size: 0.75rem; padding: 0.8rem 1rem; background: rgba(255,255,255,0.02); border-radius: 8px; border-left: 3px solid var(--primary); display: flex; align-items: flex-start; gap: 1rem; animation: slideIn 0.3s ease-out; backdrop-filter: blur(5px); }
        \\        @keyframes slideIn { from { opacity: 0; transform: translateX(10px); } to { opacity: 1; transform: translateX(0); } }
        \\        .msg:hover { background: rgba(255,255,255,0.04); border-left-color: var(--secondary); }
        \\        .ts { color: var(--text-dim); min-width: 80px; }
        \\        .topic { color: var(--secondary); font-weight: bold; min-width: 180px; }
        \\        .origin { color: var(--primary); font-size: 0.7rem; opacity: 0.8; min-width: 60px; }
        \\        .payload { color: var(--text); opacity: 0.9; word-break: break-all; }
        \\    </style>
        \\</head>
        \\<body>
        \\    <aside>
        \\        <div class="logo">WEAVE</div>
        \\        <div class="nav-label">Overview</div>
        \\        <div class="stat-card">
        \\            <div class="stat-value" id="eps-val">0</div>
        \\            <div class="stat-label">Events Per Second</div>
        \\        </div>
        \\        <div class="stat-card">
        \\            <div class="stat-value" id="client-val">1</div>
        \\            <div class="stat-label">Active Listeners</div>
        \\        </div>
        \\    </aside>
        \\    <main>
        \\        <header>
        \\            <div style="font-weight: 600;">System Event Stream</div>
        \\            <div id="status-pill">OFFLINE</div>
        \\        </header>
        \\        <div id="stream"></div>
        \\    </main>
        \\    <script>
        \\        const stream = document.getElementById('stream');
        \\        const statusPill = document.getElementById('status-pill');
        \\        const epsVal = document.getElementById('eps-val');
        \\        let count = 0;
        \\        function connect() {
        \\            const ws = new WebSocket(`ws://${location.host}/ws`);
        \\            ws.onopen = () => { statusPill.innerText = 'ONLINE'; statusPill.className = 'online'; };
        \\            ws.onmessage = (e) => {
        \\                count++;
        \\                try {
        \\                    const data = JSON.parse(e.data);
        \\                    const div = document.createElement('div');
        \\                    div.className = 'msg';
        \\                    const time = new Date(data.ts).toLocaleTimeString('ja-JP', {hour12:false});
        \\                    div.innerHTML = `
        \\                        <span class="ts">${time}</span>
        \\                        <span class="origin">#${data.origin}</span>
        \\                        <span class="topic">${data.topic}</span>
        \\                        <span class="payload">${JSON.stringify(data.payload)}</span>
        \\                    `;
        \\                    stream.insertBefore(div, stream.firstChild);
        \\                    if (stream.childNodes.length > 150) stream.removeChild(stream.lastChild);
        \\                } catch(err) { console.error(err); }
        \\            };
        \\            ws.onclose = () => { statusPill.innerText = 'OFFLINE'; statusPill.className = ''; setTimeout(connect, 2000); };
        \\        }
        \\        setInterval(() => { epsVal.innerText = count; count = 0; }, 1000);
        \\        connect();
        \\    </script>
        \\</body></html>
    ;
};
