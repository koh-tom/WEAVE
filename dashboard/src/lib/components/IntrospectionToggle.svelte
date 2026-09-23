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
  <div class="text-[10px] font-bold text-slate-800 uppercase tracking-widest mb-1.5">観測レベル</div>
  <div class="flex rounded border border-slate-200 overflow-hidden">
    {#each LEVELS as l}
      <button
        class="flex-1 py-1 text-[11px] font-bold cursor-pointer transition-colors {$introspection === l.id ? 'bg-[#0A1C56] text-white' : 'bg-white text-slate-700 hover:bg-slate-100'}"
        title={l.hint}
        onclick={() => send('core.system.introspection', l.id)}
      >
        {l.label}
      </button>
    {/each}
  </div>
</div>
