//! `weave-obs-sim` — OBS WebSocket v5 の最小シミュレータ。
//!
//! 実物の OBS が無い環境 (CI・ブース PC・開発機) で、ObsEgress の実際の通信経路を
//! そのまま動かすための相手役。デモ第 3 幕「OBS 自体が落ちて戻る」をこれで再現できる:
//! プロセスを kill → 再起動すると、WEAVE が意図した表示状態を再適用し、
//! --state-file の中身が元に戻ることを確認できる。
//!
//! 対応: ハンドシェイク / Hello / Identify (パスワード認証あり・なし) / Identified /
//!       SetSceneItemEnabled / SetCurrentProgramScene / SetInputMute / その他の要求は成功応答のみ
//!       状態変更時に SceneItemEnableStateChanged などのイベントを送る
//!       --inputs / --scenes を渡すと、その名前だけが「OBS にある」ことにする。無い名前への要求は
//!       本物と同じく code 600 (ResourceNotFound) で断り、GetInputList / GetSceneList に一覧を返す
//!
//! Usage: weave-obs-sim [--port 4455] [--password <pw>] [--state-file <path>] [--inputs A,B] [--scenes X,Y] [--quiet]

const std = @import("std");
const ws = @import("transport/ws_proto.zig");
const ObsEgressNode = @import("builtin/obs.zig").ObsEgressNode;

const State = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    /// "scene#id" -> enabled
    items: std.StringArrayHashMapUnmanaged(bool) = .{},
    current_scene: ?[]u8 = null,
    requests: u64 = 0,
    state_file: ?[]const u8 = null,
    quiet: bool = false,
    /// null = 名前を確かめない (どの名前でも成功)
    inputs: ?[]const []const u8 = null,
    scenes: ?[]const []const u8 = null,

    fn has(list: ?[]const []const u8, name: []const u8) bool {
        const l = list orelse return true;
        for (l) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// 要求の対象が OBS に無ければ、本物の obs-websocket と同じ文言を返す
    fn missing(self: *State, data: std.json.Value, buf: []u8) ?[]const u8 {
        if (data != .object) return null;
        if (data.object.get("inputName")) |v| if (v == .string and !has(self.inputs, v.string))
            return std.fmt.bufPrint(buf, "No source was found by the name of `{s}`.", .{v.string}) catch "not found";
        if (data.object.get("sourceName")) |v| if (v == .string and !has(self.inputs, v.string) and !has(self.scenes, v.string))
            return std.fmt.bufPrint(buf, "No source was found by the name of `{s}`.", .{v.string}) catch "not found";
        if (data.object.get("sceneName")) |v| if (v == .string and !has(self.scenes, v.string))
            return std.fmt.bufPrint(buf, "No scene was found by the name of `{s}`.", .{v.string}) catch "not found";
        return null;
    }

    fn writeFile(self: *State) void {
        const path = self.state_file orelse return;
        var out: std.ArrayListUnmanaged(u8) = .{};
        defer out.deinit(self.allocator);
        const w = out.writer(self.allocator);
        w.writeAll("{\"items\":{") catch return;
        var it = self.items.iterator();
        var first = true;
        while (it.next()) |e| {
            if (!first) w.writeAll(",") catch return;
            first = false;
            w.print("{f}:{}", .{ std.json.fmt(e.key_ptr.*, .{}), e.value_ptr.* }) catch return;
        }
        w.print("}},\"current_scene\":{f},\"requests\":{d}}}\n", .{ std.json.fmt(self.current_scene, .{}), self.requests }) catch return;
        var tmp_buf: [512]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return;
        std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = out.items }) catch return;
        std.fs.cwd().rename(tmp, path) catch {};
    }
};

var g_running = std.atomic.Value(bool).init(true);

fn sendJson(stream: std.net.Stream, mutex: *std.Thread.Mutex, value: anytype) !void {
    var buf: [2048]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    try w.print("{f}", .{std.json.fmt(value, .{})});
    mutex.lock();
    defer mutex.unlock();
    try ws.writeFrame(stream, .text, w.buffered(), false);
}

