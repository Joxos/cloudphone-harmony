/**
 * keymap.js —— 键位映射引擎与挂载（P1-8）
 *
 * 职责（单一）：profile 解析加载、键盘/滚轮事件消费分发、5 类映射动作合成虚拟触控
 *   （tap / swipe / joystick / wheel-scroll / wheel-zoom + command 直发 WS）。
 * 移植来源（v0.3.8 上游逐段对照）：
 *   utils/keymapEngine.js（类与动作语义）、stores/keymap.js（config schema：activeProfileId+profiles）
 * 挂载约定（对应上游 useWebRTC 挂载段，先于原生输入消费）：
 *   keydown/keyup → keymapHandleKey：消费则 preventDefault 并跳过 input.js 默认注入；
 *   wheel → keymapHandleWheel 先消费，未消费才走 inject_scroll（键位映射挂载行）。
 * 持久化：config JSON 存 Prefs 键 cloudphone_keymap（ArkWebView 桥 getKeymapProfiles 读）。
 * 坐标：映射 pos/startPos/endPos/center 为 0..1 分数，按 deviceW/H 还原为逻辑像素。
 */
'use strict';

/**
 * KeymapEngine —— 动作合成引擎（忠实移植上游 keymapEngine.js）。
 * sendTouch(action, x, y, pointerId)：action 0=DOWN 1=UP 2=MOVE；虚拟 id 自 10 起。
 * sendCommand(cmd)：command 型映射直发 WS 命令。
 */
class KeymapEngine {
  constructor(sendTouchCallback, sendCommandCallback) {
    this.activeProfile = null;
    this.sendTouch = sendTouchCallback;
    this.sendCommand = sendCommandCallback;
    // 虚拟触控 ID 从 10 开始，避免与真实手指/鼠标 (0-9 或 -1) 冲突
    this.pointerIdBase = 10;
    this.activePointers = new Map(); // mapping.id -> pointerId
    // 摇杆状态：mapping.id -> { state, pointerId }
    this.joysticks = new Map();
    // 滚轮状态：mapping.id -> { pointerId1, pointerId2, timeoutId, accumulatedDelta }
    this.wheels = new Map();
  }

  /** 应用 profile（切换时释放所有虚拟触控） */
  updateProfile(profile) {
    this.activeProfile = profile;
    this.releaseAll();
  }

  /** 释放全部活动虚拟触控（切档/断链/页面隐藏时） */
  releaseAll() {
    for (const [, pointerId] of this.activePointers.entries()) {
      this.sendTouch(1, 0, 0, pointerId);
    }
    this.activePointers.clear();
    for (const [, joy] of this.joysticks.entries()) {
      if (joy.pointerId !== null) {
        this.sendTouch(1, 0, 0, joy.pointerId);
        joy.pointerId = null;
      }
      joy.state = { up: false, down: false, left: false, right: false };
    }
    for (const [, state] of this.wheels.entries()) {
      if (state.timeoutId) clearTimeout(state.timeoutId);
      if (state.pointerId1 !== null) this.sendTouch(1, 0, 0, state.pointerId1);
      if (state.pointerId2 !== null) this.sendTouch(1, 0, 0, state.pointerId2);
    }
    this.wheels.clear();
  }

  /**
   * 键盘事件分发（key 与 mapping 匹配则消费）。
   * @returns true=消费（页面层 preventDefault 并跳过默认注入）
   */
  handleKeyEvent(event, isDown, videoWidth, videoHeight) {
    if (!this.activeProfile || !this.activeProfile.mappings) return false;
    const key = event.key.toLowerCase();
    let consumed = false;
    for (const map of this.activeProfile.mappings) {
      if (map.type === 'tap' && map.key && map.key.toLowerCase() === key) {
        if (!event.repeat) this.handleTap(map, isDown, videoWidth, videoHeight);
        consumed = true;
      } else if (map.type === 'command' && map.key && map.key.toLowerCase() === key) {
        if (isDown && !event.repeat) this.sendCommand(map.cmd);
        consumed = true;
      } else if (map.type === 'joystick') {
        const keys = map.keys || {};
        let direction = null;
        if (keys.up && key === keys.up.toLowerCase()) direction = 'up';
        else if (keys.down && key === keys.down.toLowerCase()) direction = 'down';
        else if (keys.left && key === keys.left.toLowerCase()) direction = 'left';
        else if (keys.right && key === keys.right.toLowerCase()) direction = 'right';
        if (direction) {
          if (!event.repeat) this.handleJoystick(map, direction, isDown, videoWidth, videoHeight);
          consumed = true;
        }
      } else if (map.type === 'swipe' && map.key && map.key.toLowerCase() === key) {
        if (!event.repeat) this.handleSwipe(map, isDown, videoWidth, videoHeight);
        consumed = true;
      }
    }
    return consumed;
  }

