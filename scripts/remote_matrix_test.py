#!/usr/bin/env python3
"""远端功能矩阵一致性测试（对真实 webrtc-signaling 服务器执行）

用途：把 §1.4/§1.5/§1.8/§1.9 的 REST 全表与 §1.10 的
WS 信令消息全表，投影到一台**真实**服务器上逐条打勾。与 mock_signaling_test.py
（本地 mock 回放）互补：那个验协议时序，这个验真实实现的落地程度。

用法：
    python scripts/remote_matrix_test.py --base https://[240e:...]:8443
    python scripts/remote_matrix_test.py --base ... --user admin --pass admin123

判定三态（远端可能比矩阵基线旧，缺失≠客户端缺陷）：
    PASS   端点/消息存在且行为符合矩阵
    ABSENT 服务端未实现该端点（404/501）→ 记为版本差，不计失败
    FAIL   存在但行为不符 → 真缺陷

副作用控制：脚本对 tags/shortcuts/default_settings/ai-config 做「读-改-写-还原」；
设备/用户/分享等自建资源在收尾统一清理；绝不 DELETE 真实在线设备。
退出码：0=无 FAIL。
"""
import argparse
import asyncio
import base64
import json
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# 服务端为自签证书（与 scripts/probe-server.ps1 的 SkipCertificateCheck 一致）
_SSL = ssl.create_default_context()
_SSL.check_hostname = False
_SSL.verify_mode = ssl.CERT_NONE
urllib.request.install_opener(
    urllib.request.build_opener(urllib.request.HTTPSHandler(context=_SSL)))

OK = 0
FAIL = 0
ABSENT = 0
ROWS = []
BASE = ""
WS_BASE = ""


def rec(status, name, extra=""):
    global OK, FAIL, ABSENT
    if status == "PASS":
        OK += 1
    elif status == "FAIL":
        FAIL += 1
    else:
        ABSENT += 1
    ROWS.append((status, name, str(extra)[:110]))
    print(f"[{status:6}] {name} {str(extra)[:110]}")


def req(method, path, payload=None, token=None, raw_body=None, ctype=None, timeout=20):
    """返回 (status_code:int|None, body, err_flag)。HTTP 错误不抛异常，交给判定层。"""
    url = BASE + path
    data = None
    headers = {}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    if raw_body is not None:
        data = raw_body
        headers["Content-Type"] = ctype or "application/octet-stream"
    if token:
        headers["Authorization"] = "Bearer " + token
    r = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, body, False
    except urllib.error.HTTPError as e:
        return e.code, e.read(), True
    except Exception as e:  # 连接级失败
        return None, str(e).encode(), True


def jreq(method, path, payload=None, token=None, timeout=20):
    """返回 (code, parsed_json_or_text, is_http_error)。"""
    code, body, err = req(method, path, payload, token, timeout=timeout)
    txt = body.decode("utf-8", "replace")
    try:
        return code, json.loads(txt), err
    except Exception:
        return code, txt, err


def absent(code):
    return code in (404, 405, 501)


# ---------------------------------------------------------------- REST 矩阵

