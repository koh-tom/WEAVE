<script lang="ts">
  import { faultTimeline } from '../stores';

  let recoveries = $derived($faultTimeline.filter((f) => f.kind === 'recovered' && f.downtimeMs !== undefined));
  let last = $derived(recoveries[0]?.downtimeMs);
</script>

<div class="border border-slate-200 rounded bg-white shadow-sm flex flex-col min-h-0">
  <div class="px-3 py-2 border-b border-slate-200 flex items-center justify-between">
    <div class="text-[10px] font-bold uppercase tracking-widest text-slate-800">障害と自動復帰</div>
    {#if last !== undefined}
      <div class="text-[10px] font-bold text-emerald-700">直近の復帰: {last} ms</div>
    {/if}
  </div>
  <div class="overflow-auto p-2 flex flex-col gap-1 max-h-56">
    {#each $faultTimeline as f, i (f.ts + ':' + i)}
      <div class="flex gap-2 text-[11px] font-mono items-baseline">
        <span class="text-slate-500 w-16 shrink-0">{new Date(f.ts).toLocaleTimeString([], { hour12: false })}</span>
        {#if f.kind === 'fault'}
          <span class="text-red-700 font-bold w-14 shrink-0">障害</span>
        {:else if f.kind === 'recovered'}
          <span class="text-emerald-700 font-bold w-14 shrink-0">復帰</span>
        {:else}
          <span class="text-slate-700 font-bold w-14 shrink-0">停止</span>
        {/if}
        <span class="text-[#0A1C56] shrink-0">{f.node}</span>
        <span class="text-slate-700 truncate">{f.detail}{f.downtimeMs !== undefined ? ` (停止 ${f.downtimeMs} ms)` : ''}</span>
      </div>
    {:else}
      <div class="text-xs text-slate-500 italic p-1">障害はまだ起きていません</div>
    {/each}
  </div>
</div>
