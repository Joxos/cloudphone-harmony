/**
 * clipboard.js —— 双向剪贴板同步（P1-2，clipboard-channel）
 *
 * 职责（单一）：clipboard-channel 的收发与去重——
 *   设备→本地：attachClipboardChannel 收 'clipboard' → nativeBridge.onClipboard → ETS 写系统剪贴板；
 *   本地→设备：「送剪贴板」按钮（ETS 注入文本）/ 页面 paste 事件 → 'set_clipboard'；
 *   主动拉取：requestClipboard() → 'get_clipboard'（回包仍走设备→本地通路）。
 * 依赖：session.js（inputChannel/viewOnly/DOM）；由 peer.js 在 ondatachannel 时调用注册。
 * 协议：set_clipboard / clipboard / get_clipboard 三条消息，字段与去重规则见
 *   set_clipboard{text,paste,source,suppress_broadcast} / clipboard{text,source,origin_client_id}。
 */
'use strict';

/** 最近一次本端发出的剪贴板文本与时间戳（echo 去重用） */
var lastSentClip = { text: '', ts: 0 };

/**
 * 注册被控端反向通道 clipboard-channel（peer.js ondatachannel 调用）。
 * 收到 {type:'clipboard'}：忽略 keyboard 源与 5s 内自己刚发的 echo，
 * 其余文本上报 ETS（nativeBridge.onClipboard）写入系统剪贴板。
 */
function attachClipboardChannel(ch) {
  ch.onmessage = function (me) {
    try {
      var m = JSON.parse(typeof me.data === 'string' ? me.data : '');
      if (m.type !== 'clipboard' || !m.text) return;
      if (m.source === 'keyboard') return;                                  // 上游规则：键盘源忽略
      if (m.text === lastSentClip.text && Date.now() - lastSentClip.ts < 5000) return; // 自发 echo 去重
      try {
        if (window.nativeBridge && typeof window.nativeBridge.onClipboard === 'function') {
          window.nativeBridge.onClipboard(String(m.text));                   // → ETS 写系统剪贴板
        }
      } catch (e) {}
    } catch (e) {}
  };
}

/**
 * 本地文本 → 设备（set_clipboard）。
 * @param text 剪贴板文本
 * @param paste 是否粘贴到设备当前输入焦点（上游 paste 标志）
 * @returns true=已发送；viewOnly/空文本/通道未开为 false
 */
function setClipboardToDevice(text, paste) {
  if (viewOnly) return false;                                                // P1-2：只读访客不得上送
  if (!text || !inputChannel || inputChannel.readyState !== 'open') return false;
  lastSentClip = { text: text, ts: Date.now() };
  inputChannel.send(JSON.stringify({
    type: 'set_clipboard', text: text, paste: !!paste, source: 'local'
  }));
  return true;
}

/** 暴露给 ETS：「送剪贴板」按钮（系统剪贴板文本经 runJavaScript 注入后调本函数） */
window.setClipboardFromNative = function (text) {
  return setClipboardToDevice(String(text), false);
};

/**
 * 主动拉取设备剪贴板（get_clipboard）；
 * 回包经 attachClipboardChannel → onClipboard 写入本地，无需回调。
 * @returns true=已发送
 */
function requestClipboard() {
  if (viewOnly) return false;
  if (!inputChannel || inputChannel.readyState !== 'open') return false;
  inputChannel.send(JSON.stringify({ type: 'get_clipboard' }));
  return true;
}
/** 暴露给 ETS：「取剪贴板」按钮 */
window.requestClipboard = requestClipboard;

// 页面 paste 事件 → 设备（用户在隐藏输入框粘贴即上送，对齐上游 set_clipboard{paste:true}）
imeEl.addEventListener('paste', function (ev) {
  var t = '';
  try { t = (ev.clipboardData && ev.clipboardData.getData('text')) || ''; } catch (e) {}
  if (t) {
    ev.preventDefault();
    setClipboardToDevice(t, true);
  }
});
