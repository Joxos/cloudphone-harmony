/**
 * stats.js —— 媒体统计采集与徽标明细（P0-4）
 *
 * 职责（单一）：每秒采集 pc.getStats()，解析为徽标可读的
 *              分辨率/fps/码率/RTT/传输路径/丢包明细并刷新状态展示。
 * 依赖：session.js（video/pc/curState）、state.js（reportState）。
 * 说明：ArkWeb（API20+ 对齐 Chromium）getStats() 为 Promise 形式。
 */
'use strict';

/** 码率计算基线：上一周期累计字节 / 时间戳（kbps 由此增量得出） */
var lastBytes = 0, lastStatsTs = 0, bitrateKbps = 0;

/** 统计基线复位（resetPeer/断线时调用，避免跨连接增量错算） */
function statsReset() {
  lastBytes = 0; lastStatsTs = 0; bitrateKbps = 0;
}

/**
 * 解析 RTCStatsReport → 徽标明细（纯函数，除 video 尺寸外无副作用，便于单测）。
 * @param report RTCStatsReport（以可 forEach 的形式传入）
 * @param prev 上一周期基线 { lastBytes, lastTs }
 * @returns fps/lost/kbps/rttMs/path/w/h 及新基线 lastBytes/lastTs
 */
function parseStats(report, prev) {
  var byId = {};
  var inbound = null, pair = null, localCand = null, remoteCand = null;
  report.forEach(function (s) {
    byId[s.id] = s;
    if (s.type === 'inbound-rtp' && (s.kind === 'video' || s.mediaType === 'video')) inbound = s;
    if (s.type === 'candidate-pair' && s.state === 'succeeded' && (s.nominated || s.selected)) pair = s;
  });
  if (pair) {
    localCand = byId[pair.localCandidateId];
    remoteCand = byId[pair.remoteCandidateId];
  }
  var now = Date.now();
  var bytes = inbound ? (inbound.bytesReceived || 0) : 0;
  var kbps = 0;
  if (prev.lastTs > 0 && now > prev.lastTs && bytes >= prev.lastBytes) {
    kbps = Math.round((bytes - prev.lastBytes) * 8 / (now - prev.lastTs)); // kbps
  }
  var rttMs = pair && pair.currentRoundTripTime !== undefined
    ? Math.round(pair.currentRoundTripTime * 1000) : -1;
  var proto = localCand && localCand.protocol ? localCand.protocol.toLowerCase() : '';
  var isRelay = (localCand && localCand.candidateType === 'relay') ||
                (remoteCand && remoteCand.candidateType === 'relay');
  var path = isRelay ? ((proto ? proto.toUpperCase() + ' ' : '') + 'relay')
                     : (proto === 'udp' ? 'UDP P2P' : (proto ? proto.toUpperCase() : ''));
  return {
    fps: inbound && inbound.framesPerSecond ? Math.round(inbound.framesPerSecond) : 0,
    lost: inbound ? (inbound.packetsLost || 0) : 0,
    kbps: kbps,
    rttMs: rttMs,
    path: path,
    w: video.videoWidth, h: video.videoHeight,
    lastBytes: bytes, lastTs: now
  };
}

/**
 * 启动 1s 统计 tick（ontrack 后调用一次；window.__tickTimer 防重入）。
 * 仅在 connected/connecting_webrtc 态采集，connected 态刷新徽标明细。
 */
function startTick() {
  if (window.__tickTimer) return;
  window.__tickTimer = setInterval(function () {
    if (!pc) return;
    if (curState === 'connected' || curState === 'connecting_webrtc') {
      pc.getStats().then(function (report) {
        var r = parseStats(report, { lastBytes: lastBytes, lastTs: lastStatsTs });
        lastBytes = r.lastBytes; lastStatsTs = r.lastTs;
        var detail = [];
        if (r.w > 0) detail.push(r.w + 'x' + r.h);
        if (r.fps > 0) detail.push(r.fps + 'fps');
        if (r.kbps > 0) detail.push((r.kbps / 1000).toFixed(1) + 'Mbps');
        if (r.rttMs >= 0) detail.push('rtt ' + r.rttMs + 'ms');
        if (r.path) detail.push(r.path);
        if (r.lost > 0) detail.push('lost ' + r.lost);
        if (curState === 'connected') {
          reportState('connected', detail.join(' | '));
        }
      }).catch(function () {});
    }
  }, 1000);
}

/**
 * P2-3：单次快照（get_webrtc_stats 工具用）——双采样（间隔350ms）算 kbps 增量，
 * 其余字段取末次解析。pc 未连接 reject。
 * @returns Promise<{fps,lost,kbps,rttMs,path,w,h}>
 */
function statsOnce() {
  if (!pc) {
    return Promise.reject(new Error('WebRTC 未连接'));
  }
  var base = { lastBytes: 0, lastTs: 0 };
  return pc.getStats().then(function (report) {
    var first = parseStats(report, { lastBytes: 0, lastTs: 0 });
    base = { lastBytes: first.lastBytes, lastTs: first.lastTs };
    return new Promise(function (resolve) {
      setTimeout(function () { resolve(); }, 350);
    }).then(function () {
      return pc.getStats().then(function (report2) {
        var r = parseStats(report2, base);
        return { fps: r.fps, lost: r.lost, kbps: r.kbps, rttMs: r.rttMs, path: r.path, w: r.w, h: r.h };
      });
    });
  });
}
