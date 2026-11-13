//! すぐ使い始めるためのコマンド (weave CLI から呼ぶ)。
//!
//!   weave setup                  OBS の WebSocket 設定を読み取り、つながるか確かめて weave.json に書く (配信者向け)
//!   weave wrap add <name>        既存ツールを WEAVE の下に置く (OBS の接続先を 4456 に変えるだけ)
//!   weave wrap list / show / lock / remove
//!   weave dev <name>             プラグインをビルドして起動し、保存するたびに作り直す (開発者向け)

const std = @import("std");
const ws = @import("transport/ws_proto.zig");
const approval = @import("security/approval.zig");
const gate = @import("builtin/obs_gate.zig");
const ObsEgressNode = @import("builtin/obs.zig").ObsEgressNode;

const WRAP_DIR = ".weave/wrap";

fn stdoutWriter(buf: []u8) std.fs.File.Writer {
    return std.fs.File.stdout().writer(buf);
}

fn ask(out: *std.Io.Writer, question: []const u8) !bool {
    try out.print("{s} [y/N] ", .{question});
    try out.flush();
    var in_buf: [256]u8 = undefined;
    var in_r = std.fs.File.stdin().reader(&in_buf);
    const line = in_r.interface.takeDelimiterExclusive('\n') catch "";
    const ans = std.mem.trim(u8, line, " \t\r");
    return std.mem.eql(u8, ans, "y") or std.mem.eql(u8, ans, "Y") or std.mem.eql(u8, ans, "yes");
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 48) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-')) return false;
    return true;
}

fn randomPassword(buf: *[22]u8) []const u8 {
    var raw: [16]u8 = undefined;
    std.crypto.random.bytes(&raw);
    return std.base64.url_safe_no_pad.Encoder.encode(buf, &raw);
}

fn weight(w: approval.Weight) []const u8 {
    return switch (w) {
        .normal => "",
        .sensitive => "  (要注意)",
        .strong => "  (強い権限)",
    };
}

fn printAllow(out: *std.Io.Writer, allow: []const []const u8) !void {
    for (allow) |a| {
        const colon = std.mem.indexOfScalar(u8, a, ':');
        const rt = if (colon) |c| a[0..c] else a;
        var tb: [160]u8 = undefined;
        const topic = std.fmt.bufPrint(&tb, "core.obs.request.{s}", .{rt}) catch rt;
        const d = if (std.mem.startsWith(u8, rt, "Get")) approval.Description{ .text = "OBS の状態を読む", .weight = .normal } else approval.describePublish(topic);
        if (colon) |c| {
            try out.print("    - {s} … 対象「{s}」だけ{s}\n", .{ d.text, a[c + 1 ..], weight(d.weight) });
        } else {
            try out.print("    - {s}  (どの対象でも){s}\n", .{ d.text, weight(d.weight) });
        }
    }
}

// ------------------------------------------------------------------ weave wrap

const SpecFile = struct {
    arena: std.heap.ArenaAllocator,
    spec: gate.Spec,
    path: []const u8,

    fn load(allocator: std.mem.Allocator, name: []const u8) !SpecFile {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ WRAP_DIR, name });
        const bytes = try std.fs.cwd().readFileAlloc(a, path, 1 << 20);
        const spec = try std.json.parseFromSliceLeaky(gate.Spec, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
        return .{ .arena = arena, .spec = spec, .path = path };
    }

    fn save(self: *SpecFile) !void {
        const out = try std.fmt.allocPrint(self.arena.allocator(), "{f}\n", .{std.json.fmt(self.spec, .{ .whitespace = .indent_2 })});
        try std.fs.cwd().makePath(WRAP_DIR);
        try std.fs.cwd().writeFile(.{ .sub_path = self.path, .data = out });
    }
};

