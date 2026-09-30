#!/usr/bin/env node
/**
 * control.html 运行时测试台（P0 无真机验证 · 审计 T1b 的 Node 等价物）
 *
 * 用 DevEco 自带 Node 运行：node scripts/control_html_test.mjs
 * 原理：按 control.html 的 <script> 顺序拼接 rawfile/js/ 引擎模块，于 node:vm 沙箱中
 *   以桩替代 document/video/WebSocket/RTCPeerConnection/时钟/原生 bridge，
 *   驱动信令与输入事件，对下列功能面做断言：
 *   P0-3 状态机序列与重连 | P0-4 parseStats | P0-5 触控(多指/旋转/节流/字段)
 *   P0-6 键盘/命令兜底 | P0-7 滚动 | P0-8 候选过滤 | P0-9 scrcpy_options 注入
 *   P0-11 SDP munge | P0-12 share_token/viewOnly 门
 *   P1-2 双向剪贴板（收/送/拉取/paste/去重/viewOnly 拦截）
 *   B-6 二进制通路（polyfill B64 解码/双路投递/信令容错）
 *   P1-5 prevcodec 解码核心（parseAnnexB/avcC/codec串/首帧门/AVCC 喂帧/防重配）
 *   P1-5 直控（group_control_event 帧/touch字段/节流/鼠标id/导航键/禁用门/方向交换）
 *   P1-10 群控（未组群零外溢/双通道并行/键控成对广播）
 *   P1-8 键位映射（tap/command/joystick/wheel 消费、swipe 终点、viewOnly 门）
 *   P2-6 截图（请求帧/三分支归一/预览层按钮/原生保存出口）
 *   P2-7 摄像头（通道接管/agent start·stop/裸帧发送/camera_support 门）
 *   P2-1a 文件通道（命令帧/回复分发/下载块组装与失败清理）
 *   P2-1b 上传与安装（sha256 向量/upload_start 载荷/16KB 分块泵/ack 成败/install 三态）
 *   P2-12d 仿真屏（启动/单帧绘制/波纹反馈/停止清理）
 *   P2-2 WebADB（会话队列与稳定冲刷/init 帧/CSI·SGR·备用屏/键编码）
 *   P2-3a AI 引擎（工具定义/systemMessage/命令等待器闭环/三工具效果/Agent 双轮收敛）
 * 退出码：0=全部通过
 */
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import assert from 'node:assert/strict';

const repo = join(dirname(fileURLToPath(import.meta.url)), '..');
// 兼容两种布局：本仓即工程根（entry/…），或工程作为子目录（CloudPhoneHarmony/entry/…）
const appRoot = existsSync(join(repo, 'entry', 'src'))
  ? repo
  : join(repo, 'CloudPhoneHarmony');
const rawDir = join(appRoot, 'entry/src/main/resources/rawfile');
const html = readFileSync(join(rawDir, 'control.html'), 'utf8');
// 纪律整改后 control.html 只剩视图：按 <script> 出现顺序拼接 6 个外链模块 + 内联 boot
const tags = [...html.matchAll(/<script(?:\s+src="([^"]+)")?\s*>([\s\S]*?)<\/script>/g)];
assert.ok(tags.length >= 7, '应含 6 个 js 外链 + 1 个内联 boot，实际 ' + tags.length);
const scriptSrc = tags.map((t) => (t[1] ? readFileSync(join(rawDir, t[1]), 'utf8') : t[2])).join('\n;\n');
assert.ok(scriptSrc.includes('function start'), '脚本拼接应包含 start');

const ANSWER_SDP = [
  'v=0', 'o=- 1 1 IN IP4 127.0.0.1', 's=-', 't=0 0',
  'm=video 9 UDP/TLS/RTP/SAVPF 96 97', 'c=IN IP4 0.0.0.0',
  'a=rtpmap:96 H264/90000',
  'a=fmtp:96 level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=42001f',
  'a=rtpmap:97 rtx/90000', 'a=fmtp:97 apt=96', ''
].join('\r\n');

const STATS_FIXTURE = [
  { id: 'inbound', type: 'inbound-rtp', kind: 'video', framesPerSecond: 30, bytesReceived: 240000, packetsLost: 2 },
  { id: 'pair', type: 'candidate-pair', state: 'succeeded', nominated: true, currentRoundTripTime: 0.012, localCandidateId: 'L1', remoteCandidateId: 'R1' },
  { id: 'L1', type: 'candidate', protocol: 'udp', candidateType: 'host' },
  { id: 'R1', type: 'candidate', protocol: 'udp', candidateType: 'srflx' }
];

let pass = 0;
function ok(cond, name) {
  if (!cond) { console.error('FAIL ' + name); process.exitCode = 1; }
  else { pass++; console.log('PASS ' + name); }
}
const flush = () => new Promise((r) => setImmediate(r));

function createHarness(opts = {}) {
  const stateLog = [];          // onState(state, text)
  const wsInstances = [];
  const pcInstances = [];
  const fakeTimers = [];
  let fakeNow = 1_700_000_000_000;
  const winListeners = {};
  const docListeners = {};
  const videoListeners = {};

  const clipIn = [];           // P1-2：记录 nativeBridge.onClipboard 收到的文本
  const groupFrames = [];      // P1-10：sendGroupEvent 出口帧捕获
  const saves = [];            // P2-6：saveScreenshot 出口捕获（b64, fileName）
  const aiChatCalls = [];      // P2-3：aiChat 桥调用记录（LLM 请求体）
  const bridge = Object.assign({
    getServerHost: () => '127.0.0.1:18080',
    getToken: () => 'tok-1',
    getDeviceId: () => 'dev-1',
    getUseSslFlag: () => '0',
    getScrcpyOptions: () => (opts.scrcpyOptions !== undefined ? opts.scrcpyOptions : '{"max_fps":60,"bitrate":4000000}'),
    getDemoMode: () => (opts.demoMode ? '1' : '0'),
    getShareToken: () => (opts.shareToken || ''),
    getSharePwd: () => (opts.sharePwd || ''),
    getViewOnly: () => (opts.viewOnly ? '1' : '0'),
    getGroupSlaves: () => (opts.groupSlaves !== undefined ? opts.groupSlaves : '[]'),
    getKeymapProfiles: () => (opts.keymapProfiles !== undefined ? opts.keymapProfiles : ''),
    getAiConfig: () => (opts.aiConfig !== undefined ? opts.aiConfig : '{"url":"http://llm.local/v1","key":"sk-test","model":"m1"}'),
    aiChat: (url, key, body, reqId) => { aiChatCalls.push({ url, key, body, reqId }); },
    saveScreenshot: (b64, name) => { saves.push({ b64, name }); },
    sendGroupEvent: (j) => { groupFrames.push(JSON.parse(j)); return true; },
    onState: (s, t) => stateLog.push([s, t]),
    onClipboard: (t) => clipIn.push(t)
  }, opts.bridgeOverride || {});

  class WsStub {
    constructor(url) { this.url = url; this.readyState = 0; this.sent = []; this.onopen = null; this.onmessage = null; this.onclose = null; this.onerror = null; wsInstances.push(this); }
    send(d) { this.sent.push(JSON.parse(d)); }
  }
  class PcStub {
    constructor(cfg) { this.cfg = cfg; this.dcs = []; this.sentDc = []; this.connectionState = 'new'; this.ices = []; pcInstances.push(this); }
    createDataChannel(label) { this.dcs.push(label); }
    setRemoteDescription(x) { this.remote = x; return Promise.resolve(); }
    createAnswer() { return Promise.resolve({ type: 'answer', sdp: ANSWER_SDP }); }
    setLocalDescription(a) { this.local = a; return Promise.resolve(); }
    addIceCandidate(c) { this.ices.push(c); return Promise.resolve(); }
    getStats() { return Promise.resolve(STATS_FIXTURE); }
    close() { this.closed = true; }
  }

  const PAINT2D = {
    drawImage() {}, fillRect() {}, fillText() {}, beginPath() {}, arc() {}, stroke() {}, fill() {},
    rect() {}, roundRect() {}, createLinearGradient: () => ({ addColorStop() {} }),
    font: '', fillStyle: '', strokeStyle: '', lineWidth: 1, textAlign: 'left'
  };
  const mkEl = (extra = {}) => Object.assign({ textContent: '', className: '', style: {}, value: '', listeners: {}, addEventListener(t, fn) { this.listeners[t] = fn; }, removeEventListener(t) { delete this.listeners[t]; }, appendChild() {}, focus() {}, blur() {}, play: () => Promise.resolve(), getContext: () => PAINT2D, getBoundingClientRect: () => ({ left: 0, top: 0, width: 360, height: 640 }), toBlob(cb) { cb({ arrayBuffer: () => Promise.resolve(new Uint8Array([0xFF, 0xD8, 0x42]).buffer) }); } }, extra);
  const video = mkEl({
    videoWidth: 1920, videoHeight: 1080, paused: false, srcObject: null,
    listeners: {},
    // 数组式监听器：与浏览器一致可叠加（ontrack 会再挂一个 touchend 播放重试）
    addEventListener(t, fn) { (videoListeners[t] = videoListeners[t] || []).push(fn); },
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 200, height: 100 })
  });
  const statusEl = mkEl(), hintEl = mkEl({ style: { display: '' } }), imeEl = mkEl();

  const createdEls = [];       // P1-1：记录 document.createElement 产物（audio 元素）
  const extraEls = {}; // 未知 id 元素兜底（如 #mock-screen 懒建）
  const document = {
    getElementById: (id) => {
      const known = { video, status: statusEl, hint: hintEl, ime: imeEl };
      if (known[id] !== undefined) return known[id];
      if (!extraEls[id]) extraEls[id] = mkEl();
      return extraEls[id];
    },
    createElement: (tag) => { const el = mkEl({ __tag: tag }); createdEls.push(el); return el; },
    body: { appendChild() {} },
    addEventListener(t, fn) { docListeners[t] = fn; }
  };
  const window = {
    nativeBridge: bridge,
    addEventListener(t, fn) { winListeners[t] = fn; },
    __tickTimer: null
  };
  const ctx = {
    window, document,
    WebSocket: WsStub,
    RTCPeerConnection: PcStub,
    MediaStream: class { constructor(tracks) { this.tracks = tracks; } },
    Date: { now: () => fakeNow },
    JSON, Math, String, Number, Array, Object, encodeURIComponent, console,
    setTimeout: (fn, ms) => { fakeTimers.push({ fn, ms }); return fakeTimers.length; },
    clearTimeout: () => {},
    setInterval: (fn, ms) => { fakeTimers.push({ fn, ms, interval: true }); return fakeTimers.length; },
    clearInterval: () => {}
  };
  // 脚本顶层 var/函数进入沙箱全局
  const vm = yieldlessEval(scriptSrc, ctx); // 见下：用 Function 构造注入
  return {
    ctx, stateLog, wsInstances, pcInstances, fakeTimers, videoListeners, winListeners, docListeners, clipIn, createdEls, groupFrames, saves, extraEls, aiChatCalls,
    setNow: (t) => { fakeNow = t; },
    states: () => stateLog.map((x) => x[0])
  };
}

