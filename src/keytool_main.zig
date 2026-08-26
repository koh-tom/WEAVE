//! `weave-key` — Ed25519 鍵管理 / プラグイン署名 CLI (トラストアンカー Stage 1)
//!
//! Usage:
//!   weave-key generate <name>
//!       <name>.key (秘密鍵 hex) と <name>.pub (公開鍵 hex) を生成
//!   weave-key sign <name>.key <plugin.wasm> <plugin.json>
//!       wasm + manifest に対する署名を <plugin.wasm>.sig に出力
//!   weave-key verify <name>.pub <plugin.wasm> <plugin.json> [<plugin.wasm>.sig]
//!       署名を検証 (sig 省略時は <plugin.wasm>.sig を使う)
//!
//! 署名は wasm と manifest の両方を束縛する (manifest 差し替え攻撃を防ぐ)。

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const signing = @import("security/signing.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "generate")) {
        if (args.len < 3) return usageErr("generate <name>");
        try cmdGenerate(allocator, args[2]);
    } else if (std.mem.eql(u8, cmd, "sign")) {
        if (args.len < 5) return usageErr("sign <name>.key <plugin.wasm> <plugin.json>");
        try cmdSign(allocator, args[2], args[3], args[4]);
    } else if (std.mem.eql(u8, cmd, "verify")) {
        if (args.len < 5) return usageErr("verify <name>.pub <plugin.wasm> <plugin.json> [sig]");
        const sig_path = if (args.len >= 6) args[5] else null;
        try cmdVerify(allocator, args[2], args[3], args[4], sig_path);
    } else {
        printUsage();
    }
}

fn cmdGenerate(allocator: std.mem.Allocator, name: []const u8) !void {
    const kp = Ed25519.KeyPair.generate();
    const sk = kp.secret_key.toBytes();
    const pk = kp.public_key.toBytes();

    const sk_hex = try signing.toHex(allocator, &sk);
    defer allocator.free(sk_hex);
    const pk_hex = try signing.toHex(allocator, &pk);
    defer allocator.free(pk_hex);

    const key_path = try std.fmt.allocPrint(allocator, "{s}.key", .{name});
    defer allocator.free(key_path);
    const pub_path = try std.fmt.allocPrint(allocator, "{s}.pub", .{name});
    defer allocator.free(pub_path);

    try writeFile(key_path, sk_hex);
    try writeFile(pub_path, pk_hex);

    std.debug.print("生成しました:\n  秘密鍵: {s}  (絶対に配布しないこと)\n  公開鍵: {s}\n\n公開鍵 (trust store に登録する値):\n{s}\n", .{ key_path, pub_path, pk_hex });
}

fn cmdSign(allocator: std.mem.Allocator, key_path: []const u8, wasm_path: []const u8, manifest_path: []const u8) !void {
    const sk_hex = try std.fs.cwd().readFileAlloc(allocator, key_path, 4096);
    defer allocator.free(sk_hex);
    const sk_bytes = signing.fromHex(64, std.mem.trim(u8, sk_hex, " \t\r\n")) orelse {
        std.debug.print("error: {s} の秘密鍵 hex が不正\n", .{key_path});
        return;
    };
    const sk = try Ed25519.SecretKey.fromBytes(sk_bytes);
    const kp = try Ed25519.KeyPair.fromSecretKey(sk);

    const wasm = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 16 * 1024 * 1024);
    defer allocator.free(wasm);
    const manifest = try std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(manifest);

    const sig = try signing.sign(kp, wasm, manifest);
    const sig_hex = try signing.toHex(allocator, &sig);
    defer allocator.free(sig_hex);

    const sig_path = try std.fmt.allocPrint(allocator, "{s}.sig", .{wasm_path});
    defer allocator.free(sig_path);
    try writeFile(sig_path, sig_hex);

    std.debug.print("署名しました: {s}\n(署名対象: wasm={d}B + manifest={d}B)\n", .{ sig_path, wasm.len, manifest.len });
}

fn cmdVerify(allocator: std.mem.Allocator, pub_path: []const u8, wasm_path: []const u8, manifest_path: []const u8, sig_path_opt: ?[]const u8) !void {
    const pk_hex = try std.fs.cwd().readFileAlloc(allocator, pub_path, 4096);
    defer allocator.free(pk_hex);
    const pk_bytes = signing.fromHex(32, std.mem.trim(u8, pk_hex, " \t\r\n")) orelse {
        std.debug.print("error: {s} の公開鍵 hex が不正\n", .{pub_path});
        return;
    };

    const sig_path = if (sig_path_opt) |p|
        try allocator.dupe(u8, p)
    else
        try std.fmt.allocPrint(allocator, "{s}.sig", .{wasm_path});
    defer allocator.free(sig_path);

    const sig_hex = try std.fs.cwd().readFileAlloc(allocator, sig_path, 4096);
    defer allocator.free(sig_hex);
    const sig_bytes = signing.fromHex(64, std.mem.trim(u8, sig_hex, " \t\r\n")) orelse {
        std.debug.print("error: {s} の署名 hex が不正\n", .{sig_path});
        return;
    };

    const wasm = try std.fs.cwd().readFileAlloc(allocator, wasm_path, 16 * 1024 * 1024);
    defer allocator.free(wasm);
    const manifest = try std.fs.cwd().readFileAlloc(allocator, manifest_path, 1024 * 1024);
    defer allocator.free(manifest);

    signing.verify(pk_bytes, sig_bytes, wasm, manifest) catch {
        std.debug.print("❌ 検証失敗: 署名が一致しません (改ざん or 別の鍵)\n", .{});
        std.process.exit(1);
    };
    std.debug.print("✅ 検証成功: {s} は正規の署名者によるもので、wasm と manifest は改ざんされていません\n", .{wasm_path});
}

fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn usageErr(usage: []const u8) !void {
    std.debug.print("Usage: weave-key {s}\n", .{usage});
    std.process.exit(2);
}

fn printUsage() void {
    std.debug.print(
        \\weave-key — Ed25519 鍵管理 / プラグイン署名 (トラストアンカー Stage 1)
        \\
        \\Usage:
        \\  weave-key generate <name>
        \\  weave-key sign    <name>.key <plugin.wasm> <plugin.json>
        \\  weave-key verify  <name>.pub <plugin.wasm> <plugin.json> [sig]
        \\
        \\署名は wasm と manifest の両方を束縛する (権限宣言の差し替えを防ぐ)。
        \\
    , .{});
}
