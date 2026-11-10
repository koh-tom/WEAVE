#!/usr/bin/env python3
"""demo/stream_sim/run.py — 本物の OBS に、たくさんのツールをつないだ「模擬配信」を 1 本まるごと流して記録する

  番組: 「WEAVE 杯 決勝 ― 実況配信」(約 2 分半)。視聴者・チャット・アラートはすべてローカルの偽データ
  つなぐもの:
    本物の OBS Studio (シーンコレクション WEAVE-stream、録画しながら)
    StreamElements (モック) … フォロー・サブ・投げ銭などのアラート
    Streamlabs (モック)     … 投げ銭のアラート
    チャット                … Inspector 経由で流す (Core を落としても途切れない)
    プラグイン 9 個          … subgoal / shoutout / kusa_node / scoreboard / score_tool / countdown / sfx / loop_node / malicious_plugin
  事故:
    幕 0  配信前チェックで score_tool の起動忘れ → /status で原因 → 足して起動し直す
    A     荒らしの "!freeze" で loop_node が無限ループ → そこだけ作り直す
    B     タイマーの名前違い (小文字の "timer") → OBS が断る → /status に「もしかして Timer」→ 直す
    C     Core を kill -9 → Supervisor が戻す
    常時  malicious_plugin がチャットのたびに攻撃 → 全部拒否
  記録 (demo/output/stream_sim/run-<日時>/):
    shots/      OBS が描いた配信画面 / OBS アプリの画面 / /status / Inspector のスクショ
    timeline.jsonl  出来事と時刻、events.jsonl 全イベント、audit.log、weave.log、stats.json (遅延・OBS の統計・件数)
    OBS の録画 (demo/output/stream_sim/obs/weave_stream_*.mp4)

  使い方: python3 demo/stream_sim/run.py      (前提: zig build、dashboard/dist、OBS 32、obs-websocket 有効)
"""
import json, os, re, shutil, signal, subprocess, sys, time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
from obsws import OBS  # noqa: E402

BIN = os.path.join(ROOT, "zig-out", "bin")
STAMP = datetime.now().strftime("%Y%m%d-%H%M%S")
OUT = os.path.join(ROOT, "demo", "output", "stream_sim", f"run-{STAMP}")
SHOTS = os.path.join(OUT, "shots")
TOOLS = os.path.join(ROOT, "demo", "output", "stream_sim", "tools")
os.makedirs(SHOTS, exist_ok=True)
DASH, NODE, TOKEN, VIEW = 3033, 8083, "sim-dash", "sim-view"
WSURL = f"ws://127.0.0.1:{DASH}/ws"
MON = "WEAVE-SIM"
USERINI = os.path.expanduser("~/.config/obs-studio/user.ini")
PLUGINS = ["subgoal", "shoutout", "kusa_node", "scoreboard", "countdown", "sfx", "loop_node", "malicious_plugin"]
procs = {}
t0 = time.time()
tl = open(os.path.join(OUT, "timeline.jsonl"), "w")


def now():
    return round(time.time() - t0, 2)


def mark(kind, text, **kw):
    e = {"t": now(), "kind": kind, "text": text, **kw}
    tl.write(json.dumps(e, ensure_ascii=False) + "\n")
    tl.flush()
    print(f"[{e['t']:7.2f}] {kind:8s} {text}", flush=True)


def run(args, **kw):
    return subprocess.run(args, cwd=ROOT, capture_output=True, text=True, **kw)


def pub(topic, payload):
    run([f"{BIN}/weave", "topic", "pub", topic, json.dumps(payload, ensure_ascii=False), "--url", WSURL, "--token", TOKEN])


def chat(user, msg):
    pub("ext.twitch.chat.message", {"user": user, "message": msg})
    mark("chat", f"{user}: {msg}")


def wait_log(path, pattern, timeout=15, after=0, every=0.1):
    end = time.time() + timeout
    while time.time() < end:
        try:
            s = open(path, encoding="utf-8", errors="replace").read()
            if re.search(pattern, s[after:]):
                return True
        except FileNotFoundError:
            pass
        time.sleep(every)
    return False


