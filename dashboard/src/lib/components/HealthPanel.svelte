<script lang="ts">
  import { health } from '../stores';

  // 状態を、配信の現場の言葉で
  const STATUS_JA: Record<string, string> = {
    missing: '起動していません',
    approval_required: '承認待ちのため止めています',
    restarting: '自動で作り直しています',
    quarantined: '一時的に止めています',
    stopped: '停止しています',
    degraded: '一部が動いていません',
    disconnected: '接続が切れています',
  };
  const FRIENDLY: Record<string, string> = { ObsEgress: 'OBS への送信', TwitchAdapter: 'Twitch のチャット受信' };
  const nm = (n: string) => FRIENDLY[n] ?? n;
  const time = (ms: number | null) => (ms ? new Date(ms).toLocaleTimeString([], { hour12: false }) : '');

  let sinkNodes = $derived(new Set(($health?.sinks ?? []).map((s) => s.node)));
</script>

<div class="panel">
  <div class="panel-h">
    <span class="panel-t">いま止まっている機能と、その原因</span>
    <span class="panel-note">宣言 (manifest) の pub/sub から、止まったノードの影響を計算 · 観測専用画面 /status にも同じ内容</span>
  </div>
  <div class="p-2 text-[13px]">
    {#if !$health}
      <div class="dim">計算中…</div>
    {:else if $health.overall === 'ok'}
      <div class="ok font-bold">すべて動いています</div>
    {:else}
      <table class="tbl">
        <thead><tr><th>止まっているもの</th><th>状態</th><th>そのせいで影響を受けているもの</th></tr></thead>
        <tbody>
          {#each $health.problems as p (p.node)}
            <tr>
              <td class="mono bad font-bold">{nm(p.node)}</td>
              <td class="bad">{STATUS_JA[p.status] ?? p.status}{#if p.since}<span class="dim"> ({time(p.since)} から)</span>{/if}
                {#if p.action}<div class="todo">→ {p.action}</div>{/if}</td>
              <td>
                {#each $health.impacts.filter((i) => i.because.includes(p.node)) as i (i.node)}
                  <div>
                    <span class="mono font-bold">{nm(i.node)}</span>
                    {i.effect === 'stalled' ? 'が入力を失って止まっています' : 'の入力の一部が届いていません'}
                    <span class="mono dim">({i.lost.join(', ')})</span>
                    {#if sinkNodes.has(i.node)}<span class="bad"> → 配信画面の表示が更新されません</span>{/if}
                  </div>
                {:else}
                  {#if sinkNodes.has(p.node)}<span class="bad">配信画面の表示が更新されません</span>{:else}<span class="dim">ほかへの影響はありません</span>{/if}
                {/each}
              </td>
            </tr>
          {/each}
          {#each $health.sinks_stopped as s (s)}
            <tr><td class="mono bad font-bold">{nm(s)}</td><td class="bad">止まっています</td><td class="bad">配信画面の操作が届きません</td></tr>
          {/each}
        </tbody>
      </table>
      {#each $health.obs_problems ?? [] as o (o.plugin + o.request + o.target)}
        <div class="bad mt-1">
          OBS に断られています: <span class="mono font-bold">{nm(o.plugin)}</span> の <span class="mono">{o.request}</span>
          → <span class="mono">{o.target}</span>{#if o.count > 1}<span class="dim"> ({o.count} 回)</span>{/if}
          <div class="todo">→ {o.action}</div>
        </div>
      {/each}
      {#each $health.warnings as w (w.node + w.topic)}
        <div class="warn mt-1">
          設定の気になる点: <span class="mono font-bold">{nm(w.node)}</span> が待っている <span class="mono">{w.topic}</span> を出すものがいません。
          もしかして <span class="mono font-bold">{w.suggestion}</span>({nm(w.from)} が出しています)?
        </div>
      {/each}
    {/if}
  </div>
</div>

<style>
  .todo { color: var(--fg, inherit); font-weight: 700; margin-top: 2px; }
</style>
