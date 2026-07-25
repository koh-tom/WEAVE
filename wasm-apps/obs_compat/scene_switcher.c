/**
 * scene_switcher.c — 善意のOBS互換プラグイン（WEAVE Wasm版）
 *
 * 元々はOBSネイティブプラグインとして書かれた「チャットコマンドで
 * シーンを切り替える」プラグインを、obs_shim.h を使って
 * WEAVEのWasmサンドボックス内で動くように移植した例。
 *
 * 機能:
 *   - チャットで「!scene1」→ overlay1 を表示, overlay2 を非表示
 *   - チャットで「!scene2」→ overlay2 を表示, overlay1 を非表示
 *   - チャットで「!hide」  → 両方非表示
 *
 * マニフェスト (scene_switcher.json):
 *   subscribe: ["ext.twitch.chat.message"]
 *   publish:   ["core.obs.request.SetSceneItemEnabled"]
 */

#include "obs_shim.h"

OBS_DECLARE_MODULE()

/* =========================================================
 * WEAVE Wasmプラグイン エントリポイント
 * ========================================================= */

/**
 * Wasm export: on_init
 * プラグインがロードされた直後に呼ばれる初期化関数。
 */
/* wasm_runtime.c で定義されるヒープリセット関数 */
extern void os_reset_heap(void);

WASM_EXPORT(on_init)
void on_init(void) {
    obs_log(LOG_INFO, "[scene_switcher] Plugin loaded (OBS-compat, Wasm sandboxed)");
}

/**
 * 文字列中に部分文字列が含まれるか検索する簡易実装。
 * Wasm freestanding には strstr がないため自前で用意。
 */
static bool contains(const char* haystack, uint32_t haystack_len,
                     const char* needle) {
    uint32_t needle_len = _obs_strlen(needle);
    if (needle_len > haystack_len) return false;

    for (uint32_t i = 0; i <= haystack_len - needle_len; i++) {
        bool match = true;
        for (uint32_t j = 0; j < needle_len; j++) {
            if (haystack[i + j] != needle[j]) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

/**
 * Wasm export: on_message
 * EventBusからメッセージが届いたときに呼ばれるコールバック。
 *
 * ext.twitch.chat.message のペイロード(JSON)を受け取り、
 * コマンド文字列を検出して OBS のシーンアイテムを操作する。
 */
WASM_EXPORT(on_message)
void on_message(const char* topic, uint32_t topic_len, const char* payload, uint32_t payload_len) {
    (void)topic;
    (void)topic_len;
    if (contains(payload, payload_len, "!scene1")) {
        obs_log(LOG_INFO, "[scene_switcher] Command: !scene1 -> switching overlay");
        obs_sceneitem_set_visible("MainScene", "overlay1", true);
        obs_sceneitem_set_visible("MainScene", "overlay2", false);

    } else if (contains(payload, payload_len, "!scene2")) {
        obs_log(LOG_INFO, "[scene_switcher] Command: !scene2 -> switching overlay");
        obs_sceneitem_set_visible("MainScene", "overlay1", false);
        obs_sceneitem_set_visible("MainScene", "overlay2", true);

    } else if (contains(payload, payload_len, "!hide")) {
        obs_log(LOG_INFO, "[scene_switcher] Command: !hide -> hiding all overlays");
        obs_sceneitem_set_visible("MainScene", "overlay1", false);
        obs_sceneitem_set_visible("MainScene", "overlay2", false);
    }

    /* イベント処理完了後、バンプアロケータをリセット */
    os_reset_heap();
}
