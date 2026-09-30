/**
 * WebSocket 桥（ArkWeb 页面 wss → 原生 webSocket 模块）
 *
 * 背景（问题取证结论，2026-08）：
 *  - ArkWeb 的 onSslErrorEventReceive/onSslErrorEvent 均不覆盖 WebSocket 的 SSL 错误
 *    （官方文档：前者仅主资源；后者覆盖"主资源+子资源"，但 wss 连接不在覆盖范围）
 *  - 被控端/云手机服务器为自签证书（模拟器无 root 无法装系统 CA）
 *  - 原生 webSocket 模块支持 skipServerCertVerification —— 可信任自签服务器
 * 方案：documentStart 注入 polyfill 替换 window.WebSocket，
 *       页面 JS 的 WebSocket 调用全部桥接到原生模块（页面无感知）。
 */
import { webSocket } from '@kit.NetworkKit';
import { webview } from '@kit.ArkWeb';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../../utils/Logger';

export class WebSocketBridge {
  private sockets: Map<string, webSocket.WebSocket> = new Map();
  private controller: webview.WebviewController | null = null;

  /** 注入 ArkWeb 控制器（页面 onControllerAttached 后调用；emit 依赖它执行 JS） */
  setController(controller: webview.WebviewController): void {
    this.controller = controller;
  }

