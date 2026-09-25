<script lang="ts">
  import { metrics, epsHistory } from '../stores';

  let { label = '処理速度', unit = '件/秒' }: { label?: string; unit?: string } = $props();

  // 直近 40 秒の推移 (折れ線 1 本だけ)
  let path = $derived.by(() => {
    const h = $epsHistory;
    if (h.length < 2) return '';
    const w = 200, ht = 30;
    const max = Math.max(1, ...h);
    const step = w / (h.length - 1);
    return h.map((v, i) => `${i === 0 ? 'M' : 'L'}${(i * step).toFixed(1)},${(ht - (v / max) * ht).toFixed(1)}`).join(' ');
  });
</script>

<div class="panel">
  <div class="panel-h"><span class="panel-t">{label}</span><span class="panel-note">直近 40 秒</span></div>
  <div class="px-2 py-1">
    <span class="mono tnum text-[15px]">{$metrics.eps}</span> <span class="dim text-[12px]">{unit}</span>
    {#if path}
      <svg width="100%" height="32" viewBox="0 0 200 32" preserveAspectRatio="none" class="block mt-1 border-t border-[var(--line-soft)]">
        <path d={path} fill="none" stroke="#333" stroke-width="1" vector-effect="non-scaling-stroke" />
      </svg>
    {/if}
  </div>
</div>
