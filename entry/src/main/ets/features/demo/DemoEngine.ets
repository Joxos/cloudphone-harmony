/**
 * DemoEngine —— Demo 模式驱动引擎（P2-12c，移植自上游 mock/demoEngine.js）
 *
 * 职责（单一）：无服务器演示数据的全量生成与指标模拟——
 *   ① 设备矩阵：6 台手写精细样本 + 种子 LCG 程序化补至 100 台（刷新可复现）；
 *   ② 指标差分：2s 周期对在线设备 cpu/mem/temp/上下行做区间抖动（上游 startMockStatsGenerator 同范围）；
 *   ③ Shell 仿真：ls/top/getprop 三类真实感输出 + 通用兜底（上游 getMockShellOutput 同文案）。
 * 接线（pages 组装，features 不互 import）：
 *   DeviceList.loadDevices → demoMode 时 buildDevices()；startTicker(cb) 的 cb 由页面注入
 *   MetricsService.ingest（大盘/热力矩阵在 Demo 下同样工作）。
 * 范围注记：仿真屏画面（renderMockScreenCanvas）与控制页 WebRTC 假流列 P2-12d。
 * 依赖：model.Device、utils.Logger（无网络面）。
 */
import { Device } from '../../model/Model';
import { Logger } from '../../utils/Logger';

/** 手写精细样本（上游 MOCK_DEVICES 前 6 台逐字段移植；status/tags 映射进 name 展示与后续扩展） */
class DemoSpec {
  id: string = '';
  model: string = '';
  online: boolean = true;
  cpu: number = 0;
  mem: number = 0;
  disk: number = 0;
  temp: number = 0;
  up: number = 0;
  down: number = 0;

  constructor(id: string, model: string, online: boolean,
    cpu: number, mem: number, disk: number, temp: number, up: number, down: number) {
    this.id = id;
    this.model = model;
    this.online = online;
    this.cpu = cpu;
    this.mem = mem;
    this.disk = disk;
    this.temp = temp;
    this.up = up;
    this.down = down;
  }
}

/** 上游生成器型号池 */
const DEMO_MODELS: string[] = [
  'Google Pixel 7 Pro',
  'Samsung Galaxy S23 (redroid)',
  'Xiaomi 14 (Magisk Service)',
  'OnePlus 12 (Shizuku Engine)',
  'Redroid Container Node'
];

export class DemoEngine {
  private static instance: DemoEngine | null = null;

  static getInstance(): DemoEngine {
    if (DemoEngine.instance === null) {
      DemoEngine.instance = new DemoEngine();
    }
    return DemoEngine.instance;
  }

  /** 在线设备当前指标（抖动基线）：id → [cpu, mem, disk, temp, up, down] */
  private stats: Map<string, number[]> = new Map();
  /** 指标推送定时器 */
  private timer: number = -1;
  /** 已生成缓存（幂等） */
  private cached: Device[] = [];

  /** 6 台手写样本（上游数据原样） */
  private specs(): DemoSpec[] {
    return [
      new DemoSpec('Pixel-6Pro-ARM64', 'Google Pixel 6 Pro', true, 18.4, 48.2, 42.1, 36.5, 1250, 3420),
      new DemoSpec('Redroid-S22-Container', 'Samsung Galaxy S22 (redroid)', true, 32.1, 62.5, 35.0, 41.2, 890, 2100),
      new DemoSpec('Xiaomi13-Magisk-v030', 'Xiaomi 13 (Magisk Service)', true, 12.8, 41.0, 55.4, 35.1, 2150, 5800),
      new DemoSpec('OnePlus11-Shizuku-ADB', 'OnePlus 11 (Shizuku Engine)', true, 22.5, 51.3, 60.1, 38.0, 1400, 3100),
      new DemoSpec('CloudPhone-Tensor-v030', 'Google Tensor Cloud Engine', true, 15.2, 45.8, 28.9, 34.8, 3100, 7200),
      new DemoSpec('CloudPhone-Offline-Node6', 'Qualcomm Snapdragon Node (Offline)', false, 0, 0, 0, 0, 0, 0)
    ];
  }

  /** 种子伪随机（上游 seededRand 同参——刷新布局稳定便于 UI 对比） */
  private seeded(seed: number): () => number {
    let s = seed;
    return () => {
      s = (s * 1103515245 + 12345) % 2147483648;
      return s / 2147483648;
    };
  }

