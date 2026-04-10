<script lang="ts">
  import { metrics } from '../stores';
  
  export let label: string = "Throughput";
  export let unit: string = "EPS";
  export let color: string = "#9ece6a";
</script>

<div class="bg-white/5 p-3 px-4 rounded-xl border border-white/5 flex flex-col transition-all hover:bg-white/[0.08] group">
    <div class="text-[9px] font-bold uppercase text-[#565f89] tracking-[0.15em] group-hover:text-[#7aa2f7] transition-colors">
        {label}
    </div>
    <div class="flex items-baseline gap-1.5">
        <span class="text-2xl font-black tabular-nums tracking-tighter leading-tight" style="color: {color}">
            {$metrics.eps}
        </span>
        <span class="text-[9px] font-bold opacity-30 text-[#c0caf5]">
            {unit}
        </span>
    </div>
    
    <!-- 非常に細いインジケーター -->
    <div class="mt-1.5 h-[2px] w-full bg-white/5 rounded-full overflow-hidden">
        <div 
            class="h-full transition-all duration-500 ease-out" 
            style="width: {Math.min($metrics.eps * 2, 100)}%; background-color: {color}"
        ></div>
    </div>
</div>