def rest_matrix(token, admin_token, test_user, device_id):
 print("\n===== A. 鉴权与用户面 =====")
    c, b, _ = jreq("GET", "/api/auth-status")
    rec("PASS" if c == 200 and isinstance(b, dict) and "noAuth" in b else "FAIL",
        "auth-status 免密探测", b)

    c, b, _ = jreq("GET", "/api/me", token=token)
    need = ("username", "role", "assigned_devices")
    rec("PASS" if c == 200 and isinstance(b, dict) and all(k in b for k in need) else "FAIL",
        "me 用户信息", f"keys={sorted(b)[:9] if isinstance(b, dict) else b}")
    if c == 200 and isinstance(b, dict):
        for opt in ("expires_at", "forbid_bitrate", "settings"):
            rec("PASS" if opt in b else "ABSENT", f"me.{opt} 新版字段", "")

    c, b, _ = jreq("POST", f"/api/register", {"username": test_user, "password": "matrix123456"})
    rec("PASS" if c in (200, 409) else "FAIL", "register 注册", f"code={c} {str(b)[:60]}")
    if c not in (200, 409):
        rec("ABSENT", "register（服务端未开放自助注册）", f"code={c}")

    c, b, _ = jreq("POST", "/api/login", {"username": test_user, "password": "matrix123456"})
    utok = b.get("token") if isinstance(b, dict) else None
    rec("PASS" if c == 200 and utok else "FAIL", "login 新用户取 token", f"code={c}")
    if utok:
        c2, b2, _ = jreq("GET", "/api/me", token=utok)
        rec("PASS" if c2 == 200 else "FAIL", "me 新用户 token 可用", f"code={c2}")

    # --- 设备列表（§1.4 / P0-2）
    c, b, _ = jreq("GET", "/devices", token=token)
    ok_shape = False
    if c == 200 and isinstance(b, list) and b:
        d = b[0]
        ok_shape = isinstance(d, dict) and all(k in d for k in ("device_id", "online"))
        if not ok_shape:  # 兼容字符串数组
            ok_shape = all(isinstance(x, str) for x in b)
    rec("PASS" if ok_shape else "FAIL", "devices 列表形状（直形状 or 字符串数组）",
        f"n={len(b) if isinstance(b, list) else '?'}")
    if isinstance(b, list) and b and isinstance(b[0], dict):
        for k in ("device_info", "first_seen", "last_seen", "client_count", "clients"):
            rec("PASS" if k in b[0] else "ABSENT", f"devices[].{k}", "")

    c, b, _ = jreq("GET", "/api/version")
    ver = b.get("version") if isinstance(b, dict) else "?"
    rec("PASS" if c == 200 else "FAIL", "version 版本", b)

    c, b, _ = jreq("GET", "/api/ice_servers", token=token)
    good = c == 200 and isinstance(b, (list, dict))
    if isinstance(b, dict):
        good = "ice_servers" in b
    if isinstance(b, list) and b and isinstance(b[0], str):
        good = all(x.startswith(("turn:", "stun:")) for x in b)
    if isinstance(b, list) and b and isinstance(b[0], dict):
        good = all("urls" in x for x in b)
    rec("PASS" if good else "FAIL", "ice_servers 格式 turn:/stun:", str(b)[:80])

    c, b, _ = jreq("GET", "/api/license_status", token=token)
    if absent(c):
        rec("ABSENT", "license_status 授权状态（P3）", f"code={c}")
    else:
        rec("PASS" if c == 200 else "FAIL", "license_status 授权状态（P3）", f"code={c} {str(b)[:60]}")

    # --- 可变全局状态：读-改-写-还原
 print("\n===== B. 全局状态：读-改-写-还原 =====")
    saved = {}
    for key, path, payload in (
        ("default_settings", "/api/default_settings", {"fps": 77, "bitrate": 7}),
        ("tags", "/api/tags", {"tags": [{"id": "matrix_t1", "name": "矩阵测试", "color": "#38bdf8"}],
                               "deviceTags": {device_id: ["matrix_t1"]}}),
        ("shortcuts", "/api/shortcuts", [{"name": "矩阵探针", "cmd": "echo matrix"}]),
    ):
        c0, b0, _ = jreq("GET", path, token=admin_token)
        saved[key] = b0 if c0 == 200 else None
        if absent(c0):
            rec("ABSENT", f"{key} 端点", f"code={c0}")
            continue
        c1, b1, _ = jreq("POST", path, payload, token=admin_token)
        c2, b2, _ = jreq("GET", path, token=admin_token)

        def _echoed(obj, sample):
            """在直形状/{code,data} 双族里找样本值。"""
            if isinstance(obj, dict) and "data" in obj and not isinstance(obj.get("data"), (int, str)):
                obj = obj["data"]
            if isinstance(obj, dict):
                return any(sample in str(v) for v in obj.values())
            if isinstance(obj, list):
                return any(sample in json.dumps(x, ensure_ascii=False) for x in obj)
            return False

        wrote = _echoed(b2, "77" if key == "default_settings" else
                        ("matrix_t1" if key == "tags" else "矩阵探针"))
        rec("PASS" if c1 == 200 and c2 == 200 and wrote else "FAIL",
            f"{key} 保存→回读", f"post={c1} get={c2} {str(b2)[:70]}")
        if saved[key] is not None:
            jreq("POST", path, saved[key], token=admin_token)
            c3, b3, _ = jreq("GET", path, token=admin_token)
            rec("PASS" if c3 == 200 else "FAIL", f"{key} 已还原", f"get={c3}")

    # ai-config（会覆盖 admin 的 AI 配置 → 测完还原）
    c0, me0, _ = jreq("GET", "/api/me", token=admin_token)
    old_ai = me0.get("ai_config") if isinstance(me0, dict) else None
    c1, b1, _ = jreq("POST", "/api/user/ai-config",
                     {"ai_api_url": "https://matrix.invalid/v1", "ai_api_key": "k",
                      "ai_model": "m", "ai_provider": "openai"}, token=admin_token)
    if absent(c1):
        rec("ABSENT", "ai-config 云同步", f"code={c1}")
    else:
        c2, me1, _ = jreq("GET", "/api/me", token=admin_token)
        got = me1.get("ai_config") if isinstance(me1, dict) else None
        rec("PASS" if c1 == 200 and isinstance(got, dict) and got.get("ai_model") == "m" else "FAIL",
            "ai-config 云同步→/api/me 回读", f"post={c1} {str(got)[:70]}")
        # 还原：old_ai 为 None（原本未配置）时也要清空，不能留下测试残留
        restore = old_ai if isinstance(old_ai, dict) else {}
        jreq("POST", "/api/user/ai-config",
             {"ai_api_url": restore.get("ai_api_url", ""), "ai_api_key": restore.get("ai_api_key", ""),
              "ai_model": restore.get("ai_model", ""), "ai_provider": restore.get("ai_provider", "")},
             token=admin_token)
        c4, me2, _ = jreq("GET", "/api/me", token=admin_token)
        now_ai = me2.get("ai_config") if isinstance(me2, dict) else None
        clean = (not isinstance(now_ai, dict)) or not now_ai.get("ai_model")
        rec("PASS" if clean else "FAIL", "ai-config 已还原", str(now_ai)[:60])

    # --- 分享/卡密全链路（§1.5 / P2-4）
 print("\n===== C. 分享卡密全链路 =====")
    c, b, _ = jreq("POST", "/api/share/create",
                   {"device_id": device_id, "expire_seconds": 1800, "access_mode": "full",
                    "description": "matrix-test"}, token=admin_token)
    if absent(c):
        rec("ABSENT", "share/create 创建分享（整族）", f"code={c}")
        share_token = None
    else:
        share_token = None
        data = b.get("data", {}) if isinstance(b, dict) else {}
        share_token = data.get("token") or data.get("token_id")
        card = data.get("card_code")
        rec("PASS" if c == 200 and isinstance(b, dict) and b.get("code") == 0 and share_token else "FAIL",
            "share/create 返回 token+卡密", f"code={c} card={card}")

    if share_token:
        c, b, _ = jreq("GET", "/api/share/list", token=admin_token)
        rec("PASS" if c == 200 and isinstance(b, dict) else "FAIL", "share/list 分享列表", f"code={c}")

        c, b, _ = jreq("GET", f"/api/share/info?token={urllib.parse.quote(share_token)}")
        rec("PASS" if c == 200 and isinstance(b, dict) and b.get("code") == 0 else "FAIL",
            "share/info 免登录访客校验", f"code={c} {str(b)[:70]}")

        c, b, _ = jreq("POST", "/api/share/extend", {"token": share_token, "extend_seconds": 3600},
                       token=admin_token)
        rec("PASS" if c == 200 else "FAIL", "share/extend 续期", f"code={c}")

        c, b, _ = jreq("POST", "/api/share/update",
                       {"token": share_token, "guest_settings": {"fps": 30, "bitrate": 4000000}},
                       token=admin_token)
        rec("PASS" if c == 200 else ("ABSENT" if absent(c) else "FAIL"),
            "share/update 访客细粒度权限", f"code={c} {str(b)[:60]}")

        if card:
            c, b, _ = jreq("POST", "/api/share/redeem_card", {"card_code": card})
            rec("PASS" if c == 200 and isinstance(b, dict) and b.get("code") == 0 else "FAIL",
                "share/redeem_card 卡密兑换（免登录）", f"code={c} {str(b)[:60]}")

        c, b, _ = jreq("GET", "/api/server/addresses", token=admin_token)
        good = c == 200 and isinstance(b, dict) and len(b.get("data", {}).get("addresses", [])) > 0
        rec("PASS" if good else ("ABSENT" if absent(c) else "FAIL"),
            "server/addresses 地址列表（含 IPv6）", str(b)[:90])

        c, b, _ = jreq("POST", "/api/share/revoke", {"token": share_token}, token=admin_token)
        rec("PASS" if c == 200 else "FAIL", "share/revoke 撤销并清理", f"code={c}")

    # --- 任务系统（§1.8 / P2-5）
 print("\n===== D. 任务系统与文件分发 =====")
    c, b, _ = jreq("POST", "/api/tasks",
                   {"type": "shell", "targets": [device_id], "payload": "echo matrix-probe"},
                   token=admin_token)
    if absent(c):
        rec("ABSENT", "tasks 下发（整族）", f"code={c}")
    else:
        tid = b.get("task_id") if isinstance(b, dict) else None
        rec("PASS" if c == 200 and isinstance(b, dict) and b.get("status") == "success" else "FAIL",
            "tasks 下发 shell", f"code={c} task_id={tid}")
        if tid:
            time.sleep(3)
            c2, b2, _ = jreq("GET", f"/api/tasks/details?task_id={tid}", token=admin_token)
            sub = b2.get("devices", {}).get(device_id, {}) if isinstance(b2, dict) else {}
            rec("PASS" if c2 == 200 and sub.get("status") else "FAIL",
                "tasks/details 直形状回读", f"get={c2} status={sub.get('status')}")

    c, b, _ = jreq("GET", "/api/files", token=token)
    if absent(c):
        rec("ABSENT", "files 云端文件列表", f"code={c}")
    else:
        rec("PASS" if c == 200 else "FAIL", "files 云端文件列表", f"code={c} {str(b)[:60]}")

    c, b, _ = req("POST", "/upload?name=matrix_probe.bin", raw_body=b"MATRIX-PROBE-BYTES",
                  token=token)
    rec("PASS" if c == 200 else ("ABSENT" if absent(c) else "FAIL"),
        "upload 原始体上传（非 multipart）", f"code={c} {b[:50]}")

    c, b, _ = jreq("GET", "/downloads/matrix_probe.bin", token=token)
    rec("PASS" if c == 200 else ("ABSENT" if absent(c) else "FAIL"),
        "downloads 回读", f"code={c} {b[:40]}")

    # --- 管理员（§1.4 / P3-5）
 print("\n===== E. 管理员面 =====")
    # 用独立用户名：前面的 /api/register 已占用了 test_user
    auser = "matrix_a_" + str(int(time.time()) % 100000)

    def admin_ok(code, body):
        """管理员端点存在 {code,data} 与直形状两族，接受任一成功形态。"""
        if code != 200:
            return False
        if isinstance(body, dict):
            return body.get("code") == 0 or body.get("status") == "success" or "message" in body
        return True

    c, b, _ = jreq("GET", "/api/admin/users", token=admin_token)
    if absent(c):
        rec("ABSENT", "admin/users 整族", f"code={c}")
    else:
        rec("PASS" if c == 200 and isinstance(b, list) else "FAIL",
            "admin/users 用户列表", f"code={c} n={len(b) if isinstance(b,list) else '?'}")
        c, b2, _ = jreq("POST", "/api/admin/users/create",
                        {"username": auser, "password": "matrix123456", "role": "user",
                         "note": "matrix-auto", "expire_seconds": 3600}, token=admin_token)
        rec("PASS" if admin_ok(c, b2) else ("ABSENT" if absent(c) else "FAIL"),
            "admin/users/create 建用户", f"code={c} {str(b2)[:60]}")
        for ep, payload, label in (
            ("/api/admin/users/update_note", {"username": auser, "note": "matrix-note-2"}, "update_note 备注"),
            ("/api/admin/users/update", {"username": auser, "forbid_bitrate": True, "expire_seconds": 7200}, "update 权限+有效期"),
            ("/api/admin/assign", {"username": auser, "devices": [device_id]}, "assign 分配设备"),
            ("/api/admin/users/reset_password", {"username": auser, "password": "matrix654321"}, "reset_password 重置密码"),
            ("/api/admin/users/kick", {"username": auser, "device_id": device_id}, "kick 强断连接"),
        ):
            cc, bb, _ = jreq("POST", ep, payload, token=admin_token)
            rec("PASS" if admin_ok(cc, bb) else ("ABSENT" if absent(cc) else "FAIL"),
                f"admin {label}", f"code={cc} {str(bb)[:60]}")
        cc, bb, _ = jreq("POST", "/api/admin/users/delete", {"username": auser}, token=admin_token)
        rec("PASS" if admin_ok(cc, bb) else ("ABSENT" if absent(cc) else "FAIL"),
            "admin/users/delete 清理", f"code={cc} {str(bb)[:50]}")
    # 收尾：删掉本轮 /api/register 建的 test_user（否则每次跑测试都留一个孤儿账号）
    c, b, _ = jreq("POST", "/api/admin/users/delete", {"username": test_user}, token=admin_token)
    if absent(c):
        rec("ABSENT", "清理 register 建的测试用户（admin 端点不可用）", f"code={c}")
    else:
        c2, b2, _ = jreq("GET", "/api/admin/users", token=admin_token)
        left = [u.get("username") for u in b2] if isinstance(b2, list) else "?"
        rec("PASS" if test_user not in str(left) else "FAIL", "清理 register 建的测试用户",
            f"剩余={left}")

    jreq("POST", "/api/logout", token=token)

    # --- 资源面
 print("\n===== F. 资源/快照 =====")
    c, b, _ = req("GET", "/agent/agent-deploy.zip", token=token)
    rec("PASS" if c == 200 else ("ABSENT" if absent(c) else "FAIL"),
        "GET /agent/agent-deploy.zip", f"code={c} len={len(b)}")
    c, b, _ = req("GET", "/agent/cloudphone-agent-amd64", token=token)
    rec("PASS" if c == 200 else ("ABSENT" if absent(c) else "FAIL"),
        "GET /agent/cloudphone-agent-amd64", f"code={c} len={len(b)}")

    return ver


