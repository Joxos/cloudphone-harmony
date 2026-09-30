#!/usr/bin/env python3
"""mock_signaling_server 的协议回放自测：REST 四连 + WS 信令状态机全序列。"""
import asyncio
import json
import sys
import urllib.request

BASE = "http://127.0.0.1:18080"
OK = 0
FAIL = 0


def check(name, cond, extra=""):
    global OK, FAIL
    mark = "PASS" if cond else "FAIL"
    if cond:
        OK += 1
    else:
        FAIL += 1
    print(f"[{mark}] {name} {extra}")


def rest(method, path, payload=None, token=None):
    req = urllib.request.Request(BASE + path, method=method)
    if payload is not None:
        data = json.dumps(payload).encode()
        req.add_header("Content-Type", "application/json")
    else:
        data = None
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, data=data, timeout=5) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raw = e.read().decode() or ""
        try:
            return e.code, json.loads(raw)
        except json.JSONDecodeError:
            # 真实服务器 /devices 401 为纯文本（保真 mock），错误体不一定是 JSON
            return e.code, {"raw": raw}


async def ws_test(token):
    import websockets
    uri = f"ws://127.0.0.1:18080/connect_client?token={token}"
    async with websockets.connect(uri, open_timeout=5) as ws:
        # 1. 首帧 connect
        await ws.send(json.dumps({"message_type": "connect", "device_id": "mock-1"}))
        # 2. 应收到 config
        cfg = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("WS 收到 config", cfg.get("message_type") == "config", str(cfg)[:80])
        # 3. 应收到 device_info
        di = json.loads(await asyncio.wait_for(ws.recv(), 5))
        check("WS 收到 device_info", di.get("message_type") == "device_info"
              and di["device_info"]["displays"][0]["x_res"] == 1080, str(di)[:80])
        # 4. request-offer（带 scrcpy_options）
        await ws.send(json.dumps({"message_type": "forward", "device_id": "mock-1", "payload": {
            "type": "request-offer", "ip_preference": "auto",
            "scrcpy_options": {"max_fps": 30, "max_size": 2160, "bitrate": 12000000, "audio": True}}}))
        offer = json.loads(await asyncio.wait_for(ws.recv(), 5))
        ok = (offer.get("message_type") == "device_msg"
              and offer["payload"].get("type") == "offer"
              and "fingerprint" in offer["payload"].get("sdp", ""))
        check("WS 收到 offer(假SDP)", ok, str(offer)[:60])
        # 5. 回 answer
        await ws.send(json.dumps({"message_type": "forward", "payload": {"type": "answer", "sdp": "v=0\r\n"}}))
        # 6. 回 ICE
        await ws.send(json.dumps({"message_type": "forward", "payload": {"type": "ice-candidate",
            "candidate": {"candidate": "candidate:0 1 udp 1 127.0.0.1 50000 typ host", "sdpMid": "0", "sdpMLineIndex": 0}}}))
        # 7. command → command_result
        await ws.send(json.dumps({"message_type": "command", "device_id": "mock-1",
                                  "request_id": "1730000000000", "command": "input keyevent 4"}))
        resp = json.loads(await asyncio.wait_for(ws.recv(), 5))
        ok = (resp.get("message_type") == "device_msg"
              and resp["payload"].get("type") == "command_result"
              and resp["payload"].get("request_id") == "1730000000000"
              and resp["payload"].get("exit_code") == 0)
        check("WS 收到 command_result", ok, str(resp)[:80])
        # 8. P2-6: screenshot_request → screenshot_response(base64 PNG)
        await ws.send(json.dumps({"message_type": "screenshot_request", "device_id": "mock-1"}))
        shot = json.loads(await asyncio.wait_for(ws.recv(), 5))
        ok = (shot.get("message_type") == "screenshot_response"
              and str(shot.get("data", "")).startswith("iVBOR"))
        check("WS 收到 screenshot_response(base64)", ok, str(shot)[:70])


