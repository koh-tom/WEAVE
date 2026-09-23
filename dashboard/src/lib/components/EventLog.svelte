<script lang="ts">
  import { eventLogs } from '../stores';

  function isHidden(p: any): boolean {
    return p && typeof p === 'object' && p.hidden === true;
  }
</script>

<div class="flex-1 flex flex-col min-h-0 bg-white border border-slate-200 shadow-inner">
  <div class="flex gap-4 px-3 py-1 bg-slate-100 border-b border-slate-200 text-[9px] font-bold text-slate-800 uppercase tracking-widest">
    <span class="w-20 shrink-0">時刻</span>
    <span class="w-56 shrink-0">トピック</span>
    <span class="w-12 shrink-0">発行元</span>
    <span class="flex-1">ペイロード</span>
  </div>
  <div class="flex-1 overflow-auto font-mono text-[11px] divide-y divide-slate-50">
    {#each $eventLogs as log, i (String(log.id ?? '') + ':' + log.ts + ':' + i)}
      <div class="flex gap-4 px-3 py-1.5 hover:bg-slate-50 items-start">
        <span class="text-slate-800 shrink-0 w-20">{new Date(log.ts).toLocaleTimeString([], { hour12: false })}</span>
        <span class="text-[#0A1C56] shrink-0 w-56 truncate font-bold" title={log.topic}>{log.topic}</span>
        <span class="text-slate-600 shrink-0 w-12">{log.origin}</span>
        {#if isHidden(log.payload)}
          <span class="text-slate-500 italic">中身は非表示 (観測レベル META, {log.payload.size} bytes)</span>
        {:else}
          <span class="text-slate-800 break-all leading-relaxed">{JSON.stringify(log.payload)}</span>
        {/if}
      </div>
    {:else}
      <div class="p-4 text-slate-800 italic">イベントを待機中...</div>
    {/each}
  </div>
  <div class="px-3 py-1 bg-slate-50 border-t border-slate-200 text-[9px] text-slate-800 font-medium">
    最新の {$eventLogs.length} 件を表示中
  </div>
</div>
