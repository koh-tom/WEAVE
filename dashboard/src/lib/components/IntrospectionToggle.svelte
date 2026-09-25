<script lang="ts">
  import { introspection } from '../stores';
  import { send } from '../websocket';

  const LEVELS = [
    { id: 'off', label: '出さない', hint: 'システムのイベントだけ' },
    { id: 'metadata', label: '中身を隠す', hint: 'チャット本文などは隠す (既定)' },
    { id: 'contents', label: '全部', hint: '中身まで表示 (開発時だけ)' },
  ] as const;
</script>

<div class="panel">
  <div class="panel-h"><span class="panel-t">イベントの見せ方</span></div>
  <div class="p-2 flex flex-col gap-1">
    {#each LEVELS as l}
      <label class="flex items-start gap-1.5 text-[12px] cursor-pointer">
        <input type="radio" name="introspection" class="mt-0.5" checked={$introspection === l.id}
          onchange={() => send('core.system.introspection', l.id)} />
        <span>{l.label}<br /><span class="dim text-[11px]">{l.hint}</span></span>
      </label>
    {/each}
  </div>
</div>