  /** tap：按 DOWN / 抬 UP（pos 为分数坐标） */
  handleTap(map, isDown, videoWidth, videoHeight) {
    const px = map.pos.x * videoWidth;
    const py = map.pos.y * videoHeight;
    if (isDown) {
      if (!this.activePointers.has(map.id)) {
        const ptrId = this.pointerIdBase++;
        this.activePointers.set(map.id, ptrId);
        this.sendTouch(0, px, py, ptrId); // ACTION_DOWN
      }
    } else {
      if (this.activePointers.has(map.id)) {
        const ptrId = this.activePointers.get(map.id);
        this.sendTouch(1, px, py, ptrId); // ACTION_UP
        this.activePointers.delete(map.id);
      }
    }
  }

  /** 摇杆：中心→边缘→归位（斜向归一化保证半径；半径按宽度比例） */
  handleJoystick(map, direction, isDown, videoWidth, videoHeight) {
    if (!this.joysticks.has(map.id)) {
      this.joysticks.set(map.id, { state: { up: false, down: false, left: false, right: false }, pointerId: null });
    }
    const joy = this.joysticks.get(map.id);
    joy.state[direction] = isDown;
    let dx = 0;
    let dy = 0;
    if (joy.state.up) dy -= 1;
    if (joy.state.down) dy += 1;
    if (joy.state.left) dx -= 1;
    if (joy.state.right) dx += 1;
    const isNeutral = (dx === 0 && dy === 0);
    const centerX = map.center.x * videoWidth;
    const centerY = map.center.y * videoHeight;
    const radiusPx = map.radius * videoWidth;
    if (isNeutral) {
      // 活动 → 归位：ACTION_UP 于中心
      if (joy.pointerId !== null) {
        this.sendTouch(1, centerX, centerY, joy.pointerId);
        joy.pointerId = null;
      }
    } else {
      const length = Math.sqrt(dx * dx + dy * dy);
      const targetX = centerX + (dx / length) * radiusPx;
      const targetY = centerY + (dy / length) * radiusPx;
      if (joy.pointerId === null) {
        // 归位 → 活动：中心 DOWN 紧接 MOVE 到边缘
        joy.pointerId = this.pointerIdBase++;
        this.sendTouch(0, centerX, centerY, joy.pointerId);
        this.sendTouch(2, targetX, targetY, joy.pointerId);
      } else {
        // 方向改变：MOVE
        this.sendTouch(2, targetX, targetY, joy.pointerId);
      }
    }
  }

  /** swipe：DOWN → rAF 插值 MOVE（duration 默认 150ms）→ UP 终点 */
  handleSwipe(map, isDown, videoWidth, videoHeight) {
    if (isDown) {
      if (this.activePointers.has(map.id)) return;
      const ptrId = this.pointerIdBase++;
      this.activePointers.set(map.id, ptrId);
      const startX = map.startPos.x * videoWidth;
      const startY = map.startPos.y * videoHeight;
      const endX = map.endPos.x * videoWidth;
      const endY = map.endPos.y * videoHeight;
      const duration = map.duration || 150;
      const startTime = Date.now();
      this.sendTouch(0, startX, startY, ptrId);
      const requestAnimFrame = (typeof requestAnimationFrame !== 'undefined')
        ? requestAnimationFrame
        : (cb) => setTimeout(cb, 16);
      const animate = () => {
        if (!this.activePointers.has(map.id) || this.activePointers.get(map.id) !== ptrId) return;
        let progress = (Date.now() - startTime) / duration;
        if (progress >= 1) progress = 1;
        const currentX = startX + (endX - startX) * progress;
        const currentY = startY + (endY - startY) * progress;
        this.sendTouch(2, currentX, currentY, ptrId);
        if (progress < 1) requestAnimFrame(animate);
      };
      requestAnimFrame(animate);
    } else {
      if (this.activePointers.has(map.id)) {
        const ptrId = this.activePointers.get(map.id);
        const endX = map.endPos.x * videoWidth;
        const endY = map.endPos.y * videoHeight;
        this.sendTouch(1, endX, endY, ptrId);
        this.activePointers.delete(map.id);
      }
    }
  }

