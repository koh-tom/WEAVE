//! `weave` — WEAVE の統合 CLI
//!
//!   weave run [options] [plugin.wasm ...]    Core を起動 (WEAVE と同じ引数)
//!   weave up  [options] [plugin.wasm ...]    Supervisor 付きで起動 (落ちても即再起動)
//!   weave audit [node | --failure node]      影響範囲の監査 (weave-audit)
//!   weave key <generate|sign|verify> ...     署名 (weave-key)
//!   weave obs-sim [options]                  OBS WebSocket v5 シミュレータ (weave-obs-sim)
//!   weave topic pub <topic> <payload>        Inspector 経由で publish (ext.* のみ)
//!   weave topic echo [pattern]               イベントを表示 (Ctrl+C で終了)
//!   weave node ls                            ノード一覧 (セル・状態)
//!   weave doctor                             環境の自己診断
//!   weave init <name>                        プラグインのひな形 (wasm-apps/<name>.zig/.json)
//!
//! 接続先: --url ws://127.0.0.1:3030/ws (既定)  トークン: --token / WEAVE_DASHBOARD_TOKEN

const std = @import("std");
const ws = @import("transport/ws_proto.zig");
const pattern = @import("core/pattern.zig");
const Manifest = @import("core/manifest.zig").Manifest;

const Conn = struct { host: []const u8, port: u16, path: []const u8, token: ?[]const u8 };

fn usage() void {
    std.debug.print(
        \\weave — WEAVE CLI
        \\
        \\  weave run [options] [plugin.wasm ...]   Core を起動
        \\  weave up  [options] [plugin.wasm ...]   Supervisor 付きで起動 (落ちても即再起動)
        \\  weave audit [node | --failure node]     影響範囲の監査
        \\  weave key <generate|sign|verify> ...    プラグイン署名
        \\  weave obs-sim [--port N] [--password P] OBS WebSocket v5 シミュレータ
        \\  weave topic pub <topic> <payload>       publish (Inspector の権限: ext.*)
        \\  weave topic echo [pattern]              イベントを表示
        \\  weave node ls                           ノード一覧
        \\  weave doctor                            自己診断
        \\  weave init <name>                       プラグインのひな形を作る
        \\
        \\  共通: --url ws://127.0.0.1:3030/ws  --token <t> (または WEAVE_DASHBOARD_TOKEN)
        \\
    , .{});
}

fn execSibling(allocator: std.mem.Allocator, name: []const u8, rest: []const []const u8, extra_first: ?[]const u8) !void {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fs.selfExeDirPath(&dir_buf);
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    var argv: std.ArrayListUnmanaged([]const u8) = .{};
    try argv.append(allocator, path);
    if (extra_first) |e| try argv.append(allocator, e);
    try argv.appendSlice(allocator, rest);
    const err = std.process.execv(allocator, argv.items);
    std.debug.print("weave: failed to exec {s}: {any}\n", .{ path, err });
    return err;
}

fn parseConn(allocator: std.mem.Allocator, args: []const []const u8, rest: *std.ArrayListUnmanaged([]const u8)) !Conn {
    var url: []const u8 = "ws://127.0.0.1:3030/ws";
    var token: ?[]const u8 = std.process.getEnvVarOwned(allocator, "WEAVE_DASHBOARD_TOKEN") catch null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--url") and i + 1 < args.len) {
            i += 1;
            url = args[i];
        } else if (std.mem.eql(u8, args[i], "--token") and i + 1 < args.len) {
            i += 1;
            token = args[i];
        } else try rest.append(allocator, args[i]);
    }
    if (!std.mem.startsWith(u8, url, "ws://")) return error.UnsupportedUrl;
    const after = url["ws://".len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse after.len;
    const hostport = after[0..slash];
    const path = if (slash < after.len) after[slash..] else "/ws";
    const colon = std.mem.lastIndexOfScalar(u8, hostport, ':') orelse return error.MissingPort;
    return .{ .host = hostport[0..colon], .port = try std.fmt.parseInt(u16, hostport[colon + 1 ..], 10), .path = path, .token = token };
}