# ------------------------------------------------------------------ スクショ
def ensure_playwright():
    if os.path.isdir(os.path.join(TOOLS, "node_modules", "playwright-core")):
        return
    os.makedirs(TOOLS, exist_ok=True)
    # 専用の package.json を先に置く (無いと bun が上の階層 = リポジトリの package.json を書き換えてしまう)
    if not os.path.exists(os.path.join(TOOLS, "package.json")):
        open(os.path.join(TOOLS, "package.json"), "w").write('{"name": "weave-stream-sim-tools", "private": true}\n')
    bun = shutil.which("bun") or os.path.expanduser("~/.bun/bin/bun")
    subprocess.run([bun, "add", "playwright-core@1"], cwd=TOOLS, capture_output=True)
    open(os.path.join(TOOLS, "page.mjs"), "w").write("""import { chromium } from 'playwright-core';
const [url, out, w, h, wait] = process.argv.slice(2);
const b = await chromium.launch({ executablePath: '/usr/bin/chromium', args: ['--no-sandbox'] });
const p = await b.newPage({ viewport: { width: +w, height: +h }, deviceScaleFactor: 2 });
await p.goto(url); await p.waitForTimeout(+wait || 2500);
await p.screenshot({ path: out, fullPage: true }); await b.close();
""")


def shot_page(name, path, w, h, wait=2500):
    out = os.path.join(SHOTS, name)
    subprocess.run(["node", "page.mjs", f"http://127.0.0.1:{DASH}{path}", out, str(w), str(h), str(wait)], cwd=TOOLS, capture_output=True)
    return out


def shot_obs(name, label):
    """OBS 自身が描いた配信画面 (プログラム出力) と、OBS アプリの画面 (仮想モニター) を撮る"""
    try:
        OBS().shot("Overlay", os.path.join(SHOTS, f"{name}_program.png"), 1280)
    except Exception as e:
        mark("warn", f"OBS のスクショに失敗: {e}")
    app = os.path.join(SHOTS, f"{name}_obsapp.png")
    subprocess.run(["grim", "-o", MON, app], capture_output=True)
    # 仮想モニターにもデスクトップのバー (予定・バッテリーなど) が出るので、上端を切り落として OBS だけにする
    try:
        from PIL import Image
        im = Image.open(app)
        im.crop((0, 48, im.width, im.height)).save(app)
    except Exception:
        pass
    mark("shot", label, file=f"{name}_program.png")


def shot_status(name, label):
    shot_page(f"{name}_status.png", f"/status?token={VIEW}", 420, 860)
    mark("shot", label, file=f"{name}_status.png")


def shot_inspector(name, label):
    shot_page(f"{name}_inspector.png", f"/?token={TOKEN}", 1440, 900, 3500)
    mark("shot", label, file=f"{name}_inspector.png")


# ------------------------------------------------------------------ 起動と片付け
def start_obs():
    shutil.copy(USERINI, USERINI + ".sim-bak")
    s = open(USERINI).read()
    s = re.sub(r"^(ConfirmOnExit|WarnBeforeStoppingRecord|WarnBeforeStartingRecord)=.*\n?", "", s, flags=re.M)
    s = s.replace("[General]\n", "[General]\nConfirmOnExit=false\nWarnBeforeStoppingRecord=false\nWarnBeforeStartingRecord=false\n", 1)
    open(USERINI, "w").write(s)
    subprocess.run(["hyprctl", "output", "remove", MON], capture_output=True)
    subprocess.run(["hyprctl", "output", "create", "headless", MON], capture_output=True)
    subprocess.run(["hyprctl", "keyword", "monitor", f"{MON},1920x1080@30,22000x0,1.5"], capture_output=True)
    time.sleep(0.8)
    ws = next(m["activeWorkspace"]["id"] for m in json.loads(run(["hyprctl", "monitors", "all", "-j"]).stdout) if m["name"] == MON)
    procs["obs"] = subprocess.Popen(["obs", "--collection", "WEAVE-stream", "--profile", "WEAVE-stream", "--scene", "Overlay",
                                     "--disable-shutdown-check", "--startrecording"],
                                    stdout=open(os.path.join(OUT, "obs.log"), "w"), stderr=subprocess.STDOUT)
    addr = None
    for _ in range(100):
        for c in json.loads(run(["hyprctl", "clients", "-j"]).stdout):
            if c.get("class") == "com.obsproject.Studio" and c.get("title", "").startswith("OBS"):
                addr = c["address"]
        if addr:
            break
        time.sleep(0.2)
    subprocess.run(["hyprctl", "dispatch", "movetoworkspacesilent", f"{ws},address:{addr}"], capture_output=True)
    for _ in range(100):
        try:
            OBS().call("GetVersion")
            break
        except Exception:
            time.sleep(0.2)
    time.sleep(2)
    mark("system", "本物の OBS を起動 (録画開始)", version=OBS().call("GetVersion").get("obsVersion"))


