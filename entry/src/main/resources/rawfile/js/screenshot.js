/**
 * screenshot.js —— 实时截图（P2-6）
 *
 * 职责（单一）：screenshot_request 请求帧、screenshot_response 数据归一
 *   （base64 字符串/字节数组/ArrayBuffer → PNG data URI，上游 ScreenshotModal 同款归一）、
 *   全屏预览层（图 + 保存/关闭）与保存出口（ETS 文件选择器写盘）。
 * 挂载：signaling.handleMsg 收到 screenshot_response → window.__onScreenshot（本模块注册）。
 * 依赖：session.js（ws/curDevId）、ArkWebView 桥 nativeBridge.saveScreenshot。
 * 协议： 上行 screenshot_request{device_id} / 下行 screenshot_response{data}。
 */
'use strict';

/** 预览层元素引用（模块变量；避免依赖 getElementById 在不同环境的实现差异） */
var shotLayer = null;
var shotImg = null;
/** 当前截图的裸 base64（保存时剥 data: 前缀后的部分） */
var shotB64 = '';

/**
 * 响应数据归一（上游 ScreenshotModal 三分支：字符串 / 数组 / ArrayBuffer）。
 * @returns PNG data URI；无法识别返回 ''（调用方忽略）
 */
function normalizeShotData(data) {
  if (typeof data === 'string') {
    if (data.length === 0) {
      return '';
    }
    if (data.indexOf('data:') === 0) {
      return data;
    }
    return 'data:image/png;base64,' + data;
  }
  var bytes = null;
  if (data instanceof ArrayBuffer) {
    bytes = new Uint8Array(data);
  } else if (Array.isArray(data)) {
    bytes = new Uint8Array(data);
  } else if (data && data.buffer instanceof ArrayBuffer) {
    bytes = new Uint8Array(data.buffer); // 类型数组视图
  }
  if (!bytes || bytes.length === 0) {
    return '';
  }
  var bin = '';
  for (var i = 0; i < bytes.length; i++) {
    bin += String.fromCharCode(bytes[i]);
  }
  return 'data:image/png;base64,' + btoa(bin);
}

/** 关闭预览层 */
function closeShot() {
  if (shotLayer) {
    shotLayer.style.display = 'none';
  }
}

/** 保存：裸 base64 → ETS 系统文件选择器（免存储权限），保存后收起预览 */
function saveShot() {
  try {
    if (window.nativeBridge && typeof window.nativeBridge.saveScreenshot === 'function' && shotB64.length > 0) {
      window.nativeBridge.saveScreenshot(shotB64, 'screenshot_' + Date.now() + '.png');
      closeShot();
    }
  } catch (e) {
    // 桥未就绪
  }
}

/**
 * 构建（首次）并展示预览层：黑底全屏、图片 contain、底部保存/关闭。
 * @param dataUri 归一后的 data URI
 */
function showScreenshot(dataUri) {
  shotB64 = dataUri.indexOf('data:image/png;base64,') === 0
    ? dataUri.slice('data:image/png;base64,'.length)
    : dataUri;
  if (!shotLayer) {
    var doc = document;
    shotLayer = doc.createElement('div');
    shotLayer.style.position = 'fixed';
    shotLayer.style.left = '0';
    shotLayer.style.top = '0';
    shotLayer.style.width = '100%';
    shotLayer.style.height = '100%';
    shotLayer.style.background = 'rgba(0,0,0,0.88)';
    shotLayer.style.zIndex = '999';
    shotLayer.style.textAlign = 'center';

    shotImg = doc.createElement('img');
    shotImg.style.maxWidth = '100%';
    shotImg.style.maxHeight = '76vh';
    shotImg.style.marginTop = '5vh';
    shotImg.style.objectFit = 'contain';
    shotLayer.appendChild(shotImg);

    var bar = doc.createElement('div');
    bar.style.marginTop = '16px';
    var btnSave = doc.createElement('button');
    btnSave.textContent = '保存 PNG';
    btnSave.style.cssText = 'margin:0 12px;padding:8px 22px;font-size:14px;border-radius:6px;border:none;background:#0A59F7;color:#fff;';
    btnSave.onclick = function () { saveShot(); };
    var btnClose = doc.createElement('button');
    btnClose.textContent = '关闭';
    btnClose.style.cssText = 'margin:0 12px;padding:8px 22px;font-size:14px;border-radius:6px;border:none;background:#555;color:#fff;';
    btnClose.onclick = function () { closeShot(); };
    bar.appendChild(btnSave);
    bar.appendChild(btnClose);
    shotLayer.appendChild(bar);

    // 点击图片/遮罩空白也可关闭（预览快速流）
    shotLayer.onclick = function (ev) {
      if (ev.target === shotLayer) {
        closeShot();
      }
    };
    doc.body.appendChild(shotLayer);
  }
  shotImg.src = dataUri;
  shotLayer.style.display = 'block';
  // 供测试/调试观察最近一次归一结果（不参与渲染逻辑）
  window.__shotLastSrc = dataUri;
}

/**
 * 发起截图请求（FAB「截图」经 runJavaScript 调用）。
 * ws/curDevId 用裸标识探测（页面与测试沙箱都能取到全局实例）。
 * @returns true=已发出
 */
function requestScreenshot() {
  try {
    var sock = (typeof ws !== 'undefined') ? ws : null;
    var dev = (typeof curDevId !== 'undefined') ? curDevId : '';
    if (sock && sock.readyState === 1) {
      sock.send(JSON.stringify({ message_type: 'screenshot_request', device_id: dev }));
      return true;
    }
  } catch (e) {
    // 未连接
  }
  return false;
}
window.requestScreenshot = requestScreenshot;

// 信令分发入口（signaling.handleMsg 调用；未加载预览层前也可接收）
window.__onScreenshot = function (data) {
  var uri = normalizeShotData(data);
  if (uri.length > 0) {
    showScreenshot(uri);
  }
};
