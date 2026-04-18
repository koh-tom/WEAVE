const std = @import("std");
const LogLevel = @import("types.zig").LogLevel;

pub var current_level: LogLevel = .info;

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(current_level) <= @intFromEnum(LogLevel.debug)) {
        std.debug.print("\x1b[2m[DEBUG]\x1b[0m " ++ fmt ++ "\n", args);
    }
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(current_level) <= @intFromEnum(LogLevel.info)) {
        std.debug.print("\x1b[32m[INFO]\x1b[0m  " ++ fmt ++ "\n", args);
    }
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(current_level) <= @intFromEnum(LogLevel.warn)) {
        std.debug.print("\x1b[33m[WARN]\x1b[0m  " ++ fmt ++ "\n", args);
    }
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    if (@intFromEnum(current_level) <= @intFromEnum(LogLevel.err)) {
        std.debug.print("\x1b[31;1m[ERROR]\x1b[0m " ++ fmt ++ "\n", args);
    }
}
