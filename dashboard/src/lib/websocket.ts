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
            // ※今後、Core側が送信するトポロジー情報のトピックに合わせて拡張します
            if (data.topic === 'core.system.graph.request' || data.topic === 'core.system.graph.full') {
                const rawNodes = data.payload.nodes || [];
                const rawEdges = data.payload.edges || [];

                const sfNodes = rawNodes.map((n: any, index: number) => ({
                    id: String(n.id),
                    // 簡易的な自動整列 (横に並べる)
                    position: { x: 50 + (index % 3) * 200, y: 100 + Math.floor(index / 3) * 100 },
                    data: { label: n.name || `Node ${n.id}` },
                    type: 'default',
                    style: "border: 2px solid #0A1C56; border-radius: 4px; padding: 10px; font-weight: bold;"
                }));

                const sfEdges = rawEdges.map((e: any) => ({
                    id: `e-${e.source}-${e.target}`,
                    source: String(e.source),
                    target: String(e.target),
                    animated: true
                }));

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
