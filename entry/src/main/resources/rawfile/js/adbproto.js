/**
 * adbproto.js —— WebADB 会话通道与面板装配（P2-2）
 *
 * 职责（单一）：① createAdbSession —— 每会话独立 DataChannel 工厂（上游 useWebRTC
 *   createAdbSessionChannel 逐段移植：150ms 稳定期 + 发送队列 + 关闭清理）；
 *   ② 面板装配 open/close —— 画布网格终端（ansiterm）建立、init{rows,cols} 下发、
 *   键盘/IME 字节回传、通道生命周期与断开提示。
 * 协议（useAdb.js 实读）：open 后 150ms → UTF-8 JSON `{type:'init',rows,cols}` →
 *   之后双向**裸字节流**（下行 PTY 输出入终端，上行 onData 字节）。
 * 依赖：peer.js 的全局 pc（同页复用遥控连接——上游 console 内嵌同构）、ansiterm.js、
 *   桥 native('getViewOnly') 只读拦截。
 * 范围注记：多会话（≤5）由每次 open() 新建工厂天然支持；本 UI 单面板单会话。
 */
'use strict';

/** 面板运行态 */
var adb = { term: null, session: null, open: false };

/**
 * 会话通道工厂（上游 sendData 队列/150ms 稳定语义）。
 * @param pc RTCPeerConnection（控制页全局）
 * @returns {channel, sendData, close}
 */
function adbCreateSession(pc) {
  if (!pc || pc.connectionState === 'closed') {
    throw new Error('WebRTC 连接不可用');
  }
  const channel = pc.createDataChannel('adb-channel', { ordered: true });
  channel.binaryType = 'arraybuffer';
  let lastOpen = 0;
  let stabilizeTimer = null;
  let queue = [];

  const flush = () => {
    if (queue.length > 0 && channel.readyState === 'open') {
      for (const buf of queue) {
        try {
          channel.send(buf);
        } catch (e) {
          console.error('[ADB] flush 发送失败', e);
        }
      }
      queue = [];
    }
  };
  const armStabilize = () => {
    if (!stabilizeTimer) {
      stabilizeTimer = setTimeout(() => {
        flush();
        stabilizeTimer = null;
      }, 150);
    }
  };
  channel.onopen = () => {
    lastOpen = Date.now();
    armStabilize();
  };
  channel.onclose = () => {
    if (stabilizeTimer) {
      clearTimeout(stabilizeTimer);
      stabilizeTimer = null;
    }
    if (adb.session && adb.session.channel === channel) {
      adbUiState('通道已关闭');
    }
  };
  channel.onerror = () => {
    adbUiState('通道异常');
  };

  const sendData = (data) => {
    let buffer = null;
    if (data instanceof Uint8Array || data instanceof ArrayBuffer) {
      buffer = data;
    } else if (data && data.buffer instanceof ArrayBuffer) {
      buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    } else {
      return;
    }
    const now = Date.now();
    const stabilized = (now - lastOpen) > 150;
    if (channel.readyState === 'open' && stabilized) {
      try {
        channel.send(buffer);
      } catch (e) {
        queue.push(buffer);
      }
    } else {
      queue.push(buffer);
      if (channel.readyState === 'open') {
        armStabilize();
      }
    }
  };

  return {
    channel: channel,
    sendData: sendData,
    close: () => {
      try {
        channel.close();
      } catch (e) {
        // 忽略
      }
      if (stabilizeTimer) {
        clearTimeout(stabilizeTimer);
        stabilizeTimer = null;
      }
    }
  };
}

/** init 帧编码（UTF-8 JSON；rows/cols 由面板按画布尺寸算出） */
function adbEncodeInit(rows, cols) {
  return new TextEncoder().encode(JSON.stringify({ type: 'init', rows: rows, cols: cols }));
}

/** 状态条文案（面板内显示） */
function adbUiState(text) {
  const el = document.getElementById('adb-status');
  if (el) {
    el.textContent = text;
  }
}