fn printConnect(out: *std.Io.Writer, name: []const u8, password: []const u8) !void {
    try out.print(
        \\
        \\  {s} の「OBS の接続設定」を次のように変えてください (ツール自体は変えなくて大丈夫です):
        \\      サーバー (ホスト)  127.0.0.1
        \\      ポート             {d}      ← OBS の 4455 ではなく WEAVE
        \\      パスワード         {s}
        \\
        \\  WEAVE を起動し直すと有効になります (weave up)。
        \\
    , .{ name, gate.DEFAULT_PORT, password });
}

pub fn cmdWrap(allocator: std.mem.Allocator, args: []const []const u8) !void {
    const sub = if (args.len >= 1) args[0] else "list";
    const rest = if (args.len >= 1) args[1..] else args;
    if (std.mem.eql(u8, sub, "add")) return wrapAdd(allocator, rest);
    if (std.mem.eql(u8, sub, "list")) return wrapList(allocator);
    if (std.mem.eql(u8, sub, "show")) return wrapShow(allocator, rest);
    if (std.mem.eql(u8, sub, "lock")) return wrapLock(allocator, rest);
    if (std.mem.eql(u8, sub, "remove")) return wrapRemove(rest);
    wrapUsage();
}

fn wrapUsage() noreturn {
    std.debug.print(
        \\usage:
        \\  weave wrap add <name> [--allow SetSceneItemEnabled,Get*] [--rate 10] [--yes]
        \\                                   既存ツールを WEAVE の下に置く (--allow なしなら学習モード)
        \\  weave wrap list                  ラップしたツールの一覧
        \\  weave wrap show <name>           接続先とパスワードを表示
        \\  weave wrap lock <name>           学習モードで使った操作だけを許す宣言にする
        \\  weave wrap remove <name>         ラップをやめる
        \\
    , .{});
    std.process.exit(2);
}

fn wrapAdd(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var name: ?[]const u8 = null;
    var allow = std.ArrayListUnmanaged([]const u8){};
    var rate: f64 = 10;
    var yes = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--allow") and i + 1 < args.len) {
            i += 1;
            var it = std.mem.tokenizeScalar(u8, args[i], ',');
            while (it.next()) |x| try allow.append(allocator, std.mem.trim(u8, x, " "));
        } else if (std.mem.eql(u8, args[i], "--rate") and i + 1 < args.len) {
            i += 1;
            rate = try std.fmt.parseFloat(f64, args[i]);
        } else if (std.mem.eql(u8, args[i], "--yes") or std.mem.eql(u8, args[i], "-y")) {
            yes = true;
        } else name = args[i];
    }
    const n = name orelse wrapUsage();
    if (!validName(n)) {
        std.debug.print("weave wrap: name must be [A-Za-z0-9_-]\n", .{});
        std.process.exit(2);
    }
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(&buf);
    const out = &w.interface;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ WRAP_DIR, n });
    if (std.fs.cwd().access(path, .{})) |_| {
        try out.print("'{s}' はもうラップしています (接続先: weave wrap show {s})\n", .{ n, n });
        return out.flush();
    } else |_| {}

    const learn = allow.items.len == 0;
    try out.print("\n既存ツール '{s}' を WEAVE の下に置きます\n", .{n});
    if (learn) {
        try out.print(
            \\  学習モード: しばらく普段どおりに使ってもらい、実際に使った操作を記録します。
            \\  (配信・録画の停止だけは学習モードでも通しません)
            \\  記録がたまったら weave wrap lock {s} で「その操作だけ」を許す宣言にします。
            \\
        , .{n});
    } else {
        try out.print("  このツールに許す OBS の操作:\n", .{});
        try printAllow(out, allow.items);
        try out.print("  それ以外の操作 (配信の停止など) は OBS に届きません。\n", .{});
    }
    try out.print("  操作の上限: 1 秒に {d} 回まで。超えたらこのツールだけを 10 秒止め、画面を元に戻します。\n\n", .{@as(u32, @intFromFloat(rate))});
    if (!yes and !try ask(out, "このツールをラップしますか?")) {
        try out.print("やめました (何も変えていません)\n", .{});
        return out.flush();
    }

    var pwb: [22]u8 = undefined;
    var sf = SpecFile{ .arena = std.heap.ArenaAllocator.init(allocator), .path = path, .spec = .{
        .name = n,
        .password = randomPassword(&pwb),
        .mode = if (learn) "learn" else "enforce",
        .allow = allow.items,
        .rate_per_sec = rate,
        .burst = rate * 2,
    } };
    defer sf.arena.deinit();
    try sf.save();
    try out.print("ラップしました → {s}\n", .{path});
    try printConnect(out, n, sf.spec.password);
    try out.flush();
}

