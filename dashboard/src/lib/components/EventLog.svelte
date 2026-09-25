<script lang="ts">
  import { eventLogs } from '../stores';

  function isHidden(p: any): boolean {
    return p && typeof p === 'object' && p.hidden === true;
  }
</script>

<div class="flex-1 flex flex-col min-h-0 bg-[var(--surface)] border border-[var(--line)] shadow-inner">
  <div class="flex gap-4 px-3 py-1 bg-[var(--surface-2)] border-b border-[var(--line)] text-[9px] font-bold text-[var(--t-hi)] uppercase tracking-widest">
    <span class="w-20 shrink-0">時刻</span>
    <span class="w-56 shrink-0">トピック</span>
    <span class="w-12 shrink-0">発行元</span>
    <span class="flex-1">ペイロード</span>
  </div>
  <div class="flex-1 overflow-auto font-mono text-[11px] divide-y divide-slate-50">
    {#each $eventLogs as log, i (String(log.id ?? '') + ':' + log.ts + ':' + i)}
      <div class="flex gap-4 px-3 py-1.5 hover:bg-[var(--bg)] items-start">
        <span class="text-[var(--t-hi)] shrink-0 w-20">{new Date(log.ts).toLocaleTimeString([], { hour12: false })}</span>
        <span class="text-[var(--t-hi)] shrink-0 w-56 truncate font-bold" title={log.topic}>{log.topic}</span>
        <span class="text-[var(--t-mid)] shrink-0 w-12">{log.origin}</span>
        {#if isHidden(log.payload)}
          <span class="text-[var(--t-mid)] italic">中身は非表示 (観測レベル META, {log.payload.size} bytes)</span>
        {:else}
          <span class="text-[var(--t-hi)] break-all leading-relaxed">{JSON.stringify(log.payload)}</span>
        {/if}
      </div>
    {:else}
      <div class="p-4 text-[var(--t-hi)] italic">イベントを待機中...</div>
    {/each}
  </div>
  <div class="px-3 py-1 bg-[var(--bg)] border-t border-[var(--line)] text-[9px] text-[var(--t-hi)] font-medium">
    最新の {$eventLogs.length} 件を表示中
  </div>
</div>