fn handleClient(allocator: std.mem.Allocator, state: *State, password: ?[]const u8, conn: std.net.Server.Connection) void {
    defer conn.stream.close();
    var send_mutex = std.Thread.Mutex{};
    var head_buf: [ws.MAX_HEADER_BYTES]u8 = undefined;
    const head = ws.readHead(conn.stream, &head_buf) catch return;
    const req = ws.parseRequest(head) catch return;
    ws.writeUpgrade(conn.stream, req.ws_key orelse "") catch return;

    const salt = "c2ltLXNhbHQtd2VhdmU=";
    var challenge_raw: [16]u8 = undefined;
    std.crypto.random.bytes(&challenge_raw);
    var challenge_buf: [24]u8 = undefined;
    const challenge = std.base64.standard.Encoder.encode(&challenge_buf, &challenge_raw);

    if (password != null) {
        sendJson(conn.stream, &send_mutex, .{ .op = 0, .d = .{ .obsWebSocketVersion = "5.5.0-weave-sim", .rpcVersion = 1, .authentication = .{ .challenge = challenge, .salt = salt } } }) catch return;
    } else {
        sendJson(conn.stream, &send_mutex, .{ .op = 0, .d = .{ .obsWebSocketVersion = "5.5.0-weave-sim", .rpcVersion = 1 } }) catch return;
    }

    var identified = false;
    while (g_running.load(.acquire)) {
        const frame = ws.readMessage(conn.stream, allocator, 1 << 20) catch return;
        defer allocator.free(frame.payload);
        if (frame.opcode == .close) return;
        if (frame.opcode != .text) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, frame.payload, .{}) catch continue;
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const op = parsed.value.object.get("op") orelse continue;
        const d = parsed.value.object.get("d") orelse continue;
        if (op != .integer or d != .object) continue;

        if (op.integer == 1) {
            if (password) |pw| {
                const expected = ObsEgressNode.authString(pw, salt, challenge);
                const got = d.object.get("authentication") orelse .null;
                if (got != .string or !std.mem.eql(u8, got.string, &expected)) {
                    std.debug.print("[OBS-SIM] authentication failed\n", .{});
                    return;
                }
            }
            identified = true;
            sendJson(conn.stream, &send_mutex, .{ .op = 2, .d = .{ .negotiatedRpcVersion = 1 } }) catch return;
            if (!state.quiet) std.debug.print("[OBS-SIM] client identified\n", .{});
            continue;
        }
        if (op.integer != 6 or !identified) continue;

        const rt = d.object.get("requestType") orelse continue;
        const rid = d.object.get("requestId") orelse .null;
        const data = d.object.get("requestData") orelse .null;
        if (rt != .string) continue;

        const rid_s: []const u8 = if (rid == .string) rid.string else "";
        if (std.mem.eql(u8, rt.string, "GetInputList") or std.mem.eql(u8, rt.string, "GetSceneList")) {
            sendList(conn.stream, &send_mutex, allocator, rt.string, rid_s, state) catch return;
            continue;
        }
        var miss_buf: [256]u8 = undefined;
        if (state.missing(data, &miss_buf)) |comment| {
            if (!state.quiet) std.debug.print("[OBS-SIM] {s} rejected: {s}\n", .{ rt.string, comment });
            sendJson(conn.stream, &send_mutex, .{ .op = 7, .d = .{ .requestType = rt.string, .requestId = rid_s, .requestStatus = .{ .result = false, .code = 600, .comment = comment } } }) catch return;
            continue;
        }

        state.mutex.lock();
        state.requests += 1;
        var event_sent = false;
        if (std.mem.eql(u8, rt.string, "SetSceneItemEnabled") and data == .object) {
            const scene = data.object.get("sceneName") orelse .null;
            const id = data.object.get("sceneItemId") orelse .null;
            const en = data.object.get("sceneItemEnabled") orelse .null;
            if (scene == .string and id == .integer and en == .bool) {
                var kbuf: [160]u8 = undefined;
                const key = std.fmt.bufPrint(&kbuf, "{s}#{d}", .{ scene.string, id.integer }) catch "";
                if (state.items.getPtr(key)) |v| {
                    v.* = en.bool;
                } else if (allocator.dupe(u8, key)) |owned| {
                    state.items.put(allocator, owned, en.bool) catch allocator.free(owned);
                } else |_| {}
                if (!state.quiet) std.debug.print("[OBS-SIM] {s} = {s}\n", .{ key, if (en.bool) "VISIBLE" else "hidden" });
                state.writeFile();
                state.mutex.unlock();
                event_sent = true;
                sendJson(conn.stream, &send_mutex, .{ .op = 5, .d = .{ .eventType = "SceneItemEnableStateChanged", .eventIntent = 128, .eventData = .{ .sceneName = scene.string, .sceneItemId = id.integer, .sceneItemEnabled = en.bool } } }) catch return;
            }
        } else if (std.mem.eql(u8, rt.string, "SetCurrentProgramScene") and data == .object) {
            const scene = data.object.get("sceneName") orelse .null;
            if (scene == .string) {
                if (state.current_scene) |c| allocator.free(c);
                state.current_scene = allocator.dupe(u8, scene.string) catch null;
                if (!state.quiet) std.debug.print("[OBS-SIM] current scene = {s}\n", .{scene.string});
                state.writeFile();
                state.mutex.unlock();
                event_sent = true;
                sendJson(conn.stream, &send_mutex, .{ .op = 5, .d = .{ .eventType = "CurrentProgramSceneChanged", .eventIntent = 4, .eventData = .{ .sceneName = scene.string } } }) catch return;
            }
        }
        if (!event_sent) {
            state.writeFile();
            state.mutex.unlock();
        }
        sendJson(conn.stream, &send_mutex, .{ .op = 7, .d = .{ .requestType = rt.string, .requestId = rid_s, .requestStatus = .{ .result = true, .code = 100 } } }) catch return;
    }
}