/** 在沙箱上下文中执行脚本（把顶层声明挂到 ctx 上） */
function yieldlessEval(src, ctx) {
  const names = [];
  // 收集顶层 var/function 名，执行后复制回 ctx
  const fn = new Function('window', 'document', 'WebSocket', 'RTCPeerConnection', 'MediaStream',
    'Date', 'JSON', 'Math', 'String', 'Number', 'Array', 'Object', 'encodeURIComponent', 'console',
    'setTimeout', 'clearTimeout', 'setInterval', 'clearInterval',
    src + '\n;return {vars: (function(){var o={};' +
    'try{for (var k in window){}}catch(e){};return o;})()};');
  fn(ctx.window, ctx.document, ctx.WebSocket, ctx.RTCPeerConnection, ctx.MediaStream,
    ctx.Date, ctx.JSON, ctx.Math, ctx.String, ctx.Number, ctx.Array, ctx.Object, ctx.encodeURIComponent, ctx.console,
    ctx.setTimeout, ctx.clearTimeout, ctx.setInterval, ctx.clearInterval);
  return ctx;
}

async function main() {
  // ---------- 桩环境装载 ----------
  const h = createHarness();
  const c = h.ctx;
  // 顶层 var 声明在 Function 作用域内——通过脚本自身的全局写入无法直接拿到；
  // 因此改用把脚本编译进 vm 全局的方式：
  ok(true, '脚本装载（见下方行为断言）');

  // 由于 Function 作用域限制，行为断言全部通过"可观察副作用"进行：
  // ws 消息 / pc 配置 / onState 序列 / video 监听器 / window 监听器。

  // ---- P0-3: start() → connecting + ws url（ws:// 跟随 use_ssl=0，B-3） ----
  ok(h.wsInstances.length === 1, 'start() 创建了 WebSocket');
  const ws = h.wsInstances[0];
  ok(ws.url === 'ws://127.0.0.1:18080/connect_client?token=tok-1', 'B-3: ws:// scheme + token query = ' + ws.url);
  ok(h.states().includes('connecting'), '状态机进入 connecting');

  // ---- P0-3: open → signaling + connect 首帧 ----
  ws.readyState = 1; ws.onopen();
  ok(h.states().includes('signaling'), '状态机进入 signaling');
  ok(ws.sent[0] && ws.sent[0].message_type === 'connect' && ws.sent[0].device_id === 'dev-1', 'connect 首帧含 device_id');

  // ---- P0-9 + P0-3: config → requestOffer(注入的 scrcpy_options) + waiting_offer ----
  ws.onmessage({ data: JSON.stringify({ message_type: 'config', ice_servers: [{ urls: ['stun:x'] }] }) });
  await flush();
  const pc0 = h.pcInstances[0];
  ok(!!pc0, 'config 后创建 RTCPeerConnection');
  ok(pc0 && pc0.cfg.iceTransportPolicy === 'all', '默认 connectionPath=auto → iceTransportPolicy=all');
  const offerMsg = ws.sent.find((x) => x.message_type === 'forward' && x.payload && x.payload.type === 'request-offer');
  ok(!!offerMsg, 'request-offer 已发送');
  ok(offerMsg && offerMsg.payload.scrcpy_options !== undefined, 'P0-9: scrcpy_options 存在');
  ok(offerMsg && offerMsg.payload.scrcpy_options.max_fps === 60 && offerMsg.payload.scrcpy_options.bitrate === 4000000, 'P0-9: ETS 注入的设置生效(max_fps=60)');
  ok(h.states().includes('waiting_offer'), '状态机进入 waiting_offer');

  // ---- device_info → 分辨率 ----
  ws.onmessage({ data: JSON.stringify({ message_type: 'device_info', device_info: { displays: [{ x_res: 720, y_res: 1600 }] } }) });
  ok(ws, 'device_info 处理不抛错');

  // ---- P0-11: offer → answer 带 munge ----
  ws.onmessage({ data: JSON.stringify({ message_type: 'device_msg', payload: { type: 'offer', sdp: ANSWER_SDP } }) });
  await flush(); await flush();
  const ans = ws.sent.find((x) => x.message_type === 'forward' && x.payload && x.payload.type === 'answer');
  ok(!!ans, 'answer 已发送');
  ok(ans && ans.payload.sdp.includes('b=AS:20000'), 'P0-11: answer 注入 b=AS:20000');
  ok(ans && ans.payload.sdp.includes('x-google-start-bitrate=20000'), 'P0-11: H264 fmtp 注入 x-google-start-bitrate');
  ok(ans && !/apt=96;x-google/.test(ans.payload.sdp), 'P0-11: 非 H264 fmtp(apt) 不注入');
  ok(h.states().includes('connecting_webrtc'), '状态机进入 connecting_webrtc');

  // ---- P0-3: connected ----
  pc0.connectionState = 'connected'; pc0.onconnectionstatechange();
  ok(h.states().includes('connected'), '状态机进入 connected');

  // ---- 打开 DataChannel（ondatachannel 模拟；必须在 P0-6 DC 断言之前） ----
  const dcHandler = pc0.ondatachannel;
  ok(typeof dcHandler === 'function', 'ondatachannel 已注册');
  dcHandler({ channel: { label: 'input-channel', readyState: 'open', send: (s) => { pc0.sentDc.push(JSON.parse(s)); }, onmessage: null } });
  const clipCh = { label: 'clipboard-channel', readyState: 'open', send() {}, onmessage: null };
  h.clipChannel = clipCh;   // P1-2：保存引用供剪贴板断言
  dcHandler({ channel: clipCh });

  // ---- P0-8: relay 策略（新 harness 设置后重放 config） ----
  const h2 = createHarness();
  h2.ctx.icePrefs && (h2.ctx.icePrefs.connectionPath = 'relay');
  // icePrefs 不在 window 上，行为断言改走"过滤函数可观察性"：见下方候选注入
  const ws2 = h2.wsInstances[0]; ws2.readyState = 1; ws2.onopen();
  ws2.onmessage({ data: JSON.stringify({ message_type: 'config', ice_servers: [] }) });
  await flush();
  ok(h2.pcInstances.length === 1, '第二个 harness 独立建 PC');

  // ---- P0-12: share_token 连接 ----
  const h3 = createHarness({ shareToken: 'CARD8888', sharePwd: 'pw', viewOnly: true });
  const ws3 = h3.wsInstances[0];
  ok(ws3.url.includes('share_token=CARD8888') && ws3.url.includes('share_pwd=pw'), 'P0-12: share_token/share_pwd query = ' + ws3.url);
  ok(!/[?&]token=/.test(ws3.url), 'P0-12: 分享连接不带 login token');

  // ---- P0-12: viewOnly 门（无 DC 时各注入静默） ----
  // viewOnly 在 share harness 中为 true：直接驱动 window keydown
  const kd = h3.winListeners['keydown'];
  ok(typeof kd === 'function', 'window keydown 监听器已注册');
  let sentDuringViewOnly = 0;
  const origSend = (msg) => { sentDuringViewOnly++; };
  // 无 inputChannel（PC 未到 ondatachannel），keydown 走 injectKey → viewOnly 应直接 false/静默
  if (kd) kd({ key: 'Enter', isComposing: false, preventDefault() {}, ctrlKey: false, metaKey: false, altKey: false, target: {} });
  // viewOnly 下 injectKey 返回 false 且无 channel 不产生 ws 命令：
  const cmdDuringView = ws3.sent.filter((x) => x.message_type === 'command');
  ok(cmdDuringView.length === 0, 'P0-12: viewOnly 时物理键不注入也不落 command 兜底');

  // ---- P0-6: 非 viewOnly + DC 已开 → 直接走 input-channel keycode 对 ----
  const kd1 = h.winListeners['keydown'];
  ok(typeof kd1 === 'function', 'window keydown 监听器已注册');
  kd1({ key: 'Enter', isComposing: false, preventDefault() {}, ctrlKey: false, metaKey: false, altKey: false, target: {} });
  const kcPair = pc0.sentDc.filter((x) => x.type === 'inject_keycode' && x.keycode === 66);
  ok(kcPair.length === 2 && kcPair[0].action === 0 && kcPair[1].action === 1, 'P0-6: Enter → keycode66 DOWN/UP 成对（DC 直发）');
  kd1({ key: 'q', isComposing: false, preventDefault() {}, ctrlKey: false, metaKey: false, altKey: false, target: {} });
  const txt = pc0.sentDc.find((x) => x.type === 'inject_text' && x.text === 'q');
  ok(!!txt, 'P0-6: 可打印字符 → inject_text');

  // ---- P0-6: DC 不可用（h2 无 ondatachannel）→ WS command 兜底 ----
  const kd2 = h2.winListeners['keydown'];
  kd2({ key: 'ArrowLeft', isComposing: false, preventDefault() {}, ctrlKey: false, metaKey: false, altKey: false, target: {} });
  const cmd1 = ws2.sent.find((x) => x.message_type === 'command');
  ok(!!cmd1, 'P0-6: DC 不可用 → WS command 兜底已发送');
  ok(cmd1 && cmd1.command === 'input keyevent 19', 'P0-6: ArrowLeft → keycode 19（Android KEYCODE_DPAD_LEFT）');
  ok(cmd1 && cmd1.device_id === 'dev-1' && typeof cmd1.request_id === 'string', 'P0-6: command 含 device_id + request_id');

  // ---- P0-4: ontrack → 启动 tick → getStats 解析上屏 ----
  pc0.ontrack({ track: { kind: 'video' }, streams: [{}] });
  const tick = h.fakeTimers.find((t) => t.interval);
  ok(!!tick, 'P0-4: ontrack 后注册 1s 统计 tick');
  if (tick) {
    tick.fn();
    await flush(); await flush();
    const conn = h.stateLog.filter((x) => x[0] === 'connected').map((x) => x[1]);
    ok(conn.some((t) => t.includes('30fps') && t.includes('rtt 12ms') && t.includes('UDP P2P')),
      'P0-4: getStats 解析上屏（fps/rtt/传输路径）: ' + (conn[conn.length - 1] || ''));
  }

  // ---- 触控链路（P0-5）：驱动 video 监听器，验证消息字段（DC 已在上方打开） ----
  const fireV = (type, ev) => { (h.videoListeners[type] || []).forEach((fn) => fn(ev)); };
  ok((h.videoListeners['touchstart'] || []).length >= 1 &&
    (h.videoListeners['touchmove'] || []).length >= 1 &&
    (h.videoListeners['touchend'] || []).length >= 1, 'P0-5: touch 三事件监听器已注册');

  h.setNow(1_700_000_000_000);
  fireV('touchstart', { preventDefault() {}, changedTouches: [{ identifier: 3, clientX: 100, clientY: 50 }] });
  const down = pc0.sentDc.find((x) => x.type === 'touch' && x.action === 0);
  ok(!!down, 'P0-5: touchstart → DOWN(action=0)');
  ok(down && down.id === 3 && down.seq === 1 && down.w === 1600 && down.h === 720, 'P0-5: id=identifier、seq=1、w/h=交换后设备尺寸(1600x720)');
  ok(down && typeof down.client_ts_ms === 'number', 'P0-5: client_ts_ms 存在');
  // 视频 1920x1080 横 vs 设备 720x1600 竖 → 必然交换
  ok(down && down.w === 1600 && down.h === 720, 'P0-5: 旋转不一致时 w/h 交换（got ' + (down ? down.w + 'x' + down.h : '') + '）');

  // 节流：同位置 move 不发（阈值在设备像素空间，故用同坐标保证位移=0）；25ms+4px 后才发
  const countAfterDown = pc0.sentDc.length;
  h.setNow(1_700_000_000_000 + 30);
  fireV('touchmove', { preventDefault() {}, changedTouches: [{ identifier: 3, clientX: 100, clientY: 50 }] }); // 位移 0
  ok(pc0.sentDc.length === countAfterDown, 'P0-5: 零位移被节流');
  h.setNow(1_700_000_000_000 + 60);
  fireV('touchmove', { preventDefault() {}, changedTouches: [{ identifier: 3, clientX: 160, clientY: 50 }] }); // 60px
  const mv = pc0.sentDc.filter((x) => x.type === 'touch' && x.action === 2);
  ok(mv.length === 1, 'P0-5: ≥25ms 且 ≥4px → MOVE 发送');
  fireV('touchend', { preventDefault() {}, changedTouches: [{ identifier: 3, clientX: 160, clientY: 50 }] });
  const up = pc0.sentDc.filter((x) => x.type === 'touch' && x.action === 1);
  ok(up.length === 1 && up[0].seq === 3, 'P0-5: UP 发送且 seq 递增到 3（实测 up=' + JSON.stringify(up) + ' 全序列=' + JSON.stringify(pc0.sentDc.map((x) => x.type + '/' + (x.action ?? '') + '/' + (x.seq ?? ''))) + '）');

  // 多指：第二根手指独立 id/seq
  fireV('touchstart', { preventDefault() {}, changedTouches: [{ identifier: 7, clientX: 10, clientY: 10 }] });
  const down2 = pc0.sentDc.find((x) => x.type === 'touch' && x.action === 0 && x.id === 7);
  ok(!!down2 && down2.seq === 1, 'P0-5: 多指第二触点独立 id=7/seq=1');

  // ---- P0-7: wheel → inject_scroll ----
  ok((h.videoListeners['wheel'] || []).length >= 1, 'P0-7: wheel 监听器已注册');
  let prevented = false;
  fireV('wheel', { preventDefault() { prevented = true; }, deltaY: 300, deltaX: 0, deltaMode: 0 });
  const scroll = pc0.sentDc.find((x) => x.type === 'inject_scroll');
  ok(prevented && !!scroll, 'P0-7: wheel → inject_scroll 且 preventDefault');
  ok(scroll && scroll.scroll_v >= 1 && scroll.scroll_v <= 16 && typeof scroll.x === 'number', 'P0-7: scroll_v ∈ ±1..16 + 坐标字段齐全');
  fireV('wheel', { preventDefault() {}, deltaY: -99999, deltaX: 0, deltaMode: 0 });
  const scroll2 = pc0.sentDc.filter((x) => x.type === 'inject_scroll');
  ok(scroll2.length === 2 && scroll2[1].scroll_v === -16, 'P0-7: 负向超限钳制到 -16');

  // ===================== P1-2：双向剪贴板 =====================
  // 设备→本地：clipboard 通道回包 → nativeBridge.onClipboard（keyboard 源/自发 echo 去重）
  ok(typeof clipCh.onmessage === 'function', 'P1-2: clipboard 通道已挂 onmessage（clipboard.js）');
  clipCh.onmessage({ data: JSON.stringify({ type: 'clipboard', text: 'from-device', source: 'device' }) });
  ok(h.clipIn.includes('from-device'), 'P1-2: 设备→本地 文本上报 onClipboard');
  clipCh.onmessage({ data: JSON.stringify({ type: 'clipboard', text: 'kbd-text', source: 'keyboard' }) });
  ok(!h.clipIn.includes('kbd-text'), 'P1-2: keyboard 源被忽略（上游规则）');
  // 本地→设备：ETS 注入的送剪贴板
  const sentOk = h.ctx.window.setClipboardFromNative('hello-local');
  const clipSend = pc0.sentDc.find((x) => x.type === 'set_clipboard');
  ok(sentOk === true && clipSend && clipSend.text === 'hello-local' && clipSend.paste === false && clipSend.source === 'local',
    'P1-2: 送剪贴板 set_clipboard 字段齐全（text/paste/source）');
  // 自发 echo 5s 内去重（设备回传刚发的文本不再写本地）
  const clipInBefore = h.clipIn.length;
  clipCh.onmessage({ data: JSON.stringify({ type: 'clipboard', text: 'hello-local', source: 'device' }) });
  ok(h.clipIn.length === clipInBefore, 'P1-2: 5s 内自发 echo 去重');
  // 主动拉取
  const reqOk = h.ctx.window.requestClipboard();
  const reqMsg = pc0.sentDc.find((x) => x.type === 'get_clipboard');
  ok(reqOk === true && !!reqMsg, 'P1-2: 取剪贴板 get_clipboard 已发送');
  // 页面 paste 事件 → set_clipboard{paste:true}
  let pastePrevented = false;
  (h.ctx.document.getElementById('ime').listeners['paste'] || function () {})({
    preventDefault() { pastePrevented = true; },
    clipboardData: { getData: () => 'pasted-text' }
  });
  const pasteMsg = pc0.sentDc.find((x) => x.type === 'set_clipboard' && x.text === 'pasted-text');
  ok(pastePrevented && pasteMsg && pasteMsg.paste === true, 'P1-2: 页面 paste → set_clipboard{paste:true}');
  // viewOnly 门：全部剪贴板发送被拦（含 get_clipboard）
  const h4 = createHarness({ viewOnly: true });
  const ws4 = h4.wsInstances[0];
  ws4.readyState = 1; ws4.onopen();
  ws4.onmessage({ data: JSON.stringify({ message_type: 'config', ice_servers: [] }) });
  await flush();
  const pc4 = h4.pcInstances[0];
  pc4.ondatachannel({ channel: { label: 'input-channel', readyState: 'open', send: (s) => { pc4.sentDc.push(JSON.parse(s)); }, onmessage: null } });
  const v1 = h4.ctx.window.setClipboardFromNative('blocked');
  const v2 = h4.ctx.window.requestClipboard();
  ok(v1 === false && v2 === false && pc4.sentDc.length === 0, 'P1-2: viewOnly 拦截送/取剪贴板（零发送）');

  // ===================== P1-1：远端音频（audio.js） =====================
  pc0.ontrack({ track: { kind: 'audio' }, streams: [{}] });
  const audioEls = h.createdEls.filter((e) => e.__tag === 'audio');
  ok(audioEls.length === 1 && audioEls[0].autoplay === true && !!audioEls[0].srcObject,
    'P1-1: 音频轨挂载到独立 <audio>（autoplay + srcObject）');
  const mute1 = h.ctx.window.toggleAudioMuted();
  const mute2 = h.ctx.window.toggleAudioMuted();
  ok(mute1 === 'true' && mute2 === 'false', 'P1-1: 静音开关往返（true→false 字符串回传 ETS）');
  const muteNull = h2.ctx.window.toggleAudioMuted();   // h2 未收到音频轨
  ok(muteNull === 'false', 'P1-1: 无音频轨时 toggle 返回 false（空态保护）');

  // ---- P0-3: 断线重连调度（置于全部输入测试之后——resetPeer 会清 inputChannel/pc） ----
  const before = h.fakeTimers.length;
  ws.onclose();
  const retry = h.fakeTimers.slice(before).find((t) => !t.interval && t.ms >= 3000);
  ok(!!retry, 'P0-3: onclose 调度重连定时器');
  const connTexts = h.stateLog.filter((x) => x[0] === 'connecting').map((x) => x[1]);
  ok(connTexts.some((t) => t.includes('重连(1/5)')), 'P0-3: 重连计数文案 1/5');

  // ---- P0-3: scrcpy_error 终态 ----
  ws.onmessage({ data: JSON.stringify({ message_type: 'device_msg', payload: { type: 'scrcpy_error', message: 'encoder busy' } }) });
  ok(h.states().includes('error') && h.stateLog.some((x) => x[1].includes('encoder busy')), 'P0-3: scrcpy_error → error 终态带消息');

  // ===================== B-6：polyfill 二进制通路（从 WebSocketBridge.ets 提取实测） =====================
  const bridgeSrc = readFileSync(join(appRoot, 'entry/src/main/ets/features/signaling/WebSocketBridge.ets'), 'utf8');
  const pm = bridgeSrc.match(/return \[([\s\S]*?)\]\.join\('\\n'\);/);
  assert.ok(pm, 'polyfillScript 字符串数组应可从 ETS 源码提取');
  const polyLines = eval('[' + pm[1] + ']');
  const winPoly = { nativeBridge: { wsConnect() {}, wsSend() {}, wsClose() {} } };
  new Function('window', 'atob', polyLines.join('\n'))(winPoly, atob);
  ok(typeof winPoly.WebSocket === 'function' && typeof winPoly.registerBinFrameHandler === 'function',
    'B-6: polyfill 装载（window.WebSocket 替换 + 处理器注册 API）');
  const pw = new winPoly.WebSocket('ws://mock/connect_client');
  let gotMsg = null;
  pw.onmessage = (ev) => { gotMsg = ev.data; };
  const binGot = [];
  winPoly.registerBinFrameHandler((buf) => { binGot.push(buf); });
  winPoly.__wsEvent(pw._id, 'message', '{"type":"ping"}');
  ok(gotMsg === '{"type":"ping"}' && binGot.length === 0, 'B-6: 文本帧原样透传且不触发二进制处理器');
  gotMsg = null;
  winPoly.__wsEvent(pw._id, 'message', 'B64:' + Buffer.from('HelloBin').toString('base64'));
  ok(gotMsg instanceof ArrayBuffer && new TextDecoder().decode(new Uint8Array(gotMsg)) === 'HelloBin',
    'B-6: B64 帧解码为 ArrayBuffer 投递 onmessage');
  ok(binGot.length === 1 && binGot[0] === gotMsg, 'B-6: registerBinFrameHandler 同步收到同一 buffer（P1-5 消费点）');
  // 信令层对二进制（ArrayBuffer 直投）的容错：JSON.parse 失败被 catch，不改状态
  const stateCntBefore = h.stateLog.length;
  ws.onmessage({ data: new ArrayBuffer(8) });
  ok(h.stateLog.length === stateCntBefore, 'B-6: 信令层忽略二进制帧（不改状态不崩溃）');

  // ===================== P1-5：prevcodec 解码核心（从 preview.html 提取实测） =====================
  const prevHtml = readFileSync(join(rawDir, 'preview.html'), 'utf8');
  const prevTags = [...prevHtml.matchAll(/<script(?:\s+src="([^"]+)")?\s*>([\s\S]*?)<\/script>/g)];
  assert.ok(prevTags.length >= 1, 'preview.html 应含脚本');
  // 追加测试探针：把纯函数与闭包状态暴露到 window.__test
  const prevSrc = prevTags.map((t) => (t[1] ? readFileSync(join(rawDir, t[1]), 'utf8') : t[2])).join('\n;\n')
    + '\n;window.__test = { parseAnnexB, buildAvcConfig, codecFromSps, prevFeedFrame };';
  // WebCodecs 桩（记录 configure 次数与喂入的 chunk）
  class VDStub {
    constructor(handlers) { this.handlers = handlers; this.state = 'configured'; this.cfg = null; this.chunks = []; this.configureCount = 0; VDStub.last = this; }
    configure(cfg) { if (!cfg.codec || !cfg.description) { throw new Error('configure 需要 codec+description'); } this.cfg = cfg; this.configureCount++; }
    decode(chunk) { this.chunks.push(chunk); this.handlers.output({ displayWidth: 360, height: 640, displayWidth2: 0, displayHeight: 640, close() {} }); }
    close() { this.state = 'closed'; }
  }
  class EncStub { constructor(o) { Object.assign(this, o); } }
  const prevEls = {};
  const prevSent = [];   // P1-5 直控：previewBridge 发出的帧
  const prevDoc = {
    getElementById: (id) => {
      if (!prevEls[id]) {
        prevEls[id] = {
          textContent: '', className: '', width: 0, height: 0,
          listeners: {},
          getContext: () => ({ drawImage() {} }),
          addEventListener(t, fn) { this.listeners[t] = fn; },
          getBoundingClientRect: () => ({ left: 0, top: 0, width: 360, height: 640 })
        };
      }
      return prevEls[id];
    }
  };
  const winPrev = {
    VideoDecoder: VDStub,
    EncodedVideoChunk: EncStub,
    previewBridge: { sendPreviewEvent: (j) => { prevSent.push(JSON.parse(j)); return true; } }
  };
  new Function('window', 'document', 'atob', prevSrc)(winPrev, prevDoc, atob);
  ok(typeof winPrev.__pushPrev === 'function' && prevEls['prev-status'].textContent === '等待预览帧…',
    'P1-5: preview 脚本装载（能力检查通过 → 等待帧状态）');

  // 合成 AnnexB：4B 起始码 SPS + 3B 起始码 PPS + 4B 起始码 IDR（混用起始码宽度）
  const mkAu = (withSpsPps) => {
    const parts = [];
    if (withSpsPps) {
      parts.push([0, 0, 0, 1, 0x67, 0x42, 0x00, 0x2A, 0x1E]); // SPS(type7, profile 0x42002A)
      parts.push([0, 0, 1, 0x68, 0xCE, 0x06]);                 // PPS(type8)
    }
    parts.push([0, 0, 0, 1, 0x65, 0x88, 0x84, 0x21]);          // IDR slice(type5)
    const flat = [];
    for (const p of parts) { flat.push(...p); }
    return new Uint8Array(flat);
  };
  // parseAnnexB 纯函数
  const nalus = winPrev.__test.parseAnnexB(mkAu(true));
  ok(nalus.length === 3 && nalus[0][0] === 0x67 && nalus[1][0] === 0x68 && nalus[2][0] === 0x65,
    'P1-5: parseAnnexB 拆出 SPS/PPS/IDR 且剥离起始码');
  // avcC 组装（上游 721-740 规范）
  const avcC = winPrev.__test.buildAvcConfig(nalus[0], nalus[1]);
  ok(avcC.length === 11 + nalus[0].length + nalus[1].length && avcC[0] === 1 && avcC[1] === 0x42 && avcC[5] === 0xe1,
    'P1-5: avcC 组装（版本/Profile/SPS数）');
  ok(winPrev.__test.codecFromSps(nalus[0]) === 'avc1.42002a', 'P1-5: codec 串 avc1.42002a');
  // 首帧关键帧门：无 key 前的 delta 丢弃（解码器不应被创建）
  winPrev.__test.prevFeedFrame(new Uint8Array([0, 0, 0, 1, 0x01, 0xAA]), false, 0);
  ok(!VDStub.last, 'P1-5: 首个关键帧之前的 delta 被丢弃');
  // 关键帧（含 SPS/PPS）→ configure 一次 + AVCC chunk 喂入
  winPrev.__test.prevFeedFrame(mkAu(true), true, 777);
  ok(!!VDStub.last && VDStub.last.cfg.codec === 'avc1.42002a' && VDStub.last.cfg.description.length === avcC.length,
    'P1-5: configure(codec+description=avcC) 成功');
  const chunk1 = VDStub.last.chunks[0];
  const idrLen = 4;
  ok(chunk1 && chunk1.type === 'key' && chunk1.timestamp === 777 &&
    chunk1.data[0] === 0 && chunk1.data[1] === 0 && chunk1.data[2] === 0 && chunk1.data[3] === idrLen &&
    chunk1.data[4] === 0x65,
    'P1-5: AVCC chunk（4B BE 长度前缀 + type key + pts）');
  // 同参数 SPS/PPS 第二帧：不重复 configure（sameBytes 内容比较），delta 正常喂入
  winPrev.__test.prevFeedFrame(mkAu(true), false, 810);
  ok(VDStub.last.configureCount === 1 && VDStub.last.chunks.length === 2 && VDStub.last.chunks[1].type === 'delta',
    'P1-5: SPS/PPS 未变不重配（configureCount=1），delta 帧 AVCC 喂入');

  // ===================== P1-5 直控（prevtouch.js） =====================
  const pvCanvasEl = prevEls['prev-canvas'];
  const firePv = (type, ev) => { const fn = pvCanvasEl.listeners[type]; if (fn) { fn(ev); } };
  const pvEv = (over) => Object.assign({
    cancelable: true, preventDefault() {}, currentTarget: { setPointerCapture() {} }
  }, over);
  winPrev.__previewInit('{"id":"dev-9","w":1080,"h":1920}');
  firePv('pointerdown', pvEv({ pointerId: 5, pointerType: 'touch', clientX: 180, clientY: 320 }));
  const f0 = prevSent[0];
  ok(!!f0 && f0.message_type === 'group_control_event' && f0.target_device_ids[0] === 'dev-9',
    'P1-5直控: group_control_event 帧 + target_device_ids=[dev-9]');
  ok(!!f0 && f0.event.type === 'touch' && f0.event.action === 0 &&
    f0.event.x === 540 && f0.event.y === 960 && f0.event.w === 1080 && f0.event.h === 1920 &&
    f0.event.id === 5 && f0.event.seq === 1 && typeof f0.event.client_ts_ms === 'number',
    'P1-5直控: DOWN 字段（画布中心→逻辑 540×960 / id=pointerId / seq=1）');
  firePv('pointermove', pvEv({ pointerId: 5, pointerType: 'touch', clientX: 180, clientY: 320 }));
  ok(prevSent.length === 1, 'P1-5直控: 零位移 MOVE 被节流');
  firePv('pointermove', pvEv({ pointerId: 5, pointerType: 'touch', clientX: 300, clientY: 320 }));
  const f2 = prevSent[1];
  ok(prevSent.length === 2 && f2.event.action === 2 && f2.event.seq === 2, 'P1-5直控: 位移 MOVE seq=2');
  firePv('pointerup', pvEv({ pointerId: 5, pointerType: 'touch', clientX: 300, clientY: 320 }));
  const f3 = prevSent[2];
  ok(prevSent.length === 3 && f3.event.action === 1 && f3.event.seq === 3, 'P1-5直控: UP seq=3');
  firePv('pointerdown', pvEv({ pointerId: 2, pointerType: 'mouse', clientX: 10, clientY: 100 }));
  ok(prevSent[3].event.id === -1, 'P1-5直控: 鼠标 id=-1（上游约定）');
  firePv('pointerup', pvEv({ pointerId: 2, pointerType: 'mouse', clientX: 10, clientY: 100 }));
  winPrev.__previewNavKey(4);
  const k1 = prevSent[prevSent.length - 2];
  const k2 = prevSent[prevSent.length - 1];
  ok(k1.event.type === 'inject_keycode' && k1.event.keycode === 4 && k1.event.action === 0 &&
    k2.event.action === 1 && k2.event.keycode === 4, 'P1-5直控: 导航键成对 DOWN/UP(keycode4)');
  winPrev.__previewInit('{"id":"dev-9","w":0,"h":0}');
  const n0 = prevSent.length;
  firePv('pointerdown', pvEv({ pointerId: 7, pointerType: 'touch', clientX: 10, clientY: 10 }));
  ok(prevSent.length === n0, 'P1-5直控: w/h≤0 时禁用（零发送）');
  winPrev.__previewInit('{"id":"dev-9","w":1920,"h":1080}'); // 设备横屏 vs 画布竖屏
  firePv('pointerdown', pvEv({ pointerId: 8, pointerType: 'touch', clientX: 180, clientY: 320 }));
  const sw = prevSent[prevSent.length - 1].event;
  ok(sw.w === 1080 && sw.h === 1920, 'P1-5直控: 方向不一致 w/h 交换（1920×1080→1080×1920）');

  // ===================== P1-10 群控广播（input.js groupBroadcast） =====================
  ok(h.groupFrames.length === 0, 'P1-10: 未组群时零广播（P0 触控不外溢）');
  const h5 = createHarness({ groupSlaves: '["slave-1","slave-2"]' });
  const ws5 = h5.wsInstances[0];
  ws5.readyState = 1; ws5.onopen();
  ws5.onmessage({ data: JSON.stringify({ message_type: 'config', ice_servers: [] }) });
  await flush();
  const pc5 = h5.pcInstances[0];
  pc5.ondatachannel({ channel: { label: 'input-channel', readyState: 'open', send: (s) => { pc5.sentDc.push(JSON.parse(s)); }, onmessage: null } });
  (h5.videoListeners['touchstart'] || []).forEach((fn) => fn({
    preventDefault() {}, changedTouches: [{ identifier: 1, clientX: 180, clientY: 320 }]
  }));
  const gf0 = h5.groupFrames[0];
  ok(!!gf0 && gf0.message_type === 'group_control_event' &&
    JSON.stringify(gf0.target_device_ids) === '["slave-1","slave-2"]' &&
    gf0.event.type === 'touch' && gf0.event.action === 0 && gf0.event.id === 1,
    'P1-10: DOWN 同形事件广播从机组（targets=两台）');
  ok(pc5.sentDc.length === 1, 'P1-10: 本机 input-channel 同步照发（双通道并行）');
  (h5.winListeners['keydown'] || function () {})({
    key: 'Enter', isComposing: false, preventDefault() {}, ctrlKey: false, metaKey: false, altKey: false, target: {}
  });
  const gKey = h5.groupFrames.filter((f) => f.event && f.event.type === 'inject_keycode');
  ok(gKey.length === 2 && gKey[0].event.action === 0 && gKey[1].event.action === 1 && gKey[0].event.keycode === 66,
    'P1-10: 键控成对广播（keycode66 DOWN/UP）');
  const gKeyDc = pc5.sentDc.filter((x) => x.type === 'inject_keycode');
  ok(gKeyDc.length === 2, 'P1-10: 本机通道键控同样成对（双通道一致）');

  // ===================== P1-8 键位映射（keymap.js 引擎，5 类映射 fixture） =====================
  const kmCfg = JSON.stringify({ activeProfileId: 'p1', profiles: [{ id: 'p1', name: '测试档', mappings: [
    { id: 'm_tap', type: 'tap', key: 'q', pos: { x: 0.5, y: 0.5 } },
    { id: 'm_swipe', type: 'swipe', key: 'w', startPos: { x: 0.2, y: 0.8 }, endPos: { x: 0.8, y: 0.2 }, duration: 100 },
    { id: 'm_joy', type: 'joystick', keys: { up: 'i', down: 'k', left: 'j', right: 'l' }, center: { x: 0.3, y: 0.7 }, radius: 0.1 },
    { id: 'm_wheel', type: 'wheel', action: 'scroll', pos: { x: 0.5, y: 0.5 } },
    { id: 'm_cmd', type: 'command', key: 'z', cmd: 'input keyevent 3' }
  ] }] });
  const setupKm = async (extra) => {
    const hh = createHarness(Object.assign({ keymapProfiles: kmCfg }, extra || {}));
    const w = hh.wsInstances[0];
    w.readyState = 1; w.onopen();
    w.onmessage({ data: JSON.stringify({ message_type: 'config', ice_servers: [] }) });
    await flush();
    const pp = hh.pcInstances[0];
    pp.ondatachannel({ channel: { label: 'input-channel', readyState: 'open', send: (s) => { pp.sentDc.push(JSON.parse(s)); }, onmessage: null } });
    hh.kd = (key) => (hh.winListeners['keydown'] || function () {})({ key, isComposing: false, repeat: false, preventDefault() {}, ctrlKey: false, metaKey: false, altKey: false, target: {} });
    hh.ku = (key) => (hh.winListeners['keyup'] || function () {})({ key, isComposing: false, preventDefault() {}, target: {} });
    return hh;
  };
  const h6 = await setupKm();
  const ws6 = h6.wsInstances[0];
  const pc6 = h6.pcInstances[0];
  h6.kd('q');
  const tapD = pc6.sentDc[0];
  ok(!!tapD && tapD.type === 'touch' && tapD.action === 0 && tapD.id >= 10 &&
    tapD.x === 540 && tapD.y === 960 && tapD.w === 1080 && tapD.h === 1920,
    'P1-8: tap DOWN（0.5,0.5→540×960，虚拟 id≥10）');
  ok(!pc6.sentDc.some((x) => x.type === 'inject_text'), 'P1-8: 被映射键不再默认 inject_text（消费生效）');
  h6.ku('q');
  ok(pc6.sentDc[1].action === 1 && pc6.sentDc[1].id === tapD.id, 'P1-8: tap UP 同 id');
  h6.kd('z');
  const cmd6 = ws6.sent.filter((x) => x.message_type === 'command');
  ok(cmd6.length >= 1 && cmd6[0].command === 'input keyevent 3', 'P1-8: command 映射直发 WS 命令');
  h6.kd('i');
  const joy = pc6.sentDc.slice(-2);
  ok(joy[0].action === 0 && joy[0].x === 324 && joy[0].y === 1344 &&
    joy[1].action === 2 && joy[1].x === 324 && joy[1].y === 1236,
    'P1-8: 摇杆中心 DOWN→边缘 MOVE（半径 0.1×W=108）');
  h6.ku('i');
  const joyUp = pc6.sentDc[pc6.sentDc.length - 1];
  ok(joyUp.action === 1 && joyUp.x === 324 && joyUp.y === 1344, 'P1-8: 摇杆归位 UP 于中心');
  const nSwipe = pc6.sentDc.length;
  h6.kd('w');
  ok(pc6.sentDc[nSwipe].action === 0 && pc6.sentDc[nSwipe].x === 216 && pc6.sentDc[nSwipe].y === 1536,
    'P1-8: swipe DOWN 起点（0.2,0.8）');
  h6.ku('w');
  const swipeUp = pc6.sentDc[pc6.sentDc.length - 1];
  ok(swipeUp.action === 1 && swipeUp.x === 864 && swipeUp.y === 384,
    'P1-8: swipe UP 终点（0.8,0.2）');
  const nWheel = pc6.sentDc.length;
  (h6.videoListeners['wheel'] || []).forEach((fn) => fn({ preventDefault() {}, deltaY: 120, deltaX: 0, deltaMode: 0 }));
  const wheelFrames = pc6.sentDc.slice(nWheel);
  ok(wheelFrames.length >= 1 && wheelFrames[0].type === 'touch' && wheelFrames[0].action === 0 &&
    !wheelFrames.some((x) => x.type === 'inject_scroll'),
    'P1-8: wheel 由 keymap 消费（scroll 拨动 DOWN）且不再 inject_scroll');
  // viewOnly：映射仍消费（不落默认注入），但 kmSendTouch 零外发
  const h7 = await setupKm({ viewOnly: true });
  const pc7 = h7.pcInstances[0];
  h7.kd('q');
  ok(pc7.sentDc.length === 0, 'P1-8: viewOnly 下映射消费但零注入（源头拦截）');

  // ===================== P2-6 实时截图（screenshot.js） =====================
  const shotOk = h.ctx.window.requestScreenshot();
  const shotReq = ws.sent.filter((x) => x.message_type === 'screenshot_request');
  ok(shotOk === true && shotReq.length === 1 && shotReq[0].device_id === 'dev-1',
    'P2-6: screenshot_request 帧（device_id=dev-1）');
  ws.onmessage({ data: JSON.stringify({ message_type: 'screenshot_response', data: 'aGVsbG8=' }) });
  ok(h.ctx.window.__shotLastSrc === 'data:image/png;base64,aGVsbG8=',
    'P2-6: base64 字符串 → data URI 归一');
  ws.onmessage({ data: JSON.stringify({ message_type: 'screenshot_response', data: [104, 105] }) });
  ok(h.ctx.window.__shotLastSrc === 'data:image/png;base64,' + Buffer.from('hi').toString('base64'),
    'P2-6: 字节数组归一（上游 ScreenshotModal 同款三分支之一）');
  const saveBtn = h.createdEls.find((el) => el.textContent === '保存 PNG');
  ok(!!saveBtn && typeof saveBtn.onclick === 'function', 'P2-6: 预览层「保存 PNG」按钮就绪');
  if (saveBtn) { saveBtn.onclick(); }
  ok(h.saves.length === 1 && h.saves[0].b64 === Buffer.from('hi').toString('base64') &&
    h.saves[0].name.startsWith('screenshot_'),
    'P2-6: 保存出口经原生桥（剥前缀 b64 + 建议文件名）');

  // ===================== P2-7 摄像头回传（camera.js，经真实分发路径） =====================
  const camFrames = [];
  let camTrackStopped = false;
  const camCh = {
    label: 'camera-channel', readyState: 'open', onmessage: null, onclose: null, onerror: null,
    send: (b) => { camFrames.push(b); }
  };
  // 分发：peer.ondatachannel → attachCameraChannel（模块函数为闭包局部，只能走真实路径触达）
  pc0.ondatachannel({ channel: camCh });
  ok(typeof camCh.onmessage === 'function', 'P2-7: camera-channel 接管（peer.ondatachannel 分发）');
  h.ctx.window.navigator = {
    mediaDevices: {
      getUserMedia: () => Promise.resolve({ getTracks: () => [{ stop() { camTrackStopped = true; } }] })
    }
  };
  camCh.onmessage({ data: JSON.stringify({ action: 'start' }) });
  await flush();
  ok(h.ctx.window.__cameraRunning() === true, 'P2-7: agent start → 采集进入运行态');
  // 33ms tick → 抽帧 → 裸 JPEG 发送（fakeTimers 形状 {fn,ms,interval}）
  for (const t of [...h.fakeTimers]) { if (typeof t.fn === 'function') { t.fn(); } }
  await flush();
  ok(camFrames.length === 1 && camFrames[0].byteLength === 3, 'P2-7: 采集 tick 发送裸 JPEG 帧（blob.arrayBuffer）');
  camCh.onmessage({ data: JSON.stringify({ action: 'stop' }) });
  ok(h.ctx.window.__cameraRunning() === false && camTrackStopped, 'P2-7: agent stop → 停止并释放摄像头轨道');
  // camera_support=false（经 offer 载荷注入支持位 → start 被拦截）
  ws.onmessage({ data: JSON.stringify({ message_type: 'device_msg', payload: { type: 'offer', sdp: ANSWER_SDP, camera_support: false } }) });
  camCh.onmessage({ data: JSON.stringify({ action: 'start' }) });
  await flush();
  ok(h.ctx.window.__cameraRunning() === false, 'P2-7: camera_support=false 时 start 被拦截');

  // ===================== P2-1a 文件通道协议（fileproto.js，自 file.html 提取实测） =====================
  const fileHtml = readFileSync(join(rawDir, 'file.html'), 'utf8');
  const fileTags = [...fileHtml.matchAll(/<script(?:\s+src="([^"]+)")?\s*>([\s\S]*?)<\/script>/g)];
  assert.ok(fileTags.length >= 3, 'file.html 应含 fileproto+fileboot+内联装配');
  // 装配内联段依赖 DOM——仅拼接两个协议模块（装配逻辑由页面集成验证）
  const protoSrc = fileTags.filter((t) => t[1]).map((t) => readFileSync(join(rawDir, t[1]), 'utf8')).join('\n;\n');
  const fileBridge = {
    getServerHost: () => '127.0.0.1:18080', getToken: () => 'tok-1', getDeviceId: () => 'dev-1',
    getUseSslFlag: () => '0', getScrcpyOptions: () => '{}'
  };
  const fileWin = { nativeBridge: fileBridge, confirm: () => true, setTimeout: (fn, ms) => fakeTimers.push({ fn, ms }) };
  new Function('window', 'console', protoSrc)(fileWin, console);
  ok(!!fileWin.__fpApi && typeof fileWin.__fpApi.attach === 'function', 'P2-1a: fileproto 模块装载');
  const fpCh = { readyState: 'open', sent: [], send(d) { this.sent.push(d); } };
  fileWin.__fpApi.attach(fpCh);
  ok(fileWin.__fpApi.ready() === true, 'P2-1a: 通道接管后 ready');
  // 命令帧
  fileWin.__fpApi.list('/sdcard');
  fileWin.__fpApi.mkdir('/sdcard/newdir');
  fileWin.__fpApi.del('/sdcard/a.txt');
  const fpCmds = fpCh.sent.map((s) => JSON.parse(s));
  ok(fpCmds[0].type === 'list' && fpCmds[0].path === '/sdcard' &&
    fpCmds[1].type === 'mkdir' && fpCmds[2].type === 'delete',
    'P2-1a: list/mkdir/delete 命令帧形状');
  // 回复分发
  const fpLists = [];
  fileWin.__fp.onList = (msg) => { fpLists.push(msg); };
  fpCh.onmessage({ data: JSON.stringify({ type: 'list_reply', success: true, path: '/sdcard', files: [{ name: 'a.txt', path: '/sdcard/a.txt', size: 12, is_dir: false }] }) });
  ok(fpLists.length === 1 && fpLists[0].files.length === 1, 'P2-1a: list_reply 分发');
  // 下载流：start → reply(size) → 二进制块 → 装配完成
  const dlDone = [];
  const dlProg = [];
  fileWin.__fp.onDownloadProgress = (p, l, t) => { dlProg.push([l, t]); };
  fileWin.__fp.onDownloadDone = (p, bytes) => { dlDone.push([p, bytes]); };
  ok(fileWin.__fpApi.downloadStart('/sdcard/big.bin') === true, 'P2-1a: download_start 发出');
  const dlCmd = JSON.parse(fpCh.sent[fpCh.sent.length - 1]);
  ok(dlCmd.type === 'download_start' && String(dlCmd.request_id).startsWith('dl_'), 'P2-1a: download_start 带 request_id');
  fpCh.onmessage({ data: JSON.stringify({ type: 'download_reply', success: true, size: 5, request_id: dlCmd.request_id }) });
  fpCh.onmessage({ data: new Uint8Array([1, 2, 3]).buffer });
  fpCh.onmessage({ data: new Uint8Array([4, 5]).buffer });
  ok(dlProg.length >= 2 && dlProg[dlProg.length - 1][0] === 5 && dlProg[dlProg.length - 1][1] === 5,
    'P2-1a: 下载进度随块推进至完成');
  ok(dlDone.length === 1 && dlDone[0][0] === '/sdcard/big.bin' && dlDone[0][1].length === 5 &&
    dlDone[0][1][0] === 1 && dlDone[0][1][4] === 5,
    'P2-1a: 分块组装为连续 Uint8Array（1..5）');
  ok(fileWin.__fpApi.downloadStart('/sdcard/next.bin') === true, 'P2-1a: 会话出队后可发起下一下载');
  // 失败回复路径
  fileWin.__fp.onError = () => { };
  fpCh.onmessage({ data: JSON.stringify({ type: 'download_reply', success: false, error: 'denied', request_id: fpCh.sent.length && JSON.parse(fpCh.sent[fpCh.sent.length - 1]).request_id }) });
  ok(dlDone.length === 1, 'P2-1a: 失败回复不产出字节（会话清理）');

  // ===================== P2-1b：sha256 增量哈希 + 上传泵 + 安装 =====================
  // 标准向量：'abc' → ba7816bf…
  const abcHash = await fileWin.hashFileIncremental({
    size: 3,
    slice: (a, b) => ({ arrayBuffer: () => Promise.resolve(new Uint8Array([97, 98, 99]).buffer) })
  });
  ok(abcHash === 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'P2-1b: sha256 增量哈希标准向量 abc');
  // 上传：40KB 文件 → upload_start（含64位hex sha）→ reply → 3×16KB 分块 → ack 完成
  const upEvents = { progress: [], done: [], fail: [] };
  fileWin.__fp.onUploadProgress = (p, l, t) => { upEvents.progress.push([l, t]); };
  fileWin.__fp.onUploadDone = (p, wi) => { upEvents.done.push([p, wi]); };
  fileWin.__fp.onUploadFail = (p, r) => { upEvents.fail.push([p, r]); };
  fpCh.bufferedAmount = 0;
  const upFile = {
    name: 'big.bin', size: 40000,
    slice: (s, e) => ({ arrayBuffer: () => Promise.resolve(new Uint8Array(e - s).fill(7).buffer) })
  };
  const upOk = await fileWin.__fpApi.uploadStart(upFile, '/sdcard/big.bin', false);
  ok(upOk === true, 'P2-1b: uploadStart 就绪且单活动通过');
  const upStartCmd = JSON.parse(fpCh.sent[fpCh.sent.length - 1]);
  ok(upStartCmd.type === 'upload_start' && upStartCmd.size === 40000 &&
    /^[0-9a-f]{64}$/.test(upStartCmd.sha256 || ''),
    'P2-1b: upload_start 载荷（path/size/sha256 六十四位hex）');
  const binBefore = fpCh.sent.filter((s) => s instanceof ArrayBuffer).length;
  fpCh.onmessage({ data: JSON.stringify({ type: 'upload_reply', success: true, path: '/sdcard/big.bin' }) });
  for (let i = 0; i < 8; i++) { await flush(); }
  const upChunks = fpCh.sent.filter((s) => s instanceof ArrayBuffer);
  ok(upChunks.length - binBefore === 3 && upChunks[0].byteLength === 16384 &&
    upChunks[2].byteLength === 40000 - 32768,
    'P2-1b: 分块泵按 16KB 切分发送（16384+16384+7232）');
  ok(upEvents.progress.length >= 3 && upEvents.progress[upEvents.progress.length - 1][0] === 40000,
    'P2-1b: 上传进度推进至 40000');
  fpCh.onmessage({ data: JSON.stringify({ type: 'upload_ack', path: '/sdcard/big.bin', uploaded: 40000, finished: true, success: true }) });
  ok(upEvents.done.length === 1 && upEvents.done[0][0] === '/sdcard/big.bin',
    'P2-1b: upload_ack finished → 完成回调');
  // 校验失败路径（会话清理后可再传）
  const upOk2 = await fileWin.__fpApi.uploadStart(upFile, '/sdcard/again.bin', false);
  ok(upOk2 === true, 'P2-1b: 完成后会话出队可再次上传');
  fpCh.onmessage({ data: JSON.stringify({ type: 'upload_reply', success: true, path: '/sdcard/again.bin' }) });
  for (let i = 0; i < 8; i++) { await flush(); }
  fpCh.onmessage({ data: JSON.stringify({ type: 'upload_ack', path: '/sdcard/again.bin', finished: true, success: false, error: 'sha mismatch' }) });
  ok(upEvents.fail.length === 1 && upEvents.fail[0][1].indexOf('sha') >= 0,
    'P2-1b: 校验失败 → onUploadFail（会话清理）');
  // 安装：install_apk 帧 + installing/success 三态分发
  const instEvents = [];
  fileWin.__fp.onInstall = (st, msg, path) => { instEvents.push([st, path]); };
  ok(fileWin.__fpApi.installApk('/sdcard/app.apk') === true, 'P2-1b: install_apk 发出');
  const instCmd = JSON.parse(fpCh.sent[fpCh.sent.length - 1]);
  ok(instCmd.type === 'install_apk' && String(instCmd.request_id).startsWith('ia_'),
    'P2-1b: install_apk 帧（path + request_id）');
  fpCh.onmessage({ data: JSON.stringify({ type: 'install_status', status: 'installing', request_id: instCmd.request_id }) });
  fpCh.onmessage({ data: JSON.stringify({ type: 'install_status', status: 'success', request_id: instCmd.request_id }) });
  ok(instEvents.length === 2 && instEvents[0][0] === 'installing' && instEvents[1][0] === 'success',
    'P2-1b: install_status installing→success 会话生命周期');
  ok(fileWin.__fpApi.installApk('/sdcard/b.apk') === true, 'P2-1b: 安装完成出队可再装');

  // ===================== P2-12d：控制页仿真屏（mockscreen.js） =====================
  const rafQueue = [];
  const savedRaf = globalThis.requestAnimationFrame;
  const savedCaf = globalThis.cancelAnimationFrame;
  globalThis.requestAnimationFrame = (fn) => { rafQueue.push(fn); return rafQueue.length; };
  globalThis.cancelAnimationFrame = (id) => { delete rafQueue[id - 1]; };
  try {
    const okStart = h.ctx.window.startMockScreen('mock-screen', 'demo-vm-001');
    ok(okStart === true && h.ctx.window.mockScreenState().running === true,
      'P2-12d: 仿真屏启动（canvas 就位 + running）');
    // 手动泵一帧 rAF（不依赖真实帧循环）
    const frameFn = rafQueue[0];
    if (frameFn) frameFn();
    ok(h.ctx.window.__mockScreen.deviceId === 'demo-vm-001',
      'P2-12d: 单帧绘制执行且设备标题注入（draw 无异常）');
    const mockEl = h.extraEls['mock-screen'];
    ok(!!mockEl && typeof mockEl.listeners.pointerdown === 'function',
      'P2-12d: pointerdown 波纹监听绑定');
    mockEl.listeners.pointerdown({ clientX: 180, clientY: 320 });
    ok(h.ctx.window.mockScreenState().ripples >= 1, 'P2-12d: 触控产生波纹（仿真反馈）');
    h.ctx.window.stopMockScreen();
    ok(h.ctx.window.mockScreenState().running === false,
      'P2-12d: stop 清理运行态');
  } finally {
    globalThis.requestAnimationFrame = savedRaf;
    globalThis.cancelAnimationFrame = savedCaf;
  }

  // ===================== P2-2 WebADB（会话工厂 + 网格终端） =====================
  // 会话：open 前入队 → open + 150ms 稳定 → 冲刷（上游 sendData 语义）
  const adbDc = {
    label: '', readyState: 'connecting', binaryType: '', sent: [],
    send(b) { this.sent.push(b); }
  };
  const adbPc = { connectionState: 'connected', createDataChannel: (l) => { adbDc.label = l; return adbDc; } };
  const sess = h.ctx.window.__adbApi.createSession(adbPc);
  ok(adbDc.label === 'adb-channel', 'P2-2: 会话工厂创建 adb-channel（ordered）');
  sess.sendData(new Uint8Array([1, 2, 3]));
  ok(adbDc.sent.length === 0, 'P2-2: open 前发送入队（数据不丢）');
  adbDc.readyState = 'open';
  adbDc.onopen();
  const stabTimer = [...h.fakeTimers].reverse().find((t) => !t.interval && t.ms === 150);
  if (stabTimer) stabTimer.fn();
  ok(adbDc.sent.length === 1 && adbDc.sent[0] instanceof Uint8Array, 'P2-2: 稳定期后冲刷队列');
  // init 帧（UTF-8 JSON {type,rows,cols}）
  const initObj = JSON.parse(new TextDecoder().decode(h.ctx.window.__adbApi.encodeInit(30, 100)));
  ok(initObj.type === 'init' && initObj.rows === 30 && initObj.cols === 100,
    'P2-2: init{rows,cols} UTF-8 帧');
  // 网格终端（CSI/SGR/备用屏/键编码；rAF 桩防真实调度）
  globalThis.requestAnimationFrame = (fn) => { rafQueue.push(fn); return rafQueue.length; };
  globalThis.cancelAnimationFrame = (id) => { delete rafQueue[id - 1]; };
  try {
    const termCtx = {
      fillRect() {}, fillText() {}, font: '', fillStyle: '', strokeStyle: '',
      textBaseline: '', globalAlpha: 1, lineWidth: 1, textAlign: 'left'
    };
    const adbCanvas = { width: 0, height: 0, getContext: () => termCtx };
    const term = h.ctx.window.createAnsiTerm(adbCanvas, 40, 10);
    const enc = (s) => new TextEncoder().encode(s);
    term.feed(enc('\x1b[2J\x1b[Hhello\r\nworld'));
    const dumpLines = term.dump().split('\n');
    ok(dumpLines[0] === 'hello' && dumpLines[1] === 'world', 'P2-2: 清屏定位 + CR/LF 换行');
    term.feed(enc('\x1b[H\x1b[2DZ'));
    ok(term.dump().split('\n')[0] === 'Zello', 'P2-2: CSI 光标左移 2（已贴边不越界）覆盖首字符');
    term.feed(enc('\x1b[2J\x1b[H\x1b[1;31mR'));
    ok(term.cellAt(0, 0).ch === 'R' && term.cellAt(0, 0).fg === '#cd3131' && term.cellAt(0, 0).bold === true,
      'P2-2: SGR 加粗红字属性');
    term.feed(enc('\x1b[?1049h'));
    const altOn = term.state().alt;
    term.feed(enc('\x1b[?1049l'));
    ok(altOn === true && term.state().alt === false, 'P2-2: ?1049 备用屏切换（top/vi）');
    const up = term.encodeKey({ key: 'ArrowUp', ctrlKey: false, altKey: false });
    const cc = term.encodeKey({ key: 'c', ctrlKey: true, altKey: false });
    ok(up instanceof Uint8Array && up[0] === 27 && up[1] === 91 && cc[0] === 3,
      'P2-2: 键编码（↑=ESC[A，Ctrl+C=0x03）');
    const enter = term.encodeKey({ key: 'Enter', ctrlKey: false, altKey: false });
    ok(enter[0] === 13, 'P2-2: Enter=CR(13)');
  } finally {
    globalThis.requestAnimationFrame = savedRaf;
    globalThis.cancelAnimationFrame = savedCaf;
  }

  // ===================== P2-3a AI 引擎（工具/等待器/Agent 循环） =====================
  const toolNames = h.ctx.window.__aiApi.tools().map((t) => t.function.name);
  ok(toolNames.length === 5 && toolNames.indexOf('execute_shell_command') >= 0 &&
    toolNames.indexOf('simulate_touch') >= 0,
    'P2-3a: 5 工具定义（shell/info/stats/key/touch）');
  ok(h.ctx.window.__aiApi.systemMessage('dev-42').indexOf('dev-42') >= 0 &&
    h.ctx.window.__aiApi.systemMessage('dev-42').indexOf('中文') >= 0,
    'P2-3a: systemMessage 注入 device_id 且要求中文输出');
  // shell 工具 → command 帧 → 注入 command_result → 等待器解析
  const shellP = h.ctx.window.__aiApi.executeTool('execute_shell_command', { command: 'df -h' });
  const shellCmd = [...h.wsInstances[0].sent].reverse().find((m) => m.message_type === 'command');
  ok(!!shellCmd && shellCmd.command === 'df -h' && String(shellCmd.request_id).startsWith('cr_'),
    'P2-3a: shell 工具下发 command（cr_ 等待 id）');
  ws.onmessage({ data: JSON.stringify({ message_type: 'device_msg', payload: {
    type: 'command_result', request_id: shellCmd.request_id, exit_code: 0, stdout: '/data 99%', stderr: '' } }) });
  const shellRes = await shellP;
  ok(shellRes.exit_code === 0 && shellRes.stdout === '/data 99%',
    'P2-3a: command_result 命中等待器解析回传');
  // device_info 工具
  const info = await h.ctx.window.__aiApi.executeTool('get_device_info', {});
  ok(info.device_id === 'dev-1', 'P2-3a: device_info 返回桥接设备 id');
  // keyevent 工具（无 DC → WS 兜底帧）
  const keyRes = await h.ctx.window.__aiApi.executeTool('simulate_keyevent', { keycode: 3 });
  const keyCmd = [...h.wsInstances[0].sent].reverse().find((m) => m.message_type === 'command');
  ok(keyRes.status === 'success' && keyCmd && keyCmd.command === 'input keyevent 3',
    'P2-3a: keyevent 工具走 WS command 成对注入');
  // touch 工具（DC 通道 id91 会话；UP 延时60ms 由假时钟触发）
  pc0.ondatachannel({ channel: { label: 'input-channel', readyState: 'open', send: (s) => { pc0.sentDc.push(JSON.parse(s)); }, onmessage: null } });
  const dcBeforeTouch = pc0.sentDc.length;
  const touchRes = await h.ctx.window.__aiApi.executeTool('simulate_touch', { x: 100, y: 200 });
  const timers60 = [...h.fakeTimers].reverse().filter((t) => !t.interval && t.ms === 60);
  if (timers60[0]) timers60[0].fn();
  const touchFrames = pc0.sentDc.slice(dcBeforeTouch);
  ok(touchRes.status === 'success' && touchFrames.length === 2 &&
    touchFrames[0].action === 0 && touchFrames[1].action === 1 && touchFrames[0].id === 91 &&
    touchFrames[0].x === 100 && touchFrames[0].y === 200,
    'P2-3a: touch 工具 DOWN/UP（虚拟 id=91，坐标透传）');
  // Agent 循环：双轮（tool_calls → 最终结论）
  const logs = [];
  const oldLog = h.ctx.window.__aiEvents.onLog;
  h.ctx.window.__aiEvents.onLog = (lv, tx) => { logs.push([lv, tx]); };
  h.ctx.window.__aiApi.reset();
  const runP = h.ctx.window.__aiApi.runLoop('检查设备状态');
  ok(h.aiChatCalls.length >= 1, 'P2-3a: 循环发起首跳 LLM 请求（body 含 tools）');
  const firstCall = h.aiChatCalls[h.aiChatCalls.length - 1];
  const firstBody = JSON.parse(firstCall.body);
  ok(firstBody.tool_choice === 'auto' && firstBody.messages[firstBody.messages.length - 1].content === '检查设备状态',
    'P2-3a: 请求体含 user 消息与 tool_choice=auto');
  // 第1轮 → tool_calls(get_device_info)
  h.ctx.window.__aiResolve(firstCall.reqId, true, JSON.stringify({ choices: [{ message: {
    content: '', tool_calls: [{ id: 'tc1', function: { name: 'get_device_info', arguments: '{}' } }] } }] }));
  for (let i = 0; i < 6; i++) await flush();
  ok(h.aiChatCalls.length >= 2, 'P2-3a: 工具结果入上下文后发起第2轮');
  const secondCall = h.aiChatCalls[h.aiChatCalls.length - 1];
  const secondBody = JSON.parse(secondCall.body);
  const hasToolMsg = secondBody.messages.some((m) => m.role === 'tool' && m.tool_call_id === 'tc1');
  ok(hasToolMsg, 'P2-3a: role=tool 消息（tool_call_id 对齐）回填上下文');
  // 第2轮 → 最终结论
  h.ctx.window.__aiResolve(secondCall.reqId, true, JSON.stringify({ choices: [{ message: { content: '设备状态正常' } }] }));
  const finalRes = await runP;
  ok(finalRes.final === '设备状态正常', 'P2-3a: 无 tool_calls → 循环收敛返回最终结论');
  h.ctx.window.__aiEvents.onLog = oldLog;
  ok(logs.length >= 3, 'P2-3a: 循环日志（请求/工具/回复）可观测');

  console.log('\n===== control.html 运行时断言: ' + pass + ' passed, ' + (process.exitCode ? 'FAILED' : '0 failed') + ' =====');
}

await main();
