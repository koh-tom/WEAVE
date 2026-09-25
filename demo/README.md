# WEAVE デモ

「今までの世界だとこうなる」を実物で壊し、「WEAVE ならこれだけで安全」を並べて見せるための台本と道具。

## いちばん見せたいもの: Before / After

```bash
zig build
weave demo before_after        # または ./demo/run_before_after_demo.sh
```

同じ 3 つの攻撃 (機密の読み取り / 外部への送信 / ホストのクラッシュ) を、

- **今までの世界** — `demo/bare/steal_plugin.c` を素の OS 権限でネイティブ実行 → 偽トークンを読み、127.0.0.1 の受信役へ送り、配信ソフトごとクラッシュ
- **WEAVE** — 同じ種類のコード (`malicious_plugin`) を Wasm で実行 → `fopen` も `socket` も存在せず、権限外の publish は ACL が拒否。配信は 1 度も止まらない

の両方で走らせて対比する。すべてローカルの偽データで、ネットワークには一切出ない (`demo/bare/` 冒頭の線引きを参照)。

## デモ動画

```bash
./demo/record/run.sh           # demo/output/weave_demo.mp4 (約 37 秒) を作る
```

Inspector を録画しながら、ふだんの配信 → 悪意プラグインの拒否 → 暴走からの数 ms 復帰、を字幕付きで流す。
必要なもの: `bun` (playwright-core を自動で入れる)、`chromium`、`ffmpeg`。静止画は `demo/output/still_*.png`。

## その他の台本

| コマンド | 内容 |
|---|---|
| `weave demo resilience --auto` | 通しデモ (起動 → 障害 → Core の kill -9 → OBS 落ち、の各幕を自動再生) |
| `weave demo ratelimit` | 暴走 Bot をレート制限とセル予算で封じ込める |
| `weave demo signature` | 改ざんしたプラグインが署名検証で起動拒否される |
| `weave demo kusa` | チャットの盛り上がりを OBS のオーバーレイに反映する基本形 |

## e2e (CI で毎回まわる、動く証拠)

`tests/e2e/` に、この主張をテストにしたものが並んでいる (`tests/e2e/README.md`)。
たとえば `plugin_isolation.sh` (別プロセス隔離)、`infinite_loop.sh` (暴走の遮断と復帰)、`egress_isolation.sh` (OBS 送信の別プロセス化)。
