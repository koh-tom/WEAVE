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

<div class="border border-slate-200 rounded bg-white shadow-sm flex flex-col">
  <div class="px-3 py-2 border-b border-slate-200 flex items-center justify-between">
    <div class="text-[10px] font-bold uppercase tracking-widest text-slate-800">現実世界 — 配信画面 (OBS)</div>
    <div class="flex items-center gap-2 text-[10px] font-bold">
      {#if $obsState.link === true}
        <span class="px-1.5 py-0.5 rounded bg-emerald-100 text-emerald-700">OBS 接続中</span>
      {:else if $obsState.link === false}
        <span class="px-1.5 py-0.5 rounded bg-amber-100 text-amber-700 animate-pulse">OBS 再接続待ち (状態は保持)</span>
      {:else}
        <span class="px-1.5 py-0.5 rounded bg-slate-100 text-slate-600">mock OBS</span>
      {/if}
      {#if $obsState.reconnects > 0}
        <span class="px-1.5 py-0.5 rounded bg-slate-100 text-slate-700">再接続 {$obsState.reconnects} 回 / 状態を自動再適用</span>
      {/if}
    </div>
  </div>

  <!-- 16:9 の仮想プレビュー -->
  <div class="relative m-3 rounded overflow-hidden bg-slate-900" style="aspect-ratio: 16 / 9;">
    <div class="absolute top-2 left-2 flex items-center gap-1.5 bg-red-600 text-white text-[10px] font-bold px-2 py-0.5 rounded">
      <span class="w-1.5 h-1.5 rounded-full bg-white animate-pulse"></span>
      ON AIR {fmt(now - sessionStart)}
    </div>
    <div class="absolute inset-0 flex items-center justify-center text-slate-500 text-xs font-mono">GAME CAPTURE</div>
    {#if grassOn}
      <div class="absolute inset-x-0 bottom-0 h-1/3 flex items-end justify-center pb-3 grass">
        <span class="text-emerald-300 text-2xl font-black tracking-widest drop-shadow">ｗｗｗ 草 草 草 ｗｗｗ</span>
      </div>
    {/if}
  </div>

  <div class="px-3 pb-3">
    <div class="text-[10px] font-bold uppercase tracking-widest text-slate-800 mb-1">シーンアイテム</div>
    {#if items.length === 0}
      <div class="text-xs text-slate-500 italic">まだ OBS への要求はありません</div>
    {:else}
      <table class="w-full text-[11px] font-mono">
        <thead>
          <tr class="text-slate-500 text-left">
            <th class="font-semibold">item</th>
            <th class="font-semibold">WEAVE の意図</th>
            <th class="font-semibold">OBS の実状態</th>
          </tr>
        </thead>
        <tbody>
          {#each items as i (i.key)}
            <tr>
              <td class="text-slate-800">{i.key}</td>
              <td>{i.requested === undefined ? '—' : i.requested ? 'visible' : 'hidden'}</td>
              <td class={i.actual === undefined ? 'text-slate-400' : i.actual === i.requested ? 'text-emerald-700' : 'text-amber-700'}>
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
    background: linear-gradient(to top, rgba(16, 185, 129, 0.55), transparent);
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
