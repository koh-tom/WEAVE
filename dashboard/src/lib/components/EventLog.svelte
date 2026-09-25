<script lang="ts">
  import { eventLogs } from '../stores';

  function isHidden(p: any): boolean {
    return p && typeof p === 'object' && p.hidden === true;
  }
</script>

<div class="panel flex-1 flex flex-col min-h-0">
  <div class="panel-h">
    <span class="panel-t">イベント (新しい順)</span>
    <span class="panel-note">最新 {$eventLogs.length} 件</span>
  </div>
  <div class="flex-1 overflow-auto">
    <table class="tbl mono">
      <thead><tr><th>時刻</th><th>トピック</th><th>発行元</th><th>中身</th></tr></thead>
      <tbody>
        {#each $eventLogs as log, i (String(log.id ?? '') + ':' + log.ts + ':' + i)}
          <tr>
            <td class="whitespace-nowrap dim">{new Date(log.ts).toLocaleTimeString([], { hour12: false })}</td>
            <td class="whitespace-nowrap">{log.topic}</td>
            <td class="dim">{log.origin}</td>
            {#if isHidden(log.payload)}
              <td class="dim">(非表示: 観測レベルが「中身を隠す」。{log.payload.size} バイト)</td>
            {:else}
              <td class="break-all">{JSON.stringify(log.payload)}</td>
            {/if}
          </tr>
        {:else}
          <tr><td colspan="4" class="dim">イベントを待っています…</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
</div>
