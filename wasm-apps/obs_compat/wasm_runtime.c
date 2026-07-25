/**
 * wasm_runtime.c — Wasm ランタイムサポート（バンプアロケータ + エクスポート）
 *
 * OBS互換Cプラグインが WEAVE の Wasm 環境で動作するために必要な
 * ランタイム関数群。各プラグインの .c ファイルと一緒にコンパイルする。
 *
 * エクスポートされる関数:
 *   os_alloc          - ホスト側からメモリを確保する
 *   os_dealloc        - (no-op) バンプアロケータのため個別解放なし
 *   os_reset_heap     - ヒープ全体をリセット
 *   os_api_get_heap_usage - 現在のヒープ使用量
 */

#include <stdint.h>

/* Wasm リンカが提供するヒープ開始シンボル */
extern unsigned char __heap_base;

static uint32_t _bump_offset = 0;

__attribute__((export_name("os_alloc")))
uint32_t os_alloc(uint32_t size) {
    uint32_t aligned = (size + 3u) & ~3u;
    uint32_t base = (uint32_t)(uintptr_t)&__heap_base;
    uint32_t ptr = base + _bump_offset;

    /* Wasm memory size check (pages * 64KB) */
    uint32_t mem_pages = __builtin_wasm_memory_size(0);
    uint32_t mem_size = mem_pages * 65536;

    if (ptr + aligned > mem_size) {
        uint32_t needed = ((ptr + aligned - mem_size) + 65535) / 65536;
        int32_t result = __builtin_wasm_memory_grow(0, needed);
        if (result < 0) return 0; /* grow 失敗 → OOM */
    }

    _bump_offset += aligned;
    return ptr;
}

__attribute__((export_name("os_dealloc")))
void os_dealloc(uint32_t ptr, uint32_t size) {
    (void)ptr;
    (void)size;
}

__attribute__((export_name("os_reset_heap")))
void os_reset_heap(void) {
    _bump_offset = 0;
}

__attribute__((export_name("os_api_get_heap_usage")))
uint32_t os_api_get_heap_usage(void) {
    return _bump_offset;
}