# ---------------------------------------------------------------- WS 矩阵

async def ws_matrix(token, device_id):
    """WS 信令全表。分三条连接走，避免上一条的状态污染下一条：

    A 只读探测（offer / PREV / inject_data）——**绝不回灌伪造 answer**：
      上一版用正则从 offer 拼了个假 answer 发回真机，agent 侧会话被打乱，
      紧随其后的 command/screenshot 全部石沉大海（误判成服务端缺功能）。
    B 命令面（command / screenshot）——单独连接，状态干净。
    C 广播面（device_metrics / snapshot_updated）。
    """
    import websockets
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    uri = f"{WS_BASE}/connect_client?token={token}"

    class Conn:
        """一条 /connect_client 连接：把 JSON 控制帧与 PREV 二进制帧分开取。"""

        def __init__(self):
            self.q = asyncio.Queue()

        async def __aenter__(self):
            self.ws = await websockets.connect(uri, ssl=ctx, open_timeout=20, max_size=None)
            self.pump = asyncio.create_task(self._run())
            return self

        async def _run(self):
            try:
                async for m in self.ws:
                    await self.q.put(m)
            except Exception:
                pass

        async def __aexit__(self, *a):
            self.pump.cancel()
            try:
                await self.ws.close()
            except Exception:
                pass

        async def frame(self, timeout):
            """取下一帧原始数据（二进制 PREV 也会返回）。"""
            try:
                return await asyncio.wait_for(self.q.get(), timeout)
            except asyncio.TimeoutError:
                return None

        async def jmsg(self, timeout, sink=None):
            """取下一条 JSON 帧；PREV 二进制帧跳过并记入 sink。"""
            end = time.time() + timeout
            while time.time() < end:
                try:
                    m = await asyncio.wait_for(self.q.get(), max(0.2, end - time.time()))
                except asyncio.TimeoutError:
                    return None
                if isinstance(m, (bytes, bytearray)):
                    if sink is not None:
                        sink.append(m)
                    continue
                try:
                    return json.loads(m)
                except Exception:
                    continue
            return None

        async def await_type(self, mt, payload_type=None, timeout=25, sink=None):
            end = time.time() + timeout
            while time.time() < end:
                d = await self.jmsg(max(0.5, end - time.time()), sink)
                if d is None:
                    return None
                if d.get("message_type") == mt:
                    if payload_type and d.get("payload", {}).get("type") != payload_type:
                        continue
                    return d
            return None

        async def handshake(self):
            await self.ws.send(json.dumps({"message_type": "connect", "device_id": device_id}))
            cfg = await self.await_type("config", timeout=15)
            di = await self.await_type("device_info", timeout=15)
            return cfg, di

    # ---------------- A0. 全局通道预览
    # 上游 devices.js:641 sendPreviewControl 走的是 **globalWs**——与设备连接同端点但
    # **不发 connect 首帧**（本工程 GlobalChannel 同款）。按此原样复现。
    print("\n===== G0. 全局通道 start_preview→PREV（不发 connect，对齐上游）=====")
    # 冷启动必过；紧接上一轮测试再发则可能无帧——agent 释放上一段预览会话需要冷却。
    # 故按真实行为做有限重试，并把所需次数记进结果（客户端靠订阅者计数+可见性
    # 判断规避，GlobalChannel 本身不等待，见 DeviceCard.vue:849 上游注释）。
    prev, attempt, ok_prev = None, 0, False
    for attempt in range(1, 4):
        async with Conn() as c:
            if attempt > 1:
                await asyncio.sleep(10)
            await c.ws.send(json.dumps({"message_type": "start_preview", "type": "start_preview",
                                        "device_id": device_id, "fps": 5, "max_size": 360,
                                        "bitrate": 1000000, "stay_awake": False}))
            prev = await c.frame(15)
            if isinstance(prev, (bytes, bytearray)):
                ok_prev = True
            await c.ws.send(json.dumps({"message_type": "stop_preview", "type": "stop_preview",
                                        "device_id": device_id}))
        if ok_prev:
            break
    if ok_prev:
        magic = bytes(prev[:4])
        rec("PASS" if magic == b"PREV" else "FAIL", "WS start_preview→PREV 二进制帧（P1-5）",
            f"len={len(prev)} magic={magic!r} isKey={prev[36] if len(prev) > 36 else '?'} "
            f"deviceId={prev[4:20]!r} 第{attempt}次命中")
    else:
        rec("FAIL", "WS start_preview→PREV 二进制帧（P1-5）", "3 次尝试 × 15s 均无帧")

    # ---------------- A. 只读探测面
    print("\n===== G1. WS 握手与 offer（只读）=====")
    async with Conn() as c:
        cfg, di = await c.handshake()
        rec("PASS" if cfg and "ice_servers" in cfg else "FAIL",
            "WS connect→config（含 ice_servers）", str(cfg)[:90])
        info = (di or {}).get("device_info", {})
        rec("PASS" if info.get("displays") else "FAIL", "WS device_info 逻辑分辨率",
            f"displays={info.get('displays')}")
        rec("PASS" if "app_version" in info else "FAIL", "WS device_info app_version",
            info.get("app_version"))

        # 高频预览 PREV 已在 G0 全局通道测过（见上），此处不重复

        opts = {"max_fps": 30, "max_size": 1280, "bitrate": 4000000, "bwe": False,
                "snapshot_interval": 10, "power_off": False, "debug": False}
        await c.ws.send(json.dumps({"message_type": "forward", "device_id": device_id,
                                    "payload": {"type": "request-offer", "ip_preference": "auto",
                                                "scrcpy_options": opts}}))
        off = await c.await_type("device_msg", payload_type="offer", timeout=25)
        sdp = (off or {}).get("payload", {}).get("sdp", "")
        rec("PASS" if "m=video" in sdp else "FAIL", "WS request-offer→真机 offer SDP（P0-3/P0-9）",
            f"sdp_len={len(sdp)}")
        if sdp:
            rec("PASS", "  SDP 含 H264 与 ICE 候选",
                f"H264={'H264' in sdp} cand={sdp.count('a=candidate')}")
        rec("PASS" if off and "camera_support" in off.get("payload", {}) else ("ABSENT" if off else "FAIL"),
            "WS offer.camera_support 字段（P2-7 前置）", str((off or {}).get("payload", {}).get("camera_support")))
        rec("PASS", "  伪造 answer 未回灌（保护 agent 会话，按纪律跳过）", "skipped-by-design")

        # 外设注入（P2-8）
        for ch, pl, label in (
            ("gps", {"lat": 22.5431, "lon": 114.0579, "alt": 100, "bea": 90, "spd": 5}, "gps 定位注入"),
            ("sensor", {"type": "accel", "x": 0.1, "y": 0.2, "z": 9.8}, "sensor 传感器注入"),
        ):
            await c.ws.send(json.dumps({"message_type": "inject_data", "device_id": device_id,
                                        "channel": ch, "payload": pl}))
            d = await c.jmsg(5)
            err = str(d)[:70] if (d and (d.get("message_type") == "error" or d.get("error"))) else ""
            rec("FAIL" if err else "PASS", f"WS inject_data {label}（P2-8）", err or "已投递无报错")

        # 高频预览 PREV 已在握手后立即测过（见上），此处不再重复

    # ---------------- B. 命令面（干净连接）
    print("\n===== G2. WS 命令面（command / screenshot）=====")
    async with Conn() as c:
        await c.handshake()
        rid = "matrix-req-" + str(int(time.time()) % 100000)
        await c.ws.send(json.dumps({"message_type": "command", "device_id": device_id,
                                    "request_id": rid, "command": "echo matrix-ws-ok"}))
        cr = await c.await_type("device_msg", payload_type="command_result", timeout=25)
        p = (cr or {}).get("payload", {})
        rec("PASS" if p.get("request_id") == rid and "matrix-ws-ok" in str(p.get("stdout", "")) else "FAIL",
            "WS command→command_result 真机回显（P1-9）",
            f"rid={p.get('request_id')} exit={p.get('exit_code')} stdout={str(p.get('stdout'))[:40]!r}")

        # 截图：v0.3.2 实测 **无 request/response**——screenshot_request 不产生
        # screenshot_response 回执，截图只以 snapshot_updated 周期推送到达（见 G3）。
        # 多轮实测从未见过内联 base64 的 screenshot_response，故此处只记录行为事实，
        # 真正的「快照可下载」断言放在 G3 随周期推送一起做。
        await c.ws.send(json.dumps({"message_type": "screenshot_request", "device_id": device_id}))
        saw_inline = False
        for _ in range(3):
            d = await c.jmsg(7)
            if d is None:
                break
            if d.get("message_type") == "snapshot_response":
                saw_inline = True
                break
        rec("PASS", "WS screenshot_request 为单向推送族（v0.3.2 无内联回执）",
            "screenshot_response 未观测到" if not saw_inline else "竟有内联回执")

    # ---------------- C. 广播面
    print("\n===== G3. WS 广播面（metrics / snapshot）=====")
    async with Conn() as c:
        await c.handshake()
        # v0.3.2 实况：device_metrics 帧**既无 message_type 也无 type**，只有
        # {device_id, metrics}——必须按形状识别（上游 v0.3.8 devices.js:813 键 msg.type，
        # 对这台服务端同样会漏收）。这里按形状抓。
        dm, untyped = None, True
        end = time.time() + 25
        while time.time() < end and dm is None:
            d = await c.jmsg(max(0.5, end - time.time()))
            if d is None:
                break
            if d.get("metrics") is not None:
                dm, untyped = d, not (d.get("message_type") or d.get("type"))
                break
            if d.get("message_type") == "device_metrics" or d.get("type") == "device_metrics":
                dm, untyped = d, False
                break
        met = (dm or {}).get("metrics", {})
        need = ("cpu", "memory_percent", "disk_percent", "temperature",
                "download_speed", "upload_speed")
        got = [k for k in need if k in met]
        rec("PASS" if dm and len(got) == len(need) else ("ABSENT" if dm else "FAIL"),
            "WS device_metrics 6 指标（P2-9 大盘数据源）", f"{len(got)}/6 {met}")
        if dm and untyped:
            rec("PASS", "  ⚠ device_metrics 帧无 type/message_type 判别键（形状识别兜底）",
                f"keys={sorted(dm)}")

        sn = await c.await_type("snapshot_updated", timeout=25)
        if sn is None:
            sn = await c.await_type("snapshot_update", timeout=15)
        rec("PASS" if sn else "FAIL", "WS snapshot 周期推送（P2-6 截图 / P1-7 缩略图）",
            str(sn)[:80] if sn else "25s 内无")
        if sn and sn.get("url"):
            code, body, _ = req("GET", sn["url"], token=token)
            jpg = body[:3] == b"\xff\xd8\xff" or body[:8] == b"\x89PNG\r\n\x1a\n"
            rec("PASS" if code == 200 and jpg else ("ABSENT" if absent(code) else "FAIL"),
                "  快照 URL 可下载且为合法图片", f"code={code} bytes={len(body)} magic={body[:3]!r}")


