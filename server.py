#!/usr/bin/env python3
"""
MyCompanion Backend Server

Simple HTTP + WebSocket server.
POST /chat  — chat API
WS   /ws    — WebSocket push

Usage:  python server.py
"""

import socket, threading, json, hashlib, base64, struct
from datetime import datetime

HOST = "0.0.0.0"
PORT = 8000


def generate_reply(user_text: str) -> str:
    """Replace with your AI call."""
    t = user_text.strip()
    g = ["你好", "嗨", "hello", "hi", "早上好", "下午好", "晚上好"]
    if t.lower() in [x.lower() for x in g]:
        return "你好！有什么可以帮你的吗？"
    return f"你说的是：「{t}」\n（这是占位回复，接入 LLM 后就能智能应答了。）"


# ── HTTP ──
def handle_http(conn, method, path, headers, body):
    if method == "POST" and path == "/chat":
        try:
            data = json.loads(body)
            reply = generate_reply(data.get("text", ""))
            resp = json.dumps({"reply": reply}, ensure_ascii=False)
        except Exception:
            resp = json.dumps({"reply": "无法解析消息"}, ensure_ascii=False)
        b = resp.encode()
        conn.sendall(
            f"HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\n"
            f"Content-Length: {len(b)}\r\nAccess-Control-Allow-Origin: *\r\n"
            f"Connection: close\r\n\r\n".encode() + b
        )
    elif method == "OPTIONS":
        conn.sendall(
            b"HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\n"
            b"Access-Control-Allow-Methods: POST, OPTIONS\r\n"
            b"Access-Control-Allow-Headers: Content-Type\r\nConnection: close\r\n\r\n"
        )
    else:
        r = json.dumps({"error": "Not Found"}, ensure_ascii=False).encode()
        conn.sendall(
            f"HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(r)}\r\nConnection: close\r\n\r\n".encode() + r
        )
    try: conn.close()
    except: pass


# ── WebSocket ──
def ws_frame(conn):
    h = conn.recv(2)
    if len(h) < 2: return None, None
    op = h[0] & 0xF
    n = h[1] & 0x7F
    if n == 126: n = struct.unpack(">H", conn.recv(2))[0]
    elif n == 127: n = struct.unpack(">Q", conn.recv(8))[0]
    mask = conn.recv(4)
    buf = bytearray()
    while len(buf) < n:
        c = conn.recv(min(4096, n - len(buf)))
        if not c: break
        buf.extend(c)
    return op, bytes(b ^ mask[i % 4] for i, b in enumerate(buf))


def ws_send(conn, text):
    d = text.encode()
    L = len(d)
    f = bytearray([0x81])
    if L < 126: f.append(L)
    elif L < 65536: f.append(126); f.extend(struct.pack(">H", L))
    else: f.append(127); f.extend(struct.pack(">Q", L))
    f.extend(d); conn.sendall(bytes(f))


def handle_ws(conn, ws_key):
    m = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    a = base64.b64encode(hashlib.sha1((ws_key + m).encode()).digest()).decode()
    conn.sendall(f"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                 f"Connection: Upgrade\r\nSec-WebSocket-Accept: {a}\r\n\r\n".encode())
    addr = conn.getpeername()
    print(f"[WS] + {addr}")
    ws_send(conn, json.dumps({"type": "greeting", "content": "欢迎连接知了服务！",
            "timestamp": datetime.now().isoformat()}, ensure_ascii=False))
    try:
        while True:
            op, payload = ws_frame(conn)
            if op is None or op == 0x8: break
            if op == 0x9:
                conn.sendall(bytes([0x8A, len(payload)]) + payload)
            elif op == 0x1:
                try:
                    msg = json.loads(payload.decode(errors="replace"))
                    r = generate_reply(msg.get("text", ""))
                    ws_send(conn, json.dumps({"type": "reply", "content": r,
                        "timestamp": datetime.now().isoformat()}, ensure_ascii=False))
                except: pass
    except Exception as e:
        print(f"[WS] err: {e}")
    finally:
        print(f"[WS] - {addr}")
        try: conn.close()
        except: pass


# ── Dispatcher ──
def client_handler(conn, addr):
    try:
        buf = b""
        while b"\r\n\r\n" not in buf:
            c = conn.recv(4096)
            if not c: return
            buf += c
        head, _, rest = buf.partition(b"\r\n\r\n")
        lines = head.decode(errors="replace").split("\r\n")
        method, path, *_ = lines[0].split(" ") + ["", ""]
        headers = {}
        for ln in lines[1:]:
            if ":" in ln:
                k, v = ln.split(":", 1)
                headers[k.strip().lower()] = v.strip()
        print(f"[{addr[0]}] {method} {path}")
        if headers.get("upgrade", "").lower() == "websocket" and path == "/ws":
            handle_ws(conn, headers.get("sec-websocket-key", ""))
        else:
            handle_http(conn, method, path, headers, rest.decode(errors="replace"))
    except Exception as e:
        print(f"[!!] {addr}: {e}")
        try: conn.close()
        except: pass


# ── Main ──
if __name__ == "__main__":
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(50)
    print(f"Server running on http://0.0.0.0:{PORT}")
    print(f"Test: curl http://localhost:{PORT}/chat -d '{{\"text\":\"hello\"}}'")
    try:
        while True:
            c, a = srv.accept()
            threading.Thread(target=client_handler, args=(c, a), daemon=True).start()
    except KeyboardInterrupt:
        print("\nBye.")
    finally:
        srv.close()
