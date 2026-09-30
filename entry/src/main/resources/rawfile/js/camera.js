/**
 * camera.js —— 摄像头回传（P2-7，对应上游 useWebRTC.startCameraStreaming 1467-1546）
 *
 * 职责（单一）：camera-channel 接管与 agent start/stop 指令处理、本地采集循环
 *   （getUserMedia 640×480@30 → 离屏 canvas → toBlob(jpeg 0.6) → **裸 JPEG 帧**逐帧发送）、
 *   停止与资源清理（定时器 + 流轨道）。
 * 触发方向：仅 agent 侧发起（设备端摄像头场景）；cameraSupport 来自 offer payload.camera_support
 *   （signaling.handleFwd 注入）。
 * 依赖：peer.js ondatachannel 分发（attachCameraChannel）、CAMERA 权限（module.json5 user_grant）、
 *   安全上下文（ArkWeb rawfile 满足）。
 * 与上游差异：options.camera 用户开关未接（恒允许）——列设置项后续；toBlob 分片直发
 *   （弃 FileReader 中转，blob.arrayBuffer 等价且更短）。
 */
'use strict';

/** agent 建立的反向通道（open 时机不定，发送处均做 readyState 检查） */
var cameraChannel = null;
/** 本地视频流与采集定时器 */
var cameraStream = null;
var cameraTimer = -1;
/** 设备是否支持摄像头注入（offer payload.camera_support 注入） */
var cameraSupport = true;
/** 采集运行态（测试观察 + 状态展示预留） */
var cameraRunning = false;

/** offer 载荷注入支持位（signaling.handleFwd 调用） */
function setCameraSupport(supported) {
  cameraSupport = supported !== false;
}

/**
 * camera-channel 接管（peer.ondatachannel 分发调用，对齐上游同名分支）：
 * 控制消息 {action:'start'|'stop'}（文本或二进制 JSON），其余忽略。
 */
function attachCameraChannel(ch) {
  stopCameraStreaming();
  cameraChannel = ch;
  ch.onmessage = function (ev) {
    var dataStr = ev.data;
    if (dataStr instanceof ArrayBuffer) {
      try {
        dataStr = new TextDecoder().decode(dataStr);
      } catch (e) {
        return;
      }
    }
    try {
      var msg = JSON.parse(dataStr);
      if (msg.action === 'start') {
        startCameraStreaming();
      } else if (msg.action === 'stop') {
        stopCameraStreaming();
      }
    } catch (e) {
      // 非控制消息忽略
    }
  };
  ch.onclose = function () {
    stopCameraStreaming();
    cameraChannel = null;
  };
  ch.onerror = function () {
    stopCameraStreaming();
  };
}

/**
 * 开始采集推流（上游逐段对齐：参数/隐藏 video/canvas 抽帧 30fps/jpeg 0.6）。
 * @returns true=已进入采集循环
 */
function startCameraStreaming() {
  if (!cameraSupport) {
    console.warn('[Camera] 设备不支持摄像头注入（camera_support=false），忽略 start');
    return false;
  }
  stopCameraStreaming();
  var nav = window.navigator;
  if (!nav || !nav.mediaDevices || !nav.mediaDevices.getUserMedia) {
    console.warn('[Camera] getUserMedia 不可用（需安全上下文与权限）');
    return false;
  }
  nav.mediaDevices.getUserMedia({
    video: {
      width: 640,
      height: 480,
      frameRate: 30,
      facingMode: { ideal: 'environment' }
    }
  }).then(function (stream) {
    cameraStream = stream;
    var video = document.createElement('video');
    video.autoplay = true;
    video.playsInline = true;
    video.muted = true;
    video.srcObject = stream;
    var playOk = video.play();
    if (playOk && typeof playOk.catch === 'function') {
      playOk.catch(function () { /* 静默（隐藏 video 播放常见拒绝） */ });
    }
    var canvas = document.createElement('canvas');
    canvas.width = 640;
    canvas.height = 480;
    var ctx = canvas.getContext('2d');
    cameraRunning = true;
    cameraTimer = setInterval(function () {
      if (!cameraChannel || cameraChannel.readyState !== 'open') {
        stopCameraStreaming();
        return;
      }
      ctx.drawImage(video, 0, 0, 640, 480);
      canvas.toBlob(function (blob) {
        if (!blob || !cameraChannel || cameraChannel.readyState !== 'open') {
          return;
        }
        blob.arrayBuffer().then(function (buf) {
          if (cameraChannel && cameraChannel.readyState === 'open') {
            cameraChannel.send(buf); // 裸 JPEG 字节（上游同形，无额外分帧）
          }
        }).catch(function () { /* 单帧失败不中断 */ });
      }, 'image/jpeg', 0.6);
    }, 1000 / 30);
  }).catch(function (err) {
    console.warn('[Camera] 采集失败: ' + (err && err.message));
  });
  return true;
}

/** 停止采集（定时器 + 流轨道全量清理；agent stop/onclose 均会触发） */
function stopCameraStreaming() {
  if (cameraTimer !== -1) {
    clearInterval(cameraTimer);
    cameraTimer = -1;
  }
  cameraRunning = false;
  if (cameraStream) {
    try {
      cameraStream.getTracks().forEach(function (t) { t.stop(); });
    } catch (e) {
      // 忽略
    }
    cameraStream = null;
  }
}

/** 运行态观察口（测试/状态徽标预留） */
window.__cameraRunning = function () {
  return cameraRunning;
};
