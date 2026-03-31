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
│   └── common/             # 共通型定義 (QoS, ResultCode, Config)
├── wasm-apps/              # Wasm プラグインのソースコード
│   ├── chat_node.zig       # 開発用サンプルのチャットノード
│   └── manifest.json       # プラグインの権限宣言
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
