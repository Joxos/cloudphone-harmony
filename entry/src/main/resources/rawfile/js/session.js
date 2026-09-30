/**
 * session.js —— 会话共享状态与 ETS 桥参数读取
 *
 * 职责（单一）：存放控制页跨模块共享的会话变量与 DOM 引用；
 *              提供 native() 读取 ETS javaScriptProxy 注入参数。
 * 依赖：无（必须最先加载）。消费方：state/peer/stats/input/signaling。
 * 协议背景；桥接口见 pages/ArkWebView.ets methodList。
 * 加载顺序：session → state → stats → clipboard → audio → camera → peer → keymap → input → ai → screenshot → mockscreen → ansiterm → adbproto → signaling → boot(start)
 */
'use strict';

// ---------- DOM 引用（control.html 视图层元素） ----------
/** 远端视频渲染元素（object-fit: contain，触控坐标换算的基准矩形） */
var video = document.getElementById('video');
/** 页面左上角状态徽标文本 */
var statusEl = document.getElementById('status');
/** 居中加载提示（首帧状态后隐藏） */
var hintEl = document.getElementById('hint');
/** IME 隐藏输入框（输入法组合 → inject_text） */
var imeEl = document.getElementById('ime');

// ---------- 信令与媒体会话状态 ----------
/** 信令 WebSocket（经 documentStart polyfill 桥接至原生 webSocket 模块） */
var ws = null;
/** RTCPeerConnection 实例（P2P 媒体与 DataChannel 载体） */
var pc = null;
// ICE 服务器仅来自被控端 config 消息（ice_servers，通常为其自带的 STUN/TURN）；
// 不预置任何第三方 STUN —— 局域网 host candidate 直连无需 STUN，跨网段由被控端 TURN 中转。
/** 由信令 config 消息下发的 ICE 服务器列表 */
var iceServers = [];
/** 被控端反向创建的 input-channel（触控/按键/滚动注入通道） */
var inputChannel = null;
/** 被控端反向创建的 clipboard-channel（双向剪贴板） */
var clipboardChannel = null;
/** 当前设备 ID（信令 connect 首帧与 WS command 兜底均需要） */
var curDevId = '';
/** 设备逻辑分辨率（device_info.displays 下发；触控坐标基准） */
var deviceW = 1080, deviceH = 1920;
/** 远端音频轨承载元素（懒创建，声音与静音的 video 分离） */
var audioEl = null;

// ---------- ICE 策略（P0-8；connectionPath/ipPreference 当前 auto=不过滤/全候选，
//      P1 设置页接入后可切 direct/relay、ipv4/ipv6——机制与上游 shouldKeepCandidate 对齐） ----------
/** ICE 连接偏好：ipPreference=auto|ipv4|ipv6，connectionPath=auto|direct|relay */
var icePrefs = { ipPreference: 'auto', connectionPath: 'auto' };
/** 本地候选样本（failed 时供 diagnose() 分析） */
var localCands = [];
/** 远端候选样本（failed 时供 diagnose() 分析） */
var remoteCands = [];

// ---------- P0-12 访客分享 ----------
/** 只读访客模式：true 时全部注入在源头拦截 */
var viewOnly = false;
/** 分享卡密（连接串 ?share_token=；存在时不用 login token） */
var shareToken = '';
/** 分享访问密码（?share_pwd=，可空） */
var sharePwd = '';

/**
 * 读取 ETS javaScriptProxy 注入的同步参数。
 * @param name 桥方法名（见 ArkWebView.ets methodList）
 * @param fallback 桥缺失/返回空时的回退值
 * @returns 桥方法返回值（字符串），异常一律回退 fallback
 */
function native(name, fallback) {
  try {
    if (window.nativeBridge && typeof window.nativeBridge[name] === 'function') {
      var v = window.nativeBridge[name]();
      if (v) return v;
    }
  } catch (e) {}
  return fallback || '';
}