fn wrapShow(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) wrapUsage();
    var sf = SpecFile.load(allocator, args[0]) catch {
        std.debug.print("weave wrap: '{s}' はラップしていません (weave wrap list)\n", .{args[0]});
        std.process.exit(1);
    };
    defer sf.arena.deinit();
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(&buf);
    const out = &w.interface;
    try out.print("{s} ({s})\n", .{ sf.spec.name, if (std.mem.eql(u8, sf.spec.mode, "learn")) "学習モード" else "宣言どおりに通す" });
    if (sf.spec.allow.len > 0) {
        try out.print("  許す操作:\n", .{});
        try printAllow(out, sf.spec.allow);
    }
    if (sf.spec.learned.len > 0) {
        try out.print("  学習モードで使った操作:\n", .{});
        try printAllow(out, sf.spec.learned);
    }
    try printConnect(out, sf.spec.name, sf.spec.password);
    try out.flush();
}

fn wrapList(allocator: std.mem.Allocator) !void {
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(&buf);
    const out = &w.interface;
    var dir = std.fs.cwd().openDir(WRAP_DIR, .{ .iterate = true }) catch {
        try out.print("ラップしたツールはありません (weave wrap add <name>)\n", .{});
        return out.flush();
    };
    defer dir.close();
    var it = dir.iterate();
    var count: usize = 0;
    while (try it.next()) |e| {
        if (!std.mem.endsWith(u8, e.name, ".json")) continue;
        var sf = SpecFile.load(allocator, e.name[0 .. e.name.len - 5]) catch continue;
        defer sf.arena.deinit();
        count += 1;
        const learn = std.mem.eql(u8, sf.spec.mode, "learn");
        try out.print("  {s:<20} {s}  許す操作 {d} 個{s}\n", .{ sf.spec.name, if (learn) "学習モード      " else "宣言どおりに通す", if (learn) sf.spec.learned.len else sf.spec.allow.len, if (learn) " (記録済み)" else "" });
    }
    if (count == 0) try out.print("ラップしたツールはありません (weave wrap add <name>)\n", .{});
    try out.flush();
}

fn wrapLock(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1) wrapUsage();
    const yes = args.len >= 2 and (std.mem.eql(u8, args[1], "--yes") or std.mem.eql(u8, args[1], "-y"));
    var sf = SpecFile.load(allocator, args[0]) catch {
        std.debug.print("weave wrap: '{s}' はラップしていません\n", .{args[0]});
        std.process.exit(1);
    };
    defer sf.arena.deinit();
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(&buf);
    const out = &w.interface;
    const a = sf.arena.allocator();
    var merged = std.ArrayListUnmanaged([]const u8){};
    for (sf.spec.allow) |x| try merged.append(a, x);
    for (sf.spec.learned) |x| {
        if (!gate.matches(merged.items, x)) try merged.append(a, x);
    }
    if (merged.items.len == 0) {
        try out.print("まだ操作の記録がありません。WEAVE を起動して、{s} を普段どおりに使ってみてください\n", .{sf.spec.name});
        return out.flush();
    }
    try out.print("\n{s} に、これからは次の操作だけを許します:\n", .{sf.spec.name});
    try printAllow(out, merged.items);
    try out.print("  それ以外 (配信の停止など) は OBS に届きません。\n\n", .{});
    if (!yes and !try ask(out, "この宣言にしますか?")) {
        try out.print("やめました\n", .{});
        return out.flush();
    }
    sf.spec.allow = merged.items;
    sf.spec.mode = "enforce";
    try sf.save();
    try out.print("宣言にしました → {s}\n  起動中の WEAVE はすぐに読み直します (起動し直す必要はありません)\n", .{sf.path});
    try out.flush();
}

