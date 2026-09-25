<script lang="ts">
  import { introspection } from '../stores';
  import { send } from '../websocket';

  const LEVELS = [
    { id: 'off', label: 'OFF', hint: 'システムイベントのみ' },
    { id: 'metadata', label: 'META', hint: 'チャット本文などの中身は隠す (既定)' },
    { id: 'contents', label: 'FULL', hint: '中身まで表示 (開発時のみ)' },
  ] as const;
</script>

<div>
  <div class="card-t mb-1.5">観測レベル</div>
  <div class="flex rounded border border-[var(--line)] overflow-hidden">
    {#each LEVELS as l}
      <button
        class="flex-1 py-1 text-[11px] font-bold cursor-pointer transition-colors {$introspection === l.id ? 'bg-[var(--surface-2)] text-[var(--live)] ring-1 ring-inset ring-[color-mix(in_oklab,var(--live)_40%,transparent)]' : 'bg-[var(--surface)] text-[var(--t-lo)] hover:bg-[var(--surface-2)]'}"
        title={l.hint}
        onclick={() => send('core.system.introspection', l.id)}
      >
        {l.label}
      </button>
    {/each}
  </div>
</div>
