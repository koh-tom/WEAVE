<script lang="ts">
  import { onDestroy } from 'svelte';
  import { obsState, obsText, sessionStart } from '../stores';

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
  // オーバーレイ (Overlay#1 = サブのお祝い / Overlay#2 = シャウトアウト) が出ているか、その文言
  let overlayOn = $derived(items.some((i) => (i.key === 'Overlay#1' || i.key === 'Overlay#2') && i.shown));
  let overlayText = $derived($obsText['Overlay'] ?? '');
  let subGoal = $derived($obsText['SubGoal'] ?? '');
</script>

<div class="panel">
  <div class="panel-h">
    <span class="panel-t">配信画面 (OBS)</span>
    <span class="panel-note">
      {#if $obsState.link === true}
        <span class="ok">OBS に接続中</span>
      {:else if $obsState.link === false}
        <span class="warn">OBS の再起動を待っています (表示したい状態は覚えています)</span>
      {:else}
        模擬 OBS
      {/if}
      {#if $obsState.reconnects > 0} · 再接続 {$obsState.reconnects} 回 (そのたびに表示を戻しました){/if}
    </span>
  </div>

  <div class="p-2">
    <!-- 16:9 の仮想プレビュー -->
    <div class="relative border border-[var(--line)] bg-[#e9e9e9]" style="aspect-ratio: 16 / 9;">
      <div class="absolute top-1.5 left-1.5 px-1.5 text-[11px] font-bold mono bg-[var(--bad)] text-white">
        配信中 {fmt(now - sessionStart)}
      </div>
      <div class="absolute inset-0 flex items-center justify-center dim text-[12px]">ゲーム画面</div>
      <!-- 配信画面に常に出しておくウィジェット (サブ目標バー) -->
      {#if subGoal}
        <div class="absolute top-1.5 right-1.5 px-2 py-0.5 text-[12px] font-bold mono bg-white border border-[var(--line)]">{subGoal}</div>
      {/if}
      <!-- サブのお祝い / シャウトアウトのカード (数秒だけ) -->
      {#if overlayOn}
        <div class="absolute inset-x-0 bottom-0 py-2 text-center bg-[var(--ok)] text-white text-[19px] font-bold">
          {overlayText || '🎉'}
        </div>
      {/if}
    </div>

    <table class="tbl mt-2">
      <thead><tr><th>OBS の部品</th><th>WEAVE が出したい状態</th><th>OBS の実際の状態</th></tr></thead>
      <tbody>
        {#each items as i (i.key)}
          <tr>
            <td class="mono">{i.key}</td>
            <td>{i.requested === undefined ? '—' : i.requested ? '表示' : '非表示'}</td>
            <td class={i.actual === undefined ? 'dim' : i.requested === undefined || i.actual === i.requested ? 'ok' : 'warn'}>
              {i.actual === undefined ? '(報告なし)' : i.actual ? '表示' : '非表示'}
            </td>
          </tr>
        {:else}
          <tr><td colspan="3" class="dim">まだ OBS への指示はありません</td></tr>
        {/each}
      </tbody>
    </table>
  </div>
</div>