  /** 构建设备矩阵（6 精细 + 程序化至 100；幂等缓存） */
  buildDevices(): Device[] {
    if (this.cached.length > 0) {
      return this.cached;
    }
    const out: Device[] = [];
    for (const s of this.specs()) {
      const d = new Device(s.id, s.model, s.online);
      d.x_res = 1080;
      d.y_res = 1920;
      out.push(d);
      this.stats.set(s.id, [s.cpu, s.mem, s.disk, s.temp, s.up, s.down]);
    }
    for (let i = out.length + 1; i <= 100; i++) {
      const rand = this.seeded(i * 9973);
      const spec = DEMO_MODELS[Math.floor(rand() * DEMO_MODELS.length)];
      const online = rand() > 0.12; // 约 88% 在线（上游同概率）
      const id = `CloudPhone-VM-${`${i}`.padStart(3, '0')}`;
      const d = new Device(id, spec, online);
      d.x_res = 1080;
      d.y_res = 1920;
      out.push(d);
      if (online) {
        this.stats.set(id, [
          parseFloat((10 + rand() * 60).toFixed(1)),
          parseFloat((35 + rand() * 40).toFixed(1)),
          parseFloat((20 + rand() * 50).toFixed(1)),
          parseFloat((33 + rand() * 12).toFixed(1)),
          Math.floor(200 + rand() * 3000),
          Math.floor(500 + rand() * 7000)
        ]);
      } else {
        this.stats.set(id, [0, 0, 0, 0, 0, 0]);
      }
    }
    this.cached = out;
    Logger.info('DemoEngine', `演示矩阵生成：${out.length} 台`);
    return out;
  }

  /**
   * 指标差分推送（2s 周期；区间与步长对齐上游 startMockStatsGenerator）。
   * @param onTick 页面注入的回传（deviceId + metrics 原始载荷形状）——由页面转交 MetricsService
   * @returns 停止函数（幂等重复调用安全）
   */
  startTicker(onTick: (deviceId: string, metrics: Record<string, Object>) => void): () => void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
    }
    this.timer = setInterval(() => {
      this.stats.forEach((v: number[], id: string) => {
        // 仅在线（非全零基线）抖动——离线设备保持 0
        if (v[0] === 0 && v[3] === 0) {
          return;
        }
        v[0] = Math.max(8, Math.min(85, parseFloat((v[0] + (Math.random() * 6 - 3)).toFixed(1))));
        v[1] = Math.max(30, Math.min(80, parseFloat((v[1] + (Math.random() * 2 - 1)).toFixed(1))));
        v[3] = Math.max(32, Math.min(48, parseFloat((v[3] + (Math.random() * 0.4 - 0.2)).toFixed(1))));
        v[4] = Math.max(200, v[4] + Math.floor(Math.random() * 400 - 200));
        v[5] = Math.max(500, v[5] + Math.floor(Math.random() * 800 - 400));
        onTick(id, {
          'cpu': v[0],
          'memory_percent': v[1],
          'disk_percent': v[2],
          'temperature': v[3],
          'download_speed': v[5],
          'upload_speed': v[4]
        });
      });
    }, 2000);
    const timerId = this.timer;
    return () => {
      if (this.timer === timerId) {
        clearInterval(timerId);
        this.timer = -1;
      }
    };
  }

  /**
   * Shell 仿真输出（上游 getMockShellOutput 同文案：ls/top/getprop/兜底）。
   * TerminalPage 在 demoMode 下于发命令前直接回显。
   */
  mockShell(command: string): string {
    const cmd = command.trim().toLowerCase();
    if (cmd.startsWith('ls')) {
      return 'total 48\n' +
        'drwxrwx--x 15 root root 4096 Jul 24 10:00 .\n' +
        'drwxrwx--x 11 root root 4096 Jul 24 08:11 ..\n' +
        'drwxrwx---  2 root root 4096 Jul 24 10:05 Download\n' +
        'drwxrwx---  3 root root 4096 Jul 24 10:02 DCIM\n' +
        'drwxrwx---  2 root root 4096 Jul 24 10:01 Documents\n' +
        '-rw-rw----  1 root root  128 Jul 24 11:30 config.conf';
    }
    if (cmd.startsWith('top')) {
      return 'Tasks: 142 total,   1 running, 141 sleeping\n' +
        '%Cpu(s):  8.2 us,  2.1 sy,  0.0 ni, 89.7 id,  0.0 wa\n' +
        'KiB Mem :  8048128 total,  3210440 free,  2432018 used\n' +
        '  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND\n' +
        ' 1204 shell     20   0 1048576  48200  32100 S   5.2   0.6   0:15.22 cloudphone-agent\n' +
        ' 2314 root      20   0 2048576 128400  88200 S   3.1   1.6   0:42.10 libsys_core.so\n' +
        '  840 system    20   0 4820192 342000 180000 S   2.0   4.2   1:12.50 system_server';
    }
    if (cmd.startsWith('getprop')) {
      return '[ro.product.model]: [Google Pixel 6 Pro]\n' +
        '[ro.build.version.release]: [12]\n' +
        '[ro.build.version.sdk]: [31]\n' +
        '[ro.product.cpu.abi]: [arm64-v8a]\n' +
        '[cloudphone.agent.version]: [v0.3.0]\n' +
        '[cloudphone.app.version]: [v0.3.1]';
    }
    return `[Mock ADB Shell]: Executed '${command}' successfully. (exit 0)`;
  }
}