fn connect(allocator: std.mem.Allocator, c: Conn) !std.net.Stream {
    const addr = try std.net.Address.resolveIp(c.host, c.port);
    const s = try std.net.tcpConnectToAddress(addr);
    errdefer s.close();
    var extra: [256]u8 = undefined;
    const hdr = if (c.token) |t| try std.fmt.bufPrint(&extra, "X-WEAVE-Token: {s}\r\n", .{t}) else "";
    ws.clientHandshake(s, c.host, c.port, c.path, hdr) catch |err| {
        if (err == error.HandshakeRejected) std.debug.print("weave: connection rejected (token required? use --token or WEAVE_DASHBOARD_TOKEN)\n", .{});
        return err;
    };
    _ = allocator;
    return s;
}

fn cmdTopicPub(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var rest: std.ArrayListUnmanaged([]const u8) = .{};
    const c = try parseConn(allocator, args, &rest);
    if (rest.items.len < 2) return usage();
    const topic = rest.items[0];
    const payload_raw = rest.items[1];
    if (!pattern.validTopic(topic)) {
        std.debug.print("weave: invalid topic '{s}'\n", .{topic});
        std.process.exit(2);
    }
    const s = try connect(allocator, c);
    defer s.close();
    var out: std.ArrayListUnmanaged(u8) = .{};
    const w = out.writer(allocator);
    try w.print("{{\"topic\":{f},\"payload\":", .{std.json.fmt(topic, .{})});
    if (std.json.validate(allocator, payload_raw) catch false) try w.writeAll(payload_raw) else try w.print("{f}", .{std.json.fmt(payload_raw, .{})});
    try w.writeAll("}");
    try ws.writeFrame(s, .text, out.items, true);
    std.Thread.sleep(100 * std.time.ns_per_ms);
    try ws.writeFrame(s, .close, "", true);
    std.debug.print("published {s}\n", .{topic});
}

