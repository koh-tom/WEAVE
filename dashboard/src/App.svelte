<script lang="ts">
  import { onMount } from 'svelte';
  import { connect } from './lib/websocket';
  import { connection, metrics } from './lib/stores';
  import MetricCard from './lib/components/MetricCard.svelte';
  import EventLog from './lib/components/EventLog.svelte';
  import NodeGraph from './lib/components/NodeGraph.svelte';
  import ChatSimulator from './lib/components/ChatSimulator.svelte';
  import ObsPreview from './lib/components/ObsPreview.svelte';
  import CellMap from './lib/components/CellMap.svelte';
  import SecurityFeed from './lib/components/SecurityFeed.svelte';
  import FaultTimeline from './lib/components/FaultTimeline.svelte';
  import IntrospectionToggle from './lib/components/IntrospectionToggle.svelte';

  type Tab = 'inspector' | 'stream' | 'topology';
  let activeTab: Tab = $state('inspector');

  const TABS: { id: Tab; label: string; title: string }[] = [
    { id: 'inspector', label: 'Inspector', title: '現実世界 と WEAVE 内部' },
    { id: 'stream', label: 'イベントストリーム', title: 'リアルタイム・イベントストリーム' },
    { id: 'topology', label: 'トポロジー', title: 'システムノード・トポロジー' },
  ];

  onMount(() => connect());
</script>

<main class="flex h-screen bg-white text-slate-800 font-sans overflow-hidden">
  <aside class="w-72 border-r border-slate-200 flex flex-col bg-slate-50 shrink-0">
    <div class="p-4 border-b border-slate-200">
      <h1 class="font-bold text-xl tracking-tight text-[#0A1C56]">WEAVE</h1>
      <div class="text-xs text-slate-800 mt-1 uppercase font-semibold tracking-wider">Inspector</div>
    </div>

    <div class="p-4 flex-1 flex flex-col gap-5 overflow-y-auto">
      <div>
        <div class="text-[10px] font-bold text-slate-800 uppercase tracking-widest mb-2">接続</div>
        <div class="flex items-center gap-2 text-sm font-bold">
          {#if $connection === 'open'}
            <div class="w-2 h-2 bg-emerald-500 rounded-full animate-pulse"></div>
            <span class="text-[#0A1C56]">Core に接続中</span>
          {:else if $connection === 'unauthorized'}
            <div class="w-2 h-2 bg-red-500 rounded-full"></div>
            <span class="text-red-700">トークンが必要です (起動ログの URL を開く)</span>
          {:else}
            <div class="w-2 h-2 bg-amber-500 rounded-full animate-pulse"></div>
            <span class="text-amber-700">再接続中...</span>
          {/if}
        </div>
      </div>

      <ChatSimulator />

      <div class="flex flex-col gap-2">
        <div class="text-[10px] font-bold text-slate-800 uppercase tracking-widest mb-1">メトリクス</div>
        <MetricCard label="処理速度" unit="EPS" />
        <div class="border border-slate-200 bg-white p-3 flex flex-col gap-1 shadow-sm rounded">
          <div class="text-[10px] font-bold text-slate-800 uppercase">累計イベント数</div>
          <div class="text-xl font-mono text-[#0A1C56] font-bold">{$metrics.totalEvents.toLocaleString()}</div>
        </div>
      </div>

      <IntrospectionToggle />

      <div>
        <div class="text-[10px] font-bold text-slate-800 uppercase tracking-widest mb-2">メニュー</div>
        <nav class="flex flex-col gap-1 text-sm">
          {#each TABS as t}
            <button
              class="text-left px-3 py-2 rounded font-medium transition-all cursor-pointer {activeTab === t.id ? 'bg-[#0A1C56] text-white shadow-sm' : 'text-slate-800 hover:bg-slate-200'}"
              onclick={() => (activeTab = t.id)}
            >
              {t.label}
            </button>
          {/each}
        </nav>
      </div>
    </div>
  </aside>

  <section class="flex-1 flex flex-col min-w-0 bg-white overflow-hidden">
    <header class="p-4 border-b border-slate-200 flex justify-between items-center bg-white shrink-0">
      <h2 class="font-bold text-[#0A1C56]">{TABS.find((t) => t.id === activeTab)?.title}</h2>
    </header>

    <div class="flex-1 p-4 overflow-auto bg-slate-50/50">
      {#if activeTab === 'inspector'}
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-4">
          <div class="lg:col-span-2 flex flex-col gap-4">
            <ObsPreview />
            <FaultTimeline />
          </div>
          <div class="lg:col-span-3 flex flex-col gap-4">
            <CellMap />
            <SecurityFeed />
          </div>
        </div>
      {:else if activeTab === 'stream'}
        <div class="h-full flex flex-col min-h-0"><EventLog /></div>
      {:else}
        <div class="h-full flex flex-col min-h-0"><NodeGraph /></div>
      {/if}
    </div>
  </section>
</main>
