<script lang="ts">
  import { eventLogs } from '../stores';
</script>

<div class="flex-1 flex flex-col min-h-0 bg-white border border-slate-200 shadow-inner">
    <!-- Console Header -->
    <div class="flex gap-4 px-3 py-1 bg-slate-100 border-b border-slate-200 text-[9px] font-bold text-slate-800 uppercase tracking-widest">
        <span class="w-20 shrink-0">時刻</span>
        <span class="w-48 shrink-0">トピック</span>
        <span class="flex-1">ペイロード</span>
    </div>

    <!-- Log Area -->
    <div class="flex-1 overflow-auto font-mono text-[11px] divide-y divide-slate-50">
        {#if $eventLogs.length === 0}
            <div class="p-4 text-slate-800 italic">イベントを待機中...</div>
        {:else}
            {#each $eventLogs as log (log.ts + log.topic + Math.random())}
                <div class="flex gap-4 px-3 py-1.5 hover:bg-slate-50 transition-colors group items-start">
                    <span class="text-slate-800 shrink-0 w-20">{new Date(log.ts).toLocaleTimeString()}</span>
                    <span class="text-[#0A1C56] shrink-0 w-48 truncate font-bold">[{log.topic}]</span>
                    <span class="text-slate-800 break-all group-hover:text-slate-900 leading-relaxed">
                        {JSON.stringify(log.payload)}
                    </span>
                </div>
            {/each}
        {/if}
    </div>
    
    <!-- Footer / Status -->
    <div class="px-3 py-1 bg-slate-50 border-t border-slate-200 text-[9px] text-slate-800 font-medium flex justify-between">
        <span>最新の {$eventLogs.length} 件を表示中</span>
        <span>自動スクロール有効</span>
    </div>
</div>
