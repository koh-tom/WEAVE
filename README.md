# WEAVE

**W**EAVE **E**vent **A**rchitecture with **V**erifiable **E**xtensions

> 配信・イベントのための、壊れても止まらないセキュアなイベント基盤。
> 「配信のための ROS 2」— Node / Topic / Pub-Sub / QoS を配信の世界へ。

配信の現場では、OBS・チャット Bot・オーバーレイ・自動化ツールが直結で絡み合い、
**プラグイン 1 つの不具合や侵害が全体を巻き込みます**。WEAVE は全てのイベントを 1 本のバスに通し、
拡張 (プラグイン) を WebAssembly のサンドボックスと「セル」に閉じ込めることで、次の 3 つを保証します。

| 保証 | どう実現するか |
|---|---|
| **乗っ取られても、影響はここまで** | manifest (権限宣言) を全入口 (Wasm / リモートノード / Inspector) で強制。影響範囲を起動前に計算 (`weave audit`) |
| **落ちても、配信は止まらない** | プラグインごとのセル (専用スレッド) で障害と遅延を隔離。Core が落ちても Supervisor が即再起動し、状態を復元 |
| **誰が作ったかを検証できる** | Ed25519 署名で wasm と manifest を束縛。strict モードでは未署名・改ざんをロード拒否 |

---

## クイックスタート

必要なもの: **Zig 0.15.2**。Inspector (ブラウザ UI) を使う場合は **bun** (または npm)。

```bash
git clone --recursive <repository-url> WEAVE && cd WEAVE
zig build                                   # Core・CLI・Wasm プラグインを一括ビルド
(cd dashboard && bun install && bun run build)   # Inspector (任意)

./weave doctor                              # 環境の自己診断
./weave obs-sim &                           # OBS が無ければシミュレータで代用 (127.0.0.1:4455)
./weave up --real-obs --no-twitch --introspection contents wasm-apps/kusa_node.wasm
```

起動ログの `[INSPECTOR] http://127.0.0.1:3030/?token=...` を開くと、左に「現実世界 (配信画面)」、
右に「WEAVE 内部 (セル・拒否したもの・障害と復帰)」が表示されます。サイドバーの「草ラッシュ」で
kusa_node が OBS のオーバーレイを表示し、5 秒後に自動で消します。

一番見せたいもの (通しデモ):

```bash
./demo/run_resilience_demo.sh          # 各幕で Enter 待ち (発表用)
./demo/run_resilience_demo.sh --auto   # 自動再生 (録画・ブース用)
```

---

## 何が起きても止まらないことを、実測で

`./demo/run_resilience_demo.sh` と `tests/e2e/*.sh` で再現できる数値 (Ryzen 7 7840U, Linux):

| 状況 | 結果 |
|---|---|
| 起動 (5 プラグイン, 署名・監査込み) | **約 35〜65 ms** で Ready (以前は 565 ms。うち 500 ms は旧依存 zap の固定 sleep だった) |
| Core を `kill -9` | **約 60〜90 ms** で復帰。OBS の表示状態はそのまま、kusa の自動非表示も予定どおり (状態の復元は Supervisor がクラッシュ後に再起動したときだけ。普通に起動したときは古い状態を戻さない) |
| OBS 自体が落ちて戻る | 戻ってから **約 200〜330 ms** で WEAVE が意図した表示を自動で再適用 |
| 暴走 Bot (毎秒 100 件) | manifest の上限 (5 件/秒) でバスの手前でドロップ。他のプラグインは無傷 |
| ハウリング (ツール同士の無限反響) | 因果の深さ 16 でバスが停止し、`loop_detected` を監査ログへ |
| チャット 1 行でプラグインが trap | そのプラグインだけ自動再起動。プロセスも他のセルも無傷 (以前はプロセスごと落ちた: P0-6) |
| 中央バスのコスト | 約 516 ns/msg、約 194 万 msg/s (`zig build bench -Doptimize=ReleaseFast`) |

---

## アーキテクチャ

```
 Twitch ─ TwitchAdapter ─┐                          ┌─ cell "egress" ─ ObsEgress ─── OBS (WebSocket v5)
 StreamElements / Streamlabs (wss) ┤                          │     (意図した状態を保持し、再接続時に再適用)
 Streamer.bot ─ bridge ──┤   ┌───────────────────┐  │
 (remote cell)           ├──▶│  EventBus         │──┤
 Inspector (ブラウザ) ────┘   │  制御プレーン:     │  ├─ cell "plugin.kusa_node"  ─ Wasm (WAMR)
                             │   購読表・権限・    │  ├─ cell "plugin.chat_node"  ─ Wasm
                             │   ルーティング     │  ├─ cell "plugin.spam_node"  ─ Wasm (流量上限)
                             └───────────────────┘  └─ cell "observe" ─ 監査ログ / Inspector / ゲートウェイ
        Supervisor (weave up) ─ Core を監視し、落ちたら即再起動 + スナップショットから復元
```

