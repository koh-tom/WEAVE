<script lang="ts">
  import { SvelteFlow, Controls, Background, BackgroundVariant } from '@xyflow/svelte';
  import { systemGraph, selectedNode, blast, nodes } from '../stores';
  
  // Svelte Flow の基本スタイルをインポート
  import '@xyflow/svelte/dist/style.css';
</script>

<div class="flex-1 w-full h-full bg-[var(--surface)] border border-[var(--line)] shadow-inner overflow-hidden relative">
    <SvelteFlow
        nodes={$systemGraph.nodes}
        edges={$systemGraph.edges}
        fitView
        colorMode="light"
        minZoom={0.2}
        maxZoom={2}
        onnodeclick={({ node }) => selectedNode.update((cur) => (cur === Number(node.id) ? null : Number(node.id)))}
        onpaneclick={() => selectedNode.set(null)}
    >
        <Background variant={BackgroundVariant.Dots} patternColor="#cbd5e1" gap={20} size={1} />
        <Controls />
    </SvelteFlow>
    
    {#if $blast}
        <div class="absolute top-2 left-2 max-w-xs rounded-md border border-orange-300 bg-orange-50/95 px-3 py-2 text-xs text-[var(--t-hi)] shadow" data-testid="blast-panel">
            <div class="font-bold text-orange-700">影響範囲: {$nodes[$blast.origin]?.name}</div>
            <div class="mt-1">乗っ取られた / 落ちたときに届きうるノード: <b>{$blast.reach.size}</b></div>
            {#if $blast.reach.size > 0}
                <div class="mt-0.5 text-[var(--t-mid)]">{[...$blast.reach].map((id) => $nodes[id]?.name ?? id).join(', ')}</div>
            {/if}
            <div class="mt-1 font-bold {$blast.sinks.length > 0 ? 'text-[var(--danger)]' : 'text-[var(--live)]'}">
                実世界 (OBS) への到達: {$blast.sinks.length > 0 ? `あり (${$blast.sinks.join(', ')})` : 'なし'}
            </div>
            <div class="mt-1 text-[10px] text-[var(--t-mid)]">ノードをもう一度クリック / 背景クリックで解除。起動前の予測は weave audit</div>
        </div>
    {:else if $systemGraph.nodes.length > 0}
        <div class="absolute top-2 left-2 rounded bg-[var(--surface)]/80 px-2 py-1 text-[10px] text-[var(--t-mid)] pointer-events-none">ノードをクリックすると影響範囲を表示</div>
    {/if}

    {#if $systemGraph.nodes.length === 0}
        <div class="absolute inset-0 flex items-center justify-center pointer-events-none text-[var(--t-lo)] italic text-sm">
            Waiting for topology data...
        </div>
    {/if}
</div>

<style>
    /* Svelte Flow のテーマカスタマイズ */
    :global(.xyflow__node) {
        border-radius: 4px !important;
        border: 2px solid var(--accent) !important;
        background: white !important;
        color: var(--accent) !important;
        font-weight: bold !important;
        font-size: 12px !important;
    }
    :global(.xyflow__edge-path) {
        stroke: var(--accent) !important;
        stroke-width: 2px !important;
    }
    :global(.xyflow__controls-button) {
        background: white !important;
        border-bottom: 1px solid #e2e8f0 !important;
        fill: var(--accent) !important;
    }
</style>
