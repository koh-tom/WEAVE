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

  // セル (障害ドメイン) ごとにまとめる
  let cells = $derived.by(() => {
    const groups: Record<string, NodeView[]> = {};
    for (const n of Object.values($nodes)) (groups[n.cell] ??= []).push(n);
    return Object.entries(groups)
      .sort(([a], [b]) => a.localeCompare(b))
      .map(([cell, list]) => ({ cell, list: list.sort((a, b) => a.id - b.id) }));
  });
</script>

<div class="border border-slate-200 rounded bg-white shadow-sm">
  <div class="px-3 py-2 border-b border-slate-200 flex items-center justify-between">
    <div class="text-[10px] font-bold uppercase tracking-widest text-slate-800">WEAVE 内部 — セル (障害ドメイン)</div>
    <div class="text-[10px] text-slate-600">1 セル = 1 実行スレッド。あるセルの障害は他のセルに届かない</div>
  </div>
  <div class="p-3 grid grid-cols-2 xl:grid-cols-3 gap-3">
    {#each cells as c (c.cell)}
      <div class="rounded border border-dashed border-slate-300 p-2">
        <div class="text-[10px] font-bold text-slate-600 font-mono mb-1.5">{c.cell}</div>
        <div class="flex flex-col gap-1.5">
          {#each c.list as n (n.id)}
            <div class="rounded border-2 px-2 py-1.5 bg-white transition-colors" style="border-color: {statusColor(n.status)}">
              <div class="flex items-center justify-between gap-2">
                <span class="text-xs font-bold text-[#0A1C56] truncate">{n.name}</span>
                <span class="text-[9px] font-bold px-1.5 py-0.5 rounded text-white shrink-0" style="background: {statusColor(n.status)}">
                  {STATUS_LABEL[n.status] ?? n.status}
                </span>
              </div>
              <div class="text-[10px] text-slate-600 font-mono mt-0.5 flex gap-2">
                <span>{n.type}</span>
                {#if n.faults > 0}<span class="text-red-700">障害 {n.faults}</span>{/if}
                {#if n.lastRecoveryMs !== undefined}<span class="text-emerald-700">復帰 {n.lastRecoveryMs} ms</span>{/if}
              </div>
            </div>
          {/each}
        </div>
      </div>
    {/each}
    {#if cells.length === 0}
      <div class="text-xs text-slate-500 italic col-span-full">トポロジを待機中...</div>
    {/if}
  </div>
</div>