async def main():
    # REST 序列
    c, body = rest("GET", "/api/auth-status")
    check("auth-status", c == 200 and body.get("noAuth") is False, str(body))
    c, body = rest("GET", "/api/version")
    check("version", c == 200 and "mock" in body.get("version", ""), str(body))
    c, body = rest("GET", "/devices")
    check("未登录 401", c == 401, str(body))
    c, body = rest("POST", "/api/login", {"username": "tester", "password": "x"})
    token = body.get("token", "")
    check("login 拿 token", c == 200 and token.startswith("mock-token"), token[:40])
    c, body = rest("GET", "/devices", token=token)
    check("devices 含 mock-1(在线)", c == 200 and body["devices"][0]["online"] is True, str(body)[:100])
    c, body = rest("GET", "/devices", token=token)
    check("devices mock-2 离线", c == 200 and body["devices"][1]["online"] is False, "")
    c, body = rest("GET", "/api/me", token=token)
    check("me", c == 200 and body.get("role") == "admin", str(body)[:80])
    c, body = rest("POST", "/api/register", {"username": "newbie", "password": "y"})
    check("register", c == 200, str(body))
    c, body = rest("GET", "/api/ice_servers", token=token)
    check("ice_servers", c == 200, str(body))
    # P1-3：全局默认画质 保存→回读 环（POST /api/default_settings 需 Bearer）
    c2, b2 = rest("POST", "/api/default_settings", {"settings": {"fps": 60, "bitrate": 8}}, token)
    check("default_settings 保存", c2 == 200, str(b2))
    c3, b3 = rest("GET", "/api/default_settings", token=token)
    check("default_settings 回读", c3 == 200 and b3.get("settings", {}).get("fps") == 60, str(b3))
    # P2-10: 标签 requireAdmin 收口（tester→403）+ 管理员保存→回读环
    c4, b4 = rest("GET", "/api/tags", token=token)
    check("tags 非管理员 403", c4 == 403, str(b4))
    c_admin, b_admin = rest("POST", "/api/login", {"username": "admin", "password": "z"})
    admin_token = b_admin.get("token", "")
    tag_payload = {"tags": [{"id": "tag_t1", "name": "机房", "color": "#38bdf8"}],
                   "deviceTags": {"mock-1": ["tag_t1"]}}
    c5, b5 = rest("POST", "/api/tags", tag_payload, admin_token)
    check("tags 管理员保存", c5 == 200, str(b5))
    c6, b6 = rest("GET", "/api/tags", token=admin_token)
    ok6 = (c6 == 200 and len(b6.get("tags", [])) == 1 and b6["tags"][0].get("name") == "机房"
           and b6.get("deviceTags", {}).get("mock-1") == ["tag_t1"])
    check("tags 保存→回读", ok6, str(b6)[:90])
    # P2-12: 快捷指令整表（数组体）保存→回读
    shortcut_list = [{"name": "测试指令", "cmd": "ls -l"}]
    c7, b7 = rest("POST", "/api/shortcuts", shortcut_list, token)
    check("shortcuts 保存", c7 == 200, str(b7))
    c8, b8 = rest("GET", "/api/shortcuts", token=token)
    check("shortcuts 回读", c8 == 200 and isinstance(b8, list) and len(b8) == 1 and b8[0]["name"] == "测试指令",
          str(b8)[:80])
    # P2-4: 分享全链路（create→list→extend→redeem免登录→revoke→list清空）
    sc1, sb1 = rest("POST", "/api/share/create", {
        "device_id": "mock-1", "expire_seconds": 86400, "access_mode": "view",
        "password": "", "description": "测试"}, token)
    st_id = sb1.get("data", {}).get("token_id", "") if isinstance(sb1, dict) else ""
    check("share 创建", sc1 == 200 and sb1.get("code") == 0 and st_id.startswith("st_"), str(sb1)[:90])
    sc2, sb2 = rest("GET", "/api/share/list", token=token)
    check("share 列表", sc2 == 200 and sb2.get("code") == 0 and len(sb2.get("data", [])) == 1,
          str(sb2)[:90])
    sc3, sb3 = rest("POST", "/api/share/extend", {"token": st_id, "extend_seconds": 86400}, token)
    check("share 延时", sc3 == 200 and sb3.get("code") == 0, str(sb3)[:80])
    sc4, sb4 = rest("POST", "/api/share/redeem_card", {"card_code": "ABC123", "password": ""})
    check("share 卡密兑换(免登录)", sc4 == 200 and sb4.get("code") == 0
          and str(sb4.get("data", {}).get("token", "")).startswith("st_"), str(sb4)[:80])
    # P2-4b: 访客设置更新 + 链接地址列表
    scU, sbU = rest("POST", "/api/share/update", {
        "token": st_id, "forbid_bitrate": True, "forbid_fps": False,
        "forbid_resolution": False, "forbid_audio": True, "guest_settings": None}, token)
    check("share 访客设置更新", scU == 200 and sbU.get("code") == 0, str(sbU)[:80])
    scA, sbA = rest("GET", "/api/server/addresses", token=token)
    check("server/addresses", scA == 200 and sbA.get("code") == 0
          and len(sbA.get("data", {}).get("addresses", [])) > 0, str(sbA)[:80])
    sc5, sb5 = rest("POST", "/api/share/revoke", {"token": st_id}, token)
    sc6, sb6 = rest("GET", "/api/share/list", token=token)
    check("share 撤销→列表清空", sc5 == 200 and sb5.get("code") == 0
          and sc6 == 200 and len(sb6.get("data", [])) == 0, str(sb6)[:80])
    # P2-5: 群控任务（admin 收口 create → details 直形状回读）
    tc1, tb1 = rest("POST", "/api/tasks",
                    {"type": "shell", "targets": ["mock-1"], "payload": "input keyevent 3"}, admin_token)
    tid = tb1.get("task_id", "") if isinstance(tb1, dict) else ""
    check("task 下发", tc1 == 200 and tb1.get("status") == "success" and tid.startswith("task_"),
          str(tb1)[:90])
    tc2, tb2 = rest("GET", f"/api/tasks/details?task_id={tid}", token=admin_token)
    sub = tb2.get("devices", {}).get("mock-1", {}) if isinstance(tb2, dict) else {}
    check("task 详情(直形状)", tc2 == 200 and sub.get("status") == "success"
          and "keyevent" in str(sub.get("output", "")), str(tb2)[:90])
    # P2-5b: 文件任务基建（/upload 原始体 → 签名 URL）
    req_u = urllib.request.Request(
        "http://127.0.0.1:18080/upload?name=demo_task.apk", method="POST",
        data=b"\x50\x4b\x03\x04-bytes-",
        headers={"Content-Type": "application/octet-stream", "Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req_u) as resp:
            uc, ub = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        uc, ub = e.code, e.read()
    check("upload 原始体", uc == 200, ub[:60].decode("utf-8", "replace"))
    cu, bu = rest("GET", "/api/files/url?name=demo_task.apk", token=token)
    check("files/url 签名", cu == 200 and str(bu.get("url", "")).startswith("/downloads/demo_task.apk"),
          str(bu)[:90])
    # P2-3b: AI 配置云同步（四键 Bearer POST）
    ca, ba = rest("POST", "/api/user/ai-config", {
        "ai_api_url": "https://x/v1", "ai_api_key": "k", "ai_model": "m",
        "ai_provider": "openai"}, token)
    check("ai-config 云同步", ca == 200 and ba.get("message") == "ok", str(ba)[:80])
    # WS 序列
    await ws_test(token)
    print(f"\n===== 结果: {OK} passed, {FAIL} failed =====")
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    asyncio.run(main())
