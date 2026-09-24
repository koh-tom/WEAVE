// hello_as — AssemblyScript で書いた WEAVE プラグインの例
// チャットに "hello" を含む発言が来るたびに数え、ext.as.greetings に {"count":N} を出す。
import { publish, log, text, Level, QoS } from "../assembly/weave";
export { os_alloc, os_reset_heap, os_api_get_heap_usage } from "../assembly/weave";

let count: i32 = 0;

export function on_init(): i32 {
  log(Level.Info, "[hello_as] ready (AssemblyScript)");
  return 0;
}

export function on_message(topic_ptr: usize, topic_len: u32, payload_ptr: usize, payload_len: u32): void {
  const payload = text(payload_ptr, payload_len);
  if (!payload.toLowerCase().includes("hello")) return;
  count++;
  publish("ext.as.greetings", '{"count":' + count.toString() + "}", QoS.BestEffort);
}
