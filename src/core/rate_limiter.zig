const std = @import("std");

/// Token Bucket レートリミッタ (ノード単位)。
/// 「Bot 暴走で 1 つのプラグインがバスを埋め尽くす」事故を防ぐ。
/// rate_eps <= 0 は無制限 (既定)。capacity = 1 秒分のバースト許容。
pub const RateLimiter = struct {
    rate_eps: f64 = 0,
    capacity: f64 = 0,
    tokens: f64 = 0,
    last_ms: i64 = 0,
    primed: bool = false,

    pub fn init(rate_eps: f64) RateLimiter {
        const cap = if (rate_eps <= 0) 0 else @max(rate_eps, 1);
        return .{ .rate_eps = rate_eps, .capacity = cap, .tokens = cap, .last_ms = 0 };
    }

    /// 1 メッセージ分のトークンを消費できれば true。超過なら false (=ドロップ)。
    pub fn tryConsume(self: *RateLimiter, now_ms: i64) bool {
        if (self.rate_eps <= 0) return true; // 無制限
        if (!self.primed) {
            self.last_ms = now_ms;
            self.primed = true;
        }
        const elapsed = @as(f64, @floatFromInt(now_ms - self.last_ms)) / 1000.0;
        if (elapsed > 0) {
            self.tokens = @min(self.capacity, self.tokens + elapsed * self.rate_eps);
            self.last_ms = now_ms;
        }
        if (self.tokens >= 1.0) {
            self.tokens -= 1.0;
            return true;
        }
        return false;
    }
};

test "RateLimiter: unlimited when rate<=0" {
    var rl = RateLimiter.init(0);
    var i: usize = 0;
    while (i < 1000) : (i += 1) try std.testing.expect(rl.tryConsume(0));
}

test "RateLimiter: burst is capped, then refills over time" {
    var rl = RateLimiter.init(100); // 100 eps, burst 100
    // t=0 で 150 連投 -> 先頭 100 通過、残り 50 ドロップ
    var pass: usize = 0;
    var i: usize = 0;
    while (i < 150) : (i += 1) {
        if (rl.tryConsume(0)) pass += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), pass);
    // 1 秒後 -> 100 分リフィル -> また 100 通過
    pass = 0;
    i = 0;
    while (i < 150) : (i += 1) {
        if (rl.tryConsume(1000)) pass += 1;
    }
    try std.testing.expectEqual(@as(usize, 100), pass);
    // 0.5 秒後 -> 50 分だけ -> 50 通過
    pass = 0;
    i = 0;
    while (i < 150) : (i += 1) {
        if (rl.tryConsume(1500)) pass += 1;
    }
    try std.testing.expectEqual(@as(usize, 50), pass);
}
