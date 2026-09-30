/**
 * mockscreen.js —— Demo 仿真屏（P2-12d，移植自上游 mock/demoEngine.renderMockScreenCanvas）
 *
 * 职责（单一）：无 agent 时在控制页画高仿真 Android 首屏（渐变壁纸/状态栏时钟/机型标题/
 *   4×4 应用图标格）+ 触控波纹动画反馈；rAF 循环绘制，stop 全清理。
 * 触发：control.html boot 检测桥 getDemoMode='1' 时启用（跳过信令 start）。
 * 与上游差异：roundRect 不可用时回退 fillRect（老内核/测试桩兼容）；波纹由本模块
 *   自绑 pointer 事件（canvas 即屏，坐标直用无需设备分辨率映射）。
 * 依赖：preview 页无关；仅 DOM canvas。
 */
'use strict';

/** 8 个虚拟应用图标（上游 icons 表原样） */
var MOCK_ICONS = [
  { name: '系统设置', color: '#6366f1', icon: '⚙️' },
  { name: '文件管理', color: '#06b6d4', icon: '📁' },
  { name: '相机', color: '#10b981', icon: '📷' },
  { name: '终端 Shell', color: '#f59e0b', icon: '💻' },
  { name: '云手机 Agent', color: '#3b82f6', icon: '🚀' },
  { name: 'Magisk 保活', color: '#ec4899', icon: '🧩' },
  { name: '网络监控', color: '#8b5cf6', icon: '📈' },
  { name: 'AI 助手', color: '#14b8a6', icon: '🤖' }
];

var mock = { canvas: null, ctx: null, raf: 0, ripples: [], deviceId: '', running: false };

/** 单帧绘制（上游 renderMockScreenCanvas 逐段对照） */
function mockDraw() {
  const canvas = mock.canvas;
  const ctx = mock.ctx;
  if (!canvas || !ctx) return;
  const width = canvas.width || 360;
  const height = canvas.height || 640;

  // 1) 深色背景
  ctx.fillStyle = '#0b0f19';
  ctx.fillRect(0, 0, width, height);

  // 2) 几何网格光辉（渐变）
  const grad = ctx.createLinearGradient(0, 0, width, height);
  grad.addColorStop(0, '#0f172a');
  grad.addColorStop(1, '#020617');
  ctx.fillStyle = grad;
  ctx.fillRect(0, 0, width, height);

  // 3) 顶部状态栏（时钟 + 5G/电量；受限环境 Date 构造器缺席时用占位时钟）
  ctx.fillStyle = 'rgba(255, 255, 255, 0.7)';
  ctx.font = '11px sans-serif';
  ctx.textAlign = 'left';
  let timeStr = '12:00';
  try {
    timeStr = new Date().toLocaleTimeString('zh-CN', { hour: '2-digit', minute: '2-digit' });
  } catch (e) {
    // 测试沙箱等仅提供 Date.now 的环境 → 占位时钟
  }
  ctx.fillText(timeStr, 14, 20);
  ctx.fillText('5G  🔋95%', width - 65, 20);

  // 4) 云手机标题
  ctx.fillStyle = '#38bdf8';
  ctx.font = 'bold 14px sans-serif';
  ctx.fillText(mock.deviceId || 'CloudPhone-v0.3.0', 14, 48);

  // 5) 4×4 应用图标格（前 8 图标两行）
  const colWidth = width / 4;
  const startY = 80;
  for (let i = 0; i < MOCK_ICONS.length; i++) {
    const item = MOCK_ICONS[i];
    const col = i % 4;
    const row = Math.floor(i / 4);
    const x = col * colWidth + colWidth / 2;
    const y = startY + row * 75;
    ctx.fillStyle = item.color;
    ctx.beginPath();
    if (typeof ctx.roundRect === 'function') {
      ctx.roundRect(x - 18, y - 18, 36, 36, 10);
    } else {
      ctx.rect(x - 18, y - 18, 36, 36); // 老内核/测试桩回退
    }
    ctx.fill();
    ctx.font = '18px sans-serif';
    ctx.textAlign = 'center';
    ctx.fillText(item.icon, x, y + 6);
    ctx.fillStyle = '#94a3b8';
    ctx.font = '10px sans-serif';
    ctx.fillText(item.name, x, y + 30);
  }

  // 6) 触控波纹（半径扩张 + 透明度衰减）
  ctx.textAlign = 'left';
  for (const r of mock.ripples) {
    ctx.strokeStyle = 'rgba(56, 189, 248, ' + r.alpha + ')';
    ctx.lineWidth = 3;
    ctx.beginPath();
    ctx.arc(r.x, r.y, r.radius, 0, Math.PI * 2);
    ctx.stroke();
    r.radius += 2.4;
    r.alpha -= 0.045;
  }
  mock.ripples = mock.ripples.filter((r) => r.alpha > 0);
}

/** rAF 循环（每帧先推进波纹再画） */
function mockLoop() {
  if (!mock.running) return;
  mockDraw();
  mock.raf = requestAnimationFrame(mockLoop);
}

/** 指针按下 → 波纹（canvas 坐标直用） */
function mockPointer(ev) {
  const rect = mock.canvas.getBoundingClientRect();
  mock.ripples.push({
    x: ev.clientX - rect.left,
    y: ev.clientY - rect.top,
    radius: 6,
    alpha: 0.9
  });
}

/**
 * 启动仿真屏。
 * @param canvasId 目标 canvas 元素 id（control.html #mock-screen）
 * @param deviceId 标题展示的设备 ID
 * @returns true=已启动
 */
function startMockScreen(canvasId, deviceId) {
  stopMockScreen();
  const el = document.getElementById(canvasId);
  if (!el) return false;
  mock.canvas = el;
  mock.ctx = el.getContext('2d');
  mock.deviceId = deviceId || '';
  mock.ripples = [];
  mock.running = true;
  mock.raf = requestAnimationFrame(mockLoop);
  // 波纹仅演示反馈（Demo 下无注入通道）
  mock.canvas.addEventListener('pointerdown', mockPointer);
  window.__mockScreen = mock;
  return true;
}

/** 停止并清理（rAF/波纹/监听幂等） */
function stopMockScreen() {
  mock.running = false;
  if (mock.raf) {
    cancelAnimationFrame(mock.raf);
    mock.raf = 0;
  }
  if (mock.canvas) {
    try {
      mock.canvas.removeEventListener('pointerdown', mockPointer);
    } catch (e) {
      // 忽略
    }
  }
  mock.ripples = [];
}

/** 运行态/波纹计数（测试与状态观察） */
function mockScreenState() {
  return { running: mock.running, ripples: mock.ripples.length };
}

window.startMockScreen = startMockScreen;
window.stopMockScreen = stopMockScreen;
window.mockScreenState = mockScreenState;
