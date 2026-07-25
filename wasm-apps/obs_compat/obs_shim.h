/**
 * obs_shim.h — OBS Plugin API 互換シムレイヤー
 *
 * OBSネイティブプラグイン (C言語) のソースコードを、
 * WEAVEのWasmサンドボックス内で動作するように変換するための
 * 互換ヘッダ。OBSの obs-module.h を模倣し、内部ではWEAVEの
 * Host API (os_api_*) を呼び出す。
 */

#ifndef OBS_SHIM_H
#define OBS_SHIM_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

/* =========================================================
 * Wasm export 属性
 * ========================================================= */
#define WASM_EXPORT(name) __attribute__((export_name(#name)))
#define WASM_IMPORT(mod, name) __attribute__((import_module(mod), import_name(#name)))

/* =========================================================
 * WEAVE Host API (Wasm import として解決される extern 関数)
 * ========================================================= */

WASM_IMPORT("env", os_api_publish)
extern int32_t os_api_publish(
    const char* topic_ptr, uint32_t topic_len,
    const char* payload_ptr, uint32_t payload_len,
    uint32_t qos
);

WASM_IMPORT("env", os_api_subscribe)
extern int32_t os_api_subscribe(
    const char* topic_ptr, uint32_t topic_len
);

WASM_IMPORT("env", os_api_log)
extern void os_api_log(
    int32_t level, const char* msg_ptr, uint32_t msg_len
);

WASM_IMPORT("env", os_api_current_timestamp)
extern int64_t os_api_current_timestamp(void);

/* =========================================================
 * OBS互換マクロ (OBSのboilerplateをスタブ化)
 * ========================================================= */

#define OBS_DECLARE_MODULE()
#define OBS_MODULE_USE_DEFAULT_LOCALE(name, lang)

/* =========================================================
 * OBS互換: ログ出力
 * ========================================================= */

#define LOG_ERROR   3
#define LOG_WARNING 2
#define LOG_INFO    1
#define LOG_DEBUG   0

/* strlen 代替 */
static inline uint32_t _obs_strlen(const char* s) {
    uint32_t len = 0;
    while (s[len]) len++;
    return len;
}

static inline void obs_log(int level, const char* msg) {
    os_api_log(level, msg, _obs_strlen(msg));
}

/* =========================================================
 * OBS互換: 文字列操作ヘルパー
 * ========================================================= */

static inline void _obs_strcpy(char* dst, const char* src) {
    while (*src) *dst++ = *src++;
    *dst = '\0';
}

/* =========================================================
 * OBS互換: シーンアイテム操作
 * ========================================================= */

static inline int obs_sceneitem_set_visible(
    const char* scene_name,
    const char* item_name,
    bool visible
) {
    char buf[512];
    char* p = buf;

    _obs_strcpy(p, "{\"sceneName\":\"");
    p += 14;
    _obs_strcpy(p, scene_name);
    p += _obs_strlen(scene_name);
    _obs_strcpy(p, "\",\"sceneItemId\":\"");
    p += 17;
    _obs_strcpy(p, item_name);
    p += _obs_strlen(item_name);
    _obs_strcpy(p, "\",\"sceneItemEnabled\":");
    p += 20;
    if (visible) {
        _obs_strcpy(p, "true}");
        p += 5;
    } else {
        _obs_strcpy(p, "false}");
        p += 6;
    }

    return os_api_publish(
        "core.obs.request.SetSceneItemEnabled", 36,
        buf, (uint32_t)(p - buf), 1
    );
}

static inline int obs_set_current_scene(const char* scene_name) {
    char buf[256];
    char* p = buf;
    _obs_strcpy(p, "{\"sceneName\":\"");
    p += 14;
    _obs_strcpy(p, scene_name);
    p += _obs_strlen(scene_name);
    _obs_strcpy(p, "\"}");
    p += 2;

    return os_api_publish(
        "core.obs.request.SetCurrentProgramScene", 39,
        buf, (uint32_t)(p - buf), 1
    );
}

/* =========================================================
 * ファイルシステム・ネットワーク操作のスタブ
 * ========================================================= */

#ifdef OBS_SHIM_STUB_LIBC

typedef void FILE;
#ifndef NULL
#define NULL ((void*)0)
#endif

static inline FILE* fopen(const char* path, const char* mode) {
    (void)path; (void)mode;
    obs_log(LOG_ERROR, "[BLOCKED] fopen: filesystem access denied by Wasm sandbox");
    return NULL;
}

static inline size_t fread(void* ptr, size_t size, size_t count, FILE* stream) {
    (void)ptr; (void)size; (void)count; (void)stream;
    return 0;
}

static inline int fclose(FILE* stream) {
    (void)stream;
    return -1;
}

static inline int socket(int domain, int type, int protocol) {
    (void)domain; (void)type; (void)protocol;
    obs_log(LOG_ERROR, "[BLOCKED] socket: network access denied by Wasm sandbox");
    return -1;
}

static inline int connect(int sockfd, const void* addr, uint32_t addrlen) {
    (void)sockfd; (void)addr; (void)addrlen;
    return -1;
}

#endif /* OBS_SHIM_STUB_LIBC */

#endif /* OBS_SHIM_H */
