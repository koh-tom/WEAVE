<script lang="ts">
  import { SvelteFlow, Controls, Background, BackgroundVariant } from '@xyflow/svelte';
  import { systemGraph } from '../stores';
  
  // Svelte Flow の基本スタイルをインポート
  import '@xyflow/svelte/dist/style.css';
</script>

<div class="flex-1 w-full h-full bg-white border border-slate-200 shadow-inner overflow-hidden relative">
    <SvelteFlow
        nodes={$systemGraph.nodes}
        edges={$systemGraph.edges}
        fitView
        colorMode="light"
        minZoom={0.2}
        maxZoom={2}
    >
        <Background variant={BackgroundVariant.Dots} color="#cbd5e1" gap={20} size={1} />
        <Controls />
    </SvelteFlow>
    
    {#if $systemGraph.nodes.length === 0}
        <div class="absolute inset-0 flex items-center justify-center pointer-events-none text-slate-300 italic text-sm">
            Waiting for topology data...
        </div>
    {/if}
</div>

<style>
    /* Svelte Flow のテーマカスタマイズ */
    :global(.xyflow__node) {
        border-radius: 4px !important;
        border: 2px solid #0A1C56 !important;
        background: white !important;
        color: #0A1C56 !important;
        font-weight: bold !important;
        font-size: 12px !important;
    }
    :global(.xyflow__edge-path) {
        stroke: #0A1C56 !important;
        stroke-width: 2px !important;
    }
    :global(.xyflow__controls-button) {
        background: white !important;
        border-bottom: 1px solid #e2e8f0 !important;
        fill: #0A1C56 !important;
    }
</style>