fn wrapRemove(args: []const []const u8) !void {
    if (args.len < 1 or !validName(args[0])) {
        std.debug.print("usage: weave wrap remove <name>\n", .{});
        std.process.exit(2);
    }
    var pb: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}.json", .{ WRAP_DIR, args[0] });
    std.fs.cwd().deleteFile(path) catch {
        std.debug.print("weave wrap: '{s}' はラップしていません\n", .{args[0]});
        std.process.exit(1);
    };
    std.debug.print("'{s}' のラップをやめました。ツールの接続先を OBS (4455) に戻してください\n", .{args[0]});
}

// ------------------------------------------------------------------ weave setup

const ObsWsConfig = struct {
    server_enabled: bool = false,
    server_port: u16 = 4455,
    auth_required: bool = false,
    server_password: []const u8 = "",
};

fn obsConfigPath(allocator: std.mem.Allocator) ?[]const u8 {
    const builtin = @import("builtin");
    const rel = "obs-studio/plugin_config/obs-websocket/config.json";
    if (builtin.os.tag == .windows) {
        const appdata = std.process.getEnvVarOwned(allocator, "APPDATA") catch return null;
        return std.fs.path.join(allocator, &.{ appdata, rel }) catch null;
    }
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return null;
    if (builtin.os.tag == .macos) return std.fs.path.join(allocator, &.{ home, "Library/Application Support", rel }) catch null;
    const xdg = std.process.getEnvVarOwned(allocator, "XDG_CONFIG_HOME") catch (std.fs.path.join(allocator, &.{ home, ".config" }) catch return null);
    return std.fs.path.join(allocator, &.{ xdg, rel }) catch null;
}

/// OBS に実際につないで、シーンの数を返す
fn probeObs(allocator: std.mem.Allocator, port: u16, password: ?[]const u8) !usize {
    const addr = try std.net.Address.parseIp("127.0.0.1", port);
    const s = try std.net.tcpConnectToAddress(addr);
    defer s.close();
    try ws.clientHandshake(s, "127.0.0.1", port, "/", "");
    const hello = try ws.readMessage(s, allocator, 1 << 20);
    var hp = try std.json.parseFromSlice(std.json.Value, allocator, hello.payload, .{});
    defer hp.deinit();
    const d = hp.value.object.get("d") orelse return error.BadHello;
    var buf: [512]u8 = undefined;
    var w = std.io.Writer.fixed(&buf);
    if (d.object.get("authentication")) |au| {
        const pw = password orelse return error.PasswordRequired;
        const secret = ObsEgressNode.authString(pw, au.object.get("salt").?.string, au.object.get("challenge").?.string);
        try w.print("{f}", .{std.json.fmt(.{ .op = 1, .d = .{ .rpcVersion = 1, .authentication = secret[0..], .eventSubscriptions = 0 } }, .{})});
    } else try w.print("{{\"op\":1,\"d\":{{\"rpcVersion\":1,\"eventSubscriptions\":0}}}}", .{});
    try ws.writeFrame(s, .text, w.buffered(), true);
    const ident = try ws.readMessage(s, allocator, 1 << 20);
    if (ident.opcode == .close) return error.AuthenticationFailed;
    try ws.writeFrame(s, .text, "{\"op\":6,\"d\":{\"requestType\":\"GetSceneList\",\"requestId\":\"setup\"}}", true);
    const res = try ws.readMessage(s, allocator, 4 << 20);
    var rp = try std.json.parseFromSlice(std.json.Value, allocator, res.payload, .{});
    defer rp.deinit();
    const rd = (rp.value.object.get("d") orelse return 0).object.get("responseData") orelse return 0;
    const scenes = rd.object.get("scenes") orelse return 0;
    return if (scenes == .array) scenes.array.items.len else 0;
}

