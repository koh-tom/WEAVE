<script lang="ts">
  import { SvelteFlow, Controls, Background, BackgroundVariant } from '@xyflow/svelte';
  import { systemGraph, selectedNode, blast, nodes } from '../stores';
  
  // Svelte Flow の基本スタイルをインポート
  import '@xyflow/svelte/dist/style.css';
</script>

<div class="flex-1 w-full h-full card overflow-hidden relative">
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
        <div class="absolute top-3 left-3 max-w-xs card px-3.5 py-3 text-xs text-[var(--t-hi)]" style="box-shadow:0 8px 30px rgba(0,0,0,.4)" data-testid="blast-panel">
            <div class="font-bold text-[var(--warn)] flex items-center gap-1.5"><span class="dot" style="background:var(--warn)"></span>影響範囲: {$nodes[$blast.origin]?.name}</div>
            <div class="mt-1.5 text-[var(--t-mid)]">乗っ取られた / 落ちたときに届きうるノード: <b class="text-[var(--t-hi)] tnum">{$blast.reach.size}</b></div>
            {#if $blast.reach.size > 0}
                <div class="mt-0.5 text-[var(--t-mid)]">{[...$blast.reach].map((id) => $nodes[id]?.name ?? id).join(', ')}</div>
            {/if}
            <div class="mt-1 font-bold {$blast.sinks.length > 0 ? 'text-[var(--danger)]' : 'text-[var(--live)]'}">
                実世界 (OBS) への到達: {$blast.sinks.length > 0 ? `あり (${$blast.sinks.join(', ')})` : 'なし'}
            </div>
            <div class="mt-2 pt-2 border-t border-[var(--line-soft)] text-[10px] text-[var(--t-lo)]">ノードをもう一度クリック / 背景クリックで解除。起動前の予測は weave audit</div>
        </div>
    {:else if $systemGraph.nodes.length > 0}
        <div class="absolute top-2 left-2 rounded bg-[var(--surface)]/80 px-2 py-1 text-[10px] text-[var(--t-mid)] pointer-events-none">ノードをクリックすると影響範囲を表示</div>
    {/if}

    {#if $systemGraph.nodes.length === 0}
        <div class="absolute inset-0 flex items-center justify-center pointer-events-none text-[var(--t-lo)] italic text-sm">
            トポロジを待機中…
        </div>
    {/if}
</div>

<style>
    /* Svelte Flow のテーマカスタマイズ */
    :global(.xyflow__node) {
        border-radius: 10px !important;
        font-weight: 600 !important;
        font-size: 12px !important;
        font-family: var(--mono) !important;
    }
    :global(.xyflow) { background: transparent !important; }
    :global(.xyflow__edge-textbg) { fill: var(--surface) !important; }
    :global(.xyflow__controls) { box-shadow: none !important; }
    :global(.xyflow__controls-button) {
        background: var(--surface-2) !important;
        border-bottom: 1px solid var(--line) !important;
        fill: var(--t-mid) !important;
    }
    :global(.xyflow__controls-button:hover) { background: var(--raised) !important; }
    :global(.xyflow__attribution) { display: none !important; }
</style>
