<script lang="ts">
  import { onMount } from 'svelte';
  import { connect } from './lib/websocket';
  import { metrics } from './lib/stores';
  import MetricCard from './lib/components/MetricCard.svelte';
  import EventLog from './lib/components/EventLog.svelte';
  import NodeGraph from './lib/components/NodeGraph.svelte';

  // タブ管理の状態
  let activeTab: 'stream' | 'topology' = 'stream';

  onMount(() => {
    connect();
  });
</script>

<main class="flex h-screen bg-white text-slate-800 font-sans overflow-hidden">
  <!-- Sidebar -->
  <aside class="w-64 border-r border-slate-200 flex flex-col bg-slate-50 shrink-0">
    <!-- Header -->
    <div class="p-4 border-b border-slate-200">
      <h1 class="font-bold text-xl tracking-tight text-[#0A1C56]">WEAVE</h1>
      <div class="text-xs text-slate-500 mt-1 uppercase font-semibold tracking-wider">Core Dashboard</div>
    </div>
    
    <div class="p-4 flex-1 flex flex-col gap-6 overflow-y-auto">
      <!-- Status -->
      <div>
        <div class="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-2">Status</div>
        <div class="flex items-center gap-2 text-sm text-[#0A1C56] font-bold">
          <div class="w-2 h-2 bg-[#0A1C56] rounded-full"></div>
          Gateway Online
        </div>
      </div>
      
      <!-- Metrics -->
      <div class="flex flex-col gap-2">
        <div class="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-1">Metrics</div>
        <MetricCard label="Throughput" unit="EPS" />
        
        <div class="border border-slate-200 bg-white p-3 flex flex-col gap-1 shadow-sm">
            <div class="text-[10px] font-bold text-slate-400 uppercase">Total Events</div>
            <div class="text-xl font-mono text-[#0A1C56] font-bold">{$metrics.totalEvents}</div>
        </div>
      </div>
      
      <!-- Navigation -->
      <div>
        <div class="text-[10px] font-bold text-slate-400 uppercase tracking-widest mb-2">Navigation</div>
        <nav class="flex flex-col gap-1 text-sm">
          <button 
            class="text-left px-3 py-2 rounded font-medium transition-all {activeTab === 'stream' ? 'bg-[#0A1C56] text-white shadow-sm' : 'text-slate-600 hover:bg-slate-200'}"
            onclick={() => activeTab = 'stream'}
          >
            Event Stream
          </button>
          <button 
            class="text-left px-3 py-2 rounded font-medium transition-all {activeTab === 'topology' ? 'bg-[#0A1C56] text-white shadow-sm' : 'text-slate-600 hover:bg-slate-200'}"
            onclick={() => activeTab = 'topology'}
          >
            Node Topology
          </button>
        </nav>
      </div>
    </div>
  </aside>

  <!-- Content Area -->
  <section class="flex-1 flex flex-col min-w-0 bg-white overflow-hidden">
    <header class="p-4 border-b border-slate-200 flex justify-between items-center bg-white shrink-0">
      <h2 class="font-bold text-[#0A1C56]">
        {activeTab === 'stream' ? 'Live Event Stream' : 'System Node Topology'}
      </h2>
      <div class="text-[10px] px-2 py-1 bg-slate-100 text-slate-500 rounded border border-slate-200 font-bold uppercase tracking-tighter">
        {activeTab === 'stream' ? 'Debug Mode' : 'Real-time Graph'}
      </div>
    </header>
    
    <div class="flex-1 p-4 overflow-hidden flex flex-col bg-slate-50/50">
      {#if activeTab === 'stream'}
        <EventLog />
      {:else}
        <NodeGraph />
      {/if}
    </div>
  </section>
</main>