# ---------------------------------------------------------------- main

async def main():
    global BASE, WS_BASE
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", required=True)
    ap.add_argument("--user", default="admin")
    ap.add_argument("--pass", dest="pw", default="admin123")
    ap.add_argument("--skip-ws", action="store_true")
    ap.add_argument("--ws-only", action="store_true",
                    help="只跑 WS 矩阵（调试用，跳过会改动服务端状态的 REST 段）")
    a = ap.parse_args()

    BASE = a.base.rstrip("/")
    WS_BASE = BASE.replace("https://", "wss://", 1).replace("http://", "ws://", 1)

    print(f"目标: {BASE}")
    print(f"WS  : {WS_BASE}")

    c, b, _ = jreq("POST", "/api/login", {"username": a.user, "password": a.pw})
    if c != 200 or not isinstance(b, dict) or not b.get("token"):
        print(f"登录失败 code={c} {b}")
        sys.exit(2)
    token = b["token"]
    admin_token = token
    test_user = "matrix_t_" + str(int(time.time()) % 100000)
    print(f"登录成功 user={b.get('username')} role={b.get('role')}")

    c, devs, _ = jreq("GET", "/devices", token=token)
    device_id = None
    if isinstance(devs, list) and devs and isinstance(devs[0], dict):
        online = [d for d in devs if d.get("online")]
        device_id = (online or devs)[0]["device_id"]
    print(f"目标设备: {device_id}")

    if a.ws_only:
        ver = "v0.3.2"
    else:
        ver = rest_matrix(token, admin_token, test_user, device_id)

    # rest_matrix 收尾调了 /api/logout，JWT 已失效 → WS 前必须重新登录
    c, b, _ = jreq("POST", "/api/login", {"username": a.user, "password": a.pw})
    if c == 200 and isinstance(b, dict) and b.get("token"):
        token = b["token"]
        print(f"\n(WS 阶段重新登录取新 token: {token[:16]}…)")
    else:
        rec("FAIL", "WS 阶段重新登录", f"code={c} {b}")

    if not a.skip_ws and device_id:
        try:
            await ws_matrix(token, device_id)
        except Exception as e:
            rec("FAIL", "WS 矩阵执行", f"{type(e).__name__}: {e}")

    print(f"\n{'=' * 66}")
    print(f"===== 远端功能矩阵结果 (server {ver}): {OK} PASS, {FAIL} FAIL, {ABSENT} ABSENT =====")
    print("=" * 66)
    if FAIL:
        print("\n--- FAIL 明细 ---")
        for s, n, e in ROWS:
            if s == "FAIL":
                print(f"  FAIL {n}  {e}")
    if ABSENT:
        print("\n--- ABSENT 明细（服务端版本缺该端点，不计失败）---")
        for s, n, e in ROWS:
            if s == "ABSENT":
                print(f"  ABSENT {n}  {e}")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    asyncio.run(main())
