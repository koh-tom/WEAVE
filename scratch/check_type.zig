const std = @import("std");

pub fn main() !void {
    const reader = std.io.getStdIn().reader();
    const br = std.io.bufferedReader(reader);
    std.debug.print("Type: {any}\n", .{@TypeOf(br)});
}
