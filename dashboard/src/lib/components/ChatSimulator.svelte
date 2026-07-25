<script lang="ts">
  import { send } from '../websocket';

  let customUser = $state('ViewerDemo');
  let customMessage = $state('草');
  let isSendingBurst = $state(false);

  function sendChatMessage(user: string, message: string) {
    send('ext.twitch.chat.message', {
      user: user,
      message: message,
    });
  }

  async function triggerGrassBurst() {
    if (isSendingBurst) return;
    isSendingBurst = true;

    for (let i = 1; i <= 10; i++) {
      sendChatMessage(`Viewer_${i}`, i % 2 === 0 ? '草' : 'ww');
      await new Promise((resolve) => setTimeout(resolve, 80));
    }

    isSendingBurst = false;
  }

  function handleSingleSend() {
    if (!customMessage.trim()) return;
    sendChatMessage(customUser, customMessage);
    customMessage = '';
  }
</script>

<div class="border border-slate-200 bg-white p-3 rounded flex flex-col gap-3 shadow-sm">
  <div class="flex items-center justify-between">
    <div class="text-[10px] font-bold text-slate-800 uppercase tracking-widest flex items-center gap-1.5">
      <span>💬</span>
      <span>ライブデモ・シミュレータ</span>
    </div>
    <span class="text-[9px] bg-slate-100 text-slate-600 px-1.5 py-0.5 rounded font-mono">Twitch Chat</span>
  </div>

  <!-- 10連発ボタン -->
  <button
    onclick={triggerGrassBurst}
    disabled={isSendingBurst}
    class="w-full py-2 px-3 rounded font-bold text-xs bg-emerald-600 hover:bg-emerald-700 active:scale-98 text-white transition-all shadow-sm flex items-center justify-center gap-2 disabled:opacity-50 cursor-pointer"
  >
    {#if isSendingBurst}
      <span class="w-3 h-3 border-2 border-white border-t-transparent rounded-full animate-spin"></span>
      <span>送信中 (10連発)...</span>
    {:else}
      <span>🌱 草ラッシュ (10連発) を送信</span>
    {/if}
  </button>

  <!-- 単発メッセージ送信 -->
  <div class="flex flex-col gap-1.5 pt-1 border-t border-slate-100">
    <div class="flex gap-1.5">
      <input
        type="text"
        bind:value={customUser}
        placeholder="ユーザー名"
        class="w-1/3 px-2 py-1 text-xs border border-slate-200 rounded font-mono focus:outline-none focus:border-[#0A1C56]"
      />
      <input
        type="text"
        bind:value={customMessage}
        placeholder="メッセージ (例: 草)"
        onkeydown={(e) => e.key === 'Enter' && handleSingleSend()}
        class="flex-1 px-2 py-1 text-xs border border-slate-200 rounded focus:outline-none focus:border-[#0A1C56]"
      />
    </div>
    <button
      onclick={handleSingleSend}
      class="py-1 px-2 text-xs font-semibold bg-slate-100 hover:bg-slate-200 text-slate-700 rounded transition-colors cursor-pointer text-center"
    >
      メッセージ送信
    </button>
  </div>
</div>
