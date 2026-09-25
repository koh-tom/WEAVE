<script lang="ts">
  import { nodes, type NodeView } from '../stores';

  const STATUS_LABEL: Record<string, string> = {
    active: '稼働中',
    degraded: '縮退',
    starting: '起動中',
    restarting: '復帰中',
    quarantined: '隔離中',
    stopped: '停止',
    disconnected: '切断',
  };
  const STATUS_CLASS: Record<string, string> = {
    active: 'ok', starting: 'ok', degraded: 'warn', quarantined: 'warn',
    restarting: 'bad', stopped: 'bad', disconnected: 'bad',
  };

  // セル (障害ドメイン) ごとに並べる
  let rows = $derived(
    Object.values($nodes).sort((a: NodeView, b: NodeView) => a.cell.localeCompare(b.cell) || a.id - b.id),
  );
</script>

<div class="panel">
  <div class="panel-h">
    <span class="panel-t">WEAVE の中 — プラグインごとの区画 (セル)</span>
    <span class="panel-note">区画の中で起きた障害は、ほかの区画に届かない</span>
  </div>
  <table class="tbl">
    <thead>
      <tr><th>区画</th><th>プラグイン</th><th>種類</th><th>状態</th><th>障害</th><th>直近の復帰</th></tr>
    </thead>
    <tbody>
      {#each rows as n (n.id)}
        <tr>
          <td class="mono dim">{n.cell}</td>
          <td class="mono">{n.name}</td>
          <td class="dim">{n.type}</td>
          <td class={STATUS_CLASS[n.status] ?? 'warn'}>{STATUS_LABEL[n.status] ?? n.status}</td>
          <td class="tnum {n.faults > 0 ? 'bad' : 'dim'}">{n.faults}</td>
          <td class="tnum">{n.lastRecoveryMs !== undefined ? `${n.lastRecoveryMs} ms` : '—'}</td>
        </tr>
      {:else}
        <tr><td colspan="6" class="dim">Core からの情報を待っています…</td></tr>
      {/each}
    </tbody>
  </table>
</div>
