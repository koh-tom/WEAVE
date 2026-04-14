import { addEventLog, metrics, systemGraph, type EventMessage } from './stores';

let socket: WebSocket | null = null;
let reconnectTimeout: ReturnType<typeof setTimeout> | null = null;
let epsCounter = 0;

/**
 * WEAVE Core への接続を開始する
 */
export function connect(url: string = `ws://${window.location.host}/ws`) {
    if (socket) {
        socket.close();
    }

    console.log(`Connecting to WEAVE Gateway: ${url}`);
    socket = new WebSocket(url);

    socket.onopen = () => {
        console.log('Connected to WEAVE Gateway.');
        if (reconnectTimeout) {
            clearTimeout(reconnectTimeout);
            reconnectTimeout = null;
        }
        // 接続時に現在のトポロジー情報をリクエストする
        send('core.system.graph.request', {});
    };

    socket.onmessage = (event) => {
        try {
            const data: EventMessage = JSON.parse(event.data);
            
            // 1. 全てのイベントをログに追加 (Pure Projection)
            addEventLog(data);
            epsCounter++;

            // 2. トピックに応じた特殊な状態更新
            // デルタ（変更）が来たら、手抜き（Pure Projection）として全体の再送を要求する
            if (data.topic === 'core.system.graph.delta') {
                send('core.system.graph.request', {});
            }

            if (data.topic === 'core.system.graph.request' || data.topic === 'core.system.graph.full') {
                const rawNodes = data.payload.nodes || [];
                const sfEdges: any[] = [];

                const sfNodes = rawNodes.map((n: any, index: number) => ({
                    id: String(n.id),
                    // 簡易的な自動整列 (間隔を少し広めに)
                    position: { x: 50 + (index % 3) * 250, y: 100 + Math.floor(index / 3) * 150 },
                    data: { label: n.name || `Node ${n.id}` },
                    type: 'default',
                    style: "border: 2px solid #0A1C56; border-radius: 4px; padding: 10px; font-weight: bold; background: white;"
                }));

                // Pub/Subの関係からエッジ（線）を推論
                rawNodes.forEach((pubNode: any) => {
                    const pubs = pubNode.pub || [];
                    pubs.forEach((pubTopic: string) => {
                        rawNodes.forEach((subNode: any) => {
                            if (pubNode.id === subNode.id) return; // 自己宛ての通信は線を省く
                            
                            const subs = subNode.sub || [];
                            subs.forEach((subTopic: string) => {
                                let isMatch = false;
                                // トピックのワイルドカード判定
                                if (subTopic === '#' || subTopic === '>') {
                                    isMatch = true;
                                } else if (subTopic.endsWith('*')) {
                                    const prefix = subTopic.slice(0, -1);
                                    if (pubTopic.startsWith(prefix)) isMatch = true;
                                } else if (pubTopic === subTopic) {
                                    isMatch = true;
                                }

                                if (isMatch) {
                                    // 既に同じノード間に同じトピックの線があれば重複を避ける（必要に応じて）
                                    sfEdges.push({
                                        id: `e-${pubNode.id}-${subNode.id}-${pubTopic}`,
                                        source: String(pubNode.id),
                                        target: String(subNode.id),
                                        animated: true,
                                        style: "stroke: #0A1C56; stroke-width: 2px;",
                                        label: pubTopic,
                                        labelBgStyle: { fill: 'white' },
                                        labelStyle: { fill: '#0A1C56', fontWeight: 700, fontSize: 10 }
                                    });
                                }
                            });
                        });
                    });
                });

                systemGraph.set({ nodes: sfNodes, edges: sfEdges });
            }
            
        } catch (err) {
            console.error('Failed to parse WEAVE event:', err);
        }
    };

    socket.onclose = () => {
        console.warn('WEAVE Gateway disconnected. Reconnecting in 2s...');
        if (!reconnectTimeout) {
            reconnectTimeout = setTimeout(() => connect(url), 2000);
        }
    };

    socket.onerror = (err) => {
        console.error('WebSocket error:', err);
    };
}

/**
 * 送信用のヘルパー関数 (必要に応じて)
 */
export function send(topic: string, payload: any) {
    if (socket && socket.readyState === WebSocket.OPEN) {
        socket.send(JSON.stringify({ topic, payload }));
    }
}

// 1秒ごとに EPS (Events Per Second) を計算して Store を更新
setInterval(() => {
    metrics.update((m) => ({ ...m, eps: epsCounter }));
    epsCounter = 0;
}, 1000);
