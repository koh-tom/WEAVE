const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    inline for (std.meta.declarations(std)) |decl| {
        if (std.mem.indexOf(u8, decl.name, "Queue") != null or std.mem.indexOf(u8, decl.name, "List") != null) {
            try stdout.print("{s}\n", .{decl.name});
        }
    }
}
