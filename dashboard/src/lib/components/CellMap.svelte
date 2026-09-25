<script lang="ts">
  import { nodes, statusColor, type NodeView } from '../stores';

  const STATUS_LABEL: Record<string, string> = {
    active: '稼働中',
    degraded: '縮退',
    starting: '起動中',
    restarting: '復帰中',
    quarantined: '隔離中',
    stopped: '停止',
    disconnected: '切断',
  };
  // 状態 → バッジの見た目 (live=緑 / warn=橙 / danger=赤)
  const STATUS_VARIANT: Record<string, string> = {
    active: 'live', degraded: 'warn', starting: 'live', restarting: 'danger',
    quarantined: 'warn', stopped: 'danger', disconnected: 'danger',
  };

  // セル (障害ドメイン) ごとにまとめる
  let cells = $derived.by(() => {
    const groups: Record<string, NodeView[]> = {};
    for (const n of Object.values($nodes)) (groups[n.cell] ??= []).push(n);
    return Object.entries(groups)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([cell, list]) => ({ cell, list: list.sort((a, b) => a.id - b.id) }));
  });
</script>

<div class="card">
  <div class="card-h">
    <div class="card-t">WEAVE 内部 — セル (障害ドメイン)</div>
    <div class="text-[10px] text-[var(--t-mid)]">1 セル = 1 実行スレッド。あるセルの障害は他のセルに届かない</div>
  </div>
  <div class="p-3 grid grid-cols-2 xl:grid-cols-3 gap-3">
    {#each cells as c (c.cell)}
      <div class="rounded-lg border border-[var(--line-soft)] bg-[var(--bg)]/40 p-2">
        <div class="text-[10px] font-bold text-[var(--t-lo)] mono mb-1.5 tracking-wide">{c.cell}</div>
        <div class="flex flex-col gap-1.5">
          {#each c.list as n (n.id)}
            <div class="rounded-lg border px-2.5 py-2 bg-[var(--surface-2)] transition-colors"
                 style="border-color: color-mix(in oklab, {statusColor(n.status)} 45%, var(--line))">
              <div class="flex items-center justify-between gap-2">
                <span class="text-[13px] font-semibold text-[var(--t-hi)] truncate mono">{n.name}</span>
                <span class="badge {STATUS_VARIANT[n.status] ?? 'warn'} shrink-0">
                  <span class="dot {n.status === 'active' ? 'pulse' : ''}" style="background: {statusColor(n.status)}"></span>
                  {STATUS_LABEL[n.status] ?? n.status}
                </span>
              </div>
              <div class="text-[10px] text-[var(--t-lo)] mono mt-1 flex gap-2.5">
                <span>{n.type}</span>
                {#if n.faults > 0}<span class="text-[var(--danger)]">障害 {n.faults}</span>{/if}
                {#if n.lastRecoveryMs !== undefined}<span class="text-[var(--live)]">復帰 {n.lastRecoveryMs}ms</span>{/if}
              </div>
            </div>
          {/each}
        </div>
      </div>
    {/each}
    {#if cells.length === 0}
      <div class="text-xs text-[var(--t-mid)] italic col-span-full">トポロジを待機中...</div>
    {/if}
  </div>
</div>
