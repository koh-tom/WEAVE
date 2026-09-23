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
| `streamlabs.sh` | Streamlabs Socket API (モック, socket.io 2.x) のアラートが届く。サーバー指定の間隔で ping を送る。不正なトークンは拒否され、トークンはログに出ない |
| `streamelements.sh` | StreamElements Astro (モック) の channel.activities が届く。PING に PONG を返す。不正な JWT は拒否され、JWT はログに出ない |

```bash
zig build
for t in tests/e2e/*.sh; do "$t" || break; done
```

CI (`.github/workflows/ci.yml`) でも同じものを順に実行している。