/**
 * 打开终端面板（control.html FAB 经 runJavaScript 调用）。
 * 只读访客与 Demo 态拦截；建会话 → 稳定后发 init → 绑定双向流。
 */
function adbOpenPanel() {
  if (adb.open) {
    return;
  }
  if (native('getViewOnly', '0') === '1') {
    adbShowToast('只读模式不可用 ADB');
    return;
  }
  if (native('getDemoMode', '0') === '1') {
    adbShowToast('Demo 模式无真实通道');
    return;
  }
  const panel = document.getElementById('adb-panel');
  const canvas = document.getElementById('adb-canvas');
  panel.style.display = 'flex';
  // 画布按可用区取整到 8×16 网格
  const availW = Math.floor((panel.clientWidth - 8) / 8) * 8;
  const availH = Math.floor((panel.clientHeight - 60) / 16) * 16;
  const cols = Math.max(20, availW / 8);
  const rows = Math.max(6, availH / 16);
  adb.term = window.createAnsiTerm(canvas, cols, rows);
  adb.term.onRender = function (stats) {
    const el = document.getElementById('adb-size');
    if (el) {
      el.textContent = stats.cols + '×' + stats.rows + (stats.alt ? ' · alt' : '');
    }
  };
  adb.term.writeln('\x1b[33m[Shell] 正在建立 WebRTC 终端通道...\x1b[0m');
  try {
    // 控制页 peer.js 的全局 pc（浏览器语义：顶层 var 即 window.pc）
    adb.session = adbCreateSession(window.pc);
  } catch (e) {
    adb.term.writeln('\x1b[31m[Shell] 连接失败: ' + e.message + '\x1b[0m');
    return;
  }
  adb.session.channel.onmessage = function (ev) {
    if (adb.term && ev.data instanceof ArrayBuffer) {
      adb.term.feed(new Uint8Array(ev.data));
    }
  };
  adb.open = true;
  adbUiState('建立会话…');
  // 上游：open 后 150ms 再 fit+init（此处稳定期与队列在工厂内处理，直接排队 init）
  adb.session.sendData(adbEncodeInit(rows, cols));
  adb.term.writeln('\x1b[32m[Shell] 反代终端已就绪\x1b[0m\r\n');
  adbUiState('已连接');
  const input = document.getElementById('adb-input');
  if (input) {
    input.focus();
  }
}

/** 关闭面板（清理会话/终端/输入态） */
function adbClosePanel() {
  if (!adb.open) {
    const panel0 = document.getElementById('adb-panel');
    if (panel0) panel0.style.display = 'none';
    return;
  }
  adb.open = false;
  if (adb.session) {
    adb.session.close();
    adb.session = null;
  }
  if (adb.term) {
    adb.term = null;
  }
  const panel = document.getElementById('adb-panel');
  if (panel) {
    panel.style.display = 'none';
  }
}

/** 轻提示（面板无 ETS toast 通道；用临时状态条） */
function adbShowToast(text) {
  adbUiState(text);
  setTimeout(() => {
    if (!adb.open) {
      adbUiState('');
    }
  }, 2000);
}

/** 键盘下行（面板 keydown 调用；true=已消费） */
function adbSendKey(ev) {
  if (!adb.term || !adb.session) {
    return false;
  }
  const bytes = adb.term.encodeKey(ev);
  if (bytes) {
    adb.session.sendData(bytes);
    return true;
  }
  return false;
}

/** IME 上行（compositionend/input 文本字节） */
function adbSendText(text) {
  if (!adb.session || !text) {
    return;
  }
  adb.session.sendData(new TextEncoder().encode(text));
}

/** 显式 API（window 出口 → runJavaScript 与测试共用） */
window.__adbApi = {
  open: adbOpenPanel,
  close: adbClosePanel,
  createSession: adbCreateSession,
  encodeInit: adbEncodeInit,
  sendKey: adbSendKey,
  sendText: adbSendText,
  state: function () { return { open: adb.open }; }
};
