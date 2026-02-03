const std = @import("std");
const transport_if = @import("../transport.zig");
const event_bus = @import("../event_bus.zig");

/// デバッグ用のログ出力トランスポート
pub const LogTransport = struct {
    name: []const u8,

    pub fn init(name: []const u8) LogTransport {
        return .{ .name = name };
    }

    pub fn asTransport(self: *LogTransport) transport_if.Transport {
        return .{
            .ptr = self,
            .vtable = &.{
                .send = send,
                .name = getName,
                .deinit = deinit,
            },
        };
    }

    fn send(ctx: *anyopaque, topic: []const u8, payload: []const u8, qos: event_bus.QoS) anyerror!void {
        const self: *LogTransport = @ptrCast(@alignCast(ctx));
        std.debug.print("[{s}] Forwarding Topic: {s}, QoS: {any}, Payload: {s}\n", .{ self.name, topic, qos, payload });
    }

    fn getName(ctx: *anyopaque) []const u8 {
        const self: *LogTransport = @ptrCast(@alignCast(ctx));
        return self.name;
    }

    fn deinit(ctx: *anyopaque) void {
        _ = ctx;
        // 何もしない
    }
};
