<script lang="ts">
  import { onDestroy } from 'svelte';
  import { obsState, sessionStart } from '../stores';

  // 「配信は止まっていない」ことを見せるための経過時間
  let now = $state(Date.now());
  const timer = setInterval(() => (now = Date.now()), 250);
  onDestroy(() => clearInterval(timer));

  function fmt(ms: number): string {
    const s = Math.floor(ms / 1000);
    const hh = String(Math.floor(s / 3600)).padStart(2, '0');
    const mm = String(Math.floor((s % 3600) / 60)).padStart(2, '0');
    const ss = String(s % 60).padStart(2, '0');
    return `${hh}:${mm}:${ss}`;
  }

  // 実際の状態 (OBS からの報告) を優先し、無ければ WEAVE が要求した状態を表示する
  let items = $derived.by(() => {
    const keys = new Set([...Object.keys($obsState.requested), ...Object.keys($obsState.actual)]);
    return [...keys].sort().map((k) => ({
      key: k,
      requested: $obsState.requested[k],
      actual: $obsState.actual[k],
      shown: $obsState.actual[k] ?? $obsState.requested[k] ?? false,
    }));
  });
  let grassOn = $derived(items.some((i) => i.key === 'Overlay#1' && i.shown));
</script>

<div class="card flex flex-col">
  <div class="card-h">
    <div class="card-t">現実世界 — 配信画面 (OBS)</div>
    <div class="flex items-center gap-2 text-[10px] font-bold">
      {#if $obsState.link === true}
        <span class="badge live">OBS 接続中</span>
      {:else if $obsState.link === false}
        <span class="badge warn">OBS 再接続待ち · 状態は保持</span>
      {:else}
        <span class="badge" style="background:var(--surface-2);color:var(--t-lo);border:1px solid var(--line)">mock OBS</span>
      {/if}
      {#if $obsState.reconnects > 0}
        <span class="badge" style="background:var(--surface-2);color:var(--t-mid);border:1px solid var(--line)">再接続 {$obsState.reconnects} 回 · 自動再適用</span>
      {/if}
    </div>
  </div>

  <!-- 16:9 の仮想プレビュー -->
  <div class="relative m-3 rounded overflow-hidden bg-[var(--bg)]" style="aspect-ratio: 16 / 9;">
    <div class="absolute top-2.5 left-2.5 flex items-center gap-1.5 text-[10px] font-bold px-2 py-1 rounded" style="background:var(--danger);color:#0b0d12">
      <span class="w-1.5 h-1.5 rounded-full bg-[#0b0d12] animate-pulse"></span>
      ON AIR {fmt(now - sessionStart)}
    </div>
    <div class="absolute inset-0 flex items-center justify-center text-[var(--t-mid)] text-xs font-mono">GAME CAPTURE</div>
    {#if grassOn}
      <div class="absolute inset-x-0 bottom-0 h-1/3 flex items-end justify-center pb-3 grass">
        <span class="text-[var(--live)] text-2xl font-black tracking-widest" style="text-shadow:0 0 20px rgba(52,226,164,.6)">ｗｗｗ 草 草 草 ｗｗｗ</span>
      </div>
    {/if}
  </div>

  <div class="px-3 pb-3">
    <div class="card-t mb-1">シーンアイテム</div>
    {#if items.length === 0}
      <div class="text-xs text-[var(--t-mid)] italic">まだ OBS への要求はありません</div>
    {:else}
      <table class="w-full text-[11px] font-mono">
        <thead>
          <tr class="text-[var(--t-mid)] text-left">
            <th class="font-semibold">item</th>
            <th class="font-semibold">WEAVE の意図</th>
            <th class="font-semibold">OBS の実状態</th>
          </tr>
        </thead>
        <tbody>
          {#each items as i (i.key)}
            <tr>
              <td class="text-[var(--t-hi)]">{i.key}</td>
              <td>{i.requested === undefined ? '—' : i.requested ? 'visible' : 'hidden'}</td>
              <td class={i.actual === undefined ? 'text-[var(--t-lo)]' : i.actual === i.requested ? 'text-[var(--live)]' : 'text-[var(--warn)]'}>
                {i.actual === undefined ? '(報告なし)' : i.actual ? 'visible' : 'hidden'}
              </td>
            </tr>
          {/each}
        </tbody>
      </table>
    {/if}
  </div>
</div>

<style>
  .grass {
    background: linear-gradient(to top, rgba(52, 226, 164, 0.35), transparent);
    animation: grow 0.35s ease-out;
  }
  @keyframes grow {
    from {
      transform: translateY(40%);
      opacity: 0;
    }
    to {
      transform: translateY(0);
      opacity: 1;
    }
  }
</style>
