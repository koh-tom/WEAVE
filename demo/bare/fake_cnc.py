#!/usr/bin/env python3
# fake_cnc.py — デモ用のダミー受信サーバー (Before 側の「外部 C&C」役)
#
# 127.0.0.1 でだけ待ち受け、届いたバイト列を 1 行にして表示する。ネットワークには一切出ない。
# 「素の世界では、盗んだ値がこうして外に出て行く」を目に見える形にするためだけのもの。
import socket
import sys

port = int(sys.argv[1]) if len(sys.argv) > 1 else 9099
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(8)
print(f"[C&C] 127.0.0.1:{port} で待ち受け中 (盗まれたデータの受信役)", flush=True)
try:
    while True:
        conn, _ = srv.accept()
        data = conn.recv(4096)
        if data:
            line = data.decode("utf-8", "replace").strip()
            print(f"\033[31;1m[C&C] 受信 (外部に漏れた): {line}\033[0m", flush=True)
        conn.close()
except KeyboardInterrupt:
    pass
finally:
    srv.close()
