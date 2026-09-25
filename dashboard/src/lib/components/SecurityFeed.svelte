<script lang="ts">
  import { onDestroy } from 'svelte';
  import { securityEvents } from '../stores';

  const KIND_LABEL: Record<string, string> = {
    acl_denied: '権限外の操作を拒否',
    rate_limited: '流量上限でドロップ',
    signature_invalid: '署名検証に失敗',
    auth_failed: '認証に失敗',
    manifest_rejected: 'manifest を拒否',
    loop_detected: '無限反響 (ハウリング) を遮断',
  };

  let now = $state(Date.now());
  const timer = setInterval(() => (now = Date.now()), 500);
  onDestroy(() => clearInterval(timer));

  let latest = $derived($securityEvents[0]);
  let recent = $derived(latest !== undefined && now - latest.ts < 5000);
</script>

<div class="card flex flex-col min-h-0">
  <div class="card-h">
    <div class="card-t">強制点 (Host API / 各入口) で止めたもの</div>
    <div class="text-[10px] text-[var(--t-mid)]">{$securityEvents.length} 件</div>
  </div>
  {#if recent && latest}
    <div class="mx-3 mt-3 rounded-lg px-3 py-2.5 text-xs font-bold flex items-center justify-between gap-3"
         style="background: var(--danger-d); border:1px solid color-mix(in oklab, var(--danger) 40%, transparent); color: var(--danger)">
      <span class="flex items-center gap-2"><span class="dot pulse" style="background:var(--danger)"></span>DENIED — {KIND_LABEL[latest.kind] ?? latest.kind}</span>
      <span class="mono text-[var(--t-hi)]">{latest.node} → {latest.detail}</span>
    </div>
  {/if}
  <div class="overflow-auto p-2 flex flex-col max-h-56">
    {#each $securityEvents as e, i (e.ts + ':' + i)}
      <div class="flex gap-2.5 text-[11px] mono items-baseline px-1.5 py-1 rounded hover:bg-[var(--surface-2)]/60">
        <span class="text-[var(--t-lo)] w-16 shrink-0 tnum">{new Date(e.ts).toLocaleTimeString([], { hour12: false })}</span>
        <span class="text-[var(--danger)] font-semibold w-40 shrink-0">{KIND_LABEL[e.kind] ?? e.kind}</span>
        <span class="text-[var(--t-hi)] shrink-0">{e.node}</span>
        <span class="text-[var(--t-mid)] truncate">{e.detail}</span>
      </div>
    {:else}
      <div class="text-xs text-[var(--t-lo)] italic p-2">まだ何も拒否していません</div>
    {/each}
  </div>
</div>
