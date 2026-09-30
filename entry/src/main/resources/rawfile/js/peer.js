/**
 * peer.js —— RTCPeerConnection 生命周期与 ICE/SDP 处理（P0-8/P0-11）
 *
 * 职责（单一）：创建与配置媒体连接、绑定 ICE/track/连接态/反向通道回调、
 *              候选过滤（shouldKeepCandidate）、失败诊断（diagnose）、
 *              answer SDP 限速改写（mungeSdp）。
 * 依赖：session.js、state.js、signaling.js 的 sendFwd（运行时调用，加载顺序无关）。
 * 协议：（offer/answer/ice 转发）；上游对齐 useWebRTC.js:184-197/506-545/617-658。
 */
'use strict';

/**
 * 创建 RTCPeerConnection 并绑定全部回调（幂等：pc 已存在直接返回）。
 * - iceTransportPolicy：connectionPath=relay 时仅走中转（P0-8）
 * - onicecandidate：本地候选同样过 shouldKeepCandidate 后经信令 trickle
 * - ontrack：视频挂载 <video> 并启动统计 tick；音频挂载独立 <audio>
 * - onconnectionstatechange：connected/failed/disconnected 状态流转与失败诊断
 * - ondatachannel：接收被控端反向通道（input/clipboard）
 * - 主动创建 file-channel/adb-channel（被控端 agent 需要，P2 消费）
 */
function createPeer() {
  if (pc) return;
  pc = new RTCPeerConnection({
    iceServers: iceServers,
    iceTransportPolicy: icePrefs.connectionPath === 'relay' ? 'relay' : 'all'
  });

  pc.onicecandidate = function (ev) {
    if (ev.candidate) {
      localCands.push(ev.candidate.candidate);
      if (!shouldKeepCandidate(ev.candidate.candidate)) return;   // P0-8 本地候选过滤
      sendFwd({
        type: 'ice-candidate',
        candidate: {
          candidate: ev.candidate.candidate,
          sdpMLineIndex: ev.candidate.sdpMLineIndex,
          sdpMid: ev.candidate.sdpMid,
          mid: ev.candidate.sdpMid
        }
      });
    }
  };

  pc.ontrack = function (ev) {
    if (ev.track.kind === 'video') {
      video.srcObject = ev.streams[0] || new MediaStream([ev.track]);
      // 自动播放策略：muted 已设（声音走 audio 元素）；播放失败时用户手势重试
      var tryPlay = function () { video.play().catch(function () {}); };
      tryPlay();
      video.addEventListener('touchend', tryPlay, { once: true, passive: true });
      startTick();
    } else if (ev.track.kind === 'audio') {
      attachAudioTrack(ev.track);   // P1-1：挂载/解锁/静音能力全在 audio.js
    }
  };

  pc.onconnectionstatechange = function () {
    var st = pc.connectionState;
    if (st === 'connected') {
      retryCount = 0;
      reportState('connected', '连接媒体…');
    } else if (st === 'failed') {
      reportState('error', diagnose());    // P0-8：失败诊断（Clash TUN / Agent 外网地址）
      wantConnect = false;
    } else if (st === 'disconnected') {
      reportState('connecting', '媒体链路波动');
    } else if (st === 'connecting') {
      if (curState === 'waiting_offer' || curState === 'connecting_webrtc') {
        reportState('connecting_webrtc');
      }
    }
  };

  pc.ondatachannel = function (ev) {
    var ch = ev.channel;
    if (ch.label === 'input-channel') {
      inputChannel = ch;
    } else if (ch.label === 'clipboard-channel') {
      clipboardChannel = ch;
      attachClipboardChannel(ch);   // P1-2：收发与去重全部在 clipboard.js
    } else if (ch.label === 'camera-channel') {
      attachCameraChannel(ch);      // P2-7：agent 反向指令 + 采集推流在 camera.js
    }
  };

  pc.createDataChannel('file-channel', { ordered: true });
  pc.createDataChannel('adb-channel', { ordered: true });
}

/**
 * ICE 候选过滤（对齐上游 shouldKeepCandidate，useWebRTC.js:506-545）。
 * @param c candidate 字符串（形如 "candidate:… typ host …"）
 * @returns false = 按 icePrefs 丢弃（ipPreference: ipv4/ipv6；connectionPath: direct/relay）
 */
function shouldKeepCandidate(c) {
  if (icePrefs.ipPreference === 'auto' && icePrefs.connectionPath === 'auto') return true;
  var addr = (c.split(' ')[4]) || '';
  var isV6 = addr.indexOf(':') >= 0;
  var m = c.match(/ typ (\S+)/);
  var typ = m ? m[1] : '';
  if (icePrefs.ipPreference === 'ipv4' && isV6) return false;
  if (icePrefs.ipPreference === 'ipv6' && !isV6) return false;
  if (icePrefs.connectionPath === 'relay' && typ !== 'relay') return false;
  if (icePrefs.connectionPath === 'direct' && typ === 'relay') return false;
  return true;
}

/**
 * ICE/媒体失败诊断（对齐上游 useWebRTC.js:617-658 两类经典坑）：
 * 1) 本地候选出现 198.18.x → Clash/TUN 网段劫持；
 * 2) 远端候选全为内网/回环 → Agent 缺外网地址参数。
 * @returns 可直接展示给用户的中文原因（无匹配时给通用文案）
 */
function diagnose() {
  var clash = false, allInner = remoteCands.length > 0;
  for (var i = 0; i < remoteCands.length; i++) {
    var addr = (remoteCands[i].split(' ')[4]) || '';
    var inner = addr.indexOf('127.') === 0 || addr.indexOf('172.16.') === 0 ||
      (/^172\.(1[6-9]|2[0-9]|3[01])\./.test(addr)) || addr.indexOf('192.168.') === 0;
    if (!inner) allInner = false;
  }
  for (var j = 0; j < localCands.length; j++) {
    if (localCands[j].indexOf('198.18.') >= 0) clash = true;
  }
  if (clash) return '检测到 Clash/TUN 网段(198.18.x)——请关闭代理 TUN 或让服务器加入直连规则';
  if (allInner) return '远端候选均为内网地址——Agent 需配置 -external-addr / CP_AGENT_EXTERNAL_ADDR';
  return '网络无法穿透';
}

/**
 * P0-11 answer SDP 限速改写（对齐 web useWebRTC.js:184-197，纯函数）：
 * - 每个 c=IN IP4 行后注入 b=AS:20000（kbps 会话级带宽上限）
 * - H.264 fmtp（含 packetization-mode/profile-level-id）追加
 *   x-google-start-bitrate / x-google-max-bitrate = 20000000（bps）
 * @param sdp 原始 answer SDP
 * @returns 改写后的 SDP（rtx/apt 等非 H264 fmtp 不动）
 */
function mungeSdp(sdp) {
  var out = sdp.replace(/c=IN IP4[^\r\n]*\r\n/g, function (m) { return m + 'b=AS:20000\r\n'; });
  out = out.replace(/a=fmtp:\d+ [^\r\n]*/g, function (m) {
    if (m.indexOf('packetization-mode') >= 0 || m.indexOf('profile-level-id') >= 0) {
      return m + ';x-google-start-bitrate=20000;x-google-max-bitrate=20000';
    }
    return m;
  });
  return out;
}
