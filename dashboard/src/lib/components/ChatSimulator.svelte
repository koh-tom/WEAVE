<script lang="ts">
  import { send } from '../websocket';

  let customUser = $state('viewer');
  let customMessage = $state('草');
  let isSendingBurst = $state(false);

  function sendChatMessage(user: string, message: string) {
    send('ext.twitch.chat.message', { user, message });
  }

  async function triggerGrassBurst() {
    if (isSendingBurst) return;
    isSendingBurst = true;
    for (let i = 1; i <= 10; i++) {
      sendChatMessage(`viewer${i}`, i % 2 === 0 ? '草' : 'ww');
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

<div class="panel">
  <div class="panel-h"><span class="panel-t">テスト用チャット</span></div>
  <div class="p-2 flex flex-col gap-1.5">
    <button class="btn" onclick={triggerGrassBurst} disabled={isSendingBurst}>
      {isSendingBurst ? '送信中…' : '「草」を 10 件送る'}
    </button>
    <label class="text-[12px] dim">名前 <input type="text" bind:value={customUser} class="w-full mono" /></label>
    <label class="text-[12px] dim">本文
      <input type="text" bind:value={customMessage} class="w-full"
        onkeydown={(e) => e.key === 'Enter' && handleSingleSend()} />
    </label>
    <button class="btn" onclick={handleSingleSend}>送る</button>
  </div>
</div>
