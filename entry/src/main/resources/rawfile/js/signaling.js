/**
 * signaling.js —— WSS 信令协议（连接生命周期与消息分发）
 *
 * 职责（单一）：信令 WebSocket 的建立/关闭/退避重连、首帧 connect、
 *              服务端消息分发（config/device_info/device_msg/error）、
 *              forward 转发（offer/answer/ice）与 command 兜底、
 *              request-offer（携带 scrcpy_options）、start() 载入键位映射 profile（P1-8）。
 * 依赖：session.js、state.js（reportState/resetPeer）、peer.js（createPeer/mungeSdp/
 *       shouldKeepCandidate）、stats.js（经 resetPeer）。
 * 协议为信令消息全表；B-3=ws/wss 跟随 use_ssl。
 */
'use strict';

/**
 * 建立信令连接（页面入口；重连定时器也会回调本函数）。
 * 流程：读桥参数 → 校验 → 复位资源 → 拼 URL（share_token 优先于 token）
 *      → new WebSocket（原生桥）→ open 发 connect → message 分发 → close 触发重连。
 */
function start() {
  wantConnect = true;
  var host = native('getServerHost', '');
  var token = native('getToken', '');
  var devId = native('getDeviceId', '');
  var useSsl = native('getUseSslFlag', '1') !== '0';
  if (!host) { reportState('error', '未配置被控端地址'); return; }
  if (!devId) { reportState('error', '未指定设备（请从设备列表进入）'); return; }
  curDevId = devId;
  shareToken = native('getShareToken', '');
  sharePwd = native('getSharePwd', '');
  viewOnly = native('getViewOnly', '0') === '1';
  // P1-10：读取群控从机组（ArkWebView 进页时 bindMaster 写入；空组=不广播）
  const gs = native('getGroupSlaves', '[]');
  try {
    const arr = JSON.parse(gs);
    groupSlaves = Array.isArray(arr) ? arr : [];
  } catch (e) {
    groupSlaves = [];
  }
  // P1-8：载入键位映射 profile（桥读 Prefs cloudphone_keymap；空=引擎不消费）
  keymapLoadProfiles(native('getKeymapProfiles', ''));
  localCands = []; remoteCands = [];
  resetPeer();
  // P0-12：分享访客走 ?share_token[&share_pwd]，正常登录走 ?token
  var qs = shareToken
    ? ('?share_token=' + encodeURIComponent(shareToken) + (sharePwd ? '&share_pwd=' + encodeURIComponent(sharePwd) : ''))
    : (token ? '?token=' + encodeURIComponent(token) : '');
  var wsUrl = (useSsl ? 'wss://' : 'ws://') + host + '/connect_client' + qs;
  reportState('connecting', host);
  try {
    ws = new WebSocket(wsUrl); // 走网络桥（原生 webSocket 模块，skipServerCertVerification）
  } catch (e) {
    scheduleRetry('信令创建失败');
    return;
  }
  ws.onopen = function () {
    retryCount = 0;
    reportState('signaling');
    ws.send(JSON.stringify({ message_type: 'connect', device_id: devId }));
  };
  ws.onmessage = function (ev) {
    try { handleMsg(JSON.parse(ev.data)); } catch (e) { /* 忽略非 JSON */ }
  };
  ws.onclose = function () {
    if (curState === 'error') return;
    if (wantConnect) scheduleRetry('信令断开');
    else reportState('disconnected');
  };
  ws.onerror = function () { /* onclose 统一处理 */ };
}

/**
 * 异常断开后的退避重连（P0-3）：复位资源 → 指数退避（3s×n，上限 15s）
 * 超过 MAX_RETRY 进入 error 终态。
 * @param reason 触发原因（进入状态文案）
 */
function scheduleRetry(reason) {
  resetPeer();
  if (retryCount >= MAX_RETRY) {
    reportState('error', reason + '（重连 ' + MAX_RETRY + ' 次失败）');
    wantConnect = false;
    return;
  }
  retryCount++;
  var delay = Math.min(3000 * retryCount, 15000);
  reportState('connecting', reason + '，' + (delay / 1000) + 's 后重连(' + retryCount + '/' + MAX_RETRY + ')');
  if (retryTimer) clearTimeout(retryTimer);
  retryTimer = setTimeout(function () {
    if (wantConnect) start();
  }, delay);
}

/**
 * 服务端下行消息分发（S→C 全表）：
 * config→建 Peer+request-offer；device_info→设备分辨率；
 * device_msg/裸 offer/answer/ice→handleFwd；error→状态机终态。
 */
function handleMsg(msg) {
  var type = msg.message_type || msg.type;
  if (type === 'config') {
    if (msg.ice_servers && msg.ice_servers.length > 0) iceServers = msg.ice_servers;
    createPeer();
    requestOffer();
    reportState('waiting_offer');
  } else if (type === 'device_info') {
    var d = msg.device_info && msg.device_info.displays && msg.device_info.displays[0];
    if (d) { deviceW = d.x_res || 1080; deviceH = d.y_res || 1920; }
  } else if (type === 'device_msg') {
    handleFwd(msg.payload);
  } else if (type === 'error') {
    reportState('error', '服务器: ' + (msg.error || '未知'));
  } else if (type === 'offer' || type === 'answer' || type === 'ice-candidate') {
    handleFwd(msg);
  } else if (type === 'screenshot_response') {
    if (window.__onScreenshot) window.__onScreenshot(msg.data); // P2-6：截图归一展示
  }
}

