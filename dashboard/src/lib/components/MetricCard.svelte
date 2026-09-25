<script lang="ts">
  import { metrics } from '../stores';
  
  export let label: string = "Throughput";
  export let unit: string = "EPS";
</script>

<div class="card p-3 flex flex-col gap-1">
    <div class="text-[10px] font-bold text-[var(--t-lo)] uppercase tracking-wider">{label}</div>
    <div class="flex items-baseline gap-1.5">
        <span class="text-2xl mono tnum text-[var(--live)] font-bold leading-none">{$metrics.eps}</span>
        <span class="text-[10px] text-[var(--t-lo)] font-bold">{unit}</span>
    </div>
</div>
