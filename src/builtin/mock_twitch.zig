const std = @import("std");
const log = @import("../common/log.zig");
const EventBus = @import("../core/event_bus.zig").EventBus;
const QoS = @import("../core/event_bus.zig").QoS;

pub const ScenarioItem = struct {
    delta_ms: u64,
    user: []const u8,
    message: []const u8,
};

// Twitchチャットモック用
pub const MockTwitchAdapter = struct {
    allocator: std.mem.Allocator,
    bus: *EventBus,
    node_id: u32,
    filepath: []const u8,
    running: bool = false,
    loop: bool = true,

    pub fn init(allocator: std.mem.Allocator, bus: *EventBus, node_id: u32, filepath: []const u8) !MockTwitchAdapter {
        const duped_path = try allocator.dupe(u8, filepath);
        return MockTwitchAdapter{
            .allocator = allocator,
            .bus = bus,
            .node_id = node_id,
            .filepath = duped_path,
            .running = false,
            .loop = true,
        };
    }

    pub fn deinit(self: *MockTwitchAdapter) void {
        self.allocator.free(self.filepath);
    }

    pub fn stop(self: *MockTwitchAdapter) void {
        self.running = false;
    }

    pub fn run(self: *MockTwitchAdapter) !void {
        self.running = true;
        while (self.running) {
            const file = std.fs.cwd().openFile(self.filepath, .{}) catch |err| {
                log.err("MockTwitchAdapter: failed to open file {s}: {any}", .{ self.filepath, err });
                return err;
            };
            defer file.close();

            var buf: [4096]u8 = undefined;
            var file_reader = file.reader(&buf);
            var reader = &file_reader.interface;

            while (self.running) {
                const line_opt = try reader.takeDelimiter('\n');
                const line_raw = line_opt orelse break;

                const line = std.mem.trimRight(u8, line_raw, "\r");
                if (line.len == 0) continue;

                var parsed = std.json.parseFromSlice(ScenarioItem, self.allocator, line, .{ .ignore_unknown_fields = true }) catch |err| {
                    log.err("MockTwitchAdapter: failed to parse JSON line '{s}': {any}", .{ line, err });
                    continue;
                };
                defer parsed.deinit();

                if (parsed.value.delta_ms > 0) {
                    self.sleepOrInterrupt(parsed.value.delta_ms);
                }

                if (!self.running) break;

                const json_payload = try std.fmt.allocPrint(self.allocator, "{f}", .{std.json.fmt(.{ .user = parsed.value.user, .message = parsed.value.message }, .{})});
                defer self.allocator.free(json_payload);

                try self.bus.publish("ext.twitch.chat.message", json_payload, .BestEffort, self.node_id);
            }

            if (!self.loop or !self.running) {
                break;
            }
        }
    }

    fn sleepOrInterrupt(self: *MockTwitchAdapter, ms: u64) void {
        const chunk_ms: u64 = 10;
        var remaining = ms;
        while (remaining > 0 and self.running) {
            const sleep_ms = @min(remaining, chunk_ms);
            std.Thread.sleep(@as(u64, sleep_ms) * std.time.ns_per_ms);
            remaining -= sleep_ms;
        }
    }
};
