/**
 * input.js —— 输入注入（P0-5 触控 / P0-6 键盘 / P0-7 滚动）
 *
 * 职责（单一）：把页面手势与键盘事件翻译为被控端 DataChannel JSON 并发送；
 *              含坐标换算（黑边扣除+旋转交换）、多指会话表、MOVE 节流、
 *              viewOnly 只读拦截、DataChannel 不可用时的 WS command 兜底。
 * 依赖：session.js（DOM/通道状态）、peer.js（inputChannel 被动赋值）、
 *       signaling.js 的 sendCommand（运行时调用）。
 * 协议：（touch/inject_scroll/inject_keycode/inject_text 字段定义）。
 * 注意：本文件在加载时即注册全部监听器（依赖 session.js 先行）。
 */
'use strict';

// ===================== 触控（多指/鼠标/旋转/节流，P0-5） =====================
/** 活跃触点会话表：key = 触点 id（手指 identifier / 鼠标 -1） */
var pointers = {};
/** MOVE 节流窗口：≥25ms（上游基准） */
var MOVE_INTERVAL_MS = 25;
/** MOVE 最小位移（设备像素），避免原地抖动刷屏 */
var MOVE_MIN_PX = 4;
/** 鼠标触点 id（对齐安卓鼠标约定：手指≥0，鼠标 -1） */
var MOUSE_ID = -1;

/**
 * 视口坐标 → 设备逻辑坐标（纯函数，便于单测）。
 * 1) object-fit:contain 黑边扣除后归一化到 [0,1]；
 * 2) 视频方向与设备逻辑方向不一致时交换 w/h（旋转补偿）。
 * @returns { x, y, w, h } 设备像素坐标与换算后设备宽高
 */
function mapToDevice(clientX, clientY) {
  var rect = video.getBoundingClientRect();
  var w = deviceW, h = deviceH;
  var vw = video.videoWidth || w, vh = video.videoHeight || h;
  if ((vw > vh) !== (w > h)) { var t = w; w = h; h = t; }   // 视频方向 ≠ 设备逻辑方向 → 交换
  if (rect.width === 0 || rect.height === 0) return { x: 0, y: 0, w: w, h: h };
  var scale = Math.min(rect.width / vw, rect.height / vh);
  var dw = vw * scale, dh = vh * scale;
  var ox = (rect.width - dw) / 2, oy = (rect.height - dh) / 2;
  var rx = (clientX - rect.left - ox) / dw;
  var ry = (clientY - rect.top - oy) / dh;
  return {
    x: Math.round(Math.max(0, Math.min(1, rx)) * w),
    y: Math.round(Math.max(0, Math.min(1, ry)) * h),
    w: w, h: h
  };
}

// ===================== 群控广播（P1-10） =====================
/** 已选从机组（signaling.start 从桥读入；空组=关闭广播） */
var groupSlaves = [];

/**
 * 群控广播：同一事件经全局信令转发从机组（上游 sendGroupControlEvent 包裹规范）。
 * 与本机 input-channel 相互独立——本机通道断开时广播仍可用（对齐上游）。
 * @param eventObj 与本机注入同形的事件体（touch/inject_keycode/inject_scroll/inject_text）
 * @returns true=已交原生出口
 */
function groupBroadcast(eventObj) {
  if (groupSlaves.length === 0 || viewOnly) {
    return false; // 未组群或只读访客均不广播
  }
  try {
    if (window.nativeBridge && typeof window.nativeBridge.sendGroupEvent === 'function') {
      const frame = JSON.stringify({
        message_type: 'group_control_event',
        target_device_ids: groupSlaves,
        event: eventObj
      });
      return window.nativeBridge.sendGroupEvent(frame) === true;
    }
  } catch (e) {
    // 桥未就绪
  }
  return false;
}

/**
 * 发送 touch 消息（action: 0=DOWN 1=UP 2=MOVE）。
 * 拦截：viewOnly 只读；本地通道未开时仅走群控广播（P1-10）。
 */
function sendTouchJson(p, id, action) {
  if (viewOnly) return;                          // P0-12：访客只读——源头拦截
  var st = pointers[id];
  if (!st) return;
  st.seq++;
  var ev = {
    type: 'touch', id: id, seq: st.seq, client_ts_ms: Date.now(),
    action: action, x: p.x, y: p.y, w: p.w, h: p.h
  };
  if (inputChannel && inputChannel.readyState === 'open') {
    inputChannel.send(JSON.stringify(ev));
  }
  groupBroadcast(ev);                            // P1-10：同形事件广播从机组
}

/** 触点按下：建立会话（独立 seq 计数）并发送 DOWN */
function pointerDown(id, p) {
  pointers[id] = { seq: 0, sentMs: 0, x: p.x, y: p.y, pending: p, dirty: false };
  sendTouchJson(p, id, 0); // DOWN
}