  /** 滚轮消费（存在 wheel 映射即消费） */
  handleWheelEvent(event, videoWidth, videoHeight) {
    if (!this.activeProfile || !this.activeProfile.mappings) return false;
    let consumed = false;
    for (const map of this.activeProfile.mappings) {
      if (map.type === 'wheel') {
        this.handleWheel(map, event.deltaY, videoWidth, videoHeight);
        consumed = true;
      }
    }
    return consumed;
  }

  /**
   * wheel 动作：
   *  scroll=拨动式（超 30% 屏高/边缘即抬手，200ms 闲置自动抬）；
   *  zoom=中心 45° 双指捏合（min 5%~max 40% 屏高半径，到界即抬手换新一轮）。
   */
  handleWheel(map, deltaY, videoWidth, videoHeight) {
    if (!this.wheels.has(map.id)) {
      this.wheels.set(map.id, { pointerId1: null, pointerId2: null, timeoutId: null, accumulatedDelta: 0 });
    }
    const state = this.wheels.get(map.id);
    const px = map.pos.x * videoWidth;
    const py = map.pos.y * videoHeight;
    if (state.timeoutId) {
      clearTimeout(state.timeoutId);
      state.timeoutId = null;
    }
    if (map.action === 'scroll') {
      if (state.pointerId1 === null) {
        state.pointerId1 = this.pointerIdBase++;
        // 滚轮向下(内容向上)：手指从偏下方落下
        state.accumulatedDelta = Math.sign(deltaY) * (videoHeight * 0.15);
        let startY = Math.max(0, Math.min(videoHeight, py + state.accumulatedDelta));
        this.sendTouch(0, px, startY, state.pointerId1);
      }
      const step = Math.sign(deltaY) * (videoHeight * 0.06);
      state.accumulatedDelta -= step;
      let currentY = py + state.accumulatedDelta;
      if (currentY <= 0 || currentY >= videoHeight || Math.abs(state.accumulatedDelta) > videoHeight * 0.3) {
        currentY = Math.max(0, Math.min(videoHeight, currentY));
        this.sendTouch(2, px, currentY, state.pointerId1);
        this.sendTouch(1, px, currentY, state.pointerId1);
        state.pointerId1 = null;
      } else {
        this.sendTouch(2, px, currentY, state.pointerId1);
        const capturedY = currentY;
        state.timeoutId = setTimeout(() => {
          if (state.pointerId1 !== null) {
            this.sendTouch(1, px, capturedY, state.pointerId1);
            state.pointerId1 = null;
          }
        }, 200);
      }
    } else if (map.action === 'zoom') {
      // 屏幕中心为原点、45° 倾斜的双指捏合
      const centerX = videoWidth / 2;
      const centerY = videoHeight / 2;
      const minRadius = videoHeight * 0.05;
      const maxRadius = videoHeight * 0.40;
      if (state.pointerId1 === null) {
        state.pointerId1 = this.pointerIdBase++;
        state.pointerId2 = this.pointerIdBase++;
        // 放大从近心开始外分；缩小从外围开始内捏
        state.accumulatedDelta = (deltaY < 0)
          ? minRadius + (videoHeight * 0.02)
          : maxRadius - (videoHeight * 0.02);
        const angle = Math.PI / 4;
        const ox = state.accumulatedDelta * Math.cos(angle);
        const oy = state.accumulatedDelta * Math.sin(angle);
        this.sendTouch(0, centerX - ox, centerY - oy, state.pointerId1);
        this.sendTouch(0, centerX + ox, centerY + oy, state.pointerId2);
      }
      const step = Math.sign(deltaY) * (videoHeight * 0.05);
      state.accumulatedDelta -= step;
      let outOfBounds = false;
      if (state.accumulatedDelta <= minRadius) {
        state.accumulatedDelta = minRadius;
        outOfBounds = true;
      }
      if (state.accumulatedDelta >= maxRadius) {
        state.accumulatedDelta = maxRadius;
        outOfBounds = true;
      }
      const angle = Math.PI / 4;
      const ox = state.accumulatedDelta * Math.cos(angle);
      const oy = state.accumulatedDelta * Math.sin(angle);
      this.sendTouch(2, centerX - ox, centerY - oy, state.pointerId1);
      this.sendTouch(2, centerX + ox, centerY + oy, state.pointerId2);
      if (outOfBounds) {
        // 到达捏合极限：立即抬手，下一轮滚轮触发新捏合
        this.sendTouch(1, centerX - ox, centerY - oy, state.pointerId1);
        this.sendTouch(1, centerX + ox, centerY + oy, state.pointerId2);
        state.pointerId1 = null;
        state.pointerId2 = null;
      } else {
        const cap1X = centerX - ox, cap1Y = centerY - oy, cap2X = centerX + ox, cap2Y = centerY + oy;
        state.timeoutId = setTimeout(() => {
          if (state.pointerId1 !== null) {
            this.sendTouch(1, cap1X, cap1Y, state.pointerId1);
            this.sendTouch(1, cap2X, cap2Y, state.pointerId2);
            state.pointerId1 = null;
            state.pointerId2 = null;
          }
        }, 200);
      }
    }
  }
}