pub fn cmdSetup(allocator: std.mem.Allocator, args: []const []const u8) !void {
    _ = args;
    var buf: [4096]u8 = undefined;
    var w = stdoutWriter(&buf);
    const out = &w.interface;
    try out.print("WEAVE のセットアップ\n\n", .{});

    var cfg = ObsWsConfig{};
    var found = false;
    if (obsConfigPath(allocator)) |p| {
        if (std.fs.cwd().readFileAlloc(allocator, p, 1 << 20)) |bytes| {
            if (std.json.parseFromSliceLeaky(ObsWsConfig, allocator, bytes, .{ .ignore_unknown_fields = true })) |c| {
                cfg = c;
                found = true;
                try out.print("  [ok] OBS の WebSocket 設定を見つけました ({s})\n", .{p});
            } else |_| {}
        } else |_| {}
    }
    if (!found) {
        try out.print(
            \\  [!] OBS の WebSocket 設定が見つかりません。
            \\      OBS を一度起動し、メニューの「ツール → WebSocket サーバー設定」を開いてください。
            \\
        , .{});
    } else if (!cfg.server_enabled) {
        try out.print(
            \\  [!] OBS の WebSocket サーバーが無効です。
            \\      OBS の「ツール → WebSocket サーバー設定」で「WebSocket サーバーを有効にする」にチェックを入れてください。
            \\
        , .{});
    }
    const password: ?[]const u8 = if (cfg.auth_required) cfg.server_password else null;

    // つながるか確かめる
    if (probeObs(allocator, cfg.server_port, password)) |scenes| {
        try out.print("  [ok] OBS につながりました (ポート {d}、シーン {d} 個)\n", .{ cfg.server_port, scenes });
    } else |err| {
        const hint: []const u8 = switch (err) {
            error.ConnectionRefused => "OBS が起動していないか、WebSocket サーバーが無効です",
            error.AuthenticationFailed, error.PasswordRequired => "パスワードが合いません。OBS の WebSocket サーバー設定を確かめてください",
            else => @errorName(err),
        };
        try out.print("  [!] OBS につながりませんでした: {s}\n      (設定は書いておくので、OBS を起動してから weave up で大丈夫です)\n", .{hint});
    }

    // weave.json に書く (ほかの設定は残す)
    var root = std.json.ObjectMap.init(allocator);
    if (std.fs.cwd().readFileAlloc(allocator, "weave.json", 1 << 20)) |bytes| {
        if (std.json.parseFromSliceLeaky(std.json.Value, allocator, bytes, .{})) |v| {
            if (v == .object) root = v.object;
        } else |_| {}
    } else |_| {}
    try root.put("obs_host", .{ .string = "127.0.0.1" });
    try root.put("obs_port", .{ .integer = cfg.server_port });
    try root.put("obs_password", .{ .string = if (password) |p| p else "" });
    const text = try std.fmt.allocPrint(allocator, "{f}\n", .{std.json.fmt(std.json.Value{ .object = root }, .{ .whitespace = .indent_2 })});
    try std.fs.cwd().writeFile(.{ .sub_path = "weave.json", .data = text });
    try out.print("  [ok] weave.json に OBS の接続先を書きました (パスワードを含むので人に渡さないでください)\n", .{});

    try out.print(
        \\
        \\準備ができました。
        \\  weave up                     WEAVE を起動 (OBS に自動でつながります。落ちてもすぐ戻ります)
        \\  http://127.0.0.1:3030        Inspector: 何がつながっていて、どこで何が起きたかを見る
        \\  weave wrap add <ツール名>    いま使っている OBS 連携ツールを WEAVE の下に置く (接続先を変えるだけ)
        \\  weave add <plugin.wasm>      プラグインを入れる (できることを確かめて承認)
        \\
    , .{});
    try out.flush();
}

