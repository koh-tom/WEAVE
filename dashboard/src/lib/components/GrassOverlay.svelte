<script lang="ts">
  import { eventLogs } from '../stores';

  let isOverlayActive = $state(false);
  let lastTriggerTime = $state<number | null>(null);
  let timeRemaining = $state(0);
  let cooldownRemaining = $state(0);
  let timerInterval: ReturnType<typeof setInterval> | null = null;

  $effect(() => {
    // ログから OBS リクエストまたはイベントを監視
    const latestObsLog = $eventLogs.find(
      (log) =>
        log.topic === 'core.obs.request.SetSceneItemEnabled' ||
        log.topic === 'core.obs.event.SceneItemEnableStateChanged'
    );

    if (latestObsLog) {
      const payload = latestObsLog.payload;
      let enabled = false;
      if (typeof payload === 'object' && payload !== null) {
        if ('sceneItemEnabled' in payload) {
          enabled = Boolean(payload.sceneItemEnabled);
        } else if ('d' in payload && payload.d?.eventData) {
          enabled = Boolean(payload.d.eventData.sceneItemEnabled);
        }
      }

      if (enabled && !isOverlayActive) {
        isOverlayActive = true;
        lastTriggerTime = Date.now();
        timeRemaining = 10;
        cooldownRemaining = 15;
      } else if (!enabled && isOverlayActive) {
        isOverlayActive = false;
        timeRemaining = 0;
      }
    }
  });

  $effect(() => {
    if (isOverlayActive || cooldownRemaining > 0) {
      if (!timerInterval) {
        timerInterval = setInterval(() => {
          if (timeRemaining > 0) timeRemaining--;
          if (cooldownRemaining > 0) cooldownRemaining--;
          if (timeRemaining <= 0 && cooldownRemaining <= 0) {
            if (timerInterval) clearInterval(timerInterval);
            timerInterval = null;
          }
        }, 1000);
      }
    } else {
      if (timerInterval) {
        clearInterval(timerInterval);
        timerInterval = null;
      }
    }
  });
</script>

<!-- OBS 仮想プレビュー & オーバーレイ通知 -->
<div class="relative w-full overflow-hidden rounded-xl border border-slate-200 bg-slate-900 text-white shadow-md">
  <!-- ヘッダーバー -->
  <div class="flex items-center justify-between border-b border-slate-800 bg-slate-950/80 px-4 py-2 text-xs">
    <div class="flex items-center gap-2 font-mono font-semibold">
      <span class="flex h-2 w-2 rounded-full {isOverlayActive ? 'bg-emerald-500 animate-ping' : 'bg-slate-600'}"></span>
      <span class="text-slate-300">OBS Studio 仮想キャプチャ (Overlay)</span>
    </div>
    <div class="flex items-center gap-2">
      {#if cooldownRemaining > 0}
        <span class="rounded bg-amber-500/20 px-2 py-0.5 font-mono text-[10px] text-amber-400 border border-amber-500/30">
          クールダウン: {cooldownRemaining}s
        </span>
      {/if}
      <span class="rounded px-2 py-0.5 font-mono text-[10px] uppercase font-bold {isOverlayActive ? 'bg-emerald-500/20 text-emerald-400 border border-emerald-500/30' : 'bg-slate-800 text-slate-400'}">
        {isOverlayActive ? '● STREAM ON' : '○ IDLE'}
      </span>
    </div>
  </div>

  <!-- メイン表示領域 (OBS 画面シミュレーション) -->
  <div class="relative flex h-48 w-full items-center justify-center bg-gradient-to-br from-slate-900 via-slate-950 to-slate-900 p-6 overflow-hidden">
    <!-- 背景グリッドガイド -->
    <div class="absolute inset-0 bg-[radial-gradient(#334155_1px,transparent_1px)] [background-size:16px_16px] opacity-30"></div>

    {#if isOverlayActive}
      <!-- 草エフェクトアニメーション (ポップアップ) -->
      <div class="relative z-10 flex flex-col items-center gap-3 text-center transition-all duration-300 transform scale-100">
        <div class="flex items-center gap-2 rounded-full bg-emerald-500/20 border border-emerald-500/40 px-4 py-1 backdrop-blur-md animate-bounce">
          <span class="text-xl">🌱</span>
          <span class="font-extrabold text-emerald-300 text-sm tracking-wide">Wasm Node [kusa_node] トリガー検出！</span>
          <span class="text-xl">🌱</span>
        </div>

        <div class="text-4xl font-black text-transparent bg-clip-text bg-gradient-to-r from-emerald-400 via-green-300 to-teal-200 drop-shadow-[0_4px_12px_rgba(16,185,129,0.5)]">
          ｗｗｗｗ 草草草 ｗｗｗｗ
        </div>

        <div class="flex items-center gap-3 text-xs font-mono text-emerald-200/80">
          <span>自動非表示タイマー: <strong class="text-white text-sm font-bold">{timeRemaining}s</strong></span>
          <span>•</span>
          <span>Target: Scene/Overlay #1</span>
        </div>
      </div>
    {:else}
      <!-- アイドル状態メッセージ -->
      <div class="relative z-10 flex flex-col items-center gap-2 text-center text-slate-500">
        <svg class="w-8 h-8 opacity-40 text-slate-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="1.5" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"></path>
        </svg>
        <p class="text-xs font-medium">チャットで「草」または「w」が 3秒間に10回以上連投されるとエフェクトが起動します</p>
      </div>
    {/if}
  </div>
</div>
