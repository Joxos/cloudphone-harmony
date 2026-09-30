/**
 * state.js —— 连接七态状态机（P0-3）
 *
 * 职责（单一）：状态定义/流转输出、页面徽标展示、经 onState 上报 ETS、
 *              断线重连意图与会话资源复位（resetPeer）。
 * 状态集（对齐  ConnectionStatus）：
 *   disconnected → connecting → signaling → waiting_offer → connecting_webrtc → connected
 *   任意态 → error（终态，覆盖层出现重试/退出）
 * 依赖：session.js（DOM 引用与会话变量）；消费方：signaling/peer/stats。
 */
'use strict';

/** 七态 → 展示文案（徽标与页面状态条共用） */
var STATE_TEXT = {
  disconnected: '未连接',
  connecting: '连接中',
  signaling: '信令已连接',
  waiting_offer: '等待视频流',
  connecting_webrtc: '建立媒体通道',
  connected: '已连接',
  error: '连接错误'
};
/** 当前状态（peer.js/stats.js 读取用于分支） */
var curState = 'disconnected';
/** 用户连接意图：true=保持连接（异常断开自动重连）；error 终态/主动断开置 false */
var wantConnect = false;
/** 连续重连次数（成功 open 后清零） */
var retryCount = 0;
/** 重连退避定时器句柄 */
var retryTimer = null;
/** 最大重连次数（超过进入 error 终态） */
var MAX_RETRY = 5;

/**
 * 状态迁移唯一入口：更新内部状态 + 页面状态条 + 上报 ETS ConnectionStatusBadge。
 * @param state 七态之一（STATE_TEXT 的键）
 * @param detail 明细（主机名/错误原因/统计摘要），拼接为 "状态 · 明细"
 */
function reportState(state, detail) {
  curState = state;
  var text = STATE_TEXT[state] + (detail ? ' · ' + detail : '');
  statusEl.textContent = text;
  statusEl.className = (state === 'error' || state === 'disconnected') ? 'err' : '';
  hintEl.style.display = 'none';
  try {
    if (window.nativeBridge && typeof window.nativeBridge.onState === 'function') {
      window.nativeBridge.onState(state, text);
    }
  } catch (e) {}
}

/**
 * 复位媒体与通道资源（重连/重试前调用，防止旧 PC 泄漏）：
 * 关闭 RTCPeerConnection、清空 DataChannel 引用与视频流、停统计 tick。
 */
function resetPeer() {
  if (pc) { try { pc.close(); } catch (e) {} pc = null; }
  inputChannel = null;
  clipboardChannel = null;
  video.srcObject = null;
  if (window.__tickTimer) { clearInterval(window.__tickTimer); window.__tickTimer = null; }
  statsReset();
  keymapRelease();                                  // P1-8：释放键位映射虚拟触控（防悬按）
}
