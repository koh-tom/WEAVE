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

<div class="card p-3 flex flex-col gap-2.5">
  <div class="flex items-center justify-between">
    <div class="card-t">ライブデモ</div>
    <span class="text-[9px] badge" style="background:var(--surface-2);color:var(--t-lo);border:1px solid var(--line)">Twitch Chat</span>
  </div>

  <button
    onclick={triggerGrassBurst}
    disabled={isSendingBurst}
    class="btn btn-primary w-full text-[13px] flex items-center justify-center gap-2 disabled:opacity-50"
  >
    {#if isSendingBurst}
      <span class="w-3 h-3 border-2 border-[var(--live)] border-t-transparent rounded-full animate-spin"></span>
      <span>送信中 (10連発)…</span>
    {:else}
      <span>草ラッシュ (10連発) を送る</span>
    {/if}
  </button>

  <div class="flex flex-col gap-1.5 pt-2 border-t border-[var(--line-soft)]">
    <div class="flex gap-1.5">
      <input type="text" bind:value={customUser} placeholder="ユーザー名"
        class="w-1/3 text-xs mono !py-1.5" />
      <input type="text" bind:value={customMessage} placeholder="メッセージ"
        onkeydown={(e) => e.key === 'Enter' && handleSingleSend()}
        class="flex-1 text-xs !py-1.5" />
    </div>
    <button onclick={handleSingleSend} class="btn text-xs !py-1.5">メッセージ送信</button>
  </div>
</div>