// ------------------------------------------------------------------ weave dev

fn repoRoot(allocator: std.mem.Allocator) ![]const u8 {
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_dir = try std.fs.selfExeDirPath(&dir_buf);
    // zig-out/bin → リポジトリ
    return std.fs.path.resolve(allocator, &.{ exe_dir, "..", ".." });
}

fn mtime(path: []const u8) i128 {
    const st = std.fs.cwd().statFile(path) catch return 0;
    return st.mtime;
}

fn buildPlugins(allocator: std.mem.Allocator, root: []const u8) bool {
    var child = std.process.Child.init(&.{ "zig", "build", "wasm" }, allocator);
    child.cwd = root;
    const term = child.spawnAndWait() catch return false;
    return term == .Exited and term.Exited == 0;
}

pub fn cmdDev(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1 or !validName(args[0])) {
        std.debug.print("usage: weave dev <name>   (wasm-apps/<name>.zig をビルドして起動し、保存するたびに作り直す)\n", .{});
        std.process.exit(2);
    }
    const name = args[0];
    const root = try repoRoot(allocator);
    const src = try std.fmt.allocPrint(allocator, "{s}/wasm-apps/{s}.zig", .{ root, name });
    const manifest = try std.fmt.allocPrint(allocator, "{s}/wasm-apps/{s}.json", .{ root, name });
    const wasm = try std.fmt.allocPrint(allocator, "{s}/wasm-apps/{s}.wasm", .{ root, name });
    if (mtime(src) == 0) {
        std.debug.print("weave dev: {s} がありません。先に weave init {s} でひな形を作ってください\n", .{ src, name });
        std.process.exit(1);
    }
    const exe = try std.fmt.allocPrint(allocator, "{s}/zig-out/bin/WEAVE", .{root});
    const real_obs = if (std.fs.cwd().access("weave.json", .{})) |_| true else |_| false;

    std.debug.print(
        \\weave dev {s}
        \\  保存するたびに作り直して起動し直します (Ctrl+C で終了)
        \\  OBS: {s}
        \\  Inspector: http://127.0.0.1:3030  (左の「テスト用チャット」から試せます)
        \\
    , .{ name, if (real_obs) "weave.json の OBS につなぎます" else "OBS なし (送った操作を mock_obs_received.jsonl に記録)" });

    var child: ?std.process.Child = null;
    var last: i128 = -1;
    while (true) {
        const now_m = @max(mtime(src), mtime(manifest));
        if (now_m != last) {
            last = now_m;
            std.debug.print("\n[dev] ビルドしています...\n", .{});
            if (!buildPlugins(allocator, root)) {
                std.debug.print("[dev] ビルドに失敗しました。直して保存すると、もう一度試します\n", .{});
            } else {
                if (child) |*c| {
                    _ = c.kill() catch {};
                    child = null;
                }
                var argv = std.ArrayListUnmanaged([]const u8){};
                try argv.appendSlice(allocator, &.{ exe, "--no-twitch", "--approval-mode", "off" });
                if (!real_obs) try argv.append(allocator, "--mock-obs");
                try argv.append(allocator, wasm);
                var c = std.process.Child.init(argv.items, allocator);
                c.cwd = root;
                c.spawn() catch |err| {
                    std.debug.print("[dev] 起動できません: {any}\n", .{err});
                    continue;
                };
                child = c;
                std.debug.print("[dev] 起動しました: {s}\n", .{wasm});
            }
        }
        std.Thread.sleep(400 * std.time.ns_per_ms);
    }
}
