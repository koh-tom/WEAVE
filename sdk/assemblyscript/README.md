# WEAVE plugin SDK — AssemblyScript

TypeScript に近い文法で WEAVE のプラグインを書くための SDK。Zig SDK (`wasm-apps/plugin_sdk.zig`) と
C (`wasm-apps/obs_compat/obs_shim.h`) と同じ Host API v1 (`WEAVE_docs/docs/host_api_v1.md`) を使う。

```bash
weave init my_plugin --lang as                          # sdk/assemblyscript/plugins/my_plugin.ts と wasm-apps/my_plugin.json
sdk/assemblyscript/build.sh sdk/assemblyscript/plugins/my_plugin.ts   # → wasm-apps/my_plugin.wasm (bun が必要)
weave audit my_plugin                                   # 乗っ取られたら何ができるか
weave run --mock-obs wasm-apps/my_plugin.wasm
```

## API (`assembly/weave.ts`)

| 関数 | 意味 |
|---|---|
| `publish(topic, payload, qos?)` | 発行。戻り値は `Result` (`ERROR_PERMISSION_DENIED` など) |
| `subscribe(topic)` / `unsubscribe(topic)` | 購読。manifest の宣言に収まる範囲だけ |
| `log(level, msg)` | ログ |
| `messageTimestamp()` / `now()` | 処理中のイベントの時刻 / 壁時計 (UNIX ms) |
| `text(ptr, len)` | `on_message` に渡された (ptr, len) を文字列にする |

プラグインの入口ファイルでは `os_alloc` / `os_reset_heap` / `os_api_get_heap_usage` を再エクスポートし、
`on_init(): i32` と `on_message(topic_ptr, topic_len, payload_ptr, payload_len): void` を export する
(`examples/hello_as.ts`)。

## 仕組みと制約

- GC 付きランタイム (`--runtime incremental`)。Core がイベントを書き込む領域だけを `os_alloc` で確保し、
  1 件の処理後に `os_reset_heap` で解放する。プラグイン自身の文字列・オブジェクトは GC が回収するので、
  グローバル変数に状態を持ってよい。
- WEAVE の WAMR は bulk-memory 拡張を有効にしていないので `--disable bulk-memory` でビルドする (build.sh が指定)。
- 状態のコミット (R5, Zig SDK の `exportState`) は未対応。trap すると状態は初期値に戻る。
- 例外 (`abort`) は `weaveAbort` がログに残して trap し、Core の障害隔離・再起動に乗る。