def start_weave(extra_plugins, tag):
    cfg = json.load(open(os.path.expanduser("~/.config/obs-studio/plugin_config/obs-websocket/config.json")))
    env = dict(os.environ, STREAMELEMENTS_JWT="sim-fake-jwt", STREAMLABS_SOCKET_TOKEN="sim-fake-token")
    args = [f"{BIN}/weave", "up", "--real-obs", "--obs-port", str(cfg.get("server_port", 4455)), "--obs-pass", cfg.get("server_password", ""),
            "--no-twitch", "--dash-port", str(DASH), "--node-port", str(NODE), "--dashboard-token", TOKEN, "--observer-token", VIEW,
            "--approval-mode", "strict", "--approvals", os.path.join(OUT, "approved.json"),
            "--audit-log", os.path.join(OUT, "audit.log"), "--state-dir", os.path.join(OUT, "state"),
            "--streamelements-channel", "sim-channel", "--streamelements-url", "ws://127.0.0.1:9193/",
            "--streamlabs-url", "ws://127.0.0.1:9194/socket.io/?EIO=3&transport=websocket",
            "--expect", "wasm-apps/score_tool.json"] + [f"wasm-apps/{p}.wasm" for p in PLUGINS + extra_plugins]
    log = os.path.join(OUT, f"weave_{tag}.log")
    procs["weave"] = subprocess.Popen(args, cwd=ROOT, env=env, stdout=open(log, "w"), stderr=subprocess.STDOUT, start_new_session=True)
    ok = wait_log(log, r"Ready in (\d+) ms", 20)
    ms = re.search(r"Ready in (\d+) ms", open(log).read())
    wait_log(log, "identified with OBS", 10)
    return log, (int(ms.group(1)) if ms else None) if ok else None


def stop(name, sig=signal.SIGINT, timeout=8):
    p = procs.pop(name, None)
    if not p:
        return
    try:
        os.killpg(p.pid, sig) if name == "weave" else p.send_signal(sig)
        p.wait(timeout=timeout)
    except Exception:
        try:
            os.killpg(p.pid, signal.SIGKILL) if name == "weave" else p.kill()
        except Exception:
            pass


def cleanup():
    for n in ["record", "astro", "labs", "weave"]:
        stop(n)
    stop("obs", signal.SIGINT, 20)
    if os.path.exists(USERINI + ".sim-bak"):
        shutil.move(USERINI + ".sim-bak", USERINI)
    subprocess.run(["hyprctl", "output", "remove", MON], capture_output=True)


