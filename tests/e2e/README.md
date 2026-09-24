# WEAVE E2E テスト

どれもリポジトリのルートから実行する。事前に `zig build` (Wasm プラグインも一緒にビルドされる) が必要。
外部サービスには接続しない。OBS・Twitch・Streamer.bot・StreamElements はすべてローカルのモックかシミュレータ。

| スクリプト | 確かめること |
|---|---|
| `kusa_pipeline.sh` | 草コメント 10 件 / 3 秒で OBS のオーバーレイが出る。5 秒後に自動で消え、7 秒のクールダウン中は再発火しない |
| `obs_compat_pipeline.sh` | 既存の OBS プラグイン (C) を Wasm に再コンパイルして動かす。manifest にない操作は拒否される |
| `obs_reconnect.sh` | OBS (シミュレータ) を kill -9 して新品で戻しても、意図した表示状態が再適用される |
| `core_restart.sh` | Core を kill -9 しても Supervisor が 1 秒以内に戻し、表示状態と自動非表示が続く |
| `streamerbot_bridge.sh` | Streamer.bot (モック) のチャットがブリッジ経由で kusa に届き、WEAVE から DoAction を呼べる |
| `howling.sh` | 反響し合う 2 プラグインを因果の深さ 16 で止め、`loop_detected` を記録する。他のプラグインは巻き込まれない |
| `infinite_loop.sh` | `!freeze` で無限ループに入る loop_node を命令数上限で止め、毒メッセージを DLQ に隔離し、予備インスタンスで数 ms で戻す。同じ時間の草ラッシュで kusa_node は OBS を操作できる |
| `shutdown.sh` | Ctrl+C (SIGINT) と SIGTERM で、イベントが流れている最中に止めても毎回 2 秒以内・終了コード 0 で終わる (既定 10 × 2 回, `ROUNDS=` で変更) |
| `assemblyscript_sdk.sh` | `weave init --lang as` で作った AssemblyScript のプラグインをビルドして載せ、チャットに反応することを確かめる (bun が必要) |
| `record_replay.sh` | `weave record` で全イベントを記録し、`--replay` で外部入力と tick を流し直すと、kusa_node が同じ判断をして OBS への要求の列 (内容と間隔) が一致する |
| `countdown.sh` | OBS 同梱の Countdown スクリプトの振る舞いを再実装した `countdown` プラグインで、開始 → 毎秒のテキスト更新 → 終了メッセージが OBS (mock) に届く (C3) |
| `egress_isolation.sh` | `--isolate-egress` で OBS への送信役を別プロセス (weave-cell) にし、表示中に kill -9 しても Core は止まらず ~90 ms で子が戻り、意図した表示が送り直され、その後の要求も届く。終了時は子も片付く (ADR-010 段階 1) |
| `plugin_isolation.sh` | `--isolate-plugins` で Wasm プラグインを 1 つずつ別プロセスに。同じ出力、子の publish も Core が検査 (malicious の core.system.shutdown を拒否)、待機中の kill -9 から状態ごと復帰、処理中に落ちたメッセージは Core で隔離 (ADR-010 段階 2) |
| `streamlabs.sh` | Streamlabs Socket API (モック, socket.io 2.x) のアラートが届く。サーバー指定の間隔で ping を送る。不正なトークンは拒否され、トークンはログに出ない |
| `streamelements.sh` | StreamElements Astro (モック) の channel.activities が届く。PING に PONG を返す。不正な JWT は拒否され、JWT はログに出ない |

```bash
zig build
for t in tests/e2e/*.sh; do "$t" || break; done
```

CI (`.github/workflows/ci.yml`) でも同じものを順に実行している。