/**
 * forward 载荷处理（offer/answer/ice/scrcpy_error）：
 * offer → setRemote/createAnswer/mungeSdp 后回 answer；
 * ice → 收集样本 + 过滤 + addIceCandidate；
 * scrcpy_error → 状态机终态（停止重连）。
 */
function handleFwd(p) {
  if (!p) return;
  if (p.type === 'offer') {
    reportState('connecting_webrtc');
    setCameraSupport(p.camera_support !== false);   // P2-7：摄像头注入支持位（offer 载荷）
    pc.setRemoteDescription({ type: 'offer', sdp: p.sdp })
      .then(function () { return pc.createAnswer(); })
      .then(function (a) {
        pc.setLocalDescription(a);
        sendFwd({ type: 'answer', sdp: mungeSdp(a.sdp) });   // P0-11 SDP munging
      })
      .catch(function (e) { reportState('error', 'SDP: ' + e.message); });
  } else if (p.type === 'ice-candidate' && p.candidate && p.candidate.candidate) {
    remoteCands.push(p.candidate.candidate);
    if (!shouldKeepCandidate(p.candidate.candidate)) return;   // P0-8 远端候选过滤
    pc.addIceCandidate(p.candidate).catch(function () {});
  } else if (p.type === 'scrcpy_error') {
    reportState('error', p.message || 'scrcpy 启动失败');
    wantConnect = false;
  } else if (p.type === 'command_result') {
    // P2-3：命中等待器则解析（AI 工具链）；无等待器的旧路径忽略
    const w = cmdWaiters[p.request_id];
    if (w) {
      clearTimeout(w.timer);
      delete cmdWaiters[p.request_id];
      w.resolve({
        exit_code: p.exit_code !== undefined ? p.exit_code : 0,
        stdout: p.stdout || '',
        stderr: p.stderr || ''
      });
    }
  }
}

/**
 * 发送 forward 类消息（answer/ice-candidate）；信令未就绪静默丢弃。
 * @param payload 内层载荷
 */
function sendFwd(payload) {
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify({ message_type: 'forward', payload: payload }));
  }
}

/**
 * P0-6 兜底：DataChannel 不可用时经信令 command 执行 shell。
 * @param cmd shell 命令（如 "input keyevent 19"）
 * @returns true=已发送
 */
function sendCommand(cmd) {
  if (ws && ws.readyState === 1) {
    ws.send(JSON.stringify({
      message_type: 'command', device_id: curDevId,
      request_id: String(Date.now()), command: cmd
    }));
    return true;
  }
  return false;
}

/** P2-3：command_result 等待器：request_id → {resolve, timer}（AI 工具取回执行结果） */
var cmdWaiters = {};

/**
 * 发送 command 并等待回执（AI execute_shell_command 工具用）。
 * @param cmd shell 命令原文
 * @param timeoutMs 超时（默认 15s；超时返回 exit_code=-1）
 * @returns Promise<{exit_code,stdout,stderr}>
 */
function sendCommandWait(cmd, timeoutMs) {
  const rid = 'cr_' + Date.now() + '_' + Math.floor(Math.random() * 10000);
  if (!ws || ws.readyState !== 1) {
    return Promise.resolve({ exit_code: -1, stdout: '', stderr: '信令未连接' });
  }
  ws.send(JSON.stringify({
    message_type: 'command', device_id: curDevId,
    request_id: rid, command: cmd
  }));
  return new Promise(function (resolve) {
    const timer = setTimeout(function () {
      delete cmdWaiters[rid];
      resolve({ exit_code: -1, stdout: '', stderr: '执行超时(15s)' });
    }, timeoutMs || 15000);
    cmdWaiters[rid] = { resolve: resolve, timer: timer };
  });
}

/**
 * 请求 offer（P0-9）：优先消费 ETS 注入的 scrcpy_options（设置页），
 * 解析失败/缺失时回退页面默认值；ip_preference 暂固定 auto（P1 设置页接入）。
 */
function requestOffer() {
  var opts = null;
  var raw = native('getScrcpyOptions', '');
  if (raw) {
    try { opts = JSON.parse(raw); } catch (e) { opts = null; }
  }
  if (!opts) {
    opts = {
      max_fps: 30, max_size: 2160,
      bitrate: 12000000, min_bitrate: 8000000, max_bitrate: 20000000,
      bwe: false, audio: true, audio_gain: 1,
      audio_source: 'output', audio_dup: true, audio_low_latency: false,
      video_codec_options: 'intra-refresh-period=30,i-frame-interval=2,vendor.rtc-ext-enc-low-latency=1'
    };
  }
  sendFwd({
    type: 'request-offer',
    ip_preference: 'auto',
    scrcpy_options: opts
  });
}
