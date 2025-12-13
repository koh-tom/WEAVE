const std = @import("std");

pub const QoS = enum(u32) {
    BestEffort = 0,
    Reliable = 1,
    Transient = 2,
};

/// 外部(Host)へインポートする関数
extern "env" fn os_api_publish(
    topic_ptr: [*]const u8, topic_len: usize,
    payload_ptr: [*]const u8, payload_len: usize,
    qos: u32
) i32;

extern "env" fn os_api_log(
    level: i32,
    msg_ptr: [*]const u8, msg_len: usize
) void;

pub fn publish(topic: []const u8, payload: []const u8, qos: QoS) !void {
    const res = os_api_publish(
        topic.ptr, topic.len,
        payload.ptr, payload.len,
        @intFromEnum(qos)
    );
    if (res != 0) return error.PublishFailed;
}

pub fn logInfo(msg: []const u8) void {
    os_api_log(1, msg.ptr, msg.len);
}
