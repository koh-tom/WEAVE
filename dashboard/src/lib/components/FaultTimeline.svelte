<script lang="ts">
  import { faultTimeline } from '../stores';
</script>

<div class="panel">
  <div class="panel-h"><span class="panel-t">障害と自動復帰</span></div>
  <div class="max-h-56 overflow-auto">
    <table class="tbl">
      <thead><tr><th>時刻</th><th>できごと</th><th>プラグイン</th><th>内容</th></tr></thead>
      <tbody>
        {#each $faultTimeline as f, i (f.ts + ':' + i)}
          <tr>
            <td class="mono dim whitespace-nowrap">{new Date(f.ts).toLocaleTimeString([], { hour12: false })}</td>
            {#if f.kind === 'fault'}
              <td class="bad">障害</td>
            {:else if f.kind === 'recovered'}
              <td class="ok">復帰</td>
            {:else}
              <td class="dim">停止</td>
            {/if}
            <td class="mono">{f.node}</td>
            <td>{f.detail}{#if f.downtimeMs !== undefined}<b class="ok"> (止まっていた時間 {f.downtimeMs} ms)</b>{/if}</td>
          </tr>
        {:else}
          <tr><td colspan="4" class="dim">障害はまだ起きていません</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
</div>
