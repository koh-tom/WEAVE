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

<div class="border border-slate-200 rounded bg-white shadow-sm flex flex-col min-h-0">
  <div class="px-3 py-2 border-b border-slate-200 flex items-center justify-between">
    <div class="text-[10px] font-bold uppercase tracking-widest text-slate-800">強制点 (Host API / 各入口) で止めたもの</div>
    <div class="text-[10px] text-slate-600">{$securityEvents.length} 件</div>
  </div>
  {#if recent && latest}
    <div class="mx-3 mt-2 rounded bg-red-600 text-white px-3 py-2 text-xs font-bold flex items-center justify-between">
      <span>DENIED — {KIND_LABEL[latest.kind] ?? latest.kind}</span>
      <span class="font-mono">{latest.node} → {latest.detail}</span>
    </div>
  {/if}
  <div class="overflow-auto p-2 flex flex-col gap-1 max-h-56">
    {#each $securityEvents as e, i (e.ts + ':' + i)}
      <div class="flex gap-2 text-[11px] font-mono items-baseline">
        <span class="text-slate-500 w-16 shrink-0">{new Date(e.ts).toLocaleTimeString([], { hour12: false })}</span>
        <span class="text-red-700 font-bold w-36 shrink-0">{KIND_LABEL[e.kind] ?? e.kind}</span>
        <span class="text-[#0A1C56] truncate">{e.node}</span>
        <span class="text-slate-700 truncate">{e.detail}</span>
      </div>
    {:else}
      <div class="text-xs text-slate-500 italic p-1">まだ何も拒否していません</div>
    {/each}
  </div>
</div>