def start_record():
    procs["record"] = subprocess.Popen(f"while true; do {BIN}/weave record {OUT}/events_$(date +%s%N).jsonl --url {WSURL} --token {TOKEN}; sleep 0.3; done",
                                       shell=True, cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def summary():
    out = subprocess.run(["timeout", "1.5", f"{BIN}/weave", "topic", "echo", "core.health.summary", "--url", WSURL, "--token", TOKEN],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip().splitlines()
    for line in reversed(out):
        try:
            p = json.loads(line)["payload"]
            return json.loads(p) if isinstance(p, str) else p
        except Exception:
            continue
    return {}


VIEWERS = ["kumo_23", "nyanta", "sakuraba", "tofu_maru", "pixel_ken", "hoshizora", "mochi99", "ramen_lover",
           "zigzag", "wasm_fan", "night_owl", "obs_master", "kotatsu", "mod_hanako"]


def main():
    ensure_playwright()
    # ---------------------------------------------------------------- 準備: 承認
    for p in PLUGINS + ["score_tool"]:
        r = run([f"{BIN}/weave", "add", f"wasm-apps/{p}.wasm", "--yes", "--approvals", os.path.join(OUT, "approved.json")])
        if p == "sfx":
            open(os.path.join(OUT, "weave_add_sfx.txt"), "w").write(r.stdout)
    mark("system", f"プラグイン {len(PLUGINS) + 1} 個を weave add で承認")
    procs["astro"] = subprocess.Popen([f"{BIN}/weave-bridge", "mock-astro", "--port", "9193", "--jwt", "sim-fake-jwt", "--count", "8", "--interval-ms", "14000"],
                                      stdout=open(os.path.join(OUT, "mock_streamelements.log"), "w"), stderr=subprocess.STDOUT)
    procs["labs"] = subprocess.Popen([f"{BIN}/weave-bridge", "mock-streamlabs", "--port", "9194", "--token", "sim-fake-token", "--count", "4", "--interval-ms", "33000"],
                                     stdout=open(os.path.join(OUT, "mock_streamlabs.log"), "w"), stderr=subprocess.STDOUT)
    start_obs()

    # ---------------------------------------------------------------- 幕 0: 配信前チェック
    log0, ready0 = start_weave([], "precheck")
    mark("system", "配信前チェック: WEAVE を起動 (score_tool を入れ忘れ)", ready_ms=ready0)
    time.sleep(2)
    s = summary()
    mark("health", "配信前チェックの稼働状態", overall=s.get("overall"), problems=s.get("problems"))
    shot_status("00_precheck", "配信前: /status に「score_tool が起動していません」と直し方")
    shot_obs("00_precheck", "配信前の OBS (スコアは 0 - 0 のまま)")
    stop("weave")
    log1, ready1 = start_weave(["score_tool"], "live")
    mark("system", "score_tool を足して WEAVE を起動し直す", ready_ms=ready1)
    start_record()
    time.sleep(1.5)
    s = summary()
    mark("health", "本番開始時の稼働状態", overall=s.get("overall"))

    # ---------------------------------------------------------------- 本番
    pub("ext.countdown.cmd", {"cmd": "start", "seconds": 5, "source": "Timer", "final": "START!"})
    mark("op", "モデレーター: カウントダウン 5 秒 (Timer)")
    for u, m in [("kumo_23", "こんばんは！"), ("nyanta", "待ってた"), ("sakuraba", "決勝きた"), ("tofu_maru", "わくわく")]:
        chat(u, m); time.sleep(0.9)
    time.sleep(2)
    for u in ["pixel_ken", "hoshizora", "mochi99"]:
        chat(u, "888888"); time.sleep(0.25)
    time.sleep(0.6)
    shot_obs("01_start", "開始: カウントダウンが START! に、888 で拍手の効果音")

    for u, m in [("ramen_lover", "!point a"), ("zigzag", "うまい！"), ("wasm_fan", "!point a"), ("night_owl", "!point b"),
                 ("kotatsu", "Bチーム反撃"), ("obs_master", "!point a"), ("mochi99", "!drum")]:
        chat(u, m); time.sleep(0.8)
    time.sleep(0.5)
    shot_obs("02_score", "試合: チャットの !point でスコアが A 3 - 1 B に")

    for i in range(12):
        chat(VIEWERS[i % len(VIEWERS)], ["草", "www", "草草", "wwww"][i % 4]); time.sleep(0.15)
    time.sleep(0.8)
    shot_obs("03_kusa", "草ラッシュ: 3 秒に 10 回でお祝いカード")
    time.sleep(1)
    chat("mod_hanako", "!so pixel_ken")
    time.sleep(1.0)
    shot_obs("04_shoutout", "モデレーターの !so で紹介カード")
    for u in ["hoshizora", "kotatsu", "zigzag", "nyanta", "sakuraba"]:
        chat(u, "!sub"); time.sleep(0.5)
    chat("tofu_maru", "!yay")
    time.sleep(1)
    shot_obs("05_subgoal", "サブ目標が 8 → 13 / 50 に")

    # ---------------------------------------------------------------- 事故 A: 暴走
    mark("incident", "事故 A: 荒らしが !freeze を投稿 → loop_node が無限ループ")
    off = os.path.getsize(log1)
    chat("troll_000", "!freeze")
    rec = wait_log(log1, r"Recovery: 'loop_node'.*after (\d+) ms", 5, off)
    m = re.findall(r"Recovery: 'loop_node'.*after (\d+) ms", open(log1).read()[off:])
    mark("recovery", f"loop_node だけ作り直して復帰 ({m[0] if m else '?'} ms)", ms=int(m[0]) if m else None)
    for i in range(10):
        chat(VIEWERS[(i + 3) % len(VIEWERS)], "草"); time.sleep(0.15)
    time.sleep(0.8)
    shot_obs("06_after_freeze", "暴走の直後でも、草ラッシュのお祝いカードは出る (巻き込まれない)")
    shot_inspector("06_after_freeze", "Inspector: 暴走したセルだけ作り直し、拒否された攻撃も記録")

    # ---------------------------------------------------------------- 事故 B: 名前違い
    mark("incident", "事故 B: モデレーターがタイマーのソース名を小文字の「timer」と打ち間違える")
    pub("ext.countdown.cmd", {"cmd": "start", "seconds": 30, "source": "timer", "final": "後半戦!"})
    time.sleep(2.5)
    s = summary()
    mark("health", "OBS に断られている操作", obs_problems=[{k: p.get(k) for k in ("plugin", "target", "suggestion", "action")} for p in s.get("obs_problems", [])])
    shot_status("07_typo", "/status: 「OBS に『timer』がありません。もしかして『Timer』?」")
    pub("ext.countdown.cmd", {"cmd": "reset"})
    pub("ext.countdown.cmd", {"cmd": "start", "seconds": 30, "source": "Timer", "final": "後半戦!"})
    mark("op", "モデレーター: 正しい名前 Timer で出し直す")
    time.sleep(2)
    shot_obs("08_timer", "直したあと: タイマーが動き出す")

    # ---------------------------------------------------------------- 事故 C: Core を強制終了
    sup = procs["weave"].pid
    core = run(["pgrep", "-P", str(sup)]).stdout.split()
    mark("incident", "事故 C: WEAVE の Core を kill -9")
    off = os.path.getsize(log1)
    tk = time.time()
    if core:
        os.kill(int(core[0]), signal.SIGKILL)
    wait_log(log1, r"Ready in \d+ ms", 10, off, every=0.005)
    back = round((time.time() - tk) * 1000)
    inner = re.findall(r"Ready in (\d+) ms", open(log1).read()[off:])
    mark("recovery", f"Supervisor が Core を戻した (kill から Ready まで {back} ms、うち Core の起動 {inner[0] if inner else '?'} ms)", ms=back,
         core_ready_ms=int(inner[0]) if inner else None)
    for u, m in [("night_owl", "今なにか起きた？"), ("kumo_23", "画面そのまま"), ("ramen_lover", "!point b"), ("wasm_fan", "!clap")]:
        chat(u, m); time.sleep(0.8)
    time.sleep(1)
    shot_obs("09_after_core_kill", "Core を落としても配信画面はそのまま (状態も戻る)")
    shot_status("09_after_core_kill", "/status: 自動復帰の記録")

    # ---------------------------------------------------------------- 終盤
    for u, m in [("pixel_ken", "!point a"), ("hoshizora", "決まった！"), ("mochi99", "888"), ("sakuraba", "!sub"),
                 ("nyanta", "おつかれさまでした"), ("kotatsu", "楽しかった"), ("zigzag", "88888")]:
        chat(u, m); time.sleep(0.9)
    time.sleep(2)
    shot_obs("10_end", "エンディング")
    shot_inspector("10_end", "Inspector: 配信の終わり")

    # ---------------------------------------------------------------- 集計
    stats = {"chat_messages": sum(1 for l in open(os.path.join(OUT, "timeline.jsonl")) if '"kind": "chat"' in l)}
    try:
        stats["obs"] = json.loads(run([sys.executable, os.path.join(HERE, "obsws.py"), "stats"]).stdout)
    except Exception as e:
        stats["obs_error"] = str(e)
    lat = subprocess.run(["timeout", "1.5", f"{BIN}/weave", "topic", "echo", "core.obs.latency", "--url", WSURL, "--token", TOKEN],
                         cwd=ROOT, capture_output=True, text=True).stdout.strip().splitlines()
    stats["latency"] = json.loads(lat[-1])["payload"] if lat else None
    stats["health_end"] = summary()
    stats["ready_ms"] = {"precheck": ready0, "live": ready1}
    json.dump(stats, open(os.path.join(OUT, "stats.json"), "w"), ensure_ascii=False, indent=1)
    mark("system", "配信終了")


if __name__ == "__main__":
    try:
        main()
    finally:
        cleanup()
        time.sleep(1)
        recs = sorted([f for f in os.listdir(os.path.join(ROOT, "demo", "output", "stream_sim", "obs")) if f.endswith((".mp4", ".mkv"))])
        print("OBS の録画:", recs[-1] if recs else "(なし)")
        print("記録:", OUT)
