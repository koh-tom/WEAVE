<script lang="ts">
  import { SvelteFlow, Controls } from '@xyflow/svelte';
  import { systemGraph, selectedNode, blast, nodes } from '../stores';
  import '@xyflow/svelte/dist/style.css';
</script>

<div class="panel flex-1 w-full h-full flex flex-col min-h-0">
  <div class="panel-h">
    <span class="panel-t">プラグインのつながり</span>
    <span class="panel-note">プラグインをクリックすると、そこが乗っ取られたり落ちたりしたときに影響する範囲を表示</span>
  </div>
  <div class="flex-1 relative min-h-0">
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
      <Controls showLock={false} />
    </SvelteFlow>

    {#if $blast}
      <div class="absolute top-2 left-2 max-w-xs panel text-[12px]" data-testid="blast-panel">
        <div class="panel-h"><span class="panel-t">影響範囲: {$nodes[$blast.origin]?.name}</span></div>
        <div class="p-2 flex flex-col gap-1">
          <div>届きうるプラグイン: <b class="tnum">{$blast.reach.size}</b>
            {#if $blast.reach.size > 0}<span class="dim"> ({[...$blast.reach].map((id) => $nodes[id]?.name ?? id).join(', ')})</span>{/if}
          </div>
          <div class={$blast.sinks.length > 0 ? 'bad' : 'ok'}>
            配信画面 (OBS) まで届くか: {$blast.sinks.length > 0 ? `届く (${$blast.sinks.join(', ')})` : '届かない'}
          </div>
          <div class="dim text-[11px]">もう一度クリックか背景のクリックで解除。起動前の確認は weave audit</div>
        </div>
      </div>
    {/if}

    {#if $systemGraph.nodes.length === 0}
      <div class="absolute inset-0 flex items-center justify-center dim">Core からの情報を待っています…</div>
    {/if}
  </div>
</div>

<style>
  :global(.xyflow) { background: #fff !important; }
  :global(.xyflow__node) { font-family: var(--mono) !important; font-size: 11px !important; }
  :global(.xyflow__edge-textbg) { fill: #fff !important; }
  :global(.xyflow__controls) { border: 1px solid var(--line); }
  :global(.xyflow__controls-button) { background: #f3f3f3 !important; border-bottom: 1px solid var(--line) !important; }
  :global(.xyflow__attribution), :global(.svelte-flow__attribution) { display: none !important; }
  :global(.svelte-flow) { background: #fff !important; }
  :global(.svelte-flow__edge-textbg) { fill: #fff !important; }
  :global(.svelte-flow__controls) { border: 1px solid var(--line); box-shadow: none !important; }
</style>
