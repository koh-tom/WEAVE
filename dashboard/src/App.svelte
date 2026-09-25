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

  const TABS: { id: Tab; label: string }[] = [
    { id: 'inspector', label: '状態' },
    { id: 'stream', label: 'イベント' },
    { id: 'topology', label: 'つながり' },
  ];

  onMount(() => connect());
</script>

<div class="h-screen flex flex-col overflow-hidden">
  <header class="flex items-center gap-4 px-3 h-9 border-b border-[var(--line)] shrink-0">
    <b>WEAVE Inspector</b>
    <nav class="flex gap-1">
      {#each TABS as t}
        <button class="btn {activeTab === t.id ? 'on' : ''}" onclick={() => (activeTab = t.id)}>{t.label}</button>
      {/each}
    </nav>
    <span class="ml-auto text-[12px]">
      {#if $connection === 'open'}
        <span class="ok">● Core に接続中</span>
      {:else if $connection === 'unauthorized'}
        <span class="bad">● トークンが必要です (URL に ?token=)</span>
      {:else}
        <span class="warn">● 再接続中…</span>
      {/if}
    </span>
  </header>

  <div class="flex-1 flex min-h-0">
    <aside class="w-[240px] shrink-0 border-r border-[var(--line)] p-2 flex flex-col gap-2 overflow-y-auto">
      <ChatSimulator />
      <MetricCard label="処理速度" unit="件/秒" />
      <div class="panel">
        <div class="panel-h"><span class="panel-t">累計イベント</span></div>
        <div class="px-2 py-1 mono tnum text-[15px]">{$metrics.totalEvents.toLocaleString()}</div>
      </div>
      <IntrospectionToggle />
    </aside>

    <main class="flex-1 min-w-0 overflow-auto p-2">
      {#if activeTab === 'inspector'}
        <div class="grid grid-cols-1 lg:grid-cols-5 gap-2">
          <div class="lg:col-span-2 flex flex-col gap-2">
            <ObsPreview />
            <FaultTimeline />
          </div>
          <div class="lg:col-span-3 flex flex-col gap-2">
            <CellMap />
            <SecurityFeed />
          </div>
        </div>
      {:else if activeTab === 'stream'}
        <div class="h-full flex flex-col min-h-0"><EventLog /></div>
      {:else}
        <div class="h-full flex flex-col min-h-0"><NodeGraph /></div>
      {/if}
    </main>
  </div>
</div>
