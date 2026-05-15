const std = @import("std");
const event_bus = @import("event_bus.zig");
const EventBus = event_bus.EventBus;
const PluginManager = @import("plugin_manager.zig").PluginManager;
const TransportManager = @import("../transport/interface.zig").TransportManager;
const WasmRuntime = @import("wasm_runtime.zig").WasmRuntime;
const SystemGraph = @import("graph.zig").SystemGraph;

pub const Core = struct {
    allocator: std.mem.Allocator,
    bus: EventBus,
    pm: PluginManager,
    tm: TransportManager,
    runtime: WasmRuntime,
    graph: SystemGraph,

    pub fn init(allocator: std.mem.Allocator) !Core {
        return Core{
            .allocator = allocator,
            .bus = try EventBus.init(allocator, 1000),
            .pm = PluginManager.init(allocator),
            .tm = TransportManager.init(allocator),
            .runtime = try WasmRuntime.init(),
            .graph = SystemGraph.init(allocator),
        };
    }

    pub fn deinit(self: *Core) void {
        self.graph.deinit();
        self.tm.deinit();
        self.pm.deinit();
        self.bus.deinit();
        self.runtime.deinit();
    }

    /// ゲートウェイとしての橋渡し設定
    pub fn setupGateway(self: *Core) !void {
        self.bus.global_observer = .{
            .ctx = &self.tm,
            .callback = struct {
                fn cb(ctx: *anyopaque, msg: *const event_bus.EventMessage) void {
                    const tm: *TransportManager = @ptrCast(@alignCast(ctx));
                    tm.broadcast(msg.topic, msg.payload, msg.qos);
                }
            }.cb,
        };
        std.debug.print("Core: Gateway bridge established (EventBus -> TransportManager)\n", .{});
    }

    /// Wasmプラグインをロードして初期化する
    pub fn loadPlugin(self: *Core, wasm_path: []const u8) !void {
        const wasm_buffer = try std.fs.cwd().readFileAlloc(self.allocator, wasm_path, 1024 * 1024);
        // 注意: モジュールが生きている間は wasm_buffer を解放してはいけない（WAMRの仕様）
        // defer self.allocator.free(wasm_buffer);

        const module = try self.runtime.loadModule(wasm_buffer);
        // 注意: モジュールはランタイムが管理するが、個別のアンロード戦略は将来課題

        const module_inst = try self.runtime.instantiate(module, self.pm.wasm_stack_size, self.pm.wasm_heap_size);

        // マニフェストパスの推測 (plugin.wasm -> plugin.json)
        var manifest_path_buf: [256]u8 = undefined;
        const manifest_path = if (std.mem.endsWith(u8, wasm_path, ".wasm"))
            try std.fmt.bufPrint(&manifest_path_buf, "{s}.json", .{wasm_path[0 .. wasm_path.len - 5]})
        else
            "wasm-apps/manifest.json";

        // グラフへの登録 (Wasm) - 先に登録しておかないと初期購読(subscribe)時に NodeNotFound になる
        const node_id = self.pm.next_node_id;
        try self.graph.registerNode(node_id, wasm_path, .wasm); // 仮名

        const meta = try self.pm.registerPlugin(module, module_inst, wasm_path, manifest_path, wasm_buffer, &self.bus);
        
        // 名前の更新（マニフェストから正確な名前を取得）
        try self.graph.registerNode(node_id, meta.manifest_parsed.value.name, .wasm);
        
        try self.bus.publish("core.node.registered", "{\"type\":\"wasm\"}", .Transient, 0); 

        // on_init 呼び出し
        const wamr = @import("wasm_runtime.zig").wamr;
        if (wamr.wasm_runtime_lookup_function(module_inst, "on_init")) |func| {
            const env = wamr.wasm_runtime_create_exec_env(module_inst, 16384);
            defer wamr.wasm_runtime_destroy_exec_env(env);
            var argv = [_]u32{0};
            _ = wamr.wasm_runtime_call_wasm(env, func, 0, &argv);
        }

        // マニフェストに基づいたSubscribe適用
        try self.pm.applyManifestSubscriptions(module_inst, &self.bus);

        std.debug.print("Core: Loaded plugin '{s}' (Node {})\n", .{ meta.manifest_parsed.value.name, meta.node_id });
    }
};
