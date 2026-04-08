import { writable } from 'svelte/store';
import type { Node, Edge } from '@xyflow/svelte';

/**
 * WEAVE Core から送られてくるイベントメッセージの構造
 */
export interface EventMessage {
    topic: string;
    payload: any;
    origin: number;
    ts: number;
}

/**
 * システムの流速や統計情報
 */
export interface SystemMetrics {
    eps: number;
    totalEvents: number;
}


/**
 * ノードグラフの状態 (Svelte Flow用)
 * Zig Core の現在のトポロジーを反映する
 */
export const systemGraph = writable<{ nodes: Node[]; edges: Edge[] }>({
    nodes: [],
    edges: [],
});

/**
 * リアルタイムメトリクス
 */
export const metrics = writable<SystemMetrics>({
    eps: 0,
    totalEvents: 0,
});

/**
 * イベント履歴 (最新 N 件)
 */
export const eventLogs = writable<EventMessage[]>([]);

// --- Helper Functions ---

/**
 * イベント履歴に新しいログを追加し、最大数を超えたら古いものを削除する
 */
export function addEventLog(event: EventMessage, maxLogs = 100) {
    eventLogs.update((logs) => {
        const newLogs = [event, ...logs];
        return newLogs.slice(0, maxLogs);
    });

    // 総イベント数をカウントアップ
    metrics.update((m) => ({
        ...m,
        totalEvents: m.totalEvents + 1,
    }));
}
