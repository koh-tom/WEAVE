//! プラグインのセル (weave-cell plugin) を OS の機能で閉じ込める (ADR-010 段階 3)。
//!
//! Wasm にはもともとファイルもネットワークも無い。ここで塞ぐのは「WAMR (インタプリタ) 自体に穴があった場合」で、
//! そのときに子プロセスが OS に対してできることを最小にする二重の柵:
//!   - seccomp-bpf: 読み込みが終わった後に必要なシステムコールだけを許し、それ以外 (open・socket・execve・
//!     ptrace など) を呼んだらプロセスを即座に終わらせる (SIGSYS)。Core はそれを「子が落ちた」として扱う
//!   - 名前空間: user + network を分ける。新しいネットワーク名前空間にはループバックすら無いので外に出られない。
//!     Core との UNIX ソケットは分ける前に開いてあるので使い続けられる
//! Linux x86_64 のみ。他では何もしない (Level 1 と同じ隔離になる)。
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

/// 読み込み後の子プロセスが使ってよいシステムコール。これ以外は SECCOMP_RET_KILL_PROCESS
const allowed = if (builtin.cpu.arch == .x86_64) [_]linux.SYS{
    // ソケット (Core との UNIX ソケット) の読み書き
    .read,    .write,           .readv,           .writev,            .recvfrom,     .sendto,
    .recvmsg, .sendmsg,         .poll,            .ppoll,             .shutdown,     .close,
    // メモリ (アロケータ・WAMR の線形メモリ)
    .mmap,    .munmap,          .mprotect,        .madvise,           .mremap,       .brk,
    // スレッドの同期・時刻
    .futex,   .clock_gettime,   .clock_nanosleep, .nanosleep,         .sched_yield,  .gettid,
    .getpid,  .restart_syscall, .getrandom,
    // smp_allocator が CPU 数を知るため (自分の CPU 割り当てを読むだけ)
          .sched_getaffinity,
    // シグナルと終了
    .rt_sigreturn, .rt_sigprocmask,
    .exit,    .exit_group,
} else [_]linux.SYS{};

const SockFilter = extern struct { code: u16, jt: u8, jf: u8, k: u32 };
const SockFprog = extern struct { len: u16, filter: [*]const SockFilter };

// BPF 命令
const BPF_LD_W_ABS: u16 = 0x00 | 0x00 | 0x20; // BPF_LD | BPF_W | BPF_ABS
const BPF_JEQ_K: u16 = 0x05 | 0x10 | 0x00; // BPF_JMP | BPF_JEQ | BPF_K
const BPF_RET_K: u16 = 0x06 | 0x00; // BPF_RET | BPF_K
const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;
const SECCOMP_RET_TRAP: u32 = 0x00030000;
const SECCOMP_RET_ALLOW: u32 = 0x7fff0000;
const AUDIT_ARCH_X86_64: u32 = 0xc000003e;
const OFF_NR = 0; // struct seccomp_data.nr
const OFF_ARCH = 4; // struct seccomp_data.arch

const FILTER_LEN = allowed.len + 6;

/// [0] arch を読む  [1] x86_64 なら 1 つ飛ばす  [2] KILL
/// [3] 番号を読む   [4 .. 4+n) 許可リストと比較 (一致したら ALLOW へ)  [4+n] KILL  [5+n] ALLOW
fn buildFilter() [FILTER_LEN]SockFilter {
    return buildFilterWith(SECCOMP_RET_KILL_PROCESS);
}

fn buildFilterWith(deny: u32) [FILTER_LEN]SockFilter {
    var f: [FILTER_LEN]SockFilter = undefined;
    const n = allowed.len;
    f[0] = .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = OFF_ARCH };
    f[1] = .{ .code = BPF_JEQ_K, .jt = 1, .jf = 0, .k = AUDIT_ARCH_X86_64 };
    f[2] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = deny };
    f[3] = .{ .code = BPF_LD_W_ABS, .jt = 0, .jf = 0, .k = OFF_NR };
    for (allowed, 0..) |sys, i| {
        // 次に実行される命令 = pc + 1 + jt。ALLOW は 5+n にある
        f[4 + i] = .{ .code = BPF_JEQ_K, .jt = @intCast(n - i), .jf = 0, .k = @intCast(@intFromEnum(sys)) };
    }
    f[4 + n] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = deny };
    f[5 + n] = .{ .code = BPF_RET_K, .jt = 0, .jf = 0, .k = SECCOMP_RET_ALLOW };
    return f;
}