/** 触点移动：缓存最新点，满足 25ms+4px 双阈值才发 MOVE（上游节流基准） */
function pointerMove(id, p) {
  var st = pointers[id];
  if (!st) return;
  st.pending = p;
  st.dirty = true;
  var now = Date.now();
  var dx = p.x - st.x, dy = p.y - st.y;
  var dist2 = dx * dx + dy * dy;
  if (now - st.sentMs >= MOVE_INTERVAL_MS && dist2 >= MOVE_MIN_PX * MOVE_MIN_PX) {
    sendTouchJson(p, id, 2); // MOVE（节流后）
    st.sentMs = now; st.x = p.x; st.y = p.y; st.dirty = false;
  }
}

/** 触点抬起：补发未送出的落点 MOVE，再发 UP（携带最终坐标）并清理会话 */
function pointerUp(id) {
  var st = pointers[id];
  if (!st) return;
  if (st.dirty) { sendTouchJson(st.pending, id, 2); }  // 落点补发
  sendTouchJson(st.pending, id, 1);                    // UP（携带最终坐标）
  delete pointers[id];
}

// ---- touch 事件绑定（preventDefault 阻断页面滚动/缩放） ----
video.addEventListener('touchstart', function (ev) {
  ev.preventDefault();
  for (var i = 0; i < ev.changedTouches.length; i++) {
    var t = ev.changedTouches[i];
    pointerDown(t.identifier, mapToDevice(t.clientX, t.clientY));
  }
}, { passive: false });

video.addEventListener('touchmove', function (ev) {
  ev.preventDefault();
  for (var i = 0; i < ev.changedTouches.length; i++) {
    var t = ev.changedTouches[i];
    pointerMove(t.identifier, mapToDevice(t.clientX, t.clientY));
  }
}, { passive: false });

/** touchend/touchcancel 共用收尾：逐触点 UP */
function touchEndHandler(ev) {
  ev.preventDefault();
  for (var i = 0; i < ev.changedTouches.length; i++) {
    pointerUp(ev.changedTouches[i].identifier);
  }
}
video.addEventListener('touchend', touchEndHandler, { passive: false });
video.addEventListener('touchcancel', touchEndHandler, { passive: false });

// ---- 鼠标（ArkWeb 桌面/外接鼠标场景；中键/右键映射物理键） ----
video.addEventListener('mousedown', function (ev) {
  if (ev.button === 1) { ev.preventDefault(); injectKey(3); return; }    // 中键 → HOME
  if (ev.button === 2) { ev.preventDefault(); injectKey(4); return; }    // 右键 → BACK
  ev.preventDefault();
  pointerDown(MOUSE_ID, mapToDevice(ev.clientX, ev.clientY));
});
video.addEventListener('mousemove', function (ev) {
  if (!(MOUSE_ID in pointers)) return;
  pointerMove(MOUSE_ID, mapToDevice(ev.clientX, ev.clientY));
});
video.addEventListener('mouseup', function (ev) {
  if (MOUSE_ID in pointers) pointerUp(MOUSE_ID);
});
video.addEventListener('mouseleave', function () {
  if (MOUSE_ID in pointers) pointerUp(MOUSE_ID);
});
/** 屏蔽右键菜单（为右键=BACK 让路） */
document.addEventListener('contextmenu', function (ev) { ev.preventDefault(); });

// ===================== 滚动注入（P0-7） =====================
/** inject_scroll 序列号（单通道递增即可） */
var scrollSeq = 0;

/**
 * 滚轮增量 → 协议幅度（纯函数）：deltaMode 行/页先归一到像素，
 * 标准一格≈100px，结果钳制在协议区间 ±1..16。
 */
function wheelAmount(delta, deltaMode) {
  var px = delta;
  if (deltaMode === 1) px = delta * 16;          // 行 → px 近似
  else if (deltaMode === 2) px = delta * 400;    // 页 → px 近似
  if (px === 0) return 0;
  var n = Math.round(px / 100);                  // 标准滚轮一格 ≈ 100
  if (n === 0) n = px > 0 ? 1 : -1;
  return Math.max(-16, Math.min(16, n));
}

