//! `weave-audit` — Blast Radius 監査 CLI
//!
//! 使い方:
//!   weave-audit                         全ノードの影響範囲を要約
//!   weave-audit <node-name>             指定ノードの詳細 blast radius
//!   weave-audit --manifests a.json b.json ...   監査対象の manifest を明示
//!
//! manifest を明示しない場合は wasm-apps/ の既定セットを走査する。
//! builtin (TwitchAdapter / ObsEgress) は常に含める。

const std = @import("std");
const blast = @import("audit/blast.zig");

const default_manifests = [_][]const u8{
    "wasm-apps/kusa_node.json",
    "wasm-apps/chat_node.json",
    "wasm-apps/bad_node.json",
    "wasm-apps/scene_switcher.json",
    "wasm-apps/malicious_plugin.json",
};

pub fn main() !void {
    var arena_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const args = try std.process.argsAlloc(arena);

    var target: ?[]const u8 = null;
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
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            target = arg;
        }
    }

    if (manifest_paths.items.len == 0) {
        for (default_manifests) |p| try manifest_paths.append(arena, p);
    }

    // ノード収集: builtin + manifest
    var nodes = std.ArrayListUnmanaged(blast.Node){};
    const builtins = try blast.builtinNodes(arena);
    for (builtins) |b| try nodes.append(arena, b);

    for (manifest_paths.items) |path| {
        const node = blast.loadManifestNode(arena, path) catch |err| {
            std.debug.print("warn: skip {s}: {any}\n", .{ path, err });
            continue;
        };
        try nodes.append(arena, node);
    }

    var stdout_buf: [1]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const w = &stdout_writer.interface;

    if (target) |t| {
        const report = blast.computeBlast(arena, nodes.items, t) catch |err| {
            if (err == error.NodeNotFound) {
                std.debug.print("error: node '{s}' not found. Known nodes:\n", .{t});
                for (nodes.items) |n| std.debug.print("  - {s}\n", .{n.name});
                return;
            }
            return err;
        };
        try blast.printReport(w, report);
    } else {
        // 要約: 全ノードについて「シンク到達可否」「PII 読取可否」を一覧
        try w.print("\n=== WEAVE Blast Radius Summary ({d} nodes) ===\n\n", .{nodes.items.len});
        try w.print("{s: <24} {s: <8} {s: <14} {s}\n", .{ "NODE", "KIND", "REAL-WORLD", "READS PII?" });
        try w.print("{s: <24} {s: <8} {s: <14} {s}\n", .{ "----", "----", "----------", "----------" });
        for (nodes.items) |n| {
            const report = try blast.computeBlast(arena, nodes.items, n.name);
            const reaches_sink = report.reachable_sinks.len > 0;
            var reads_pii = false;
            for (report.readable) |r| {
                if (blast.classify(r.topic) == .pii) reads_pii = true;
            }
            try w.print("{s: <24} {s: <8} {s: <14} {s}\n", .{
                n.name,
                n.kind,
                if (reaches_sink) "YES (⚠)" else "no",
                if (reads_pii) "YES (⚠)" else "no",
            });
        }
        try w.print("\n(詳細は `weave-audit <node-name>` で表示)\n\n", .{});
    }
    try w.flush();
}

fn printUsage() void {
    std.debug.print(
        \\weave-audit — Blast Radius 監査 (ADR-008)
        \\
        \\Usage:
        \\  weave-audit                    全ノードの影響範囲を要約
        \\  weave-audit <node-name>        指定ノードの詳細
        \\  weave-audit --manifests <paths...>   監査対象を明示
        \\
    , .{});
}
