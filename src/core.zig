const std = @import("std");
const EventBus = @import("event_bus.zig").EventBus;
const PluginManager = @import("plugin_manager.zig").PluginManager;
const TransportManager = @import("transport.zig").TransportManager;
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
            .bus = EventBus.init(allocator, 1000),
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
                fn cb(ctx: *anyopaque, msg: *const @import("event_bus.zig").EventMessage) void {
                    const tm: *TransportManager = @ptrCast(@alignCast(ctx));
                    tm.broadcast(msg.topic, msg.payload, msg.qos);
                }
            }.cb,
        };
        std.debug.print("Core: Gateway bridge established (EventBus -> TransportManager)\n", .{});
    }
};