fn cmdTopicEcho(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var rest: std.ArrayListUnmanaged([]const u8) = .{};
    const c = try parseConn(allocator, args, &rest);
    const filter: []const u8 = if (rest.items.len > 0) rest.items[0] else "#";
    const s = try connect(allocator, c);
    defer s.close();
    var stdout_buf: [4096]u8 = undefined;
    var stdout = std.fs.File.stdout().writer(&stdout_buf);
    while (true) {
        const f = ws.readMessage(s, allocator, 16 << 20) catch break;
        defer allocator.free(f.payload);
        if (f.opcode != .text) continue;
        const parsed = std.json.parseFromSlice(struct { topic: []const u8 = "" }, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer parsed.deinit();
        if (!pattern.isMatch(filter, parsed.value.topic)) continue;
        try stdout.interface.print("{s}\n", .{f.payload});
        try stdout.interface.flush();
    }
}

fn cmdNodeLs(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var rest: std.ArrayListUnmanaged([]const u8) = .{};
    const c = try parseConn(allocator, args, &rest);
    const s = try connect(allocator, c);
    defer s.close();
    const Graph = struct {
        payload: struct {
            nodes: []struct { id: u32, name: []const u8, type: []const u8, cell: []const u8 = "", status: []const u8 = "" },
        },
    };
    const deadline = std.time.milliTimestamp() + 3000;
    while (std.time.milliTimestamp() < deadline) {
        const f = ws.readMessage(s, allocator, 16 << 20) catch break;
        defer allocator.free(f.payload);
        if (std.mem.indexOf(u8, f.payload, "\"core.system.graph.full\"") == null) continue;
        const g = std.json.parseFromSlice(Graph, allocator, f.payload, .{ .ignore_unknown_fields = true }) catch continue;
        defer g.deinit();
        std.debug.print("{s: <6} {s: <22} {s: <8} {s: <24} {s}\n", .{ "ID", "NAME", "TYPE", "CELL", "STATUS" });
        for (g.value.payload.nodes) |n| {
            std.debug.print("{d: <6} {s: <22} {s: <8} {s: <24} {s}\n", .{ n.id, n.name, n.type, n.cell, n.status });
        }
        return;
    }
    std.debug.print("weave: no topology received\n", .{});
    std.process.exit(1);
}

fn check(ok: bool, what: []const u8, hint: []const u8) bool {
    if (ok) {
        std.debug.print("  \x1b[32mOK\x1b[0m   {s}\n", .{what});
    } else {
        std.debug.print("  \x1b[31mNG\x1b[0m   {s}\n       -> {s}\n", .{ what, hint });
    }
    return ok;
}

fn portFree(port: u16) bool {
    const addr = std.net.Address.parseIp("127.0.0.1", port) catch return false;
    var srv = addr.listen(.{ .reuse_address = true }) catch return false;
    srv.deinit();
    return true;
}

fn cmdDoctor(allocator: std.mem.Allocator) !void {
    std.debug.print("weave doctor\n\n", .{});
    var all = true;
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = try std.fs.selfExeDirPath(&dir_buf);
    for ([_][]const u8{ "WEAVE", "weave-audit", "weave-key", "weave-obs-sim" }) |b| {
        const p = try std.fs.path.join(allocator, &.{ dir, b });
        const ok = if (std.fs.cwd().access(p, .{})) |_| true else |_| false;
        all = check(ok, b, "run: zig build") and all;
    }
    const dist_ok = if (std.fs.cwd().access("dashboard/dist/index.html", .{})) |_| true else |_| false;
    all = check(dist_ok, "Inspector (dashboard/dist)", "cd dashboard && bun install && bun run build") and all;
    for ([_]struct { u16, []const u8 }{ .{ 3030, "dashboard" }, .{ 8081, "node ws" } }) |pp| {
        var buf: [64]u8 = undefined;
        const what = try std.fmt.bufPrint(&buf, "port {d} ({s}) is free", .{ pp[0], pp[1] });
        _ = check(portFree(pp[0]), what, "another WEAVE may be running (or pass --dash-port / --node-port)");
    }
    const obs_up = !portFree(4455);
    _ = check(obs_up, "OBS WebSocket (127.0.0.1:4455) is listening", "start OBS with WebSocket enabled, or use --mock-obs / weave obs-sim");
    const trust = std.fs.cwd().readFileAlloc(allocator, ".weave/trusted_keys", 1 << 20) catch null;
    _ = check(trust != null and std.mem.trim(u8, trust.?, " \n\r\t").len > 0, "trusted keys (.weave/trusted_keys)", "weave key generate .weave/devkey && cp .weave/devkey.pub .weave/trusted_keys (strict mode rejects everything otherwise)");

    // manifest の検証
    var wdir = std.fs.cwd().openDir("wasm-apps", .{ .iterate = true }) catch null;
    if (wdir) |*d| {
        defer d.close();
        var it = d.iterate();
        while (try it.next()) |e| {
            if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
            const bytes = try d.readFileAlloc(allocator, e.name, 1 << 20);
            var buf: [128]u8 = undefined;
            const what = try std.fmt.bufPrint(&buf, "manifest wasm-apps/{s}", .{e.name});
            if (Manifest.parse(allocator, bytes)) |m| {
                m.deinit();
                all = check(true, what, "") and all;
            } else |err| {
                all = check(false, what, @errorName(err)) and all;
            }
        }
    }
    std.debug.print("\n{s}\n", .{if (all) "all required checks passed" else "some required checks failed"});
    if (!all) std.process.exit(1);
}

fn cmdInit(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) return usage();
    const name = args[0];
    for (name) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) {
            std.debug.print("weave init: name must be [A-Za-z0-9_]\n", .{});
            std.process.exit(2);
        }
    }
    const zig_path = try std.fmt.allocPrint(allocator, "wasm-apps/{s}.zig", .{name});
    const json_path = try std.fmt.allocPrint(allocator, "wasm-apps/{s}.json", .{name});
    if (std.fs.cwd().access(zig_path, .{})) |_| {
        std.debug.print("weave init: {s} already exists\n", .{zig_path});
        std.process.exit(1);
    } else |_| {}
    const src = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\const sdk = @import("plugin_sdk");
        \\
        \\pub const panic = sdk.panic;
        \\
        \\// {s}: チャットに "!hello" が来たら ext.{s}.greeting を発行する最小のプラグイン
        \\const Chat = struct {{ user: []const u8, message: []const u8 }};
        \\
        \\export fn on_init() i32 {{
        \\    sdk.log(1, "[{s}] started");
        \\    return 0;
        \\}}
        \\
        \\export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {{
        \\    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
        \\    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];
        \\    if (!std.mem.eql(u8, topic, "ext.twitch.chat.message")) return;
        \\    const chat = sdk.parseJson(Chat, payload) catch return;
        \\    defer chat.deinit();
        \\    if (std.mem.startsWith(u8, chat.value.message, "!hello")) {{
        \\        _ = sdk.publishJson("ext.{s}.greeting", .{{ .to = chat.value.user }}, .BestEffort) catch {{}};
        \\    }}
        \\}}
        \\
    , .{ name, name, name, name });
    const manifest = try std.fmt.allocPrint(allocator,
        \\{{
        \\    "abi_version": 1,
        \\    "name": "{s}",
        \\    "version": "0.1.0",
        \\    "permissions": {{
        \\        "publish": ["ext.{s}.greeting"],
        \\        "subscribe": ["ext.twitch.chat.message"],
        \\        "data_access": ["pii"]
        \\    }},
        \\    "rate_limit_eps": 20
        \\}}
        \\
    , .{ name, name });
    try std.fs.cwd().writeFile(.{ .sub_path = zig_path, .data = src });
    try std.fs.cwd().writeFile(.{ .sub_path = json_path, .data = manifest });
    std.debug.print(
        \\created {s} and {s}
        \\
        \\next:
        \\  zig build                                  # wasm-apps/{s}.wasm ができる
        \\  weave audit {s}                           # 乗っ取られたら何ができるかを確認
        \\  weave run --mock-obs wasm-apps/{s}.wasm   # 起動して Inspector で確認
        \\
    , .{ zig_path, json_path, name, name, name });
}