fn sendList(stream: std.net.Stream, mutex: *std.Thread.Mutex, allocator: std.mem.Allocator, rt: []const u8, rid: []const u8, state: *State) !void {
    const scenes = std.mem.eql(u8, rt, "GetSceneList");
    const names = (if (scenes) state.scenes else state.inputs) orelse &.{};
    var out = std.io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("{{\"op\":7,\"d\":{{\"requestType\":{f},\"requestId\":{f},\"requestStatus\":{{\"result\":true,\"code\":100}},\"responseData\":{{\"{s}\":[", .{ std.json.fmt(rt, .{}), std.json.fmt(rid, .{}), if (scenes) "scenes" else "inputs" });
    for (names, 0..) |n, i| try w.print("{s}{{\"{s}\":{f}}}", .{ if (i == 0) "" else ",", if (scenes) "sceneName" else "inputName", std.json.fmt(n, .{}) });
    try w.writeAll("]}}}");
    mutex.lock();
    defer mutex.unlock();
    try ws.writeFrame(stream, .text, out.written(), false);
}

fn onSignal(_: i32) callconv(.c) void {
    // accept() は EINTR で再試行されるので、フラグだけでは止まらない。状態ファイルは
    // 変更のたびに書き出し済みなので、そのまま終了してよい。
    g_running.store(false, .release);
    std.os.linux.exit_group(0);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var port: u16 = 4455;
    var password: ?[]const u8 = null;
    var state = State{ .allocator = allocator };
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--port") and i + 1 < args.len) {
            i += 1;
            port = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, a, "--password") and i + 1 < args.len) {
            i += 1;
            password = args[i];
        } else if (std.mem.eql(u8, a, "--state-file") and i + 1 < args.len) {
            i += 1;
            state.state_file = args[i];
        } else if ((std.mem.eql(u8, a, "--inputs") or std.mem.eql(u8, a, "--scenes")) and i + 1 < args.len) {
            i += 1;
            var list = std.ArrayListUnmanaged([]const u8){};
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |n| if (n.len > 0) try list.append(allocator, n);
            const owned = try list.toOwnedSlice(allocator);
            if (std.mem.eql(u8, a, "--inputs")) state.inputs = owned else state.scenes = owned;
        } else if (std.mem.eql(u8, a, "--quiet")) {
            state.quiet = true;
        } else if (std.mem.eql(u8, a, "--help")) {
            std.debug.print("Usage: weave-obs-sim [--port 4455] [--password <pw>] [--state-file <path>] [--inputs A,B] [--scenes X,Y] [--quiet]\n", .{});
            return;
        }
    }
    defer {
        var it = state.items.iterator();
        while (it.next()) |e| allocator.free(e.key_ptr.*);
        state.items.deinit(allocator);
        if (state.current_scene) |c| allocator.free(c);
        if (state.inputs) |l| allocator.free(l);
        if (state.scenes) |l| allocator.free(l);
    }

    const act = std.os.linux.Sigaction{ .handler = .{ .handler = onSignal }, .mask = std.mem.zeroes(std.os.linux.sigset_t), .flags = 0 };
    _ = std.os.linux.sigaction(std.os.linux.SIG.INT, &act, null);
    _ = std.os.linux.sigaction(std.os.linux.SIG.TERM, &act, null);

    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    var server = try ws.listenExclusive(addr);
    defer server.deinit();
    std.debug.print("[OBS-SIM] listening on ws://127.0.0.1:{d} (auth: {s})\n", .{ port, if (password != null) "on" else "off" });
    state.writeFile();

    while (g_running.load(.acquire)) {
        const conn = server.accept() catch |err| {
            if (err == error.SocketNotListening or !g_running.load(.acquire)) break;
            continue;
        };
        // 本物の OBS と同じく、複数のクライアントを同時に受け付ける (WEAVE の送信役と、ラップした既存ツールなど)
        const th = std.Thread.spawn(.{}, handleClient, .{ allocator, &state, password, conn }) catch {
            conn.stream.close();
            continue;
        };
        th.detach();
    }
}
