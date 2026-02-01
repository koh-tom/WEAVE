const std = @import("std");
const net = std.net;

/// シンプルなTCPクライアント。
/// Twitch IRCのような行ベース（\r\n区切り）プロトコル向けに
/// 手動バッファリングによる行読み取りを提供する。
pub const TcpClient = struct {
    allocator: std.mem.Allocator,
    stream: ?net.Stream = null,

    // 受信バッファ（リングバッファ風に使う）
    buf: [4096]u8 = undefined,
    buf_start: usize = 0,
    buf_end: usize = 0,

    pub fn init(allocator: std.mem.Allocator) TcpClient {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TcpClient) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    /// ホスト名とポートを指定してTCP接続する
    pub fn connect(self: *TcpClient, host: []const u8, port: u16) !void {
        self.stream = try net.tcpConnectToHost(self.allocator, host, port);
    }

    /// データを送信する（全バイト書き込み保証）
    pub fn send(self: *TcpClient, data: []const u8) !void {
        const s = self.stream orelse return error.NotConnected;
        var written: usize = 0;
        while (written < data.len) {
            const n = try s.write(data[written..]);
            if (n == 0) return error.ConnectionClosed;
            written += n;
        }
    }

    /// 1行読み取る（\r\n または \n で区切る）。
    /// 戻り値のスライスは allocator で確保されるため呼び出し側で free が必要。
    /// 接続が閉じた場合は null を返す。
    pub fn readLine(self: *TcpClient, allocator: std.mem.Allocator) !?[]const u8 {
        const s = self.stream orelse return error.NotConnected;

        // 行を蓄積するための固定バッファ（IRC行は最大512バイト仕様）
        var line_buf: [4096]u8 = undefined;
        var line_len: usize = 0;

        while (true) {
            // バッファ内に \n を探す
            if (self.buf_start < self.buf_end) {
                const window = self.buf[self.buf_start..self.buf_end];
                if (std.mem.indexOfScalar(u8, window, '\n')) |pos| {
                    // \n が見つかった — pos までが行の一部
                    const chunk = window[0..pos];
                    if (line_len + chunk.len > line_buf.len) return error.LineTooLong;
                    @memcpy(line_buf[line_len..][0..chunk.len], chunk);
                    line_len += chunk.len;
                    self.buf_start += pos + 1; // \n をスキップ

                    // 末尾の \r を除去
                    if (line_len > 0 and line_buf[line_len - 1] == '\r') {
                        line_len -= 1;
                    }

                    return try allocator.dupe(u8, line_buf[0..line_len]);
                } else {
                    // \n が無い — バッファ全体を行に追加して続行
                    if (line_len + window.len > line_buf.len) return error.LineTooLong;
                    @memcpy(line_buf[line_len..][0..window.len], window);
                    line_len += window.len;
                    self.buf_start = 0;
                    self.buf_end = 0;
                }
            }

            // バッファが空なのでソケットから読み込む
            const n = try s.read(&self.buf);
            if (n == 0) {
                // 接続が閉じた
                if (line_len > 0) {
                    return try allocator.dupe(u8, line_buf[0..line_len]);
                }
                return null;
            }
            self.buf_start = 0;
            self.buf_end = n;
        }
    }
};