pub fn main() void {
    realMain() catch |err| {
        const hint: []const u8 = switch (err) {
            error.ConnectionRefused => " (WEAVE は起動していますか? --url でポートを指定できます)",
            error.HandshakeRejected => " (トークンが必要です: --token または WEAVE_DASHBOARD_TOKEN)",
            else => "",
        };
        std.debug.print("weave: {s}{s}\n", .{ @errorName(err), hint });
        std.process.exit(1);
    };
}

fn realMain() !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const allocator = arena_inst.allocator();
    const argv = try std.process.argsAlloc(allocator);
    if (argv.len < 2) return usage();
    const cmd = argv[1];
    const rest = argv[2..];

    if (std.mem.eql(u8, cmd, "run")) return execSibling(allocator, "WEAVE", rest, null);
    if (std.mem.eql(u8, cmd, "up")) return execSibling(allocator, "WEAVE", rest, "--supervise");
    if (std.mem.eql(u8, cmd, "audit")) return execSibling(allocator, "weave-audit", rest, null);
    if (std.mem.eql(u8, cmd, "key")) return execSibling(allocator, "weave-key", rest, null);
    if (std.mem.eql(u8, cmd, "obs-sim")) return execSibling(allocator, "weave-obs-sim", rest, null);
    if (std.mem.eql(u8, cmd, "doctor")) return cmdDoctor(allocator);
    if (std.mem.eql(u8, cmd, "init")) return cmdInit(allocator, rest);
    if (std.mem.eql(u8, cmd, "topic") and rest.len >= 1) {
        if (std.mem.eql(u8, rest[0], "pub")) return cmdTopicPub(allocator, rest[1..]);
        if (std.mem.eql(u8, rest[0], "echo")) return cmdTopicEcho(allocator, rest[1..]);
    }
    if (std.mem.eql(u8, cmd, "node") and rest.len >= 1 and std.mem.eql(u8, rest[0], "ls")) return cmdNodeLs(allocator, rest[1..]);
    usage();
    std.process.exit(2);
}
