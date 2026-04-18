const std = @import("std");

/// イベントのQoSレベル (Host/Wasm共通)
pub const QoS = enum(u32) {
    BestEffort = 0,
    Reliable = 1,
    Transient = 2,
};

/// 観測レベル
pub const IntrospectionLevel = enum {
    off,
    metadata,
    contents,
};

/// WEAVE API 戻り値定義 (Host/Wasm共通)
pub const ResultCode = enum(i32) {
    SUCCESS = 0,
    ERROR_UNKNOWN = 1,
    ERROR_PERMISSION_DENIED = 2,
    ERROR_INVALID_PARAMETER = 3,
    ERROR_QUEUE_FULL = 4,
    ERROR_NOT_FOUND = 5,
};

/// ログレベル
pub const LogLevel = enum(u32) {
    debug = 0,
    info = 1,
    warn = 2,
    err = 3,

    pub fn fromString(s: []const u8) LogLevel {
        if (std.mem.eql(u8, s, "debug")) return .debug;
        if (std.mem.eql(u8, s, "warn")) return .warn;
        if (std.mem.eql(u8, s, "error")) return .err;
        return .info;
    }
};
