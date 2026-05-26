# WEAVE

**W**EAVE **E**vent **A**rchitecture with **V**erifiable **E**xtensions

> 配信・イベントのための、WebAssemblyとCapability-based Securityを備えたセキュアなリアルタイムイベント基盤

---

## 概要 (Overview)

**WEAVE** は、配信・イベント向けの分散アーキテクチャ「ストリーミングOS」です。

全てのイベント（チャット、シーン切替、音量など）は中央の `EventBus` を通過し、サードパーティの機能拡張は WebAssembly サンドボックス 内で安全に隔離されて実行されます。

## アーキテクチャ (Architecture)

WEAVEのシステムは、大きく分けて「Core Daemon（Host）」と「Community Node（Guest/Wasm）」、そして「External Interface」から構成されます。

## プロジェクト構造 (Project Structure)

```text
WEAVE/
├── src/
│   ├── main.zig            # エントリポイント
│   ├── core/               # コア基盤 (EventBus,WasmRuntime, PluginManager, Graph)
│   ├── builtin/            # ビルトインノード (Twitch, OBS, Dashboard)
│   ├── transport/          # 通信プロトコル・ゲートウェイ層 (WebSocket, TCP等)
│   ├── api/                # Host API (Wasmから呼ばれる関数群)
│   ├── common/             # 共通型定義 (QoS, ResultCode, Config)
│   └── tests/              # 統合・スタンドアローンテスト
│       ├── bus_test.zig    # EventBus 単体テスト (Wasm依存なし)
│       └── stress_test.zig # メモリ・非同期負荷テスト (Wasm込み)
├── wasm-apps/              # Wasm プラグインのソースコード
│   ├── plugin_sdk.zig      # プラグイン向け SDK (publish / subscribe / log)
│   ├── chat_node.zig       # 開発用サンプルのチャットノード
│   ├── bad_node.zig        # ACL 違反テスト用ノード
│   └── *.json              # プラグインの権限宣言 (manifest)
└── build.zig               # Core本体とWasmプラグインの一括ビルドスクリプト
```

## 使い方 (Getting Started)

### 必須要件
*   **Zig**: `0.15.2`

### ビルドと実行

WEAVE Core デーモンと Wasm プラグイン（`chat_node.wasm`）は `build.zig` により一括でビルドされます。

```bash
# クローンと依存関係の取得
git clone --recursive <repository-url> WEAVE
cd WEAVE

# ビルド
zig build

# 実行
./zig-out/bin/WEAVE
```

起動後、ブラウザで `http://localhost:3030`（デフォルト）にアクセスすると、リアルタイムの Dashboard が表示され、現在のノード構成や流れているイベントを監視できます。

## 権限マニフェスト (Manifest Example)

Wasm プラグインは、以下のような `manifest.json` をルートに配置することで、最小権限の原則に従って実行されます。

```json
{
  "name": "chat_node",
  "version": "0.1.0",
  "permissions": {
    "publish": ["core.node.status"],
    "subscribe": ["ext.twitch.*"]
  }
}
```

未許可のトピックへの `publish` や `subscribe` は、Host API レベルで即座に拒否され、イベントバスを保護します。

---

## 開発コマンド一覧 (Build & Test Commands)

`build.zig` に定義されているビルドステップをまとめます。

### ビルド

| コマンド | 説明 |
|---|---|
| `zig build` | Core デーモン本体 (`WEAVE`) と全 Wasm プラグインを一括でビルドします。`zig-out/bin/WEAVE` が生成されます。Wasm プラグインは自動的に `wasm-apps/` 以下に配置されます。 |
| `zig build wasm` | Wasm プラグイン（現状：`chat_node.wasm`, `bad_node.wasm`）のみを再ビルドします。Host 本体を再ビルドせずにプラグインだけ更新したいときに使います。 |

### 実行

| コマンド | 説明 |
|---|---|
| `zig build run` | Core デーモンをビルドしてそのまま起動します。`zig build && ./zig-out/bin/WEAVE` のと同じ。 |
| `zig build run -- wasm-apps/chat_node.wasm` | 追加の引数（`-- <args>`）を渡して実行できます。プラグインのパスを明示的に指定したい場合などに使います。 |
| `./zig-out/bin/WEAVE` | ビルド済みバイナリを直接実行します。デフォルトで `wasm-apps/chat_node.wasm` をロードして起動します。 |

### テスト

WEAVEのテストは一括実行コマンドに加え、目的ごとに3種類に分かれています。

#### 0. `zig build test_all` — 全テストの一括実行（推奨）

```bash
zig build test_all
```

- **対象**: ユニットテスト、EventBus単体テスト、メモリ負荷テストのすべて
- **用途**: コミット前やCIにおいて、システム全体の挙動を一括して検証します。

#### 1. `zig build test` — ユニットテスト

```bash
zig build test
```

- **対象**: `EventBus`, `SystemGraph`, `Manifest`, `PluginManager`, `Config` の全ユニットテスト
- **内容**: 
  - EventBus のメッセージ配送、ワイルドカード購読、QoS、Transient、Introspection（観測レベル変更通知、大容量ペイロードトレース）
  - ACL 違反プラグイン（`bad_node.wasm`）による権限チェック統合テスト
  - PluginManager のクラッシュ後自動再起動
  - Config のパース、Production バリデーション、メモリ安全性
- **依存**: Wasm プラグインのビルドが先に走ります（`bad_node.wasm` などが必要）
- **注意**: `bad_node.wasm` が `wasm-apps/` に存在しない場合は先に `zig build wasm` を実行してください。

#### 2. `zig build bus_test` — EventBusスタンドアローンテスト

```bash
zig build bus_test
```

- **対象**: `src/tests/bus_test.zig`
- **内容**: Wasm ランタイムや WAMR に一切依存しない、純粋なZigだけで構成された EventBusの動作確認です。購読・発行・コールバック・マルチスレッド配送などの基本動作をすばやく検証します。
- **用途**: EventBusのロジックを修正したとき、重いWAMRビルドを省いて高速にフィードバックを得るために使います。

#### 3. `zig build stress` — メモリ・負荷テスト

```bash
zig build stress
```

- **対象**: `src/tests/stress_test.zig`
- **内容**: Wasmランタイム（WAMR）を含む完全なスタックを立ち上げ、大量メッセージを非同期で連続パブリッシュし、メモリリークや競合が発生しないかを検証します。非同期メモリ管理健全性確認が主目的です。
- **用途**: パフォーマンスリグレッションの検出や、長時間稼働時のメモリ挙動を確認したいときに使います。

### クリーン

| コマンド | 説明 |
|---|---|
| `zig build clean` | `.zig-cache/`, `zig-out/`, `zig-cache/` に加え、生成された `wasm-apps/*.wasm` やログファイルをすべて削除します。ビルド環境を完全にリセットしたいときに使います。 |

---

### テストの使い分け早見表

```
修正したもの             → 使うコマンド
─────────────────────────────────────────────────
全体の一括検証           → zig build test_all  (推奨)
EventBus のロジック      → zig build bus_test  (高速)
その後の全体確認         → zig build test      (完全)
Config / Manifest        → zig build test
Wasm プラグイン          → zig build wasm && zig build test
大量メッセージ・メモリ   → zig build stress
全部クリアして再ビルド   → zig build clean && zig build
```

