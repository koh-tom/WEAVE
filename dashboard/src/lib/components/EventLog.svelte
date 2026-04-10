<script lang="ts">
  import { eventLogs } from '../stores';
</script>

<div class="flex-1 overflow-auto bg-white border border-slate-200 p-2 font-mono text-[11px] shadow-inner">
    {#if $eventLogs.length === 0}
        <div class="text-slate-300 italic">Waiting for events...</div>
    {:else}
        <div class="flex flex-col gap-0.5">
            {#each $eventLogs as log (log.ts + log.topic + Math.random())}
                <div class="flex gap-4 hover:bg-slate-50 p-1 group border-b border-slate-50 last:border-0">
                    <span class="text-slate-400 shrink-0 w-20">{new Date(log.ts).toLocaleTimeString()}</span>
                    <span class="text-[#0A1C56] shrink-0 w-48 truncate font-bold">[{log.topic}]</span>
                    <span class="text-slate-600 truncate group-hover:text-slate-900">{JSON.stringify(log.payload)}</span>
                </div>
            {/each}
        </div>
    {/if}
</div>
