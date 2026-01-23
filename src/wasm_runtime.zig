const std = @import("std");
const wamr = @import("wamr_libs.zig").wamr;

pub const WasmRuntime = struct {
    pub fn init() !WasmRuntime {
        var init_args = std.mem.zeroInit(wamr.RuntimeInitArgs, .{
            .mem_alloc_type = wamr.Alloc_With_System_Allocator,
        });
        if (!wamr.wasm_runtime_full_init(&init_args)) {
            return error.RuntimeInitFailed;
        }
        return WasmRuntime{};
    }

    pub fn deinit(self: *WasmRuntime) void {
        _ = self;
        wamr.wasm_runtime_destroy();
    }

    pub fn registerNatives(self: *WasmRuntime, module_name: [:0]const u8, symbols: []wamr.NativeSymbol) !void {
        _ = self;
        if (!wamr.wasm_runtime_register_natives(module_name.ptr, symbols.ptr, @intCast(symbols.len))) {
            return error.NativeRegistrationFailed;
        }
    }

    /// Wasmモジュールをロードする。
    /// 注意: モジュールがインスタンス化されている間、wasm_buffer は生存している必要があります。
    pub fn loadModule(self: *WasmRuntime, wasm_buffer: []u8) !wamr.wasm_module_t {
        _ = self;
        var error_buf: [128]u8 = undefined;
        const module = wamr.wasm_runtime_load(wasm_buffer.ptr, @intCast(wasm_buffer.len), &error_buf, @intCast(error_buf.len));
        if (module == null) {
            std.debug.print("Wasm load error: {s}\n", .{error_buf});
            return error.ModuleLoadFailed;
        }
        return module.?;
    }

    pub fn instantiate(self: *WasmRuntime, module: wamr.wasm_module_t, stack_size: u32, heap_size: u32) !wamr.wasm_module_inst_t {
        _ = self;
        var error_buf: [128]u8 = undefined;
        const inst = wamr.wasm_runtime_instantiate(module, stack_size, heap_size, &error_buf, @intCast(error_buf.len));
        if (inst == null) {
            std.debug.print("Wasm instantiation error: {s}\n", .{error_buf});
            return error.ModuleInstantiationFailed;
        }
        return inst.?;
    }
};
