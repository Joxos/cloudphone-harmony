/**
 * fileboot.js —— 文件页引导（P2-1a：数据通道专用连接的极简信令与对等端）
 *
 * 职责（单一）：读桥参数 → WSS connect → request-offer → createPeer（仅 file-channel）
 *   → ICE/answer 转发 → 接线 attachFileChannel；断线 3s 退避重连（上限 10 次）。
 * 与 control/boot 的分工：control.html 承载媒体/输入/七通道；本页只建**一条
 *   本地 file-channel** 的纯数据连接（上游 FileManagerPage useWebRTC(audio:false,video:false)
 *   同构：agent 仍可能推视频轨，本页 createPeer 不挂 ontrack 即忽略——上游 ontrack 注释同语义）。
 * mungeSdp：与 peer.js P0-11 同源的复制（写入期为避免 file 页反向依赖控制页模块；
 *   后续如抽 shared SDP 工具应两处合一）。
 * ICE：本页接受全部候选（auto 语义；控制页的 ipPreference 过滤属用户设置面，文件页不做）。
 */
'use strict';

/** 桥参数缓存（nativeBridge 同名方法——FileCenterPage 代理提供） */
var fbServer = '';
var fbToken = '';
var fbDeviceId = '';
var fbUseSsl = '0';
var fbScrcpyOptions = '{}';
/** WS/PC 句柄与重连态 */
var fbWs = null;
var fbPc = null;
var fbIceServers = [];
var fbRetry = 0;
var fbRetryTimer = -1;
/** 连接意图（false=主动换设备/关闭，旧 onclose 不再重连） */
var fbWantRun = true;

/** 事件出口（状态条订阅） */
window.__fb = { onState: null }; // (text, ok)

function fbState(text, ok) {
  if (window.__fb.onState) window.__fb.onState(text, !!ok);
}

/**
 * P0-11 同源 SDP 改写（peer.mungeSdp 复制：c=IN IP4 后注入 b=AS:20000；
 * H264 fmtp 追加 x-google 起始/最大码率）。
 */
function fbMungeSdp(sdp) {
  var out = sdp.replace(/c=IN IP4[^\r\n]*\r\n/g, function (m) { return m + 'b=AS:20000\r\n'; });
  out = out.replace(/a=fmtp:\d+ [^\r\n]*/g, function (m) {
    if (m.indexOf('packetization-mode') >= 0 || m.indexOf('profile-level-id') >= 0) {
      return m + ';x-google-start-bitrate=20000;x-google-max-bitrate=20000';
    }
    return m;
  });
  return out;
}

/** 读桥参数（每阶段重读，登录态变更可感知） */
function fbReadBridge() {
  const b = window.nativeBridge;
  fbServer = b.getServerHost();
  fbToken = b.getToken();
  fbDeviceId = b.getDeviceId();
  fbUseSsl = b.getUseSslFlag();
  fbScrcpyOptions = b.getScrcpyOptions();
}

/** 建立信令（幂等；close/error 均走重连） */
function fbConnect() {
  fbReadBridge();
  if (fbServer.length === 0 || fbToken.length === 0 || fbDeviceId.length === 0) {
    fbState('缺少服务器/凭证/设备参数', false);
    return;
  }
  const scheme = fbUseSsl === '1' ? 'wss://' : 'ws://';
  const url = scheme + fbServer + '/connect_client?token=' + encodeURIComponent(fbToken);
  fbState('连接信令…', false);
  fbWantRun = true;
  const ws = new WebSocket(url);
  fbWs = ws;
  ws.onopen = function () {
    fbRetry = 0;
    ws.send(JSON.stringify({ message_type: 'connect', device_id: fbDeviceId }));
  };
  ws.onmessage = function (ev) {
    let msg;
    try {
      msg = JSON.parse(ev.data);
    } catch (e) {
      return;
    }
    const t = msg.message_type || msg.type;
    if (t === 'config') {
      fbIceServers = msg.ice_servers || [];
      fbRequestOffer();
      fbState('协商中…', false);
    } else if (t === 'device_msg') {
      fbHandleFwd(msg.payload);
    } else if (t === 'offer' || t === 'answer' || t === 'ice-candidate') {
      fbHandleFwd(msg);
    } else if (t === 'error') {
      fbState('信令错误: ' + (msg.error || ''), false);
    }
  };
  ws.onclose = function () {
    fbTeardownPc();
    if (fbWs !== ws) {
      return; // 旧连接（设备切换已换新 ws），不再重连
    }
    if (fbWantRun && fbRetry < 10) {
      fbRetry++;
      fbState('信令断开，' + (3 * fbRetry) + 's 后重连…', false);
      fbRetryTimer = setTimeout(fbConnect, 3000 * fbRetry);
    } else if (fbWantRun) {
      fbState('信令重连次数用尽', false);
    }
  };
  ws.onerror = function () {
    // 由 close 统一处理
  };
}