- **セル = 障害ドメイン = スケジューリング単位**。各セルが専用のキューと実行スレッドを持つので、
  あるセルが遅延・停止・再起動しても他のセルの配送は待たされません。
- **購読時の再配送 (Transient) もキュー経由**。コールバックを同期で呼ばないので、
  再起動中のプラグインに毒メッセージが再配送されてデッドロックする経路がありません。
- **メッセージは参照カウントで共有**。宛先セルの数だけコピーせずに配ります。
- **トピック種別** (`src/core/topics.zig`): event (保持しない) / state (最新値を保持) / control (実世界操作) /
  telemetry / system (Core 専用)。外部入力の既定 QoS は種別で決まります。
- **因果トレース**: プラグインが処理中のイベントに反応して発行したものは parent と深さ (hops) を持ちます。

制御プレーンは中央、データプレーンは差し替え可能 (ADR-006)。全通信が宣言済みの単一バスを通るので、
影響範囲を起動前に計算できます (ADR-008)。

---

## セキュリティ

### manifest v1

```json
{
  "abi_version": 1,
  "name": "kusa_node",
  "version": "0.1.0",
  "permissions": {
    "publish": ["core.obs.request.SetSceneItemEnabled"],
    "subscribe": ["ext.twitch.chat.message", "core.system.tick", "core.obs.event.SceneItemEnableStateChanged"],
    "data_access": ["pii"]
  },
  "rate_limit_eps": 20
}
```

- **予約名前空間** (`core.node.*` / `core.system.*` / `core.security.*` / `core.cell.*`) はプラグインが宣言できません
  (障害通知や監査イベントの偽造を防ぐ)。
- 個人情報を含みうるトピック (チャット本文など) の購読には `data_access: ["pii"]` の宣言が必要です。
- 強制点は 3 つとも同じ検査を通ります: **Wasm の Host API**、**リモートノード** (`hello` で manifest を名乗る)、
  **Inspector** (固定の権限。OBS 操作や予約名前空間は発行不可)。
- Host API はゲストが渡した (ポインタ, 長さ) が自分の線形メモリに収まっているかを検証します。
- 既定の待ち受けは `127.0.0.1`。外に開くのは `--bind 0.0.0.0` で明示したときだけ。Inspector とリモートノードはトークン必須。
- OBS への要求はトピック末尾 = 要求種別が権限の単位です (生の OBS フレームの素通しはしません)。

### 署名 (トラストアンカー Stage 1)

```bash
./weave key generate .weave/devkey
cp .weave/devkey.pub .weave/trusted_keys
./weave key sign .weave/devkey.key wasm-apps/kusa_node.wasm wasm-apps/kusa_node.json
./weave run --signature-mode strict wasm-apps/kusa_node.wasm
```

署名対象は wasm と manifest の両方です。検証に使ったのと同じバイト列を manifest としてロードします (TOCTOU 対策)。
`WEAVE_ENV=production` では署名モードの既定が strict になります。

### 影響範囲の監査

```bash
./weave audit                      # 全ノード: 実世界シンクに届くか / PII を読めるか / 落ちたら何が止まるか
./weave audit kusa_node            # 乗っ取られたら何ができるか
./weave audit --failure kusa_node  # 落ちたらどこまで止まるか
```

---

## プラグインと既存ツール

| 経路 | 使いどころ | 例 |
|---|---|---|
| **Zig SDK** (`wasm-apps/plugin_sdk.zig`) | 新しく書く | `./weave init my_bot` → `zig build` で自動的にビルド対象になる |
| **C / OBS 互換 shim** (`wasm-apps/obs_compat/obs_shim.h`) | 既存の OBS プラグインの C ソースを載せ替える | `scene_switcher.c` を `zig build` が wasm32 にビルド |
| **ブリッジ** (`weave-bridge`) | 改変できない常駐ツールを繋ぐ | Streamer.bot のイベントを WEAVE へ、WEAVE から Streamer.bot のアクションを実行 |
| **ネイティブアダプタ** (Core 内) | クラウドサービスの実プロトコル | OBS WebSocket v5、Twitch IRC、StreamElements Astro (`ext.streamelements.activity.<type>`)、Streamlabs Socket API (`ext.streamlabs.event.<type>`) |
| **リモートノード** (WebSocket, `ws://127.0.0.1:8081/`) | 任意の言語のプロセス | `{"type":"hello","manifest":{...}}` で参加 |

Host API v1 (Wasm から呼べる関数): `os_api_publish` / `os_api_subscribe` / `os_api_unsubscribe` / `os_api_log` /
`os_api_message_timestamp` (処理中のイベントの時刻。再生しても同じ) / `os_api_now` (壁時計)。
旧名 `os_api_current_timestamp` は互換のため残しています。

---

## CLI