  /**
   * 页面调用：建立连接
   */
  wsConnect(id: string, url: string, _protocols: string): void {
    if (this.sockets.has(id)) {
      return;
    }
    try {
      const ws = webSocket.createWebSocket();
      this.sockets.set(id, ws);
      const bridgeId = id;

      ws.on('open', () => {
        Logger.info('WsBridge', `open ${url.slice(0, 60)}`);
        this.emit(bridgeId, 'open', '');
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (typeof value === 'string') {
          this.emit(bridgeId, 'message', value);
        } else {
          // B-6（已解决）：二进制帧（P1-5 PREV 预览 / P2 文件通道）→ base64 文本通路；
          // 标记前缀 "B64:" 由页面 polyfill 解码回 ArrayBuffer 并双路投递
          // （ws.onmessage + window.__binFrameHandlers，见 polyfillScript 注释）。
          const b64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(value));
          this.emit(bridgeId, 'message', `B64:${b64}`);
        }
      });
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        Logger.info('WsBridge', `close code=${value.code} reason=${value.reason.slice(0, 50)}`);
        this.emit(bridgeId, 'close', String(value.code));
        this.sockets.delete(bridgeId);
      });
      ws.on('error', () => {
        Logger.warn('WsBridge', `error ${url.slice(0, 60)}`);
        this.emit(bridgeId, 'error', '');
        this.sockets.delete(bridgeId);
      });

      // 被控端自签证书：跳过验证（对外分发环境应使用受信证书或 caPath）
      const options: webSocket.WebSocketRequestOptions = {
        skipServerCertVerification: true
      };
      ws.connect(url, options, (err: BusinessError) => {
        if (err) {
          Logger.error('WsBridge', `connect fail: ${err.message}`);
          this.emit(bridgeId, 'error', '');
          this.sockets.delete(bridgeId);
        }
      });
    } catch (e) {
      const err = e as Error;
      Logger.error('WsBridge', `connect exception: ${err.message}`);
      this.emit(id, 'error', '');
    }
  }

  /**
   * 页面调用：发送文本
   */
  wsSend(id: string, data: string): void {
    const ws = this.sockets.get(id);
    if (ws !== undefined) {
      try {
        ws.send(data);
      } catch (e) {
        const err = e as Error;
        Logger.warn('WsBridge', `send fail: ${err.message}`);
      }
    }
  }

  /**
   * 页面调用：关闭
   */
  wsClose(id: string, code: number, reason: string): void {
    const ws = this.sockets.get(id);
    if (ws !== undefined) {
      try {
        ws.close({ code: code, reason: reason });
      } catch (e) {
        Logger.warn('WsBridge', 'close exception');
      }
      this.sockets.delete(id);
    }
  }

  /**
   * 原生事件 → 页面回调
   */
  private emit(id: string, type: string, payload: string): void {
    if (this.controller === null) {
      return;
    }
    // 双重转义 payload 安全嵌入 JS 字符串
    const escaped = payload.replace(/\\/g, '\\\\').replace(/'/g, `\\'`).replace(/\r/g, '\\r').replace(/\n/g, '\\n');
    const js = `window.__wsEvent && window.__wsEvent('${id}', '${type}', '${escaped}');`;
    try {
      this.controller.runJavaScript(js);
    } catch (e) {
      Logger.warn('WsBridge', 'emit js fail');
    }
  }

  /** 销毁：关闭并清空全部桥接 socket（控制页 aboutToDisappear 调用，防泄漏） */
  destroy(): void {
    this.sockets.forEach((ws: webSocket.WebSocket) => {
      try {
        ws.close({ code: 1000, reason: 'bridge destroy' });
      } catch (e) {
        // 忽略
      }
    });
    this.sockets.clear();
  }

  /**
   * documentStart 注入的 WebSocket polyfill（页面 JS 执行前生效）
   * B-6（已解决）：原生侧二进制帧以 "B64:" 前缀文本过桥，此处解码回 ArrayBuffer
   *   并双路投递——标准 onmessage（文本帧原样、二进制为 ArrayBuffer，信令层自然忽略）
   *   + registerBinFrameHandler 注册的二进制处理器（P1-5 PREV 预览按帧消费）。
   */
  static polyfillScript(): string {
    return [
      '(function(){',
      'if (window.__wsBridgeInstalled) return;',
      'window.__wsBridgeInstalled = true;',
      'window.__wsMap = {};',
      'window.__wsSeq = 0;',
      '// B-6：二进制帧通路——"B64:" 前缀解码 + 处理器注册（P1-5 预览消费）',
      'window.__binFrameHandlers = [];',
      'window.registerBinFrameHandler = function(fn) { window.__binFrameHandlers.push(fn); };',
      'window.__b64ToBuf = function(s) {',
      '  var bin = atob(s); var len = bin.length;',
      '  var buf = new Uint8Array(len);',
      '  for (var i = 0; i < len; i++) { buf[i] = bin.charCodeAt(i); }',
      '  return buf.buffer;',
      '};',
      'window.__wsEvent = function(id, type, data) {',
      '  var ws = window.__wsMap[id];',
      '  if (!ws) return;',
      '  var ev;',
      '  if (type === "open") {',
      '    ws.readyState = 1;',
      '    ev = { type: "open" };',
      '    if (ws.onopen) ws.onopen(ev);',
      '    ws.dispatchEvent(ev);',
      '  } else if (type === "message" && typeof data === "string" && data.slice(0, 4) === "B64:") {',
      '    var binBuf = window.__b64ToBuf(data.slice(4));',
      '    ev = { type: "message", data: binBuf };',
      '    if (ws.onmessage) ws.onmessage(ev);',
      '    ws.dispatchEvent(ev);',
      '    var hs = window.__binFrameHandlers;',
      '    for (var bi = 0; bi < hs.length; bi++) { try { hs[bi](binBuf, ws); } catch (be) {} }',
      '  } else if (type === "message") {',
      '    ev = { type: "message", data: data };',
      '    if (ws.onmessage) ws.onmessage(ev);',
      '    ws.dispatchEvent(ev);',
      '  } else if (type === "close") {',
      '    ws.readyState = 3;',
      '    ev = { type: "close", code: parseInt(data) || 1000, reason: "" };',
      '    if (ws.onclose) ws.onclose(ev);',
      '    ws.dispatchEvent(ev);',
      '  } else if (type === "error") {',
      '    ws.readyState = 3;',
      '    ev = { type: "error" };',
      '    if (ws.onerror) ws.onerror(ev);',
      '    ws.dispatchEvent(ev);',
      '  }',
      '};',
      'function BridgeWebSocket(url, protocols) {',
      '  var self = this;',
      '  self.url = url;',
      '  self.readyState = 0;',
      '  self.bufferedAmount = 0;',
      '  self.extensions = "";',
      '  self.protocol = "";',
      '  self.binaryType = "blob";',
      '  self._id = "ws_" + (++window.__wsSeq);',
      '  self._listeners = {};',
      '  window.__wsMap[self._id] = self;',
      '  window.nativeBridge.wsConnect(self._id, String(url), String(protocols || ""));',
      '}',
      'BridgeWebSocket.prototype.CONNECTING = 0;',
      'BridgeWebSocket.prototype.OPEN = 1;',
      'BridgeWebSocket.prototype.CLOSING = 2;',
      'BridgeWebSocket.prototype.CLOSED = 3;',
      'BridgeWebSocket.prototype.send = function(data) {',
      '  if (this.readyState !== 1) return;',
      '  if (typeof data === "string") { window.nativeBridge.wsSend(this._id, data); }',
      '};',
      'BridgeWebSocket.prototype.close = function(code, reason) {',
      '  this.readyState = 2;',
      '  window.nativeBridge.wsClose(this._id, code || 1000, reason || "");',
      '};',
      'BridgeWebSocket.prototype.addEventListener = function(type, fn) {',
      '  (this._listeners[type] = this._listeners[type] || []).push(fn);',
      '};',
      'BridgeWebSocket.prototype.removeEventListener = function(type, fn) {',
      '  var arr = this._listeners[type] || [];',
      '  var i = arr.indexOf(fn);',
      '  if (i >= 0) arr.splice(i, 1);',
      '};',
      'BridgeWebSocket.prototype.dispatchEvent = function(ev) {',
      '  var arr = this._listeners[ev.type] || [];',
      '  for (var i = 0; i < arr.length; i++) arr[i](ev);',
      '  return true;',
      '};',
      'Object.defineProperty(BridgeWebSocket, "CONNECTING", { value: 0 });',
      'Object.defineProperty(BridgeWebSocket, "OPEN", { value: 1 });',
      'Object.defineProperty(BridgeWebSocket, "CLOSING", { value: 2 });',
      'Object.defineProperty(BridgeWebSocket, "CLOSED", { value: 3 });',
      'window.WebSocket = BridgeWebSocket;',
      '})();'
    ].join('\n');
  }
}
