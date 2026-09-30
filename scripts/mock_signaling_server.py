#!/usr/bin/env python3
"""
本地 Mock 信令服务器 —— 无真机/无远程实例时验证 P0 链路（REST + WS 信令状态机）。

依据：ScrcpyOverWebRTC 协议的公开 REST 端点与 WS 消息全表。
覆盖：/api/auth-status /api/version /api/login /api/register /api/me /api/ice_servers /devices
      /connect_client：connect → config → device_info → request-offer → (假) offer → answer/ICE 回收
      command → command_result 回执；?share_token= 访客连接骨架（P0-12）。

单端口 HTTP+WS（真实服务端也是单端口复用）：REST 走普通请求，
`Upgrade: websocket` 走同端口劫持升级——纯标准库实现，无第三方依赖。

用法：
  python scripts/mock_signaling_server.py                    # 0.0.0.0:18080，需要登录
  python scripts/mock_signaling_server.py --no-auth          # NO_AUTH 模式（P0-12）
  客户端填：<主机IP>:18080 且 use_ssl=false

注意：offer 是**假 SDP**（无真实 ICE 候选）——信令状态机可走到 connecting_webrtc，
      ICE 必然失败属预期；本 mock 只验证协议时序，不做媒体。
"""
import argparse
import base64
import hashlib
import json
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKENS = {}
ARGS = None
WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
# P1-3：全局默认画质（POST /api/default_settings 写入，GET 回读）
DEFAULT_SETTINGS = {}
# P2-10：标签存储（{tags, deviceTags}，GET/POST /api/tags；保真 requireAdmin=admin token）
TAGS_STORE = {"tags": [], "deviceTags": {}}
# P2-12：控制台快捷指令（数组整体 GET/POST /api/shortcuts，保真本地优先语义——空表=客户端回退）
SHORTCUTS_STORE = []
# P2-4：分享存储（{token_id,device_id,access_mode,description,created_at,expires_at}；{code,data} 包裹）
SHARE_LIST = []
# P2-5：群控任务（{task_id,type,devices:{id:{status,output}}}；create admin-only 收口）
TASKS_STORE = {}
# P2-5b：已上传文件名集合（POST /upload?name= 原始体——内容不存，仅保真存名流程）
UPLOAD_FILES = set()

# 假 offer（结构合法：fingerprint/ufrag/pwd/rtpmap 齐全，ICE 不会连通）
FAKE_OFFER_SDP = "\r\n".join([
    "v=0",
    "o=- 773642141 2 IN IP4 127.0.0.1",
    "s=-",
    "t=0 0",
    "a=group:BUNDLE 0",
    "a=msid-semantic: WMS mock",
    "m=video 9 UDP/TLS/RTP/SAVPF 96 97",
    "c=IN IP4 0.0.0.0",
    "a=rtcp:9 IN IP4 0.0.0.0",
    "a=ice-ufrag:mocku",
    "a=ice-pwd:mockpasswordmockpasswordmock",
    "a=ice-options:trickle",
    "a=fingerprint:sha-256 " + ":".join(["00"] * 32),
    "a=setup:actpass",
    "a=mid:0",
    "a=recvonly",
    "a=rtcp-mux",
    "a=rtpmap:96 H264/90000",
    "a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f",
    "a=rtpmap:97 rtx/90000",
    "a=fmtp:97 apt=96",
    "",
])


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


# ---------------------------------------------------------------- WebSocket 帧编解码（RFC6455 子集）
def _recv_exact(sock: socket.socket, n: int) -> bytes:
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("peer closed")
        buf += chunk
    return buf


def ws_recv_frame(sock: socket.socket):
    """返回 (opcode, payload_bytes)；自动处理掩码与 ping/pong/close。"""
    while True:
        b1, b2 = _recv_exact(sock, 2)
        opcode = b1 & 0x0F
        masked = bool(b2 & 0x80)
        length = b2 & 0x7F
        if length == 126:
            length = struct.unpack(">H", _recv_exact(sock, 2))[0]
        elif length == 127:
            length = struct.unpack(">Q", _recv_exact(sock, 8))[0]
        mask = _recv_exact(sock, 4) if masked else b""
        payload = _recv_exact(sock, length) if length else b""
        if masked:
            payload = bytes(payload[i] ^ mask[i % 4] for i in range(len(payload)))
        if opcode == 0x8:  # close
            return 0x8, payload
        if opcode == 0x9:  # ping -> pong
            _ws_send_frame(sock, 0xA, payload)
            continue
        if opcode == 0xA:  # pong
            continue
        return opcode, payload


