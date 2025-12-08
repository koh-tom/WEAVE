const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wamr_dir = "deps/wasm-micro-runtime";

    const exe = b.addExecutable(.{
        .name = "WEAVE",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // WAMRのインクルードパス
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/iwasm/include" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/iwasm/common" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/iwasm/interpreter" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/shared/utils" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/shared/platform/linux" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/shared/platform/common/posix" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/shared/platform/common/libc-util" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/shared/platform/include" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/shared/mem-alloc" }) catch unreachable));
    exe.addIncludePath(b.path(std.fs.path.join(b.allocator, &.{ wamr_dir, "core/iwasm/libraries/libc-wasi/sandboxed-system-primitives/src" }) catch unreachable));

    // WAMRの定義
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

    // WAMRのソースファイル
    inline for (.{
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
        "core/iwasm/common/arch/invokeNative_general.c",
        "core/iwasm/common/wasm_c_api.c",
    }) |src| {
        exe.addCSourceFile(.{
            .file = b.path(b.fmt("{s}/{s}", .{ wamr_dir, src })),
            .flags = wamr_defines,
        });
    }

    exe.linkLibC();
    exe.linkSystemLibrary("m");
    exe.linkSystemLibrary("dl");
    exe.linkSystemLibrary("pthread");
    exe.linkSystemLibrary("rt");

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
