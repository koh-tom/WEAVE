<script lang="ts">
  import { metrics } from '../stores';
  
  export let label: string = "Throughput";
  export let unit: string = "EPS";
</script>

<div class="border border-slate-200 bg-white p-3 flex flex-col gap-1 shadow-sm">
    <div class="text-[10px] font-bold text-slate-800 uppercase">{label}</div>
    <div class="flex items-baseline gap-2">
        <span class="text-xl font-mono text-[#0A1C56] font-bold">{$metrics.eps}</span>
        <span class="text-[10px] text-slate-800 font-bold">{unit}</span>
    </div>
</div>
