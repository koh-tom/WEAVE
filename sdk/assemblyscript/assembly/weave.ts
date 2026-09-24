// WEAVE plugin SDK for AssemblyScript (Host API v1)
//
// 使い方: examples/hello_as.ts を参照。プラグインの入口ファイルで
//   export { os_alloc, os_reset_heap, os_api_get_heap_usage } from "../assembly/weave";
// を再エクスポートし、on_init / on_message を export する。
//
// メモリ: GC 付きランタイム (--runtime incremental) を使う。Core がイベントを書き込む領域は
// os_alloc で確保し、イベント 1 件の処理後に Core が呼ぶ os_reset_heap でまとめて解放する。
// プラグインが作った文字列・オブジェクトは GC が回収するので、グローバルに状態を持ってよい。

@external("env", "os_api_publish")
declare function os_api_publish(topic_ptr: usize, topic_len: u32, payload_ptr: usize, payload_len: u32, qos: u32): i32;
@external("env", "os_api_subscribe")
declare function os_api_subscribe(topic_ptr: usize, topic_len: u32): i32;
@external("env", "os_api_unsubscribe")
declare function os_api_unsubscribe(topic_ptr: usize, topic_len: u32): i32;
@external("env", "os_api_log")
declare function os_api_log(level: i32, msg_ptr: usize, msg_len: u32): void;
@external("env", "os_api_message_timestamp")
declare function os_api_message_timestamp(): i64;
@external("env", "os_api_now")
declare function os_api_now(): i64;

export enum QoS {
  BestEffort = 0,
  Reliable = 1,
  Transient = 2,
}

/** Host API の戻り値 (docs: host_api_v1.md) */
export enum Result {
  SUCCESS = 0,
  ERROR_UNKNOWN = 1,
  ERROR_PERMISSION_DENIED = 2,
  ERROR_INVALID_PARAMETER = 3,
  ERROR_QUEUE_FULL = 4,
  ERROR_NOT_FOUND = 5,
  ERROR_RATE_LIMITED = 6,
  ERROR_LIMIT_EXCEEDED = 7,
  ERROR_INVALID_TOPIC = 8,
}

export enum Level {
  Debug = 0,
  Info = 1,
  Warn = 2,
  Error = 3,
}

export function publish(topic: string, payload: string, qos: QoS = QoS.BestEffort): Result {
  const t = String.UTF8.encode(topic);
  const p = String.UTF8.encode(payload);
  return <Result>os_api_publish(changetype<usize>(t), <u32>t.byteLength, changetype<usize>(p), <u32>p.byteLength, <u32>qos);
}

export function subscribe(topic: string): Result {
  const t = String.UTF8.encode(topic);
  return <Result>os_api_subscribe(changetype<usize>(t), <u32>t.byteLength);
}

export function unsubscribe(topic: string): Result {
  const t = String.UTF8.encode(topic);
  return <Result>os_api_unsubscribe(changetype<usize>(t), <u32>t.byteLength);
}

export function log(level: Level, msg: string): void {
  const m = String.UTF8.encode(msg);
  os_api_log(<i32>level, changetype<usize>(m), <u32>m.byteLength);
}

/** 処理中のイベントのタイムスタンプ (UNIX ms)。再生しても同じ値 */
export function messageTimestamp(): i64 {
  return os_api_message_timestamp();
}

/** 壁時計 (UNIX ms) */
export function now(): i64 {
  return os_api_now();
}

/** on_message に渡された (ptr, len) を文字列にする */
export function text(ptr: usize, len: u32): string {
  return String.UTF8.decodeUnsafe(ptr, <usize>len);
}

// ---- Core との ABI (再エクスポートして使う) ----

const MAX_EVENT_ALLOCS = 8;
const eventAllocs = new StaticArray<usize>(MAX_EVENT_ALLOCS);
let eventAllocCount: i32 = 0;
let eventAllocBytes: u32 = 0;

/** Core がイベント (topic / payload) を書き込む領域を確保する */
export function os_alloc(size: u32): usize {
  if (eventAllocCount >= MAX_EVENT_ALLOCS) return 0;
  const ptr = heap.alloc(size > 0 ? <usize>size : 1);
  unchecked((eventAllocs[eventAllocCount++] = ptr));
  eventAllocBytes += size;
  return ptr;
}

/** イベント 1 件の処理後に Core が呼ぶ。os_alloc した領域を解放する */
export function os_reset_heap(): void {
  for (let i = 0; i < eventAllocCount; i++) heap.free(unchecked(eventAllocs[i]));
  eventAllocCount = 0;
  eventAllocBytes = 0;
}

export function os_api_get_heap_usage(): u32 {
  return eventAllocBytes;
}

/** ランタイムの異常 (--use abort=assembly/weave/weaveAbort)。ログに残して trap する */
export function weaveAbort(message: string | null, file: string | null, line: u32, column: u32): void {
  log(Level.Error, "abort: " + (message !== null ? message : "") + " at " + (file !== null ? file : "?") + ":" + line.toString() + ":" + column.toString());
  unreachable();
}
