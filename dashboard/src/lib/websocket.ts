import { get } from 'svelte/store';
import {
  addEventLog,
  addFault,
  addSecurityEvent,
  connection,
  edges,
  type EventMessage,
  introspection,
  metrics,
  type NodeStatus,
  type NodeView,
  nodes,
  obsState,
} from './stores';

let socket: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let graphTimer: ReturnType<typeof setTimeout> | null = null;
let epsCounter = 0;

/** トークンは URL (?token=...) で渡され、タブを閉じるまで sessionStorage に保持する */
function token(): string | null {
  const fromUrl = new URLSearchParams(window.location.search).get('token');
  if (fromUrl) {
    try {
      sessionStorage.setItem('weave-token', fromUrl);
    } catch {
      /* プライベートモード等では保存できないが、URL にあるので問題ない */
    }
    return fromUrl;
  }
  try {
    return sessionStorage.getItem('weave-token');
  } catch {
    return null;
  }
}

function defaultUrl(): string {
  // vite dev server (5173) から開いた場合は WEAVE 本体 (3030) に繋ぐ
  const host = window.location.port === '5173' ? `${window.location.hostname}:3030` : window.location.host;
  const proto = window.location.protocol === 'https:' ? 'wss' : 'ws';
  const t = token();
  return `${proto}://${host}/ws${t ? `?token=${encodeURIComponent(t)}` : ''}`;
}

export function connect(url: string = defaultUrl()) {
  if (socket) socket.close();
  connection.set('connecting');
  socket = new WebSocket(url);

  socket.onopen = () => {
    connection.set('open');
    if (reconnectTimer) {
      clearTimeout(reconnectTimer);
      reconnectTimer = null;
    }
    send('core.system.graph.request', {});
  };

  socket.onmessage = (event) => {
    let data: EventMessage;
    try {
      data = JSON.parse(event.data);
    } catch (err) {
      console.error('WEAVE: invalid event', err);
      return;
    }
    addEventLog(data);
    epsCounter++;
    route(data);
  };

  socket.onclose = (ev) => {
    // 401 はハンドシェイク前に閉じられるので、code 1006 で即閉じた場合は認証エラーの可能性が高い
    connection.set(ev.code === 1006 && get(connection) === 'connecting' ? 'unauthorized' : 'closed');
    if (!reconnectTimer) reconnectTimer = setTimeout(() => connect(url), 2000);
  };
}

export function send(topic: string, payload: unknown) {
  if (socket && socket.readyState === WebSocket.OPEN) {
    socket.send(JSON.stringify({ topic, payload }));
  }
}

function requestGraphSoon() {
  if (graphTimer) return;
  graphTimer = setTimeout(() => {
    graphTimer = null;
    send('core.system.graph.request', {});
  }, 300);
}

function nodeName(id: number): string {
  return get(nodes)[id]?.name ?? `node ${id}`;
}

function applyGraph(p: any) {
  const prev = get(nodes);
  const next: Record<number, NodeView> = {};
  for (const n of p?.nodes ?? []) {
    const old = prev[n.id];
    next[n.id] = {
      id: n.id,
      name: n.name,
      type: n.type,
      cell: n.cell ?? 'core',
      status: n.status as NodeStatus,
      pub: n.pub ?? [],
      sub: n.sub ?? [],
      faults: old?.faults ?? 0,
      restarts: old?.restarts ?? 0,
      downSince: old?.downSince,
      lastRecoveryMs: old?.lastRecoveryMs,
    };
  }
  nodes.set(next);
  edges.set(p?.edges ?? []);
}

function applyStatus(id: number, status: NodeStatus, ts: number) {
  nodes.update((all) => {
    const n = all[id];
    if (!n) return all;
    const was = n.status;
    const updated = { ...n, status };
    // 復帰時間は Core が測って core.node.recovered で送ってくる (R13)。ここでは状態だけ反映する
    if (status === 'stopped' && was !== 'stopped') {
      addFault({ ts, node: n.name, kind: 'stopped', detail: '自動復帰を停止 (再起動上限)' });
    }
    return { ...all, [id]: updated };
  });
}

function sceneKey(d: any): string | null {
  if (!d || typeof d !== 'object') return null;
  if (d.sceneName === undefined || d.sceneItemId === undefined) return null;
  return `${d.sceneName}#${d.sceneItemId}`;
}

function route(msg: EventMessage) {
  const p = msg.payload;
  const t = msg.topic;

  if (t === 'core.system.graph.full') return applyGraph(p);

  if (t === 'core.system.graph.delta') {
    if (p?.type === 'node_status') return applyStatus(p.id, p.status, msg.ts);
    return requestGraphSoon();
  }

  if (t === 'core.node.down') {
    nodes.update((all) => {
      const n = all[p?.node_id];
      return n ? { ...all, [n.id]: { ...n, downSince: p?.ts ?? msg.ts } } : all;
    });
    // プラグインのトラップは core.node.fault で出るので、ここでは接続系の縮退・切断だけを載せる
    if (p?.status === 'degraded' || p?.status === 'disconnected') {
      addFault({ ts: p?.ts ?? msg.ts, node: p?.name ?? nodeName(p?.node_id), kind: 'fault', detail: `→ ${p.status}` });
    }
    return;
  }

  if (t === 'core.node.recovered') {
    const restarted = ['restarting', 'quarantined', 'stopped'].includes(p?.from);
    nodes.update((all) => {
      const n = all[p?.node_id];
      if (!n) return all;
      return {
        ...all,
        [n.id]: { ...n, downSince: undefined, lastRecoveryMs: p?.down_ms, restarts: n.restarts + (restarted ? 1 : 0) },
      };
    });
    return addFault({
      ts: p?.ts ?? msg.ts,
      node: p?.name ?? nodeName(p?.node_id),
      kind: 'recovered',
      detail: `${p?.from} → active`,
      downtimeMs: p?.down_ms,
    });
  }

  if (t === 'core.node.fault') {
    nodes.update((all) => {
      const n = all[p?.node_id];
      return n ? { ...all, [n.id]: { ...n, faults: n.faults + 1 } } : all;
    });
    return addFault({ ts: msg.ts, node: nodeName(p?.node_id), kind: 'fault', detail: String(p?.exception ?? 'trap') });
  }

  if (t.startsWith('core.security.')) {
    return addSecurityEvent({
      ts: msg.ts,
      kind: t.slice('core.security.'.length),
      node: p?.name ?? nodeName(p?.node_id),
      detail: p?.topic ?? p?.detail ?? p?.reason ?? '',
    });
  }

  if (t === 'core.obs.link') {
    return obsState.update((s) => ({ ...s, link: !!p?.connected, reconnects: p?.reconnects ?? s.reconnects }));
  }

  if (t === 'core.obs.request.SetSceneItemEnabled') {
    const k = sceneKey(p);
    if (k) obsState.update((s) => ({ ...s, requested: { ...s.requested, [k]: !!p.sceneItemEnabled }, lastChange: msg.ts }));
    return;
  }

  if (t === 'core.obs.event.SceneItemEnableStateChanged') {
    const d = p?.d?.eventData ?? p?.eventData;
    const k = sceneKey(d);
    if (k) obsState.update((s) => ({ ...s, actual: { ...s.actual, [k]: !!d.sceneItemEnabled }, lastChange: msg.ts }));
    return;
  }

  if (t === 'core.system.introspection.changed' && p?.to) {
    introspection.set(p.to);
  }
}

setInterval(() => {
  metrics.update((m) => ({ ...m, eps: epsCounter }));
  epsCounter = 0;
}, 1000);
