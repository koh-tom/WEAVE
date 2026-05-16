const test_mod = @import("tests/bus_test.zig");
pub fn main() !void {
    return test_mod.main();
}
