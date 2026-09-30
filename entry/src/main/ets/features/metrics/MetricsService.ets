/**
 * MetricsService —— 监控指标域（P2-9a，对应上游 devices.js updateMetrics + Dashboard.vue）
 *
 * 职责（单一）：device_metrics 广播订阅、每设备最新值与 360 点环形历史、
 *   阈值分级（对齐 Dashboard.vue 阈值配置）与告警计数、变更通知。
 * 载荷字段（devices.js 实读）：cpu / memory_percent / disk_percent / temperature /
 *   download_speed / upload_speed；历史同序 push，上限 360 点（shift 出队）。
 * 阈值（Dashboard.vue currentMetricConfig）：
 *   cpu   正常<=70 告警>70 严重>85（%）
 *   mem   正常<=75 告警>75 严重>90（%）
 *   disk  正常<=80 告警>80 严重>90（%）
 *   temp  正常<=65 告警>65 严重>75（℃）
 *   ↓/↑ 速率无阈值（热力矩阵以"有流量/无流量"信息色呈现）
 * 订阅：GlobalChannel('device_metrics')（上游 msg.type 兼容——GlobalChannel 路由 message_type??type）。
 * UI 观察：AppStorage('metricsState') 时间戳。
 */
import { Logger } from '../../utils/Logger';
import { ChannelLike } from '../../model/Model';

/** 历史容量（上游 360 点） */
const HISTORY_CAP: number = 360;

/** 六指标键（展示顺序即矩阵列序） */
export const METRIC_KEYS: string[] = ['cpu', 'memory', 'disk', 'temp', 'down', 'up'];

/** 单设备指标快照（防御式缺省 0） */
export class DeviceMetrics {
  cpu: number = 0;
  memory: number = 0;
  disk: number = 0;
  temp: number = 0;
  down: number = 0;
  up: number = 0;
}

/** 单设备环形历史（六轨 + 时间戳轨，与上游 deviceHistory 同构） */
export class DeviceHistory {
  cpu: number[] = [];
  memory: number[] = [];
  disk: number[] = [];
  temp: number[] = [];
  down: number[] = [];
  up: number[] = [];
  timestamps: string[] = [];

  private push(arr: number[], v: number): void {
    arr.push(v);
    if (arr.length > HISTORY_CAP) {
      arr.shift();
    }
  }

  /** 六轨同步入队（同上游 push 序列） */
  pushAll(m: DeviceMetrics, timeStr: string): void {
    this.push(this.cpu, m.cpu);
    this.push(this.memory, m.memory);
    this.push(this.disk, m.disk);
    this.push(this.temp, m.temp);
    this.push(this.down, m.down);
    this.push(this.up, m.up);
    this.timestamps.push(timeStr);
    if (this.timestamps.length > HISTORY_CAP) {
      this.timestamps.shift();
    }
  }
}

export class MetricsService {
  private static instance: MetricsService | null = null;

  static getInstance(): MetricsService {
    if (MetricsService.instance === null) {
      MetricsService.instance = new MetricsService();
    }
    return MetricsService.instance;
  }

  /** 最新快照：deviceId → DeviceMetrics */
  private latest: Map<string, DeviceMetrics> = new Map();
  /** 历史：deviceId → DeviceHistory */
  private history: Map<string, DeviceHistory> = new Map();

  private notify(): void {
    AppStorage.setOrCreate<number>('metricsState', Date.now());
  }

  /** 阈值分级：0=正常 1=告警 2=严重 3=无阈值(信息)——温度用℃，速率无阈值 */
  static levelOf(metricKey: string, value: number): number {
    if (metricKey === 'cpu') {
      if (value > 85) {
        return 2;
      }
      if (value > 70) {
        return 1;
      }
      return 0;
    }
    if (metricKey === 'memory') {
      if (value > 90) {
        return 2;
      }
      if (value > 75) {
        return 1;
      }
      return 0;
    }
    if (metricKey === 'disk') {
      if (value > 90) {
        return 2;
      }
      if (value > 80) {
        return 1;
      }
      return 0;
    }
    if (metricKey === 'temp') {
      if (value > 75) {
        return 2;
      }
      if (value > 65) {
        return 1;
      }
      return 0;
    }
    return 3; // down/up：无阈值
  }

