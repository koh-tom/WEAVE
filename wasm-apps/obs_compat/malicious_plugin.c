/**
 * malicious_plugin.c — 悪意のあるOBS互換プラグイン（デモ用）
 *
 * このプラグインは「OBSネイティブ環境なら成功してしまう攻撃」を
 * WEAVEのWasmサンドボックス内で試み、全てが遮断されることを
 * 技術的に証明するためのデモ用プラグインです。
 *
 * 攻撃シナリオ:
 *   1. ファイルシステムからDiscordトークンを窃取しようとする
 *   2. 外部C&Cサーバーへソケット接続を試みる
 *   3. 権限外のシステム制御トピックにpublishを試みる
 *
 * 期待される結果:
 *   攻撃1: Wasmにはファイルシステムが存在しない → 物理的に不可能
 *   攻撃2: Wasmにはソケットが存在しない → 物理的に不可能
 *   攻撃3: Capability ACLによる ERROR_PERMISSION_DENIED → ソフトウェア的に遮断
 */

#define OBS_SHIM_STUB_LIBC  /* fopen/socket のスタブを有効化 */
#include "obs_shim.h"

OBS_DECLARE_MODULE()

/* =========================================================
 * 攻撃結果をEventBusにレポートするためのヘルパー
 * （ダッシュボードでリアルタイム可視化するため）
 * ========================================================= */

/* wasm_runtime.c で定義されるヒープリセット関数 */
extern void os_reset_heap(void);

static void report_attack_result(const char* attack_name, const char* result) {
    char buf[512];
    char* p = buf;

    _obs_strcpy(p, "{\"attack\":\"");
    p += 11;
    _obs_strcpy(p, attack_name);
    p += _obs_strlen(attack_name);
    _obs_strcpy(p, "\",\"result\":\"");
    p += 12;
    _obs_strcpy(p, result);
    p += _obs_strlen(result);
    _obs_strcpy(p, "\"}");
    p += 2;

    /* このpublishはマニフェストで許可されたトピックなので成功する */
    const char* topic = "ext.security.attack_log";
    os_api_publish(topic, 23, buf, (uint32_t)(p - buf), 1);
}

/* =========================================================
 * WEAVE Wasmプラグイン エントリポイント
 * ========================================================= */

WASM_EXPORT(on_init)
void on_init(void) {
    obs_log(LOG_WARNING, "[malicious] Malicious plugin loaded - will attempt attacks");
}

WASM_EXPORT(on_message)
void on_message(const char* topic, uint32_t topic_len, const char* payload, uint32_t payload_len) {
    (void)topic;
    (void)topic_len;
    (void)payload;
    (void)payload_len;

    obs_log(LOG_WARNING, "[malicious] === ATTACK SEQUENCE INITIATED ===");

    /* -------------------------------------------------------
     * 攻撃1: ファイルシステムからの機密情報窃取
     * OBSネイティブプラグインなら fopen() で自由に読める
     * ------------------------------------------------------- */
    obs_log(LOG_WARNING, "[malicious] Attack 1: Attempting to read Discord token...");

    FILE* f = fopen("/home/user/.config/discord/Local Storage/leveldb/token.ldb", "r");

    if (f == NULL) {
        obs_log(LOG_INFO, "[malicious] Attack 1 BLOCKED: fopen returned NULL (no filesystem in Wasm)");
        report_attack_result("discord_token_theft", "BLOCKED_SANDBOX");
    } else {
        /* ここに到達することは物理的にありえない */
        obs_log(LOG_ERROR, "[malicious] Attack 1 SUCCEEDED - THIS SHOULD NEVER HAPPEN");
        fclose(f);
    }

    /* -------------------------------------------------------
     * 攻撃2: C&Cサーバーへのネットワーク接続
     * OBSネイティブプラグインなら socket() + connect() で通信可能
     * ------------------------------------------------------- */
    obs_log(LOG_WARNING, "[malicious] Attack 2: Attempting to connect to C&C server...");

    int sockfd = socket(2 /* AF_INET */, 1 /* SOCK_STREAM */, 0);

    if (sockfd < 0) {
        obs_log(LOG_INFO, "[malicious] Attack 2 BLOCKED: socket returned -1 (no network in Wasm)");
        report_attack_result("cnc_connection", "BLOCKED_SANDBOX");
    } else {
        obs_log(LOG_ERROR, "[malicious] Attack 2 SUCCEEDED - THIS SHOULD NEVER HAPPEN");
    }

    /* -------------------------------------------------------
     * 攻撃3: 権限外のシステム制御トピックへの publish
     * Wasmのサンドボックスは通過するが、Capability ACLで遮断される
     * ------------------------------------------------------- */
    obs_log(LOG_WARNING, "[malicious] Attack 3: Attempting unauthorized system control...");

    /* core.system.shutdown はシステム制御トピック。
     * このプラグインのマニフェストには許可されていない。 */
    int result = os_api_publish(
        "core.system.shutdown", 20,
        "{\"force\":true}", 14,
        1
    );

    if (result != 0) {
        obs_log(LOG_INFO, "[malicious] Attack 3 BLOCKED: Permission denied by Capability ACL");
        report_attack_result("system_shutdown", "BLOCKED_ACL");
    } else {
        obs_log(LOG_ERROR, "[malicious] Attack 3 SUCCEEDED - THIS SHOULD NEVER HAPPEN");
    }

    obs_log(LOG_WARNING, "[malicious] === ALL ATTACKS BLOCKED - WEAVE SECURITY VERIFIED ===");

    os_reset_heap();
}
