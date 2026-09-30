/**
 * audio.js —— 远端音频播放（P1-1）
 *
 * 职责（单一）：音频轨挂载到独立 <audio>、autoplay 手势解锁、
 *              页面静音开关（FAB「静音」经 ETS runJavaScript 调用）。
 * 依赖：session.js（audioEl/video 变量）；由 peer.js ontrack(audio) 委托 attachAudioTrack。
 * 背景：video 元素恒 muted（声音只走 audio 元素），对齐上游"静音画面+独立声音"策略；
 *       ArkWeb 对无手势的 autoplay 有限制，首次触摸画面时重试播放（与视频同一手势）。
 */
'use strict';

/**
 * 挂载远端音频轨（peer.ontrack kind=audio 时调用，幂等复用 audio 元素）。
 * @param track 远端音频 MediaStreamTrack
 */
function attachAudioTrack(track) {
  if (!audioEl) {
    audioEl = document.createElement('audio');
    audioEl.autoplay = true;
    document.body.appendChild(audioEl);
  }
  audioEl.srcObject = new MediaStream([track]);
  // autoplay 策略可能拒绝：首次触摸画面重试一次（与视频解锁同手势）
  var tryPlay = function () { audioEl.play().catch(function () {}); };
  tryPlay();
  video.addEventListener('touchend', tryPlay, { once: true, passive: true });
}

/**
 * 页面静音开关（仅本地，不发任何协议消息）。
 * @returns 新静音状态的字符串形式（'true'/'false'，供 ETS Promise<string> 解析更新按钮）
 */
function toggleAudioMuted() {
  if (!audioEl) {
    return 'false';
  }
  audioEl.muted = !audioEl.muted;
  return String(audioEl.muted);
}
/** 暴露给 ETS：FAB「静音/开声」按钮 */
window.toggleAudioMuted = toggleAudioMuted;
