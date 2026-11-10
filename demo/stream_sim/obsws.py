#!/usr/bin/env python3
"""demo/stream_sim/obsws.py — 本物の OBS に obs-websocket v5 で話しかける最小のクライアント (標準ライブラリだけ)

  python3 obsws.py shot <scene> <out.png> [width]   OBS が描いた配信画面 (シーン) を PNG で保存
  python3 obsws.py stats                            OBS の統計 (CPU・描画/出力で落ちたフレーム・録画中か) を JSON で
  python3 obsws.py call <RequestType> [json]        任意の要求 (読み取り用。記録を取るためだけに使う)
パスワードは OBS の設定ファイル (plugin_config/obs-websocket/config.json) から読む。表示はしない
"""
import base64, hashlib, json, os, socket, struct, sys

CFG = os.path.expanduser("~/.config/obs-studio/plugin_config/obs-websocket/config.json")


class OBS:
    def __init__(self, host="127.0.0.1"):
        cfg = json.load(open(CFG))
        self.port, self.pw = cfg.get("server_port", 4455), cfg.get("server_password", "")
        self.s = socket.create_connection((host, self.port), timeout=10)
        key = base64.b64encode(os.urandom(16)).decode()
        self.s.sendall(f"GET / HTTP/1.1\r\nHost: {host}:{self.port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                       f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: obswebsocket.json\r\n\r\n".encode())
        head = b""
        while b"\r\n\r\n" not in head:
            head += self.s.recv(1)
        if b" 101 " not in head.split(b"\r\n")[0]:
            raise RuntimeError("websocket handshake failed")
        hello = self.recv()
        ident = {"rpcVersion": 1, "eventSubscriptions": 0}
        auth = hello["d"].get("authentication")
        if auth:
            secret = base64.b64encode(hashlib.sha256((self.pw + auth["salt"]).encode()).digest()).decode()
            ident["authentication"] = base64.b64encode(hashlib.sha256((secret + auth["challenge"]).encode()).digest()).decode()
        self.send({"op": 1, "d": ident})
        while self.recv()["op"] != 2:
            pass
        self.n = 0

    def _read(self, n):
        b = b""
        while len(b) < n:
            c = self.s.recv(n - len(b))
            if not c:
                raise EOFError
            b += c
        return b

    def recv(self):
        data = b""
        while True:
            h = self._read(2)
            fin, op, ln = h[0] & 0x80, h[0] & 0x0F, h[1] & 0x7F
            if ln == 126:
                ln = struct.unpack(">H", self._read(2))[0]
            elif ln == 127:
                ln = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(ln)
            if op == 9:  # ping
                self._frame(10, payload)
                continue
            data += payload
            if fin:
                return json.loads(data)

    def _frame(self, op, payload):
        mask = os.urandom(4)
        n = len(payload)
        h = bytes([0x80 | op]) + (bytes([0x80 | n]) if n < 126 else bytes([0x80 | 126]) + struct.pack(">H", n) if n < 65536 else bytes([0x80 | 127]) + struct.pack(">Q", n))
        self.s.sendall(h + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(payload)))

    def send(self, obj):
        self._frame(1, json.dumps(obj).encode())

    def call(self, rtype, data=None):
        self.n += 1
        rid = f"sim-{self.n}"
        self.send({"op": 6, "d": {"requestType": rtype, "requestId": rid, "requestData": data or {}}})
        while True:
            m = self.recv()
            if m["op"] == 7 and m["d"].get("requestId") == rid:
                st = m["d"]["requestStatus"]
                if not st.get("result"):
                    raise RuntimeError(f"{rtype}: {st.get('code')} {st.get('comment', '')}")
                return m["d"].get("responseData", {})

    def shot(self, source, path, width=1280):
        r = self.call("GetSourceScreenshot", {"sourceName": source, "imageFormat": "png", "imageWidth": width})
        open(path, "wb").write(base64.b64decode(r["imageData"].split(",", 1)[1]))


if __name__ == "__main__":
    a = sys.argv[1:]
    o = OBS()
    if a[0] == "shot":
        o.shot(a[1], a[2], int(a[3]) if len(a) > 3 else 1280)
    elif a[0] == "stats":
        st = o.call("GetStats")
        st["record"] = o.call("GetRecordStatus")
        print(json.dumps(st, ensure_ascii=False))
    elif a[0] == "call":
        print(json.dumps(o.call(a[1], json.loads(a[2]) if len(a) > 2 else {}), ensure_ascii=False))
