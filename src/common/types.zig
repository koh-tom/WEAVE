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
    ERROR_RATE_LIMITED = 6,
    /// manifest の limits (トピック数など) を超えた
    ERROR_LIMIT_EXCEEDED = 7,
    /// トピック名の形式が不正 (文字種・長さ・ワイルドカード)
    ERROR_INVALID_TOPIC = 8,
};

/// ノードの健康状態 (R8)。Inspector と依存ノードの縮退判断に使う。
pub const NodeStatus = enum(u8) {
    starting,
    active,
    /// 動いているが一部機能が落ちている (上流が停止中など)
    degraded,
    /// 障害から自動復帰中
    restarting,
    /// 短時間に障害が続いたため隔離中 (breaker open)。一定時間後に half-open で再試行
    quarantined,
    /// 手動停止 / 再起動ポリシーにより停止
    stopped,
    /// 外部ノード (remote) が切断
    disconnected,
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
