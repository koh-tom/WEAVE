<script lang="ts">
  import { onMount } from 'svelte';
  import { connect } from './lib/websocket';
  import { metrics, eventLogs } from './lib/stores';
  import MetricCard from './lib/components/MetricCard.svelte';

  onMount(() => {
    // WEAVE Core への接続開始
    connect();
  });
</script>

<main class="h-screen bg-[#050508] text-[#c0caf5] flex flex-col overflow-hidden">
  <!-- Header -->
  <header class="h-16 border-b border-white/5 flex items-center px-8 justify-between shrink-0">
    <div class="flex items-center gap-3">
        <div class="w-3 h-3 bg-[#7aa2f7] rounded-sm shadow-[0_0_15px_#7aa2f7]"></div>
        <h1 class="text-xl font-black tracking-tight">WEAVE <span class="font-light opacity-50 uppercase text-sm tracking-widest ml-2">Dashboard</span></h1>
    </div>
    
    <div class="flex items-center gap-4">
        <MetricCard label="Throughput" unit="EPS" />
        <div class="bg-white/5 px-4 py-2 rounded-xl border border-white/5 flex flex-col items-end justify-center">
            <span class="text-[10px] uppercase font-bold text-[#565f89] tracking-widest">Total Events</span>
            <span class="font-mono text-lg leading-tight">{$metrics.totalEvents}</span>
        </div>
    </div>
  </header>

  <div class="flex-1 flex overflow-hidden">
    <!-- Sidebar -->
    <aside class="w-64 border-r border-white/5 bg-[#0d0d16] p-6 flex flex-col gap-6 shrink-0">
        <div>
            <h2 class="text-[10px] font-bold uppercase text-[#565f89] tracking-[0.2em] mb-4">System Status</h2>
            <div class="flex items-center gap-2 px-3 py-2 bg-[#9ece6a]/10 border border-[#9ece6a]/20 rounded-lg">
                <div class="w-2 h-2 bg-[#9ece6a] rounded-full animate-pulse"></div>
                <span class="text-xs font-bold text-[#9ece6a]">GATEWAY ONLINE</span>
            </div>
        </div>
        
        <div class="flex flex-col gap-3">
            <h2 class="text-[10px] font-bold uppercase text-[#565f89] tracking-[0.2em]">Real-time Metrics</h2>
            <MetricCard label="Core Flow" color="#bb9af7" />
        </div>
        
        <div>
            <h2 class="text-[10px] font-bold uppercase text-[#565f89] tracking-[0.2em] mb-4">Navigation</h2>
            <nav class="flex flex-col gap-1">
                <button class="px-3 py-2 text-left text-sm rounded-md bg-white/5 text-white font-medium">Event Stream</button>
                <button class="px-3 py-2 text-left text-sm rounded-md text-[#565f89] hover:bg-white/5 hover:text-white transition-colors">Node Topology</button>
                <button class="px-3 py-2 text-left text-sm rounded-md text-[#565f89] hover:bg-white/5 hover:text-white transition-colors">Wasm Runtime</button>
            </nav>
        </div>
    </aside>

    <!-- Content Area (Event Stream) -->
    <section class="flex-1 flex flex-col p-8 overflow-hidden">
        <div class="flex items-center justify-between mb-6">
            <h2 class="text-lg font-bold flex items-center gap-2">
                Live Event Stream
                <span class="text-[10px] bg-white/5 px-2 py-0.5 rounded text-[#565f89] font-mono">DEBUG MODE</span>
            </h2>
        </div>
        
        <div class="flex-1 overflow-y-auto space-y-1 font-mono text-[11px]">
            {#each $eventLogs as log (log.ts + log.topic + Math.random())}
                <div class="flex gap-4 p-2 hover:bg-white/[0.02] border-l-2 border-transparent hover:border-[#7aa2f7] transition-colors group">
                    <span class="text-[#565f89] shrink-0">{new Date(log.ts).toLocaleTimeString()}</span>
                    <span class="text-[#primary] shrink-0 font-bold w-48 truncate">[{log.topic}]</span>
                    <span class="text-[#c0caf5] opacity-80 break-all">{JSON.stringify(log.payload)}</span>
                </div>
            {/each}
            
            {#if $eventLogs.length === 0}
                <div class="h-full flex items-center justify-center text-[#565f89] italic">
                    Waiting for events...
                </div>
            {/if}
        </div>
    </section>
  </div>
</main>

<style>
  /* 必要に応じてスタイルを追記 */
</style>