def _ws_send_frame(sock: socket.socket, opcode: int, payload: bytes) -> None:
    header = bytes([0x80 | opcode])
    n = len(payload)
    if n < 126:
        header += bytes([n])
    elif n < (1 << 16):
        header += bytes([126]) + struct.pack(">H", n)
    else:
        header += bytes([127]) + struct.pack(">Q", n)
    sock.sendall(header + payload)


def ws_send_text(sock: socket.socket, text: str) -> None:
    _ws_send_frame(sock, 0x1, text.encode("utf-8"))


# ---------------------------------------------------------------- 信令处理（与 handler 线程共用 socket）
def log_json(obj) -> str:
    return json.dumps(obj, ensure_ascii=False)


def handle_signaling(sock: socket.socket, query: str, owns_socket: bool = True) -> None:
    token = ""
    for part in query.split("&"):
        if part.startswith("token="):
            token = part[6:]
        elif part.startswith("share_token="):
            token = part[12:]
    share = "share_token=" in query
    log(f"WS open (share={share}) {query[:80]}")

    def send(obj):
        ws_send_text(sock, json.dumps(obj, ensure_ascii=False))

    try:
        while True:
            opcode, payload = ws_recv_frame(sock)
            if opcode == 0x8:
                break
            if opcode != 0x1:
                continue
            message = payload.decode("utf-8", "replace")
            try:
                msg = json.loads(message)
            except json.JSONDecodeError:
                log(f"WS non-json: {message[:200]}")
                continue
            mtype = msg.get("message_type", "")
            log(f"WS <- {log_json(msg)[:300]}")
            if mtype == "connect":
                send({"message_type": "config", "ice_servers": []})
                send({"message_type": "device_info",
                      "device_info": {"app_version": "mock", "displays": [{"x_res": 1080, "y_res": 1920}]}})
            elif mtype == "forward":
                inner = msg.get("payload", {})
                itype = inner.get("type", "")
                if itype == "request-offer":
                    scrcpy = inner.get("scrcpy_options", {})
                    log(f"  request-offer scrcpy_options={log_json(scrcpy)}")
                    send({"message_type": "device_msg",
                          "payload": {"type": "offer", "sdp": FAKE_OFFER_SDP, "camera_support": True}})
                elif itype == "answer":
                    log(f"  answer received ({len(inner.get('sdp', ''))} chars) —— mock 无真实 peer，忽略")
                elif itype == "ice-candidate":
                    log(f"  ice-candidate: {inner.get('candidate', {}).get('candidate', '')[:80]}")
                else:
                    log(f"  forward/{itype} 已记录")
            elif mtype == "command":
                send({"message_type": "device_msg", "payload": {
                    "type": "command_result", "request_id": msg.get("request_id"),
                    "stdout": "mock: command echoed", "stderr": "", "exit_code": 0}})
            elif mtype == "screenshot_request":
                # P2-6：实时截图回包（1x1 PNG 标准 base64，客户端预览层可直接渲染）
                send({"message_type": "screenshot_response",
                      "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="})
                log(f"  screenshot_request dev={msg.get('device_id')}")
            else:
                log(f"  [{mtype or 'unknown'}] 已记录（P0 mock 不响应）")
    except ConnectionError:
        pass
    except Exception as e:  # noqa: BLE001
        log(f"WS error: {e!r}")
    finally:
        if owns_socket:  # 同步模式由 http.server 统一关闭，避免双关
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()
        log("WS closed")


