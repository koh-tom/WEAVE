//! `weave-audit` — 影響範囲の監査 CLI (ADR-008 / R9)
//!
//! 使い方:
//!   weave-audit                          全ノードの要約 (侵害時・障害時の両方)
//!   weave-audit <node>                   侵害されたら何ができるか (security blast radius)
//!   weave-audit --failure <node>         落ちたらどこまで止まるか (failure radius)
//!   weave-audit --manifests a.json ...   監査対象の manifest を明示 (既定: wasm-apps/*.json を走査)
//!
//! builtin (Core / TwitchAdapter / ObsEgress) は常に含める。
//! 実行前に、宣言 (manifest) だけから計算する。コードを読まないので難読化に左右されない。

const std = @import("std");
const blast = @import("audit/blast.zig");

fn collectManifests(arena: std.mem.Allocator, dir_path: []const u8, out: *std.ArrayListUnmanaged([]const u8)) !void {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    var names = std.ArrayListUnmanaged([]const u8){};
    while (try it.next()) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".json")) continue;
        try names.append(arena, try std.fs.path.join(arena, &.{ dir_path, e.name }));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    try out.appendSlice(arena, names.items);
}

pub fn main() !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const args = try std.process.argsAlloc(arena);
    var target: ?[]const u8 = null;
    var failure_target: ?[]const u8 = null;
    var manifest_paths = std.ArrayListUnmanaged([]const u8){};

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--manifests")) {
            i += 1;
            while (i < args.len and !std.mem.startsWith(u8, args[i], "--")) : (i += 1) {
                try manifest_paths.append(arena, args[i]);
            }
            i -= 1;
        } else if (std.mem.eql(u8, arg, "--failure")) {
            i += 1;
            if (i >= args.len) return printUsage();
            failure_target = args[i];
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return printUsage();
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            target = arg;
        }
    }

    if (manifest_paths.items.len == 0) try collectManifests(arena, "wasm-apps", &manifest_paths);

    // 運用者が宣言したセル (weave.json の cell_budgets)。実行時と同じく、ここにあるセルにだけ
    // manifest の `cell` で入れる
    var declared = std.ArrayListUnmanaged([]const u8){};
    if (std.fs.cwd().readFileAlloc(arena, "weave.json", 1024 * 1024)) |cfg| {
        if (std.json.parseFromSliceLeaky(std.json.Value, arena, cfg, .{})) |v| {
            if (v == .object) if (v.object.get("cell_budgets")) |cb| if (cb == .object) {
                var it = cb.object.iterator();
                while (it.next()) |e| try declared.append(arena, e.key_ptr.*);
            };
        } else |_| {}
    } else |_| {}

    var nodes = std.ArrayListUnmanaged(blast.Node){};
    for (try blast.builtinNodes(arena)) |b| try nodes.append(arena, b);
    for (manifest_paths.items) |path| {
        const node = blast.loadManifestNodeIn(arena, path, declared.items) catch |err| {
            std.debug.print("warn: skip {s}: {any}\n", .{ path, err });
            continue;
        };
        // 同名の manifest (obs_compat の複製など) は 1 つにまとめる
        var dup = false;
        for (nodes.items) |n| {
            if (std.mem.eql(u8, n.name, node.name)) dup = true;
        }
        if (!dup) try nodes.append(arena, node);
    }

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    if (failure_target) |t| {
        const r = blast.computeFailure(arena, nodes.items, t) catch |err| return notFound(err, t, nodes.items);
        try blast.printFailure(w, r);
    } else if (target) |t| {
        const report = blast.computeBlast(arena, nodes.items, t) catch |err| return notFound(err, t, nodes.items);
        try blast.printReport(w, report);
    } else {
        try w.print("\n=== WEAVE Impact Summary ({d} nodes) ===\n", .{nodes.items.len});
        try w.print("侵害されたら (security) / 落ちたら (failure) の上限を、宣言だけから起動前に計算\n\n", .{});
        try w.print("{s: <20} {s: <7} {s: <24} {s: <16} {s: <11} {s}\n", .{ "NODE", "KIND", "CELL", "REACHES SINK", "READS PII", "IF DOWN, ALSO STOPS" });
        try w.print("{s: <20} {s: <7} {s: <24} {s: <16} {s: <11} {s}\n", .{ "----", "----", "----", "------------", "---------", "-------------------" });
        for (nodes.items) |n| {
            const report = try blast.computeBlast(arena, nodes.items, n.name);
            var reads_pii = false;
            for (report.readable) |r| {
                if (blast.classify(r.topic) == .pii) reads_pii = true;
            }
            const f = try blast.computeFailure(arena, nodes.items, n.name);
            var stops: std.ArrayListUnmanaged(u8) = .{};
            for (f.stalled, 0..) |s, k| {
                if (k > 0) try stops.appendSlice(arena, ", ");
                try stops.appendSlice(arena, s);
            }
            for (f.cell_mates) |m| {
                if (stops.items.len > 0) try stops.appendSlice(arena, ", ");
                try stops.appendSlice(arena, try std.fmt.allocPrint(arena, "{s} (delayed, same cell)", .{m}));
            }
            try w.print("{s: <20} {s: <7} {s: <24} {s: <16} {s: <11} {s}\n", .{
                n.name,
                n.kind,
                n.cell,
                if (report.reachable_sinks.len > 0) "YES (!)" else "no",
                if (reads_pii) "YES (!)" else "no",
                if (stops.items.len == 0) "(nothing)" else stops.items,
            });
        }
        try w.print("\n詳細: `weave-audit <node>` (侵害時) / `weave-audit --failure <node>` (障害時)\n\n", .{});
    }
    try w.flush();
}

fn notFound(err: anyerror, t: []const u8, nodes: []const blast.Node) !void {
    if (err != error.NodeNotFound) return err;
    std.debug.print("error: node '{s}' not found. Known nodes:\n", .{t});
    for (nodes) |n| std.debug.print("  - {s}\n", .{n.name});
    std.process.exit(1);
}

fn printUsage() void {
    std.debug.print(
        \\weave-audit — 影響範囲の監査 (ADR-008 / R9)
        \\
        \\Usage:
        \\  weave-audit                        全ノードの要約
        \\  weave-audit <node>                 侵害されたら何ができるか
        \\  weave-audit --failure <node>       落ちたらどこまで止まるか
        \\  weave-audit --manifests <paths...> 監査対象を明示 (既定: wasm-apps/*.json)
        \\
    , .{});
}

test {
    _ = blast;
}
