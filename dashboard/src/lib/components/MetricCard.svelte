<script lang="ts">
  import { metrics, epsHistory } from '../stores';

  let { label = 'Throughput', unit = 'EPS' }: { label?: string; unit?: string } = $props();

  // スパークライン (直近 40 秒の EPS)
  let path = $derived.by(() => {
    const h = $epsHistory;
    if (h.length < 2) return '';
    const w = 96, ht = 24;
    const max = Math.max(1, ...h);
    const step = w / (h.length - 1);
    return h.map((v, i) => `${i === 0 ? 'M' : 'L'}${(i * step).toFixed(1)},${(ht - (v / max) * ht).toFixed(1)}`).join(' ');
  });
</script>

<div class="card p-3 flex flex-col gap-1.5">
  <div class="flex items-center justify-between">
    <div class="text-[10px] font-bold text-[var(--t-lo)] uppercase tracking-wider">{label}</div>
    {#if path}
      <svg width="96" height="24" viewBox="0 0 96 24" class="overflow-visible">
        <path d={path} fill="none" stroke="var(--live)" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" opacity="0.85" />
      </svg>
    {/if}
  </div>
  <div class="flex items-baseline gap-1.5">
    <span class="text-2xl mono tnum text-[var(--live)] font-bold leading-none">{$metrics.eps}</span>
    <span class="text-[10px] text-[var(--t-lo)] font-bold">{unit}</span>
  </div>
</div>
