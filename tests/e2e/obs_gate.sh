#!/usr/bin/env bash
# E2E: 既存ツールを WEAVE の下に置く (ObsGate)。ツールは OBS (ここでは weave-obs-sim) の代わりに WEAVE の 4456 番につなぐだけ
#   1. パスワードが合わないツールはつながれない
#   2. 宣言した対象への操作は OBS に届く。宣言にない対象 (番組名) と操作 (StopStream) は 205 で断られ、OBS に届かない
#   3. 上限を超えて送り続けると、そのツールだけが止まる (207)。core.security.* と core.wrap.status に出る
set -euo pipefail
cd "$(dirname "$0")/../.."
BIN=./zig-out/bin
DIR=$(mktemp -d)
W=0; S=0
cleanup() {
  for p in $W $S; do [ "$p" -gt 0 ] && { kill -INT "$p" 2>/dev/null || true; }; done
  sleep 0.3
  for p in $W $S; do [ "$p" -gt 0 ] && { kill -9 "$p" 2>/dev/null || true; }; done
  echo "logs: $DIR"
}
trap cleanup EXIT INT TERM
fail() { echo "FAIL: $*"; exit 1; }

"$BIN/weave-obs-sim" --port 4475 --password simpw --inputs OverlayText,番組名 --scenes Overlay --quiet > "$DIR/sim.log" 2>&1 &
S=$!
mkdir -p "$DIR/wrap"
cat > "$DIR/wrap/bot.json" <<'J'
{"name":"bot","password":"botpw","mode":"enforce","allow":["SetInputSettings:OverlayText","SetSceneItemEnabled:Overlay#1"],"rate_per_sec":5,"burst":5,"quarantine_secs":3}
J
"$BIN/WEAVE" --real-obs --obs-port 4475 --obs-pass simpw --no-twitch --gate-port 4476 --wrap-dir "$DIR/wrap" \
  --dash-port 3075 --node-port 8075 --dashboard-token gt --audit-log "$DIR/audit.log" --state-dir "$DIR/state" > "$DIR/weave.log" 2>&1 &
W=$!
for _ in $(seq 1 60); do grep -q "ObsGate: listening" "$DIR/weave.log" 2>/dev/null && break; sleep 0.1; done
grep -q "ObsGate: listening" "$DIR/weave.log" || fail "ObsGate did not start"

python3 - <<'PY' || exit 1
import sys
sys.path.insert(0, "demo/stream_sim")
from obsws import OBS

try:
    OBS(port=4476, password="wrong")
    raise SystemExit("FAIL: a tool with a wrong password was accepted")
except SystemExit:
    raise
except Exception:
    print("ok: wrong password rejected")

o = OBS(port=4476, password="botpw")
o.call("SetInputSettings", {"inputName": "OverlayText", "inputSettings": {"text": "hi"}})
print("ok: declared target passes")

def code_of(rt, data):
    try:
        o.call(rt, data)
        return 100
    except RuntimeError as e:
        return int(str(e).split(": ")[1].split(" ")[0])

c = code_of("SetInputSettings", {"inputName": "番組名", "inputSettings": {"text": "pwned"}})
assert c == 205, f"undeclared target should be 205, got {c}"
c = code_of("StopStream", {})
assert c == 205, f"undeclared request should be 205, got {c}"
print("ok: undeclared target / request denied (205)")

codes = [code_of("SetInputSettings", {"inputName": "OverlayText", "inputSettings": {"text": str(i)}}) for i in range(30)]
assert 207 in codes, f"flood was never stopped: {codes}"
print(f"ok: flood stopped after {codes.index(207)} request(s) (207)")
PY
grep -q '"core.security.acl_denied"' "$DIR/audit.log" || fail "denial not audited"
grep -q '"core.security.limit_exceeded"' "$DIR/audit.log" || fail "quarantine not audited"
sleep 3.5
grep -q "ObsGate: bot released" "$DIR/weave.log" || fail "bot was not released after quarantine_secs"
echo "PASS"
