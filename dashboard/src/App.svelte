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

<main class="flex h-screen text-[var(--t-hi)] overflow-hidden">
  <aside class="w-[268px] border-r border-[var(--line)] flex flex-col bg-[var(--bg)] shrink-0">
    <div class="px-5 pt-5 pb-4 border-b border-[var(--line)]">
      <div class="flex items-center gap-2.5">
        <svg width="26" height="26" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <path d="M3 6h4l2.5 12L12 8l2.5 10L17 6h4" stroke="var(--live)" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        <div>
          <div class="font-bold text-[17px] tracking-[0.06em] leading-none">WEAVE</div>
          <div class="text-[10px] text-[var(--t-lo)] mt-1 uppercase tracking-[0.22em]">Inspector</div>
        </div>
      </div>
    </div>

    <nav class="px-3 pt-3 flex flex-col gap-0.5">
      {#each TABS as t}
        <button
          class="text-left px-3 py-2 rounded-lg text-[13px] font-medium transition-colors cursor-pointer flex items-center gap-2.5 {activeTab === t.id ? 'bg-[var(--surface-2)] text-[var(--t-hi)] ring-1 ring-[var(--line)]' : 'text-[var(--t-mid)] hover:bg-[var(--surface-2)]/60 hover:text-[var(--t-hi)]'}"
          onclick={() => (activeTab = t.id)}
        >
          <span class="w-1 h-4 rounded-full {activeTab === t.id ? 'bg-[var(--live)]' : 'bg-transparent'}"></span>
          {t.label}
        </button>
      {/each}
    </nav>

    <div class="px-4 pt-5 flex-1 flex flex-col gap-5 overflow-y-auto pb-4">
      <ChatSimulator />

      <div class="flex flex-col gap-2">
        <div class="card-t mb-0.5">メトリクス</div>
        <MetricCard label="処理速度" unit="EPS" />
        <div class="card p-3 flex flex-col gap-1">
          <div class="text-[10px] font-bold text-[var(--t-lo)] uppercase tracking-wider">累計イベント</div>
          <div class="text-xl mono tnum text-[var(--t-hi)] font-bold">{$metrics.totalEvents.toLocaleString()}</div>
        </div>
      </div>

      <IntrospectionToggle />
    </div>

    <div class="px-5 py-3.5 border-t border-[var(--line)] flex items-center gap-2 text-[12px] font-semibold">
      {#if $connection === 'open'}
        <span class="dot pulse text-[var(--live)]" style="background:var(--live)"></span>
        <span class="text-[var(--t-mid)]">Core に接続中</span>
      {:else if $connection === 'unauthorized'}
        <span class="dot" style="background:var(--danger)"></span>
        <span class="text-[var(--danger)]">トークンが必要です</span>
      {:else}
        <span class="dot pulse text-[var(--warn)]" style="background:var(--warn)"></span>
        <span class="text-[var(--warn)]">再接続中…</span>
      {/if}
    </div>
  </aside>

  <section class="flex-1 flex flex-col min-w-0 overflow-hidden">
    <header class="px-5 h-[52px] border-b border-[var(--line)] flex justify-between items-center shrink-0">
      <h2 class="font-semibold text-[15px] text-[var(--t-hi)] tracking-tight">{TABS.find((t) => t.id === activeTab)?.title}</h2>
      <div class="text-[11px] mono text-[var(--t-lo)]">core.weave · localhost</div>
    </header>

    <div class="flex-1 p-5 overflow-auto bg-[var(--bg)]">
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