video.addEventListener('wheel', function (ev) {
  ev.preventDefault();
  if (keymapHandleWheel(ev)) return;                // P1-8：键位映射优先消费（挂载约定）
  if (viewOnly) return;                           // P0-12
  if (!inputChannel || inputChannel.readyState !== 'open') return;
  var vh = wheelAmount(ev.deltaY, ev.deltaMode);
  var hz = wheelAmount(ev.deltaX, ev.deltaMode);
  if (vh === 0 && hz === 0) return;
  // 滚动坐标：优先用当前指针位置，否则画面中心
  var rect = video.getBoundingClientRect();
  var anyPtr = null;
  for (var k in pointers) { anyPtr = pointers[k].pending; break; }
  var p = anyPtr || mapToDevice(rect.left + rect.width / 2, rect.top + rect.height / 2);
  scrollSeq++;
  var scrollEv = {
    type: 'inject_scroll', seq: scrollSeq, client_ts_ms: Date.now(),
    x: p.x, y: p.y, w: p.w, h: p.h, scroll_h: hz, scroll_v: vh
  };
  inputChannel.send(JSON.stringify(scrollEv));
  groupBroadcast(scrollEv);                      // P1-10：同步广播
}, { passive: false });

// ===================== 键盘 / IME（P0-6） =====================
/** 控制键 → Android keycode（CONTROL_KEY_MAP 集合） */
var CONTROL_KEY_MAP = {
  'Enter': 66, 'Backspace': 67, 'Delete': 112, 'Tab': 61, 'Escape': 111,
  'ArrowLeft': 19, 'ArrowUp': 20, 'ArrowRight': 21, 'ArrowDown': 22, ' ': 62
};

/**
 * 注入按键（成对 DOWN/UP）。
 * 优先 input-channel；DataChannel 不可用时回落信令 WS command。
 * @returns true=已发送；false=只读拦截或无通道可发
 */
function injectKey(keycode) {
  if (viewOnly) return false;                    // P0-12
  var down = { type: 'inject_keycode', action: 0, keycode: keycode, repeat: 0, meta: 0 };
  var up = { type: 'inject_keycode', action: 1, keycode: keycode, repeat: 0, meta: 0 };
  var sent = false;
  if (inputChannel && inputChannel.readyState === 'open') {
    inputChannel.send(JSON.stringify(down));
    inputChannel.send(JSON.stringify(up));
    sent = true;
  }
  groupBroadcast(down);                          // P1-10：成对事件同步广播
  groupBroadcast(up);
  if (sent) return true;
  return sendCommand('input keyevent ' + keycode); // P0-6：DC 不可用时信令兜底
}
/** 暴露给 ETS（FAB 工具条经 runJavaScript 调用） */
window.injectKey = injectKey;

/** 注入文本（仅 input-channel；viewOnly 拦截；IME 与硬件可打印字符共用；P1-10 同步广播） */
function sendText(text) {
  if (viewOnly) return;                          // P0-12
  if (!text) return;
  var ev = { type: 'inject_text', text: text };
  if (inputChannel && inputChannel.readyState === 'open') {
    inputChannel.send(JSON.stringify(ev));
  }
  groupBroadcast(ev);
}

// ---- 全局物理键盘（硬件键盘/模拟器/外接键盘） ----
window.addEventListener('keydown', function (ev) {
  if (ev.isComposing) return;                       // IME 组合中交给 textarea 路径
  if (keymapHandleKey(ev, true)) {                  // P1-8：键位映射先于默认注入消费
    ev.preventDefault();
    return;
  }
  if (viewOnly) return;                             // P0-12：只读访客不注入
  if (ev.key === 'Escape') {                        // Esc：关软键盘 + 注入设备 Esc(111)
    imeEl.blur();
    ev.preventDefault();
    injectKey(111);
    return;
  }
  var kc = CONTROL_KEY_MAP[ev.key];
  if (kc !== undefined) {
    ev.preventDefault();
    injectKey(kc);
    return;
  }
  // 可打印字符：非 textarea 来源 → 直接 inject_text（textarea 来源走 composition/input）
  if (ev.key.length === 1 && !ev.ctrlKey && !ev.metaKey && !ev.altKey) {
    if (ev.target === imeEl) return;
    ev.preventDefault();
    sendText(ev.key);
  }
});

// ---- 抬键（P1-8：tap/swipe 抬手、摇杆归位依赖 keyup；无默认注入职责） ----
window.addEventListener('keyup', function (ev) {
  if (ev.isComposing) return;
  keymapHandleKey(ev, false);
});

// ---- IME 隐藏框：输入法组合上屏（compositionend 为准，组合期间 input 不发） ----
imeEl.addEventListener('compositionend', function () {
  var v = imeEl.value;
  imeEl.value = '';
  sendText(v);
});
imeEl.addEventListener('input', function (ev) {
  if (ev.isComposing || ev.inputType === 'insertCompositionText') return;
  var v = imeEl.value;
  imeEl.value = '';
  sendText(v);   // 非组合输入（如直接上屏/删除回车分段）
});

// 双击画面 → 聚焦隐藏输入框（唤起软键盘）；避免单击误触
video.addEventListener('dblclick', function () {
  imeEl.focus();
});
