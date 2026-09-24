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

/** Inspector でクリックしたノード (影響範囲の起点) */
export const selectedNode = writable<number | null>(null);

export interface BlastView {
  origin: number;
  /** 起点から publish → subscribe を辿って届くノード (起点を含まない) */
  reach: Set<number>;
  /** 辿った辺 (source-target-topic) */
  edgeKeys: Set<string>;
  /** 届く先のうち実世界に作用するシンク (egress セル) */
  sinks: string[];
}

export function edgeKey(e: GraphEdge): string {
  return `${e.source}-${e.target}-${e.topic}`;
}

/**
 * 影響範囲 (blast radius) — 起点ノードが乗っ取られた / 落ちたときに、書いたものが届きうる範囲。
 * weave audit と同じ考え方 (宣言された publish → subscribe の到達) を、実行中の購読グラフで辿る。
 */
export const blast = derived([selectedNode, nodes, edges], ([$sel, $nodes, $edges]): BlastView | null => {
  if ($sel == null || !$nodes[$sel]) return null;
  const reach = new Set<number>();
  const edgeKeys = new Set<string>();
  const queue = [$sel];
  const seen = new Set<number>([$sel]);
  while (queue.length > 0) {
    const cur = queue.shift()!;
    for (const e of $edges) {
      if (e.source !== cur) continue;
      edgeKeys.add(edgeKey(e));
      if (!seen.has(e.target)) {
        seen.add(e.target);
        reach.add(e.target);
        queue.push(e.target);
      }
    }
  }
  const sinks = [...reach].map((id) => $nodes[id]).filter((n) => n && n.cell === 'egress').map((n) => n.name);
  return { origin: $sel, reach, edgeKeys, sinks };
});

/** Svelte Flow 用のグラフ (状態で枠の色を変える。ノード選択中は影響範囲を重ねる) */
export const systemGraph = derived([nodes, edges, blast], ([$nodes, $edges, $blast]) => {
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
      style: nodeStyle(n, $blast),
    };
  });
  const sfEdges: Edge[] = $edges.map((e) => {
    const hot = $blast?.edgeKeys.has(edgeKey(e)) ?? false;
    const dim = $blast != null && !hot;
    const color = hot ? '#ea580c' : '#0A1C56';
    return {
      id: `e-${edgeKey(e)}`,
      source: String(e.source),
      target: String(e.target),
      animated: !dim,
      label: e.topic,
      style: `stroke: ${color}; stroke-width: ${hot ? 3 : 2}px; opacity: ${dim ? 0.15 : 1};`,
      labelStyle: `font-size: 9px; fill: ${color}; font-weight: 700; opacity: ${dim ? 0.2 : 1};`,
    };
  });
  return { nodes: sfNodes, edges: sfEdges };
});

function nodeStyle(n: NodeView, b: BlastView | null): string {
  const base = 'border-radius: 6px; padding: 8px; font-weight: 700; white-space: pre-line; font-size: 11px;';
  if (b == null) return `${base} border: 2px solid ${statusColor(n.status)}; background: white;`;
  if (n.id === b.origin) return `${base} border: 3px solid #ea580c; background: #ffedd5;`;
  if (b.reach.has(n.id)) {
    const sink = n.cell === 'egress';
    return `${base} border: 3px solid ${sink ? '#dc2626' : '#f97316'}; background: ${sink ? '#fee2e2' : '#fff7ed'};`;
  }
  return `${base} border: 2px solid ${statusColor(n.status)}; background: white; opacity: 0.25;`;
}

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
