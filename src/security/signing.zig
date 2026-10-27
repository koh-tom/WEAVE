//! Ed25519 署名 — トラストアンカー Stage 1 (ADR-008 §3 / dev_policy §1.3)
//!
//! トラストアンカーの段階:
//!   Stage 0 : ローカルユーザーの承認 (TOFU) — 署名なしでも load 時に承認を要求 (security/approval.zig, weave add)
//!   Stage 1 : 開発者 Ed25519 署名 (本モジュール)
//!   Stage 2 : Registry 鍵をルートにした検証チェーン (将来)
//!
//! 【設計上の要点】署名対象に **manifest を必ず含める**。
//! バイナリだけ署名して manifest (= 権限宣言) が差し替え可能では、
//! 「署名済みだから安全」が成立しない。本実装は
//!   digest = SHA-512( "WEAVE-SIG-v1\n" || len(wasm) || wasm || len(manifest) || manifest )
//! を署名対象とし、コードと権限宣言をアトミックに束縛する。

const std = @import("std");
const Ed25519 = std.crypto.sign.Ed25519;
const Sha512 = std.crypto.hash.sha2.Sha512;

pub const DOMAIN = "WEAVE-SIG-v1\n";

pub const SigningError = error{
    InvalidPublicKeyHex,
    InvalidSecretKeyHex,
    InvalidSignatureHex,
    SignatureMismatch,
    UntrustedSigner,
};

/// 署名対象ダイジェストを計算する。wasm と manifest を長さ前置きで連結し、
/// ドメイン分離タグを付けて SHA-512 に通す (長さ拡張・境界混同を防止)。
pub fn computeDigest(wasm: []const u8, manifest: []const u8) [64]u8 {
    var h = Sha512.init(.{});
    h.update(DOMAIN);
    var len_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &len_buf, wasm.len, .little);
    h.update(&len_buf);
    h.update(wasm);
    std.mem.writeInt(u64, &len_buf, manifest.len, .little);
    h.update(&len_buf);
    h.update(manifest);
    var out: [64]u8 = undefined;
    h.final(&out);
    return out;
}

/// wasm + manifest に対する署名を生成し、生の 64 バイト署名を返す。
pub fn sign(kp: Ed25519.KeyPair, wasm: []const u8, manifest: []const u8) ![64]u8 {
    const digest = computeDigest(wasm, manifest);
    const sig = try kp.sign(&digest, null);
    return sig.toBytes();
}

/// 署名を検証する。pubkey/署名は生バイト。
pub fn verify(pubkey_bytes: [32]u8, sig_bytes: [64]u8, wasm: []const u8, manifest: []const u8) SigningError!void {
    const digest = computeDigest(wasm, manifest);
    const pk = Ed25519.PublicKey.fromBytes(pubkey_bytes) catch return SigningError.SignatureMismatch;
    const sig = Ed25519.Signature.fromBytes(sig_bytes);
    sig.verify(&digest, pk) catch return SigningError.SignatureMismatch;
}

// ---- hex エンコード/デコード (鍵・署名のファイル保存用) ----

pub fn toHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = try allocator.alloc(u8, bytes.len * 2);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        hex[i * 2] = charset[b >> 4];
        hex[i * 2 + 1] = charset[b & 0xf];
    }
    return hex;
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

/// hex 文字列を固定長バイト列にデコードする。空白/改行は無視。
pub fn fromHex(comptime n: usize, hex: []const u8) ?[n]u8 {
    var out: [n]u8 = undefined;
    var oi: usize = 0;
    var hi: ?u8 = null;
    for (hex) |c| {
        if (c == ' ' or c == '\n' or c == '\r' or c == '\t') continue;
        const nib = hexNibble(c) orelse return null;
        if (hi) |h| {
            if (oi >= n) return null;
            out[oi] = (h << 4) | nib;
            oi += 1;
            hi = null;
        } else {
            hi = nib;
        }
    }
    if (hi != null or oi != n) return null;
    return out;
}

// ---- トラストストア: 信頼する公開鍵の集合 ----

pub const VerifyMode = enum {
    off, // 検証しない (署名がなくても load)
    warn, // 検証するが、失敗しても警告のみで load (development 既定)
    strict, // 検証失敗・署名なし・未知の署名者は load 拒否 (production 既定)

    /// 未知の文字列は null (呼び出し側で起動を拒否する)。
    /// 以前は typo が黙って warn になり、strict のつもりで未署名プラグインが動いていた。
    pub fn parse(s: []const u8) ?VerifyMode {
        return std.meta.stringToEnum(VerifyMode, s);
    }

    pub fn fromString(s: []const u8) VerifyMode {
        return parse(s) orelse .warn;
    }
};

