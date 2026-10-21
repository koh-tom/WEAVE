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
./demo/record/run.sh           # demo/output/weave_demo.mp4 (約 44 秒) を作る
```

普段の Inspector をそのまま全画面で録画し、その上に「雑な動画編集」風の文字と矢印を後付けする。
ふだんの配信 → 悪意プラグインの拒否 (「今までの世界ならここでトークンが盗まれてた」と矢印で指す) →
暴走からの数 ms 復帰 (「配信は止まらない」) を、実際の画面の行を指しながら見せる。
必要なもの: `bun` (playwright-core を自動で入れる)、`chromium`、`ffmpeg`。静止画は `demo/output/still_*.png`。
実物の Before (偽トークン窃取→送信→クラッシュ) を実行して見たいときは `weave demo before_after`。

## その他の台本

| コマンド | 内容 |
|---|---|
| `weave demo resilience --auto` | 通しデモ (起動 → 障害 → Core の kill -9 → OBS 落ち、の各幕を自動再生) |
| `weave demo ratelimit` | 暴走 Bot をレート制限とセル予算で封じ込める |
| `weave demo signature` | 改ざんしたプラグインが署名検証で起動拒否される |
| `weave demo kusa` | チャットの盛り上がりを OBS のオーバーレイに反映する基本形 |

## 実用プラグイン (配信者が実際に使うツール)

デモの「ふだんの配信」役は、配信者が実際に使うツールを SDK で書いたもの:

| プラグイン | 何をする | 操作 |
|---|---|---|
| `subgoal` | サブスク目標バー「サブ N / 50」を配信画面に出し、新しいサブでお祝い | チャット `!sub` / `!goal 100`、`ext.subgoal.cmd` |
| `shoutout` | `!so <名前>` で配信者紹介カードを数秒出す (Nightbot/Streamer.bot 系) | チャット `!so <名前>` |
| `countdown` | OBS 同梱 Countdown スクリプトの振る舞いを移植したタイマー | `ext.countdown.cmd` |

どれも OBS へのテキスト更新 (`SetInputSettings`) と表示切替 (`SetSceneItemEnabled`) を、manifest で宣言した
権限の中だけで行う。`weave audit <名前>` で「乗っ取られても OBS のこの操作まで」を起動前に確認できる。

## e2e (CI で毎回まわる、動く証拠)

`tests/e2e/` に、この主張をテストにしたものが並んでいる (`tests/e2e/README.md`)。
たとえば `plugin_isolation.sh` (別プロセス隔離)、`infinite_loop.sh` (暴走の遮断と復帰)、`egress_isolation.sh` (OBS 送信の別プロセス化)。

## 本物の OBS で見せる (画面分割 / 動画)

`--mock-obs` の代わりに、本物の OBS Studio (obs-websocket v5) に繋いで、プラグインの出力が**実際の配信画面**に出るところを見せる版。

```bash
./demo/real_obs/run.sh            # ライブ: OBS を専用シーンで起動 → WEAVE を実接続。左 OBS / 右 Inspector の画面分割
./demo/real_obs/run.sh --record   # 同上 + OBS が自分の出力を demo/output/obs/ に録画
./demo/real_obs/record.sh         # 動画版: 左 OBS のアプリ画面そのもの (wf-recorder) / 右 Inspector(注釈つき) を横に並べる
                                  #   → demo/output/weave_demo_real_obs.mp4 (約 63 秒, 2560x720)
```

- 専用のシーンコレクション/プロファイル **WEAVE-demo** を `demo/real_obs/make_obs_collection.py` が作る (無ければ `run.sh` が自動で作る)。
  既存のシーンは触らない。scene `Overlay` の item 1 = お祝い (subgoal / kusa_node)、item 2 = シャウトアウト (shoutout)、
  入力 `SubGoal` / `OverlayText` / `ShoutoutText` = プラグインが `SetInputSettings` で書くテキスト。
- obs-websocket のパスワードは OBS の設定ファイルから読む (表示・保存はしない)。OBS の既定コレクション/プロファイルは終了時に元に戻す。
- Inspector の「OBS の実際の状態」は、本物の OBS からの `SceneItemEnableStateChanged` で埋まる (mock は自前でイベントを流す)。

## どこが止まっていて、原因はどれか(稼働状態と観測専用画面)

イベント運営で実際に起きた事故の再現です。スコア係のツールを起動し忘れたため、配信画面のスコア表示が 0-0 のまま固まりました。見た目は正常なので誰も気づかず、原因が分からないまま進行が約 30 分遅れました。

```bash
weave demo health          # 3 幕。各幕で Enter 待ち
weave demo health --auto   # 通しで自動再生
```

| 幕 | 状況 | 結果 |
|---|---|---|
| 1. 今までの世界 | スコア係(`score_tool`)を起動していない | スコア表示は「A 0 - 0 B」のまま。どこにもエラーは出ない |
| 2. WEAVE | 本来いるはずの構成を宣言する(`--expect wasm-apps/score_tool.json`) | 「score_tool が起動していません → scoreboard が入力を失って止まっています(原因: score_tool)→ 配信画面の表示が更新されません」と出る |
| 3. 直す | スコア係を起動する | スコアが更新され、「すべて動いています」に戻る |

- **稼働状態**: Core の HealthMonitor が、止まっているノードの集合から影響を計算し、`core.health.summary` に出します。規則は `weave audit --failure` と同じで、宣言(manifest)の pub/sub だけを使います。Inspector の一番上にも表示されます。
- **観測専用画面**: `http://<PC の IP>:3030/status?token=<観測専用トークン>`。トークンは起動ログの `[STATUS]` 行に出ます。この画面には稼働状態(`core.health.*`)しか届かず、publish もできません。会場を動き回るスタッフのスマホに渡しても、チャット本文などは漏れません。スマホから見るときは `--bind 0.0.0.0` で起動します。
- **設定ミスの検出**: 起動時に、誰も出していないトピックを購読しているものを調べます。似た名前があれば、`Did you mean 'ext.twitch.chat.message'?` のように候補を出します。
