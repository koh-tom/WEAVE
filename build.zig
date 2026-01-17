const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    const exe = b.addExecutable(.{
        .name = "WEAVE",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
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
            .root_source_file = b.path("src/stress_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addWamrDeps(b, stress_exe, wamr_dir, wamr_include_paths, wamr_sources, wamr_defines);

    const run_stress_cmd = b.addRunArtifact(stress_exe);
    const stress_step = b.step("stress", "Run memory stress test (Phase 2.1)");
    stress_step.dependOn(&run_stress_cmd.step);

    // --- Pure Zig EventBus Test ---
    const bus_test_exe = b.addExecutable(.{
        .name = "bus_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_event_bus.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_bus_test = b.addRunArtifact(bus_test_exe);
    const bus_test_step = b.step("bus_test", "Run pure Zig EventBus test");
    bus_test_step.dependOn(&run_bus_test.step);
}