/// 信頼する公開鍵リスト (hex 1 行 1 鍵のファイルから読む想定)。
pub const TrustStore = struct {
    keys: std.ArrayListUnmanaged([32]u8) = .{},

    pub fn deinit(self: *TrustStore, allocator: std.mem.Allocator) void {
        self.keys.deinit(allocator);
    }

    pub fn add(self: *TrustStore, allocator: std.mem.Allocator, pubkey: [32]u8) !void {
        try self.keys.append(allocator, pubkey);
    }

    pub fn isTrusted(self: *const TrustStore, pubkey: [32]u8) bool {
        for (self.keys.items) |k| {
            if (std.mem.eql(u8, &k, &pubkey)) return true;
        }
        return false;
    }

    /// 信頼する公開鍵のいずれかで署名が検証できれば true。
    /// (署名者を明示しないため、trust store の各鍵で試行する)
    pub fn verifyAny(self: *const TrustStore, sig_bytes: [64]u8, wasm: []const u8, manifest: []const u8) bool {
        for (self.keys.items) |k| {
            if (verify(k, sig_bytes, wasm, manifest)) |_| {
                return true;
            } else |_| {}
        }
        return false;
    }

    pub fn isEmpty(self: *const TrustStore) bool {
        return self.keys.items.len == 0;
    }

    /// hex 公開鍵を 1 行ずつ並べたファイルを読み込む (`#` 始まりはコメント)。
    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !TrustStore {
        var store = TrustStore{};
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return store;
            return err;
        };
        defer allocator.free(content);
        var it = std.mem.splitScalar(u8, content, '\n');
        while (it.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;
            const key = fromHex(32, trimmed) orelse continue;
            try store.add(allocator, key);
        }
        return store;
    }
};

// ============================================================
// Tests
// ============================================================

test "sign and verify roundtrip" {
    const kp = Ed25519.KeyPair.generate();
    const wasm = "\x00asm fake binary contents";
    const manifest = "{\"name\":\"kusa_node\",\"permissions\":{}}";

    const sig = try sign(kp, wasm, manifest);
    try verify(kp.public_key.toBytes(), sig, wasm, manifest);
}

test "tampered manifest fails verification (manifest is bound to signature)" {
    const kp = Ed25519.KeyPair.generate();
    const wasm = "\x00asm fake binary contents";
    const manifest_good = "{\"permissions\":{\"publish\":[\"core.obs.request.*\"]}}";
    const manifest_evil = "{\"permissions\":{\"publish\":[\"#\"]}}"; // 権限を全開に差し替え

    const sig = try sign(kp, wasm, manifest_good);
    // バイナリは同一でも manifest を差し替えると検証は失敗する
    try std.testing.expectError(SigningError.SignatureMismatch, verify(kp.public_key.toBytes(), sig, wasm, manifest_evil));
}

test "tampered wasm fails verification" {
    const kp = Ed25519.KeyPair.generate();
    const manifest = "{\"name\":\"x\"}";
    const sig = try sign(kp, "original wasm", manifest);
    try std.testing.expectError(SigningError.SignatureMismatch, verify(kp.public_key.toBytes(), sig, "modified wasm", manifest));
}

test "wrong key fails verification" {
    const kp = Ed25519.KeyPair.generate();
    const other = Ed25519.KeyPair.generate();
    const sig = try sign(kp, "w", "m");
    try std.testing.expectError(SigningError.SignatureMismatch, verify(other.public_key.toBytes(), sig, "w", "m"));
}

test "hex roundtrip" {
    const allocator = std.testing.allocator;
    const kp = Ed25519.KeyPair.generate();
    const pk = kp.public_key.toBytes();
    const hex = try toHex(allocator, &pk);
    defer allocator.free(hex);
    const decoded = fromHex(32, hex).?;
    try std.testing.expectEqualSlices(u8, &pk, &decoded);
}

test "trust store membership" {
    const allocator = std.testing.allocator;
    var store = TrustStore{};
    defer store.deinit(allocator);
    const kp = Ed25519.KeyPair.generate();
    const other = Ed25519.KeyPair.generate();
    try store.add(allocator, kp.public_key.toBytes());
    try std.testing.expect(store.isTrusted(kp.public_key.toBytes()));
    try std.testing.expect(!store.isTrusted(other.public_key.toBytes()));
}

test "trust store verifyAny: trusted signer accepted, others rejected" {
    const allocator = std.testing.allocator;
    const signer = Ed25519.KeyPair.generate();
    const untrusted = Ed25519.KeyPair.generate();
    const wasm = "\x00asm plugin body";
    const manifest = "{\"permissions\":{\"publish\":[\"core.obs.request.*\"]}}";

    var store = TrustStore{};
    defer store.deinit(allocator);
    try store.add(allocator, signer.public_key.toBytes());

    // 信頼された鍵で署名 → 受理
    const good_sig = try sign(signer, wasm, manifest);
    try std.testing.expect(store.verifyAny(good_sig, wasm, manifest));

    // 信頼されていない鍵で署名 → 拒否
    const bad_sig = try sign(untrusted, wasm, manifest);
    try std.testing.expect(!store.verifyAny(bad_sig, wasm, manifest));

    // 正規署名でも manifest 改ざん → 拒否
    try std.testing.expect(!store.verifyAny(good_sig, wasm, "{\"permissions\":{\"publish\":[\"#\"]}}"));

    // 空の trust store → 常に拒否
    var empty = TrustStore{};
    defer empty.deinit(allocator);
    try std.testing.expect(!empty.verifyAny(good_sig, wasm, manifest));
    try std.testing.expect(empty.isEmpty());
}
