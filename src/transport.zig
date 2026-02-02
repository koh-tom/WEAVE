const std = @import("std");
const event_bus = @import("event_bus.zig");

/// Transportインターフェース
/// 外部のNode（別プロセス、ブラウザ、別サーバー等）との通信路を抽象化します。
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 指定されたトピック、ペイロード、QoSでメッセージを外部に送信する
        send: *const fn (ctx: *anyopaque, topic: []const u8, payload: []const u8, qos: event_bus.QoS) anyerror!void,
        
        /// トランスポートの名前を返す（デバッグ用）
        name: *const fn (ctx: *anyopaque) []const u8,
        
        /// トランスポートをクリーンアップする
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub fn send(self: Transport, topic: []const u8, payload: []const u8, qos: event_bus.QoS) !void {
        return self.vtable.send(self.ptr, topic, payload, qos);
    }

    pub fn name(self: Transport) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: Transport) void {
        return self.vtable.deinit(self.ptr);
    }
};

/// トランスポートを管理するためのコンテナ
pub const TransportManager = struct {
    allocator: std.mem.Allocator,
    transports: std.ArrayList(Transport),

    pub fn init(allocator: std.mem.Allocator) TransportManager {
        return TransportManager{
            .allocator = allocator,
            .transports = std.ArrayList(Transport).init(allocator),
        };
    }

    pub fn deinit(self: *TransportManager) void {
        for (self.transports.items) |t| {
            t.deinit();
        }
        self.transports.deinit();
    }

    pub fn register(self: *TransportManager, transport: Transport) !void {
        try self.transports.append(transport);
    }
};