pub const Supported = builtin.os.tag == .linux and builtin.cpu.arch == .x86_64;

/// seccomp の許可リストを掛ける。以後、許可していないシステムコールを呼ぶとプロセスが終わる。
/// 新しいスレッドは作れなくなるので、スレッドは全て作り終えてから呼ぶこと
pub fn applySeccomp() !void {
    if (!Supported) return error.Unsupported;
    // 調査用: WEAVE_CELL_SECCOMP_DEBUG=1 なら殺す代わりに SIGSYS を送り、違反したシステムコールの番号を出して終わる
    const debug = std.process.hasEnvVarConstant("WEAVE_CELL_SECCOMP_DEBUG");
    if (debug) {
        var act = linux.Sigaction{ .handler = .{ .sigaction = onSigsys }, .mask = linux.sigemptyset(), .flags = linux.SA.SIGINFO };
        _ = linux.sigaction(linux.SIG.SYS, &act, null);
    }
    const filter = if (debug) buildFilterWith(SECCOMP_RET_TRAP) else buildFilter();
    const prog = SockFprog{ .len = FILTER_LEN, .filter = &filter };
    // 特権を得る手段 (setuid 実行ファイル) を封じる。これが無いと非特権で seccomp を掛けられない
    if (linux.E.init(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0)) != .SUCCESS) return error.NoNewPrivsFailed;
    const SECCOMP_SET_MODE_FILTER = 1;
    const SECCOMP_FILTER_FLAG_TSYNC = 1; // 全スレッドに同時に掛ける
    const rc = linux.syscall3(.seccomp, SECCOMP_SET_MODE_FILTER, SECCOMP_FILTER_FLAG_TSYNC, @intFromPtr(&prog));
    if (linux.E.init(rc) != .SUCCESS) return error.SeccompFailed;
}

fn onSigsys(_: i32, info: *const linux.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // siginfo の _sigsys._syscall (x86_64 ではオフセット 24 の i32)
    const bytes: [*]const u8 = @ptrCast(info);
    const nr = std.mem.readInt(i32, bytes[24..28], .little);
    var buf: [64]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "seccomp: blocked syscall {d}\n", .{nr}) catch "seccomp: blocked\n";
    _ = linux.write(2, msg.ptr, msg.len);
    linux.exit_group(159);
}

/// user + network 名前空間に移る (外に出るネットワークを持たなくなる)。既に開いているソケットはそのまま使える。
/// 非特権ユーザー名前空間が無効な環境では失敗するので、呼ぶ側はログに残して続ける
pub fn unshareNetwork() !void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const flags = linux.CLONE.NEWUSER | linux.CLONE.NEWNET;
    if (linux.E.init(linux.unshare(flags)) != .SUCCESS) return error.UnshareFailed;
}

test "seccomp filter: every allowed syscall jumps to ALLOW, the rest fall through to KILL" {
    if (!Supported) return error.SkipZigTest;
    const f = buildFilter();
    const n = allowed.len;
    try std.testing.expectEqual(SECCOMP_RET_ALLOW, f[5 + n].k);
    try std.testing.expectEqual(SECCOMP_RET_KILL_PROCESS, f[4 + n].k);
    for (0..n) |i| {
        const target = 4 + i + 1 + f[4 + i].jt;
        try std.testing.expectEqual(@as(usize, 5 + n), target);
    }
    // 危険なものは許可リストに無い
    for ([_]linux.SYS{ .open, .openat, .socket, .connect, .execve, .ptrace, .clone, .fork, .kill }) |bad| {
        for (allowed) |a| try std.testing.expect(a != bad);
    }
}
