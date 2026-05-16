const std = @import("std");
const sdk = @import("plugin_sdk");

export fn on_init() i32 {
    sdk.log(1, "BadNode starting...");

    // 1. 許可されたトピックへの publish
    const res1 = sdk.publish("allowed.topic", "hello", .BestEffort);
    if (res1 != .SUCCESS) {
        sdk.log(1, "Error: Allowed publish failed!");
        return -1;
    }

    // 2. 許可されていないトピックへの publish -> ERROR_PERMISSION_DENIED が返るべき
    const res2 = sdk.publish("forbidden.topic", "hello", .BestEffort);
    if (res2 != .ERROR_PERMISSION_DENIED) {
        sdk.log(1, "Error: Forbidden publish did not return permission denied!");
        return -2;
    }
    sdk.log(1, "Success: Forbidden publish rejected as expected.");

    // 3. 許可されたトピックへの subscribe
    const res3 = sdk.subscribe("allowed.topic");
    if (res3 != .SUCCESS) {
        sdk.log(1, "Error: Allowed subscribe failed!");
        return -3;
    }

    // 4. 許可されていないトピックへの subscribe -> ERROR_PERMISSION_DENIED が返るべき
    const res4 = sdk.subscribe("forbidden.topic");
    if (res4 != .ERROR_PERMISSION_DENIED) {
        sdk.log(1, "Error: Forbidden subscribe did not return permission denied!");
        return -4;
    }
    sdk.log(1, "Success: Forbidden subscribe rejected as expected.");

    sdk.log(1, "BadNode finished checks. All validation passed!");
    return 0;
}

export fn on_message(topic_ptr: u32, topic_len: u32, payload_ptr: u32, payload_len: u32) void {
    _ = topic_ptr;
    _ = topic_len;
    _ = payload_ptr;
    // 長さ 4 のメッセージを受信した際に意図的に Wasm トラップを起こす (障害分離検証用)
    if (payload_len == 4) {
        @panic("Intentional Trap");
    }
}