/** 下行 forward 载荷处理（offer→answer；ice→直加） */
function fbHandleFwd(p) {
  if (!p) return;
  if (p.type === 'offer') {
    fbCreatePeer();
    fbPc.setRemoteDescription({ type: 'offer', sdp: p.sdp })
      .then(function () { return fbPc.createAnswer(); })
      .then(function (a) {
        fbPc.setLocalDescription(a);
        fbSendFwd({ type: 'answer', sdp: fbMungeSdp(a.sdp) });
        fbState('连接设备…', false);
      })
      .catch(function (e) {
        fbState('SDP 失败: ' + e.message, false);
      });
  } else if (p.type === 'ice-candidate' && p.candidate && p.candidate.candidate) {
    fbPc.addIceCandidate(p.candidate).catch(function () {});
  }
}

/** request-offer（scrcpy_options 与控制页同源注入；本页不消费媒体） */
function fbRequestOffer() {
  fbSendFwd({
    type: 'request-offer',
    ip_preference: 'auto',
    connection_path: 'auto',
    scrcpy_options: JSON.parse(fbScrcpyOptions || '{}')
  });
}

function fbSendFwd(payload) {
  if (fbWs && fbWs.readyState === 1) {
    fbWs.send(JSON.stringify({ message_type: 'forward', payload: payload }));
  }
}

/** 对等端：仅一条本地 file-channel（不挂 ontrack——纯数据连接） */
function fbCreatePeer() {
  if (fbPc) {
    try { fbPc.close(); } catch (e) { /* 忽略 */ }
  }
  const pc = new RTCPeerConnection({ iceServers: fbIceServers });
  fbPc = pc;
  const dc = pc.createDataChannel('file-channel', { ordered: true });
  attachFileChannel(dc); // fileproto.js：open/message/onState 自接线
  pc.onicecandidate = function (ev) {
    if (ev.candidate) {
      fbSendFwd({
        type: 'ice-candidate',
        candidate: {
          candidate: ev.candidate.candidate,
          sdpMid: ev.candidate.sdpMid,
          sdpMLineIndex: ev.candidate.sdpMLineIndex
        }
      });
    }
  };
  pc.onconnectionstatechange = function () {
    const s = pc.connectionState;
    if (s === 'connected') {
      fbState('通道连接中…', true);
    } else if (s === 'failed' || s === 'disconnected') {
      fbState('P2P ' + s, false);
    }
  };
}

function fbTeardownPc() {
  if (fbPc) {
    try { fbPc.close(); } catch (e) { /* 忽略 */ }
    fbPc = null;
  }
}

/** 页入口（file.html 内联 boot 调用） */
function fbStart() {
  window.__fp.onState = function (ready) {
    fbState(ready ? '文件通道就绪' : '文件通道断开', ready);
  };
  fbConnect();
}

/** 设备切换（FileCenterPage 选择器经 runJavaScript 调用；换设备即重建连接） */
window.__fbRestart = function (deviceId) {
  fbDeviceId = String(deviceId || '');
  fbRetry = 0;
  fbWantRun = false; // 拦断旧 ws 的 onclose 重连
  if (fbRetryTimer !== -1) {
    clearTimeout(fbRetryTimer);
    fbRetryTimer = -1;
  }
  fbTeardownPc();
  if (fbWs) {
    try {
      fbWs.close();
    } catch (e) {
      // 忽略
    }
    fbWs = null;
  }
  fbConnect(); // 内部恢复 fbWantRun = true
};