  /**
   * GlobalChannel 监听入口（DeviceList 装配调用）。
   * @param deviceId 目标设备；metrics 载荷（原始 Record）
   */
  ingest(deviceId: string, metrics: Record<string, Object>): void {
    if (deviceId.length === 0) {
      return;
    }
    const m = new DeviceMetrics();
    m.cpu = (metrics['cpu'] as number) ?? 0;
    m.memory = (metrics['memory_percent'] as number) ?? 0;
    m.disk = (metrics['disk_percent'] as number) ?? 0;
    m.temp = (metrics['temperature'] as number) ?? 0;
    m.down = (metrics['download_speed'] as number) ?? 0;
    m.up = (metrics['upload_speed'] as number) ?? 0;
    this.latest.set(deviceId, m);

    let h = this.history.get(deviceId);
    if (h === undefined) {
      h = new DeviceHistory();
      this.history.set(deviceId, h);
    }
    const now = new Date();
    const hh = `${now.getHours()}`.padStart(2, '0');
    const mm = `${now.getMinutes()}`.padStart(2, '0');
    const ss = `${now.getSeconds()}`.padStart(2, '0');
    h.pushAll(m, `${hh}:${mm}:${ss}`);
    this.notify();
  }

  /** 最新快照（无数据 null） */
  getMetrics(deviceId: string): DeviceMetrics | null {
    return this.latest.get(deviceId) ?? null;
  }

  /** 历史轨道（key ∈ cpu/memory/disk/temp/down/up；无数据空数组） */
  getTrack(deviceId: string, key: string): number[] {
    const h = this.history.get(deviceId);
    if (h === undefined) {
      return [];
    }
    if (key === 'cpu') {
      return h.cpu;
    }
    if (key === 'memory') {
      return h.memory;
    }
    if (key === 'disk') {
      return h.disk;
    }
    if (key === 'temp') {
      return h.temp;
    }
    if (key === 'down') {
      return h.down;
    }
    if (key === 'up') {
      return h.up;
    }
    return [];
  }

  /** 有指标数据的设备（矩阵行序） */
  deviceIds(): string[] {
    const out: string[] = [];
    this.latest.forEach((_v: DeviceMetrics, id: string) => {
      out.push(id);
    });
    return out;
  }

  /** 单指标告警计数（告警+严重；矩阵/汇总卡共用） */
  warningCount(metricKey: string): number {
    let n = 0;
    this.latest.forEach((m: DeviceMetrics, _id: string) => {
      const v = MetricsService.valueOf(m, metricKey);
      const lv = MetricsService.levelOf(metricKey, v);
      if (lv === 1 || lv === 2) {
        n++;
      }
    });
    return n;
  }

  /** 按键取值（矩阵/计数统一入口） */
  static valueOf(m: DeviceMetrics, metricKey: string): number {
    if (metricKey === 'cpu') {
      return m.cpu;
    }
    if (metricKey === 'memory') {
      return m.memory;
    }
    if (metricKey === 'disk') {
      return m.disk;
    }
    if (metricKey === 'temp') {
      return m.temp;
    }
    if (metricKey === 'down') {
      return m.down;
    }
    return m.up;
  }

  /** 指标展示名（矩阵列头/卡片标题） */
  static labelOf(metricKey: string): string {
    if (metricKey === 'cpu') {
      return 'CPU';
    }
    if (metricKey === 'memory') {
      return '内存';
    }
    if (metricKey === 'disk') {
      return '磁盘';
    }
    if (metricKey === 'temp') {
      return '温度';
    }
    if (metricKey === 'down') {
      return '下行';
    }
    return '上行';
  }

  /** 单值展示（temp 带 ℃；速率 KB/s 两位小数；其余 %） */
  static formatOf(metricKey: string, value: number): string {
    if (metricKey === 'temp') {
      return `${value.toFixed(1)}℃`;
    }
    if (metricKey === 'down' || metricKey === 'up') {
      return `${value.toFixed(2)} KB/s`;
    }
    return `${value.toFixed(1)}%`;
  }

  /** 接线用：GlobalChannel 监听注册（DeviceList 装配根调用一次） */
  static register(channel: ChannelLike): void {
    channel.on('device_metrics', (msg: Record<string, Object>): void => {
      const id = (msg['device_id'] as string) ?? '';
      const m = msg['metrics'];
      if (m === undefined || m === null) {
        Logger.warn('MetricsService', 'device_metrics 缺 metrics 字段');
        return;
      }
      MetricsService.getInstance().ingest(id, m as Record<string, Object>);
    });
    Logger.info('MetricsService', 'device_metrics 监听已注册');
  }
}
