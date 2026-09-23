const std = @import("std");
const sdk = @import("plugin_sdk");

const TwitchMessage = struct {
    user: []const u8,
    message: []const u8,
};

// 状態は WEAVE に預ける (R5)。on_message が成功した時だけコミットされ、trap による再起動の後も
// Core 自体の再起動の後も (スナップショット) 直前の値から続く。表示中に落ちても自動非表示が来る。
const State = struct {
    wc: sdk.WindowCounter = .{ .window_ms = 3000 },
    visible: bool = false,
    last_trigger_ts: i64 = -15000,
};
var state: State = .{};
comptime {
    sdk.exportState(&state);
}

export fn on_init() i32 {
    sdk.log(1, "[kusa_node] Initializing kusa_node Wasm plugin...");
    return 0;
}

fn containsKusa(message: []const u8) bool {
    if (std.mem.indexOf(u8, message, "草") != null) {
        return true;
    }
    for (message) |char| {
        if (char == 'w' or char == 'W') {
            return true;
        }
    }
    return false;
}

fn maybeAutoHide(now: i64) void {
    // 5秒経過で自動非表示。chat / tick どちらの契機でも動く。
    if (state.visible and now >= state.last_trigger_ts + 5000) {
        const res = sdk.publishJson("core.obs.request.SetSceneItemEnabled", .{
            .sceneName = "Overlay",
            .sceneItemId = 1,
            .sceneItemEnabled = false,
        }, .BestEffort) catch |err| {
            var err_buf: [128]u8 = undefined;
            const err_msg = std.fmt.bufPrint(&err_buf, "[kusa_node] Error publishing hide request: {any}", .{err}) catch "[kusa_node] Error publishing hide request";
            sdk.log(3, err_msg);
            return;
        };
        if (res == .SUCCESS) {
            state.visible = false;
            sdk.log(1, "[kusa_node] auto-hide: visible=false");
        }
    }
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    const topic = @as([*]const u8, @ptrFromInt(topic_ptr))[0..topic_len];
    const payload = @as([*]const u8, @ptrFromInt(payload_ptr))[0..payload_len];

    const now = sdk.messageTimestamp();

    // 全 topic 共通: 5秒経過チェック (tick でも chat でも回る)
    maybeAutoHide(now);

    // tick topic はここで終わり (payload をパースする必要なし)
    if (std.mem.eql(u8, topic, "core.system.tick")) return;

    // OBS の実際の表示状態 (保持されたイベント)。基盤の再起動などで自分の記憶が消えても、
    // 購読した瞬間に届く「今の状態」から表示中かどうかを取り戻す。
    if (std.mem.eql(u8, topic, "core.obs.event.SceneItemEnableStateChanged")) {
        const Ev = struct { d: struct { eventData: struct { sceneName: []const u8 = "", sceneItemId: i64 = 0, sceneItemEnabled: bool = false } } };
        const ev = sdk.parseJson(Ev, payload) catch return;
        defer ev.deinit();
        const e = ev.value.d.eventData;
        if (!std.mem.eql(u8, e.sceneName, "Overlay") or e.sceneItemId != 1) return;
        if (e.sceneItemEnabled and !state.visible) {
            state.visible = true;
            state.last_trigger_ts = now; // イベントの時刻から自動非表示までを数える
            sdk.log(1, "[kusa_node] resynced from OBS state: visible=true");
        } else if (!e.sceneItemEnabled) {
            state.visible = false;
        }
        return;
    }

    // chat message: 発火判定
    if (std.mem.eql(u8, topic, "ext.twitch.chat.message")) {
        const parsed = sdk.parseJson(TwitchMessage, payload) catch {
            sdk.log(3, "[kusa_node] Error: Failed to parse Twitch message payload");
            return;
        };
        defer parsed.deinit();

        if (containsKusa(parsed.value.message)) {
            state.wc.record(now);
            const count = state.wc.count(now);

            if (count >= 10 and !state.visible and now >= state.last_trigger_ts + 7000) {
                const res = sdk.publishJson("core.obs.request.SetSceneItemEnabled", .{
                    .sceneName = "Overlay",
                    .sceneItemId = 1,
                    .sceneItemEnabled = true,
                }, .BestEffort) catch |err| {
                    var err_buf: [128]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "[kusa_node] Error publishing trigger request: {any}", .{err}) catch "[kusa_node] Error publishing trigger request";
                    sdk.log(3, err_msg);
                    return;
                };
                if (res == .SUCCESS) {
                    state.visible = true;
                    state.last_trigger_ts = now;
                    sdk.log(1, "[kusa_node] trigger: visible=true");
                }
            }
        }
    }
}
