/**
 * prevtouch.js —— 预览直控注入（P1-5，group_control_event 通道）
 *
 * 职责（单一）：预览画布 Pointer 手势 → 设备逻辑坐标 → 上游直控事件帧
 *              （touch DOWN/MOVE/UP + 导航 keycode），经 previewBridge 原生出口发送。
 * 依赖：preview.html DOM（#prev-canvas）；配置由 PreviewPage 注入 window.__previewInit；
 *      出口为 javaScriptProxy(window.previewBridge.sendPreviewEvent → GlobalChannel.sendRaw)。
 * 协议：帧 = group_control_event{target_device_ids,event}；
 *      事件体与 input-channel 同形；上游基准：DeviceCard 直控
 *      （Pointer 事件、id=pointerId/鼠标-1、seq 递增、MOVE 25ms+4px 设备像素节流）。
 */
'use strict';

/** 直控配置：id=目标设备；w/h=设备逻辑分辨率（≤0 禁用直控） */
var pvCfg = { id: '', w: 0, h: 0 };
/** 每触点会话表：pointerId → {seq,x,y,pending,dirty,sentMs}（多指独立 seq） */
var pvPointers = {};
/** MOVE 节流窗口（毫秒，上游同款） */
var pvMoveInterval = 25;
/** MOVE 最小位移（设备像素，上游同款 4px） */
var pvMoveMinPx = 4;
/** 预览画布（直控手势绑定目标；与 prevcodec 共用同一元素） */
var pvCanvas = document.getElementById('prev-canvas');

/**
 * ETS 注入的初始化（PreviewPage onPageEnd 调用，先于预览启动）。
 * @param json 字符串 JSON {"id":设备ID,"w":逻辑宽,"h":逻辑高}
 */
function previewInit(json) {
  try {
    const o = JSON.parse(json);
    pvCfg = { id: String(o.id || ''), w: o.w | 0, h: o.h | 0 };
  } catch (e) {
    pvCfg = { id: '', w: 0, h: 0 };
  }
}
window.__previewInit = previewInit;

/**
 * 视口坐标 → 设备逻辑坐标（纯函数，便于单测）。
 * 预览画布无黑边（canvas 即帧），仅需方向交换：画布纵横比与设备逻辑不一致时先交换 w/h。
 */
function previewMap(clientX, clientY) {
  const rect = pvCanvas ? pvCanvas.getBoundingClientRect() : { left: 0, top: 0, width: 0, height: 0 };
  let w = pvCfg.w;
  let h = pvCfg.h;
  if (rect.width > 0 && rect.height > 0 && (rect.width > rect.height) !== (w > h)) {
    const t = w; w = h; h = t; // 方向不一致 → 交换（同 input.js mapToDevice 语义）
  }
  if (rect.width === 0 || rect.height === 0) {
    return { x: 0, y: 0, w: w, h: h };
  }
  const rx = (clientX - rect.left) / rect.width;
  const ry = (clientY - rect.top) / rect.height;
  return {
    x: Math.round(Math.max(0, Math.min(1, rx)) * w),
    y: Math.round(Math.max(0, Math.min(1, ry)) * h),
    w: w, h: h
  };
}

/**
 * 组装并发送直控帧（上游 sendGroupControlEvent 包裹规范）。
 * @param eventObj 事件体（touch / inject_keycode，字段见文件头协议）
 * @returns true=已发出；配置缺失或原生出口不可用为 false
 */
function pvSend(eventObj) {
  if (pvCfg.id.length === 0 || pvCfg.w <= 0) {
    return false; // 未初始化或缺逻辑分辨率基准 → 直控禁用（防坐标错乱）
  }
  const frame = JSON.stringify({
    message_type: 'group_control_event',
    target_device_ids: [pvCfg.id],
    event: eventObj
  });
  try {
    if (window.previewBridge && typeof window.previewBridge.sendPreviewEvent === 'function') {
      const ok = window.previewBridge.sendPreviewEvent(frame);
      return ok === true || ok === 'true';
    }
  } catch (e) {
    // 桥未就绪
  }
  return false;
}

/** 触点 → touch 事件发送（seq 会话内递增） */
function pvTouchSend(id, p, action) {
  const st = pvPointers[id];
  if (!st) {
    return;
  }
  st.seq++;
  pvSend({
    type: 'touch', action: action, x: p.x, y: p.y, w: p.w, h: p.h,
    id: id, seq: st.seq, client_ts_ms: Date.now()
  });
}

function pvPointerDown(ev) {
  if (ev.cancelable) {
    ev.preventDefault();
  }
  try {
    ev.currentTarget.setPointerCapture(ev.pointerId);
  } catch (e) {
    // 桌面浏览器可能不支持
  }
  const id = ev.pointerType === 'mouse' ? -1 : ev.pointerId;
  const p = previewMap(ev.clientX, ev.clientY);
  pvPointers[id] = { seq: 0, x: p.x, y: p.y, pending: p, dirty: false, sentMs: 0 };
  pvTouchSend(id, p, 0); // DOWN
}

function pvPointerMove(ev) {
  const id = ev.pointerType === 'mouse' ? -1 : ev.pointerId;
  const st = pvPointers[id];
  if (!st) {
    return; // 未按下不响应（与上游直控一致）
  }
  const p = previewMap(ev.clientX, ev.clientY);
  st.pending = p;
  st.dirty = true;
  const now = Date.now();
  const dx = p.x - st.x;
  const dy = p.y - st.y;
  if (now - st.sentMs >= pvMoveInterval && (dx * dx + dy * dy) >= (pvMoveMinPx * pvMoveMinPx)) {
    pvTouchSend(id, p, 2); // MOVE（25ms+4px 双阈值）
    st.sentMs = now;
    st.x = p.x;
    st.y = p.y;
    st.dirty = false;
  }
}

function pvPointerUp(ev) {
  const id = ev.pointerType === 'mouse' ? -1 : ev.pointerId;
  const st = pvPointers[id];
  if (!st) {
    return;
  }
  if (st.dirty) {
    pvTouchSend(id, st.pending, 2); // 落点补发
  }
  pvTouchSend(id, st.pending, 1);   // UP（携带最终坐标）
  delete pvPointers[id];
}

/**
 * 导航键注入（页面 FAB 调用）：成对 DOWN/UP（上游虚拟导航：返回4/主页3/电源26…）。
 * @param keycode Android KeyEvent 码
 */
function previewNavKey(keycode) {
  pvSend({ type: 'inject_keycode', action: 0, keycode: keycode, repeat: 0, meta: 0 });
  pvSend({ type: 'inject_keycode', action: 1, keycode: keycode, repeat: 0, meta: 0 });
}
window.__previewNavKey = previewNavKey;

// 手势绑定（Pointer 事件统一触控/鼠标/笔，上游 DeviceCard 同模型）
if (pvCanvas) {
  pvCanvas.addEventListener('pointerdown', pvPointerDown, { passive: false });
  pvCanvas.addEventListener('pointermove', pvPointerMove);
  pvCanvas.addEventListener('pointerup', pvPointerUp);
  pvCanvas.addEventListener('pointercancel', pvPointerUp);
  pvCanvas.addEventListener('contextmenu', (e) => { e.preventDefault(); });
}