# ---------------------------------------------------------------- REST（含 WS 升级劫持）
class Handler(BaseHTTPRequestHandler):
    server_version = "MockSignaling/1.0"
    connection: socket.socket

    # -- 工具 --
    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _text(self, code: int, text: str) -> None:
        body = text.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self, admin_only: bool = False) -> bool:
        auth = self.headers.get("Authorization", "")
        if not (auth.startswith("Bearer ") and auth[7:] in TOKENS):
            return False
        # admin_only：/api/tags 等 requireAdmin 端点保真（TOKENS 存用户名）
        if admin_only and TOKENS.get(auth[7:]) != "admin":
            return False
        return True

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length).decode("utf-8", "replace") if length else "{}"
        try:
            return json.loads(raw or "{}")
        except json.JSONDecodeError:
            return {}

    # -- WS 升级 --
    def _try_ws_upgrade(self) -> bool:
        if self.headers.get("Upgrade", "").lower() != "websocket":
            return False
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.wfile.write((
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode())
        self.close_connection = True
        # 同步跑信令循环：ThreadingMixIn 每连接一线程，阻塞在本线程即可；
        # WS 结束后正常走 finish/shutdown_request 关闭，无需 socket 劫持。
        handle_signaling(self.connection, self.path.split("?", 1)[1] if "?" in self.path else "",
                         owns_socket=False)
        return True

    # -- REST --
    def do_GET(self):  # noqa: N802
        if self._try_ws_upgrade():
            return
        raw = self.path          # 含 query（详情/过滤参数解析用）
        p = raw.split("?")[0]    # 纯路径（路由匹配用）
        if p == "/api/auth-status":
            return self._json(200, {"noAuth": bool(ARGS.no_auth)})
        if p == "/api/version":
            return self._json(200, {"version": "0.3.8-mock", "git_commit": "mock"})
        if p == "/api/ice_servers":
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            return self._json(200, {"ice_servers": []})
        if p == "/api/me":
            if not self._authed():
                return self._json(401, {"error": "unauthorized"})
            tok = self.headers.get("Authorization", "")[7:]
            return self._json(200, {
                "username": TOKENS.get(tok, "mock"), "role": "admin", "assigned_devices": [],
                "ai_config": {}, "forbid_bitrate": False, "forbid_fps": False,
                "forbid_resolution": False, "forbid_audio": False, "settings": {}, "expires_at": 0,
            })
        if p == "/devices":
            if not ARGS.no_auth and not self._authed():
                # 保真实测行为（DiscoveryService.ets 注释记录）：真实服务器此处返回
                # 401 纯文本 "Unauthorized"（非 JSON）——扫描指纹逻辑依赖状态码即可，body 保持一致
                return self._text(401, "Unauthorized")
            return self._json(200, {"devices": [
                {"device_id": "mock-1",
                 "device_info": {"displays": [{"x_res": 1080, "y_res": 1920}]}, "app_version": "mock",
                 "online": True, "client_count": 0, "clients": []},
                {"device_id": "mock-2",
                 "device_info": {"displays": [{"x_res": 720, "y_res": 1600}]}, "app_version": "mock",
                 "online": False, "client_count": 0, "clients": []},
            ]})
        if p == "/api/default_settings":
            if not self._authed():
                return self._json(401, {"error": "unauthorized"})
            return self._json(200, {"settings": DEFAULT_SETTINGS})
        if p == "/api/tags":
            # P2-10：GET 同样 requireAdmin 收口
            if not ARGS.no_auth and not self._authed(admin_only=True):
                return self._json(403, {"error": "admin required"})
            return self._json(200, TAGS_STORE)
        if p == "/api/server/addresses":
            # P2-4b：访客链接地址选择（{code,data:{addresses,current}}）
            if not self._authed():
                return self._json(401, {"error": "unauthorized"})
            return self._json(200, {"code": 0, "msg": "ok", "data": {
                "addresses": ["127.0.0.1:18080", "[::1]:18080"],
                "current": "127.0.0.1:18080"}})
        if p.startswith("/api/files/url"):
            # P2-5b：签名下载地址（{url} 相对路径，客户端拼 scheme://host；10 分钟有效语义）
            if not self._authed():
                return self._json(401, {"error": "unauthorized"})
            name = ""
            if "?" in raw:
                for kv in raw.split("?", 1)[1].split("&"):
                    if kv.startswith("name="):
                        from urllib.parse import unquote as _u2
                        name = _u2(kv.split("=", 1)[1])
            if name not in UPLOAD_FILES:
                return self._json(404, {"error": "file not found"})
            return self._json(200, {"url": f"/downloads/{name}?sig=mock-10min"})
        if p.startswith("/api/tasks/details"):
            # P2-5：任务详情（**直形状** {devices:{id:{status,output}}}，无外层包裹——上游 poll 同语义）
            if not ARGS.no_auth and not self._authed(admin_only=True):
                return self._json(403, {"error": "admin required"})
            tid = ""
            if "?" in raw:
                for kv in raw.split("?", 1)[1].split("&"):
                    if kv.startswith("task_id="):
                        tid = kv.split("=", 1)[1]
            task = TASKS_STORE.get(tid)
            if task is None:
                return self._json(404, {"error": "task not found"})
            return self._json(200, task)
        if p.startswith("/api/share/list"):
            # P2-4：列表（?device_id 过滤；Bearer 收口）
            if not self._authed():
                return self._json(401, {"error": "unauthorized"})
            dev_filter = ""
            if "?" in raw:
                for kv in raw.split("?", 1)[1].split("&"):
                    if kv.startswith("device_id="):
                        dev_filter = kv.split("=", 1)[1]
            items = [s for s in SHARE_LIST if not dev_filter or s["device_id"] == dev_filter]
            return self._json(200, {"code": 0, "msg": "ok", "data": items})
        if p == "/api/shortcuts":
            # P2-12：整表数组直回（空数组→客户端回退本地/默认）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            return self._json(200, SHORTCUTS_STORE)
        return self._json(404, {"error": f"no such path {p}"})

    def do_POST(self):  # noqa: N802
        payload = self._read_json()
        if self.path == "/api/login":
            user = payload.get("username", "")
            if not user:
                return self._json(400, {"error": "username required"})
            token = f"mock-token-{user}-{int(time.time())}"
            TOKENS[token] = user
            log(f"REST POST /api/login user={user} -> token")
            return self._json(200, {"token": token, "username": user, "role": "admin", "assigned_devices": []})
        if self.path == "/api/register":
            user = payload.get("username", "")
            if not user:
                return self._json(400, {"error": "username required"})
            log(f"REST POST /api/register user={user}")
            return self._json(200, {"message": "ok"})
        if self.path == "/api/default_settings":
            # P1-3：保存全局（保真：需 Bearer；写入后 GET 可回读）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            DEFAULT_SETTINGS.update(payload.get("settings", {}) or {})
            log(f"REST POST /api/default_settings -> {DEFAULT_SETTINGS}")
            return self._json(200, {"message": "ok"})
        if self.path == "/api/tags":
            # P2-10：标签保存（保真 requireAdmin：admin token 才收）
            if not ARGS.no_auth and not self._authed(admin_only=True):
                return self._json(403, {"error": "admin required"})
            TAGS_STORE["tags"] = payload.get("tags", []) or []
            TAGS_STORE["deviceTags"] = payload.get("deviceTags", {}) or {}
            log(f"REST POST /api/tags -> {len(TAGS_STORE['tags'])} tags")
            return self._json(200, {"message": "ok"})
        if self.path == "/api/shortcuts":
            # P2-12：快捷指令整表保存（请求体是数组，非对象；原地变异避免局部绑定陷阱）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            if isinstance(payload, list):
                SHORTCUTS_STORE.clear()
                SHORTCUTS_STORE.extend(payload)
            log(f"REST POST /api/shortcuts -> {len(SHORTCUTS_STORE)} items")
            return self._json(200, {"message": "ok"})
        if self.path == "/api/share/create":
            # P2-4：创建分享（{code,msg,data} 包裹；data 含 token_id/expires_at）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            import time as _t
            share = {
                "token_id": f"st_mock_{len(SHARE_LIST) + 1}_{int(_t.time())}",
                "device_id": payload.get("device_id", ""),
                "access_mode": payload.get("access_mode", "view"),
                "description": payload.get("description", ""),
                "created_at": _t.strftime("%Y-%m-%dT%H:%M:%SZ", _t.gmtime()),
                "expires_at": _t.strftime("%Y-%m-%dT%H:%M:%SZ",
                                          _t.gmtime(_t.time() + int(payload.get("expire_seconds", 86400)))),
            }
            SHARE_LIST.append(share)
            log(f"REST POST /api/share/create -> {share['token_id']}")
            return self._json(200, {"code": 0, "msg": "ok", "data": share})
        if self.path == "/api/share/revoke":
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            tid = payload.get("token", "")
            before = len(SHARE_LIST)
            SHARE_LIST[:] = [s for s in SHARE_LIST if s["token_id"] != tid]
            if len(SHARE_LIST) == before:
                return self._json(200, {"code": 1, "msg": "share not found"})
            log(f"REST POST /api/share/revoke -> {tid}")
            return self._json(200, {"code": 0, "msg": "ok"})
        if self.path == "/api/share/extend":
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            import time as _t
            tid = payload.get("token", "")
            for s in SHARE_LIST:
                if s["token_id"] == tid:
                    base = _t.mktime(_t.strptime(s["expires_at"], "%Y-%m-%dT%H:%M:%SZ"))
                    s["expires_at"] = _t.strftime("%Y-%m-%dT%H:%M:%SZ",
                                                  _t.gmtime(base + int(payload.get("extend_seconds", 0))))
                    return self._json(200, {"code": 0, "msg": "ok"})
            return self._json(200, {"code": 1, "msg": "share not found"})
        if self.path == "/api/share/redeem_card":
            # P2-4：卡密兑换——保真免登录（上游 CardConnectModal 不带 Authorization）
            code = str(payload.get("card_code", "")).strip()
            if len(code) == 0:
                return self._json(200, {"code": 1, "msg": "invalid card"})
            return self._json(200, {"code": 0, "msg": "ok", "data": {"token": f"st_card_{code[:6]}"}})
        if self.path == "/api/share/update":
            # P2-4b：访客设置更新（四维 forbid + guest_settings，null=继承）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            tid = payload.get("token", "")
            for s in SHARE_LIST:
                if s["token_id"] == tid:
                    s["forbid_bitrate"] = bool(payload.get("forbid_bitrate", False))
                    s["forbid_fps"] = bool(payload.get("forbid_fps", False))
                    s["forbid_resolution"] = bool(payload.get("forbid_resolution", False))
                    s["forbid_audio"] = bool(payload.get("forbid_audio", False))
                    s["guest_settings"] = payload.get("guest_settings")
                    log(f"REST POST /api/share/update -> {tid}")
                    return self._json(200, {"code": 0, "msg": "ok"})
            return self._json(200, {"code": 1, "msg": "share not found"})
        if self.path.startswith("/upload?name="):
            # P2-5b：原始字节体上传（上游 xhr.send(file) 同形；body 已被 _read_json 消耗）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            from urllib.parse import unquote as _unq
            name = _unq(self.path.split("name=", 1)[1])
            UPLOAD_FILES.add(name)
            log(f"REST POST /upload -> {name}")
            return self._json(200, {"message": "ok"})
        if self.path == "/api/user/ai-config":
            # P2-3b：AI 配置云同步（上游 saveAIConfig 四键契约；Bearer 收口）
            if not ARGS.no_auth and not self._authed():
                return self._json(401, {"error": "unauthorized"})
            log(f"REST POST /api/user/ai-config keys={sorted(payload.keys()) if isinstance(payload, dict) else '?'}")
            return self._json(200, {"message": "ok"})
        if self.path == "/api/tasks":
            if not ARGS.no_auth and not self._authed(admin_only=True):
                return self._json(403, {"error": "admin required"})
            import time as _tt
            task_id = f"task_{len(TASKS_STORE) + 1}_{int(_tt.time())}"
            targets = payload.get("targets", []) or []
            cmd = str(payload.get("payload", ""))
            devices = {d: {"status": "success", "output": f"mock done: {cmd}"} for d in targets}
            TASKS_STORE[task_id] = {"task_id": task_id, "type": payload.get("type", "shell"),
                                    "devices": devices}
            log(f"REST POST /api/tasks -> {task_id} targets={len(targets)}")
            return self._json(200, {"status": "success", "task_id": task_id})
        return self._json(404, {"error": f"no such path {self.path}"})

    def log_message(self, fmt, *args):  # 静默访问日志
        return


def main():
    global ARGS
    parser = argparse.ArgumentParser(description="Mock 信令服务器（P0 验证用，纯标准库）")
    parser.add_argument("--port", type=int, default=18080, help="REST 与 WS 共用端口（默认 18080）")
    parser.add_argument("--no-auth", action="store_true", help="NO_AUTH 模式")
    ARGS = parser.parse_args()
    httpd = ThreadingHTTPServer(("0.0.0.0", ARGS.port), Handler)
    log(f"listening on http://0.0.0.0:{ARGS.port}（REST+WS 同端口）  no_auth={ARGS.no_auth}")
    log("客户端连接地址填：<本机IP>:%d 且关闭 use_ssl" % ARGS.port)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        log("bye")


if __name__ == "__main__":
    main()
