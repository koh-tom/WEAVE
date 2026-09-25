<script lang="ts">
  import { onDestroy } from 'svelte';
  import { securityEvents } from '../stores';

  const KIND_LABEL: Record<string, string> = {
    acl_denied: '許可されていない操作を拒否',
    rate_limited: '送りすぎを止めた',
    signature_invalid: '署名が合わない',
    auth_failed: '認証に失敗',
    manifest_rejected: '申告内容を拒否',
    loop_detected: 'ツール同士の無限反応を止めた',
    limit_exceeded: '暴走を上限で止めた',
  };

  let now = $state(Date.now());
  const timer = setInterval(() => (now = Date.now()), 500);
  onDestroy(() => clearInterval(timer));

  let latest = $derived($securityEvents[0]);
  let recent = $derived(latest !== undefined && now - latest.ts < 5000);
</script>

<div class="panel">
  <div class="panel-h">
    <span class="panel-t">WEAVE が止めた操作</span>
    <span class="panel-note">{$securityEvents.length} 件</span>
  </div>
  {#if recent && latest}
    <div class="px-2 py-1 border-b border-[var(--line)] bad font-bold">
      いま止めました: {KIND_LABEL[latest.kind] ?? latest.kind} — <span class="mono">{latest.node}</span> → <span class="mono">{latest.detail}</span>
    </div>
  {/if}
  <div class="max-h-64 overflow-auto">
    <table class="tbl">
      <thead><tr><th>時刻</th><th>内容</th><th>プラグイン</th><th>やろうとしたこと</th></tr></thead>
      <tbody>
        {#each $securityEvents as e, i (e.ts + ':' + i)}
          <tr>
            <td class="mono dim whitespace-nowrap">{new Date(e.ts).toLocaleTimeString([], { hour12: false })}</td>
            <td class="bad whitespace-nowrap">{KIND_LABEL[e.kind] ?? e.kind}</td>
            <td class="mono">{e.node}</td>
            <td class="mono dim">{e.detail}</td>
          </tr>
        {:else}
          <tr><td colspan="4" class="dim">まだ何も止めていません</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
</div>