| コマンド | 内容 |
|---|---|
| `weave run [options] [plugins...]` | Core を起動 |
| `weave up [options] [plugins...]` | Supervisor 付きで起動 (落ちても即再起動・状態復元) |
| `weave audit [node \| --failure node]` | 影響範囲の監査 |
| `weave key generate\|sign\|verify` | プラグイン署名 |
| `weave obs-sim [--port N] [--password P] [--state-file F]` | OBS WebSocket v5 シミュレータ |
| `weave topic pub <topic> <payload>` / `weave topic echo [pattern]` | イベントの発行・表示 |
| `weave node ls` | ノード一覧 (所属セル・状態) |
| `weave doctor` | 環境の自己診断 |
| `weave init <name>` | プラグインのひな形 |
| `weave-bridge [--streamerbot ws://...] [--weave ws://...]` | Streamer.bot ブリッジ (`mock-streamerbot` / `mock-astro` / `mock-streamlabs` でモック) |

主な起動オプション: `--mock-obs` / `--real-obs --obs-port --obs-pass` / `--mock-twitch <scenario> [--mock-twitch-once]` /
`--no-twitch` / `--bind` / `--dash-port` / `--node-port` / `--introspection off|metadata|contents` /
`--signature-mode off|warn|strict` / `--audit-log` / `--state-dir` / `--no-snapshot` /
`--streamelements-channel <id>` (JWT は環境変数 `STREAMELEMENTS_JWT` のみ) / `--streamlabs` (トークンは環境変数 `STREAMLABS_SOCKET_TOKEN` のみ)。`./zig-out/bin/WEAVE --help` で全て表示。

---

## テスト

```bash
zig build test_all                  # ユニット + EventBus + ストレス (Wasm が 10 万件を処理)
./tests/e2e/kusa_pipeline.sh        # チャット → Wasm → OBS
./tests/e2e/obs_compat_pipeline.sh  # ソースからビルドした OBS 互換 C プラグインをサンドボックスで
./tests/e2e/obs_reconnect.sh        # OBS が落ちて戻っても表示状態を再適用
./tests/e2e/core_restart.sh         # Core を kill -9 しても 1 秒未満で復帰・状態復元
./tests/e2e/streamerbot_bridge.sh   # 既存ツール (Streamer.bot) を remote ノードとして接続
./tests/e2e/howling.sh              # 無限反響を因果の深さで停止
./tests/e2e/streamelements.sh       # StreamElements Astro (モック) のアクティビティ・PING/PONG・不正 JWT
./tests/e2e/streamlabs.sh           # Streamlabs Socket API (モック) のアラート・Engine.IO の ping・不正トークン
```

CI (`.github/workflows/ci.yml`) は上の全てと `weave audit` を実行します。

---

## 既知の制限 (v1.0 に向けて残っている作業)

- **プラグインの自動再起動は、そのプラグインのセルの実行スレッド上で同期的に行います。** 再起動中はそのセルだけが止まります
  (他のセルは影響を受けません)。再起動処理を配送経路から切り離す Supervisor 化・毒メッセージの隔離・待機インスタンス・
  状態のコミット (計画書の R1〜R5) は未実装です。
- **命令数上限 (metering) と線形メモリ上限は未導入です。** 無限ループするプラグインは、そのプラグインのセルを占有し続けます
  (他のセルと Core は止まりません)。
- **プラグインのメモリ上の状態は、プラグインの再起動で失われます。** 保持されている state 種別のトピック
  (例: `core.obs.event.*`) から状態を取り戻す書き方をすれば、Core の再起動はまたげます (kusa_node がその例)。

詳細な計画: `WEAVE_docs/docs/v1_plan_2026-09.md`

---

## プロジェクト構造

```text
src/
├── main.zig              Core デーモン (Supervisor: --supervise)
├── cli_main.zig          weave CLI
├── audit_main.zig        weave-audit (影響範囲: 侵害時 / 障害時)
├── keytool_main.zig      weave-key (Ed25519 署名)
├── obs_sim_main.zig      weave-obs-sim (OBS WebSocket v5 シミュレータ)
├── bridge_main.zig       weave-bridge (Streamer.bot ブリッジ + Streamer.bot / Astro / Streamlabs のモック)
├── core/                 EventBus (セル) / pattern / topics / manifest / graph / snapshot / プラグイン管理
├── api/host_api.zig      Wasm から呼ばれる Host API v1
├── builtin/              Twitch / OBS (状態の再適用) / StreamElements / Streamlabs / mock / Dashboard (自前 HTTP + WebSocket)
├── transport/            ws_proto (RFC 6455, wss は std の TLS + システム CA) / node_ws (リモートノード)
├── security/signing.zig  署名とトラストストア
└── audit/blast.zig       影響範囲の計算
wasm-apps/                プラグイン (*.zig は自動でビルド) / SDK / OBS 互換 C shim
dashboard/                Inspector (Svelte 5)
demo/                     デモ台本とシナリオ
tests/e2e/                E2E テスト
```
