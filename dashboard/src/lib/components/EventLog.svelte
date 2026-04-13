<script lang="ts">
  import { eventLogs } from '../stores';
</script>

<div class="flex-1 flex flex-col min-h-0 bg-white border border-slate-200 shadow-inner">
    <!-- Console Header -->
    <div class="flex gap-4 px-3 py-1 bg-slate-100 border-b border-slate-200 text-[9px] font-bold text-slate-400 uppercase tracking-widest">
        <span class="w-20 shrink-0">Timestamp</span>
        <span class="w-48 shrink-0">Topic</span>
        <span class="flex-1">Payload</span>
    </div>

    <!-- Log Area -->
    <div class="flex-1 overflow-auto font-mono text-[11px] divide-y divide-slate-50">
        {#if $eventLogs.length === 0}
            <div class="p-4 text-slate-300 italic">Waiting for events...</div>
        {:else}
            {#each $eventLogs as log (log.ts + log.topic + Math.random())}
                <div class="flex gap-4 px-3 py-1.5 hover:bg-slate-50 transition-colors group items-start">
                    <span class="text-slate-400 shrink-0 w-20">{new Date(log.ts).toLocaleTimeString()}</span>
                    <span class="text-[#0A1C56] shrink-0 w-48 truncate font-bold">[{log.topic}]</span>
                    <span class="text-slate-600 break-all group-hover:text-slate-900 leading-relaxed">
                        {JSON.stringify(log.payload)}
                    </span>
                </div>
            {/each}
        {/if}
    </div>
    
    <!-- Footer / Status -->
    <div class="px-3 py-1 bg-slate-50 border-t border-slate-200 text-[9px] text-slate-400 font-medium flex justify-between">
        <span>Displaying latest {$eventLogs.length} events</span>
        <span>Auto-scrolling enabled</span>
    </div>
</div>