// ===================== 控制页挂载（页面适配层） =====================
/** 引擎实例（start 时构建；null=未装载 profile） */
var keymapEngine = null;
/** 虚拟触控序号：pointerId → seq（与真实触点的 pointers 表相互独立） */
var kmSeqs = {};

/**
 * 引擎 → 本页 touch 发送适配：seq 自持、走 input-channel + 群控广播（P1-10 同形）。
 * viewOnly 在源头拦截（与 input.js 同门）。
 * @param action 0=DOWN 1=UP 2=MOVE
 */
function kmSendTouch(action, x, y, pointerId) {
  if (viewOnly) return;
  kmSeqs[pointerId] = (kmSeqs[pointerId] || 0) + 1;
  const ev = {
    type: 'touch', id: pointerId, seq: kmSeqs[pointerId], client_ts_ms: Date.now(),
    action: action, x: x, y: y, w: deviceW, h: deviceH
  };
  if (inputChannel && inputChannel.readyState === 'open') {
    inputChannel.send(JSON.stringify(ev));
  }
  if (action === 1) delete kmSeqs[pointerId]; // UP 收尾清序号
  groupBroadcast(ev);
}

/**
 * 从桥载入 profile 配置（signaling.start 调用）。
 * @param json config JSON（{activeProfileId, profiles[]}；空/坏 JSON → 引擎置空）
 */
function keymapLoadProfiles(json) {
  let profile = null;
  try {
    const cfg = JSON.parse(json && json.length > 0 ? json : '{}');
    const list = Array.isArray(cfg.profiles) ? cfg.profiles : [];
    profile = list.find((p) => p.id === cfg.activeProfileId) || list[0] || null;
  } catch (e) {
    profile = null;
  }
  keymapEngine = new KeymapEngine(kmSendTouch, sendCommand);
  keymapEngine.updateProfile(profile);
}

/** 释放全部虚拟触控（断链/重置时防悬按） */
function keymapRelease() {
  if (keymapEngine) keymapEngine.releaseAll();
}

/**
 * keydown/keyup 挂载点（input.js 调用，先于默认注入）。
 * @returns true=被 keymap 消费（调用方 preventDefault 且不再走默认注入）
 */
function keymapHandleKey(event, isDown) {
  if (!keymapEngine || !keymapEngine.activeProfile) return false;
  return keymapHandleKeyInner(event, isDown);
}

function keymapHandleKeyInner(event, isDown) {
  const down = isDown;
  return keymapEngine.handleKeyEvent(event, down, deviceW, deviceH);
}

/** wheel 挂载点（input.js 滚轮先交此处，未消费才 inject_scroll） */
function keymapHandleWheel(event) {
  if (!keymapEngine || !keymapEngine.activeProfile) return false;
  return keymapEngine.handleWheelEvent(event, deviceW, deviceH);
}
