const std = @import("std");

fn ensureWrapperFile(path: []const u8, content: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    };
}

pub fn build(b: *std.Build) void {
    ensureWrapperFile("src/bus_test_wrapper.zig", "const test_mod = @import(\"tests/bus_test.zig\");\npub fn main() !void {\n    return test_mod.main();\n}\n") catch {};
    ensureWrapperFile("src/stress_test_wrapper.zig", "const test_mod = @import(\"tests/stress_test.zig\");\npub fn main() !void {\n    return test_mod.main();\n}\n") catch {};

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Wasmターゲットの設定
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
    });

    // 共通モジュールの定義 (Host/Wasmで共有)
    const common_module = b.createModule(.{
        .root_source_file = b.path("src/common/types.zig"),
    });

    // Wasm SDKモジュールの定義
    const sdk_module = b.createModule(.{
        .root_source_file = b.path("wasm-apps/plugin_sdk.zig"),
    });
    sdk_module.addImport("common", common_module);

    const wamr_dir = "deps/wasm-micro-runtime";

    // WAMRのインクルードパス (共通)
    const wamr_include_paths = &[_][]const u8{
        "core/iwasm/include",
        "core/iwasm/common",
        "core/iwasm/interpreter",
        "core/shared/utils",
        "core/shared/platform/linux",
        "core/shared/platform/common/posix",
        "core/shared/platform/common/libc-util",
        "core/shared/platform/include",
        "core/shared/mem-alloc",
        "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src",
    };

    // WAMRの定義 (共通)
    const wamr_defines = &.{
        "-D_GNU_SOURCE",
        "-DBH_PLATFORM_LINUX",
        "-DWASM_ENABLE_INTERP=1",
        "-DWASM_ENABLE_AOT=0",
        "-DWASM_ENABLE_LIBC_BUILTIN=0",
        "-DWASM_ENABLE_LIBC_WASI=0",
        "-DWASM_ENABLE_FAST_INTERP=1",
        // 命令数上限 (P0-1): 無限ループするプラグインを trap させ、既存の fault/再起動経路に乗せる
        "-DWASM_ENABLE_INSTRUCTION_METERING=1",
        "-DBH_MALLOC=wasm_runtime_malloc",
        "-DBH_FREE=wasm_runtime_free",
        "-DWASM_HAVE_MREMAP=1",
        "-fno-sanitize=alignment",
    };

    // WAMRのソースファイル (共通)
    const wamr_sources = &[_][]const u8{
        "core/iwasm/common/wasm_application.c",
        "core/iwasm/common/wasm_runtime_common.c",
        "core/iwasm/common/wasm_native.c",
        "core/iwasm/common/wasm_exec_env.c",
        "core/iwasm/common/wasm_memory.c",
        "core/iwasm/common/wasm_loader_common.c",
        "core/iwasm/interpreter/wasm_interp_fast.c",
        "core/iwasm/interpreter/wasm_runtime.c",
        "core/iwasm/interpreter/wasm_loader.c",
        "core/shared/platform/linux/platform_init.c",
        "core/shared/platform/common/posix/posix_thread.c",
        "core/shared/platform/common/posix/posix_time.c",
        "core/shared/platform/common/posix/posix_memmap.c",
        "core/shared/platform/common/posix/posix_sleep.c",
        "core/shared/platform/common/posix/posix_malloc.c",
        "core/shared/platform/common/posix/posix_blocking_op.c",
        "core/shared/platform/common/posix/posix_clock.c",
        "core/shared/platform/common/libc-util/libc_errno.c",
        "core/shared/mem-alloc/mem_alloc.c",
        "core/shared/mem-alloc/ems/ems_alloc.c",
        "core/shared/mem-alloc/ems/ems_gc.c",
        "core/shared/mem-alloc/ems/ems_kfc.c",
        "core/shared/mem-alloc/ems/ems_hmu.c",
        "core/shared/utils/bh_common.c",
        "core/shared/utils/bh_list.c",
        "core/shared/utils/bh_log.c",
        "core/shared/utils/bh_queue.c",
        "core/shared/utils/bh_vector.c",
        "core/shared/utils/bh_leb128.c",
        "core/shared/utils/runtime_timer.c",
        "core/shared/utils/uncommon/bh_read_file.c",
        "core/iwasm/common/arch/invokeNative_em64.s",
        "core/iwasm/common/wasm_c_api.c",
    };

    // --- ヘルパー: WAMR設定を実行ファイルに適用 ---
    const addWamrDeps = struct {
        fn apply(bb: *std.Build, exe_target: *std.Build.Step.Compile, dir: []const u8, includes: []const []const u8, sources: []const []const u8, defines: anytype) void {
            for (includes) |inc| {
                exe_target.addIncludePath(bb.path(std.fs.path.join(bb.allocator, &.{ dir, inc }) catch unreachable));
            }
            for (sources) |src| {
                exe_target.addCSourceFile(.{
                    .file = bb.path(bb.fmt("{s}/{s}", .{ dir, src })),
                    .flags = defines,
                });
            }
            exe_target.linkLibC();
            exe_target.linkSystemLibrary("m");
            exe_target.linkSystemLibrary("dl");
            exe_target.linkSystemLibrary("pthread");
            exe_target.linkSystemLibrary("rt");
        }
    }.apply;

    // --- Main Executable ---
    // (zap / facil.io への依存は廃止。Dashboard は自前の HTTP + WebSocket 実装)

    const exe = b.addExecutable(.{
        .name = "WEAVE",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("common", common_module);
    // Workaround: omarchyOS (GCC 16 / glibc 2.43+) の .sframe セクションに
    // Zig のセルフホストリンカーが未対応のため、LLVM/LLD を使用する
    exe.use_llvm = true;
    exe.use_lld = true;

    addWamrDeps(b, exe, wamr_dir, wamr_include_paths, wamr_sources, wamr_defines);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // --- Stress Test Step ---
    const stress_exe = b.addExecutable(.{
        .name = "stress_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stress_test_wrapper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    stress_exe.root_module.addImport("common", common_module);
    stress_exe.use_llvm = true;
    stress_exe.use_lld = true;
    addWamrDeps(b, stress_exe, wamr_dir, wamr_include_paths, wamr_sources, wamr_defines);

    const run_stress_cmd = b.addRunArtifact(stress_exe);
    const stress_step = b.step("stress", "Run memory stress test (Phase 2.1)");
    stress_step.dependOn(&run_stress_cmd.step);

    // --- Blast Radius Audit CLI (ADR-008, pure Zig / WAMR 非依存) ---
    const audit_exe = b.addExecutable(.{
        .name = "weave-audit",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audit_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    audit_exe.use_llvm = true;
    audit_exe.use_lld = true;
    b.installArtifact(audit_exe);

    const run_audit = b.addRunArtifact(audit_exe);
    if (b.args) |args| run_audit.addArgs(args);
    const audit_step = b.step("audit", "Run blast-radius audit CLI");
    audit_step.dependOn(&run_audit.step);

    const audit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/audit_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_audit_tests = b.addRunArtifact(audit_tests);

    // --- Ed25519 署名 CLI (weave-key, トラストアンカー Stage 1, 純 Zig) ---
    const keytool_exe = b.addExecutable(.{
        .name = "weave-key",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/keytool_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    keytool_exe.use_llvm = true;
    keytool_exe.use_lld = true;
    b.installArtifact(keytool_exe);

    const run_keytool = b.addRunArtifact(keytool_exe);
    if (b.args) |args| run_keytool.addArgs(args);
    const keytool_step = b.step("key", "Run Ed25519 key/sign CLI");
    keytool_step.dependOn(&run_keytool.step);

    const signing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/security/signing.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_signing_tests = b.addRunArtifact(signing_tests);

    // --- 統合 CLI (weave run / up / audit / key / topic / node / doctor / init) ---
    const cli_exe = b.addExecutable(.{
        .name = "weave",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cli_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cli_exe.root_module.addImport("common", common_module);
    cli_exe.use_llvm = true;
    cli_exe.use_lld = true;
    b.installArtifact(cli_exe);

    // --- 別プロセスのセル (ADR-010 Level 2 段階 1: egress) ---
    const cell_exe = b.addExecutable(.{
        .name = "weave-cell",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/cell_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    cell_exe.root_module.addImport("common", common_module);
    cell_exe.use_llvm = true;
    cell_exe.use_lld = true;
    // プラグインのセル (段階 2) は子の中で WAMR を動かす
    addWamrDeps(b, cell_exe, wamr_dir, wamr_include_paths, wamr_sources, wamr_defines);
    b.installArtifact(cell_exe);

    // --- 既存ツール (Streamer.bot) とのブリッジ (互換戦略 C) ---
    const bridge_exe = b.addExecutable(.{
        .name = "weave-bridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bridge_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bridge_exe.root_module.addImport("common", common_module);
    bridge_exe.use_llvm = true;
    bridge_exe.use_lld = true;
    b.installArtifact(bridge_exe);
    const bridge_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/bridge_main.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    bridge_tests.root_module.addImport("common", common_module);
    const run_bridge_tests = b.addRunArtifact(bridge_tests);

    // --- OBS WebSocket v5 シミュレータ (実物の OBS が無い環境でのデモ・e2e 用) ---
    const obs_sim_exe = b.addExecutable(.{
        .name = "weave-obs-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/obs_sim_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    obs_sim_exe.root_module.addImport("common", common_module);
    obs_sim_exe.use_llvm = true;
    obs_sim_exe.use_lld = true;
    b.installArtifact(obs_sim_exe);

    // --- 中央バス オーバーヘッド ベンチ (ADR-006, WAMR 非依存) ---
    const bench_exe = b.addExecutable(.{
        .name = "bus_bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_exe.root_module.addImport("common", common_module);
    bench_exe.use_llvm = true;
    bench_exe.use_lld = true;
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run central-bus overhead benchmark");
    bench_step.dependOn(&run_bench.step);

    // --- Pure Zig EventBus Test ---
    const bus_test_exe = b.addExecutable(.{
        .name = "bus_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bus_test_wrapper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bus_test_exe.root_module.addImport("common", common_module);
    bus_test_exe.use_llvm = true;
    bus_test_exe.use_lld = true;
    const run_bus_test = b.addRunArtifact(bus_test_exe);
    const bus_test_step = b.step("bus_test", "Run pure Zig EventBus test");
    bus_test_step.dependOn(&run_bus_test.step);

    // --- Wasm Plugin Build (wasm-apps/*.zig を自動で拾う。`weave init` で作ったものもそのまま乗る) ---
    // 全プラグインを ReleaseSmall でビルドする (起動が速い)。以前は bad_node だけ Debug にしていたが、
    // OOM テストのハングの原因 (SDK os_alloc の u32 折り返し + メモリ上限なし) を直したので不要。
    var zig_plugin_steps: std.ArrayListUnmanaged(*std.Build.Step) = .{};
    {
        var dir = b.build_root.handle.openDir("wasm-apps", .{ .iterate = true }) catch @panic("wasm-apps/ not found");
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
            if (std.mem.eql(u8, entry.name, "plugin_sdk.zig")) continue;
            const name = b.dupe(entry.name[0 .. entry.name.len - 4]);
            const plugin = b.addExecutable(.{
                .name = name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path(b.fmt("wasm-apps/{s}", .{entry.name})),
                    .target = wasm_target,
                    .optimize = .ReleaseSmall,
                }),
            });
            plugin.root_module.addImport("plugin_sdk", sdk_module);
            plugin.root_module.addImport("common", common_module);
            plugin.rdynamic = true;
            plugin.entry = .disabled;
            const inst = b.addInstallArtifact(plugin, .{ .dest_dir = .{ .override = .{ .custom = "../wasm-apps" } } });
            zig_plugin_steps.append(b.allocator, &inst.step) catch @panic("OOM");
        }
    }

    // --- OBS 互換 C プラグイン (obs_shim.h 経由で wasm32 にビルド) ---
    // 既存の OBS プラグインの C ソースを、ソースをほぼ変えずに Wasm サンドボックスへ載せる経路 (互換戦略 B)。
    // 以前はコミット済みの .wasm に頼っていたが、ソースからビルドして再現可能にする。
    const c_plugins = [_][]const u8{ "scene_switcher", "malicious_plugin" };
    var c_installs: [c_plugins.len]*std.Build.Step = undefined;
    for (c_plugins, 0..) |name, idx| {
        const c_exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .target = wasm_target,
                .optimize = .ReleaseSmall,
            }),
        });
        c_exe.root_module.addCSourceFiles(.{
            .root = b.path("wasm-apps/obs_compat"),
            .files = &.{ b.fmt("{s}.c", .{name}), "wasm_runtime.c" },
            .flags = &.{ "-std=c11", "-Wall", "-Wno-unused-function" },
        });
        c_exe.root_module.addIncludePath(b.path("wasm-apps/obs_compat"));
        c_exe.rdynamic = true;
        c_exe.entry = .disabled;
        const inst = b.addInstallArtifact(c_exe, .{ .dest_dir = .{ .override = .{ .custom = "../wasm-apps" } } });
        c_installs[idx] = &inst.step;
    }

    const wasm_step = b.step("wasm", "Build Wasm plugins");
    for (c_installs) |st| wasm_step.dependOn(st);
    for (zig_plugin_steps.items) |st| wasm_step.dependOn(st);

    // デフォルトの install ステップが Wasm ビルドにも依存するようにする
    b.getInstallStep().dependOn(wasm_step);

    // --- Unit Tests ---
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addWamrDeps(b, unit_tests, wamr_dir, wamr_include_paths, wamr_sources, wamr_defines);
    unit_tests.root_module.addImport("common", common_module);
    unit_tests.use_llvm = true;
    unit_tests.use_lld = true;

    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_unit_tests.step.dependOn(wasm_step);

    const sdk_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("wasm-apps/plugin_sdk.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdk_tests.root_module.addImport("common", common_module);
    const run_sdk_tests = b.addRunArtifact(sdk_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_sdk_tests.step);
    test_step.dependOn(&run_audit_tests.step);
    test_step.dependOn(&run_signing_tests.step);
    test_step.dependOn(&run_bridge_tests.step);

    // --- Test All Step ---
    const test_all_step = b.step("test_all", "Run all tests (unit, EventBus, and stress tests)");
    test_all_step.dependOn(&run_unit_tests.step);
    test_all_step.dependOn(&run_sdk_tests.step);
    test_all_step.dependOn(&run_audit_tests.step);
    test_all_step.dependOn(&run_signing_tests.step);
    test_all_step.dependOn(&run_bridge_tests.step);
    test_all_step.dependOn(&run_bus_test.step);
    test_all_step.dependOn(&run_stress_cmd.step);

    // --- Clean Step ---
    const clean_step = b.step("clean", "Remove build artifacts and Wasm plugins");
    const clean_cmd = b.addSystemCommand(&[_][]const u8{
        "sh", "-c", "rm -rf zig-cache zig-out .zig-cache build_err.log test_err.log src/bus_test_wrapper.zig src/stress_test_wrapper.zig && find wasm-apps -maxdepth 1 -name '*.wasm' -delete",
    });
    clean_step.dependOn(&clean_cmd.step);
}
