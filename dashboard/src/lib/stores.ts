import { derived, writable } from 'svelte/store';
import type { Edge, Node } from '@xyflow/svelte';

/** WEAVE Core から届くイベント (Inspector WebSocket) */
export interface EventMessage {
  id?: number;
  topic: string;
  payload: any;
  origin: number;
  ts: number;
  qos?: number;
  /** このイベントを発行する契機になったイベントの id (因果トレース) */
  parent?: number;
  hops?: number;
}

export type NodeStatus =
  | 'starting'
  | 'active'
  | 'degraded'
  | 'restarting'
  | 'quarantined'
  | 'stopped'
  | 'disconnected';

export interface NodeView {
  id: number;
  name: string;
  type: string;
  cell: string;
  status: NodeStatus;
  pub: string[];
  sub: string[];
  faults: number;
  restarts: number;
  downSince?: number;
  lastRecoveryMs?: number;
}

export interface GraphEdge {
  source: number;
  target: number;
  topic: string;
}

export interface SecurityEvent {
  ts: number;
  kind: string;
  node: string;
  detail: string;
}

export interface FaultEntry {
  ts: number;
  node: string;
  kind: 'fault' | 'recovered' | 'stopped';
  detail: string;
  downtimeMs?: number;
}

export interface ObsState {
  /** true = 接続中, false = 切断中, null = 情報なし (mock OBS など) */
  link: boolean | null;
  reconnects: number;
  /** WEAVE が OBS に要求した表示状態 (sceneName#sceneItemId -> enabled) */
  requested: Record<string, boolean>;
  /** OBS から報告された実際の表示状態 */
  actual: Record<string, boolean>;
  lastChange: number;
}

export interface SystemMetrics {
  eps: number;
  totalEvents: number;
}

export type Connection = 'connecting' | 'open' | 'closed' | 'unauthorized';

export const connection = writable<Connection>('connecting');
export const nodes = writable<Record<number, NodeView>>({});
export const edges = writable<GraphEdge[]>([]);
export const metrics = writable<SystemMetrics>({ eps: 0, totalEvents: 0 });
export const eventLogs = writable<EventMessage[]>([]);
export const securityEvents = writable<SecurityEvent[]>([]);
export const faultTimeline = writable<FaultEntry[]>([]);
export const introspection = writable<'off' | 'metadata' | 'contents'>('metadata');
export const obsState = writable<ObsState>({
  link: null,
  reconnects: 0,
  requested: {},
  actual: {},
  lastChange: 0,
});

/** 配信が止まっていない時間の起点 (Inspector を開いた時刻) */
export const sessionStart = Date.now();

const STATUS_COLOR: Record<string, string> = {
  active: '#059669',
  degraded: '#d97706',
  starting: '#2563eb',
  restarting: '#dc2626',
  quarantined: '#7c3aed',
  stopped: '#475569',
  disconnected: '#94a3b8',
};

export function statusColor(s: string): string {
  return STATUS_COLOR[s] ?? '#475569';
}

/** Svelte Flow 用のグラフ (状態で枠の色を変える) */
export const systemGraph = derived([nodes, edges], ([$nodes, $edges]) => {
  const list = Object.values($nodes).sort((a, b) => a.cell.localeCompare(b.cell) || a.id - b.id);
  const cells = [...new Set(list.map((n) => n.cell))];
  const perCell: Record<string, number> = {};
  const sfNodes: Node[] = list.map((n) => {
    const col = cells.indexOf(n.cell);
    const row = (perCell[n.cell] = (perCell[n.cell] ?? -1) + 1);
    return {
      id: String(n.id),
      position: { x: 40 + col * 230, y: 60 + row * 110 },
      data: { label: `${n.name}\n[${n.cell}]` },
      style: `border: 2px solid ${statusColor(n.status)}; border-radius: 6px; padding: 8px; font-weight: 700; background: white; white-space: pre-line; font-size: 11px;`,
    };
  });
  const sfEdges: Edge[] = $edges.map((e) => ({
    id: `e-${e.source}-${e.target}-${e.topic}`,
    source: String(e.source),
    target: String(e.target),
    animated: true,
    label: e.topic,
    style: 'stroke: #0A1C56; stroke-width: 2px;',
    labelStyle: 'font-size: 9px; fill: #0A1C56; font-weight: 700;',
  }));
  return { nodes: sfNodes, edges: sfEdges };
});

function pushCapped<T>(list: T[], item: T, max: number): T[] {
  const next = [item, ...list];
  return next.length > max ? next.slice(0, max) : next;
}

export function addEventLog(event: EventMessage, maxLogs = 80) {
  eventLogs.update((logs) => pushCapped(logs, event, maxLogs));
  metrics.update((m) => ({ ...m, totalEvents: m.totalEvents + 1 }));
}

export function addSecurityEvent(e: SecurityEvent) {
  securityEvents.update((l) => pushCapped(l, e, 50));
}

export function addFault(e: FaultEntry) {
  faultTimeline.update((l) => pushCapped(l, e, 50));
}
