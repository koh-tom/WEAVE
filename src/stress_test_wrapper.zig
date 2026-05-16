const test_mod = @import("tests/stress_test.zig");
pub fn main() !void {
    return test_mod.main();
}
