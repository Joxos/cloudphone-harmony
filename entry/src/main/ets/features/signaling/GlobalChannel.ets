/**
 * GlobalChannel —— 全局信令 WS 单例（P1-7 基座，P1-5 预览控制入口）
 *
 * 职责（单一）：与信令服务的**全局**长连接（区别于控制页的按设备连接）——
 *   建连/20s 应用层心跳({type:'ping'})/3s×n 断线退避重连；
 *   广播分发（message_type → 监听器，页面层注册）；PREV 二进制帧解析与回调。
 * 连接事实（对齐上游 web-app devices.js:769-815 实读）：
 *   - URL 与设备连接同端点 `/connect_client?token=`，**不发 connect 首帧**；
 *   - 心跳 {type:'ping'} 每 20s；pong 忽略；
 *   - ArrayBuffer → PREV 帧（4B magic 'PREV' + 32B deviceId + 1B isKey + 8B ptsUs + 4B len + NALU）。
 * 组合根：pages/DeviceList.ets 装配监听（跨域经页面协作）；
 * 消费：global_settings_updated（SettingsStore 热更）/ device_list_update / snapshot_update（缩略图）。
 * 依赖：utils/{Prefs,HttpClient,Logger}；PREV 解码依赖 @kit.ArkTS Base64Helper。
 */
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { Prefs } from '../../utils/Prefs';
import { normalizeHost, wsScheme } from '../../utils/HttpClient';
import { Logger } from '../../utils/Logger';
import { ChannelLike } from '../../model/Model';

export class GlobalChannel implements ChannelLike {
  private static instance: GlobalChannel | null = null;

  static getInstance(): GlobalChannel {
    if (GlobalChannel.instance === null) {
      GlobalChannel.instance = new GlobalChannel();
    }
    return GlobalChannel.instance;
  }

  /** 全局 WS 句柄（单例仅一条） */
  private ws: webSocket.WebSocket | null = null;
  /** 广播监听注册表：message_type → 回调（同类型后注册覆盖，单消费者语义） */
  private listeners: Map<string, (msg: Record<string, Object>) => void> = new Map();
  /** 应用层心跳定时器（20s） */
  private heartbeatTimer: number = -1;
  /** 重连退避定时器 */
  private retryTimer: number = -1;
  /** 连续重连计数（open 后清零） */
  private retryCount: number = 0;
  /** 保持连接意图（登出置 false） */
  private wantRun: boolean = false;

  /** P1-5：PREV 帧回调（PreviewHost 注入；null=暂无消费者则丢弃帧）
   *  @param deviceId 帧头设备 ID
   *  @param isKey 关键帧标志（帧头第 37 字节；页面首帧门用）
   *  @param ptsUs 显示时间戳（微秒，EncodedVideoChunk.timestamp 同单位）
   *  @param frameB64 NALU 段 base64（49B 头之后的负载）
   */
  onPrevFrame: ((deviceId: string, isKey: boolean, ptsUs: number, frameB64: string) => void) | null = null;

  /**
   * 注册广播监听（覆盖同类型旧监听）。
   * @param type 服务端 message_type（如 global_settings_updated / device_list_update）
   * @param cb 载荷回调（原始 Record，字段以协议为准）
   */
  on(type: string, cb: (msg: Record<string, Object>) => void): void {
    this.listeners.set(type, cb);
  }

  /** 当前是否已连接（页面徽标/发送前判断） */
  isConnected(): boolean {
    return this.ws !== null;
  }

  /**
   * 建立全局连接（幂等；登出后需先 disconnect）。
   * 流程：读凭证 → createWebSocket(skipServerCertVerification) → open 启心跳 →
   *      message 分发/二进制 PREV → close 后按需退避重连。
   */
  async ensureConnected(): Promise<void> {
    if (this.ws !== null) {
      return;
    }
    this.wantRun = true;
    const ip = await Prefs.getInstance().getServerIp();
    const token = await Prefs.getInstance().getToken();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (ip.length === 0 || token.length === 0) {
      Logger.warn('GlobalChannel', '缺少服务器/凭证，未连接');
      return;
    }
    const url = `${wsScheme(useSsl)}${normalizeHost(ip)}/connect_client?token=${encodeURIComponent(token)}`;
    const ws = webSocket.createWebSocket();
    this.ws = ws;
    Logger.info('GlobalChannel', `连接全局信令 ${url.slice(0, 80)}`);

    ws.on('open', () => {
      this.retryCount = 0;
      Logger.info('GlobalChannel', '已连接（20s 心跳启动）');
      this.stopHeartbeat();
      this.heartbeatTimer = setInterval(() => {
        this.sendObj({ 'type': 'ping' });
      }, 20000);
    });
    ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
      if (typeof value !== 'string') {
        this.handleBinary(value);
        return;
      }
      try {
        const msg = JSON.parse(value) as Record<string, Object>;
        let mtype = ((msg['message_type'] as string) ?? (msg['type'] as string)) ?? '';
        // 形状兜底：v0.3.2 服务端的 device_metrics 帧**既无 message_type 也无 type**，
        // 只有 {device_id, metrics}。上游 v0.3.8 键 msg.type（devices.js:813）在该
        // 服务端上同样会漏收；无判别键时按形状补一个，避免 P2-9 大盘全程无数据。
        if (mtype === '' && msg['metrics'] !== undefined) {
          mtype = 'device_metrics';
          Logger.warn('GlobalChannel', 'device_metrics 帧无判别键，按形状兜底路由');
        }
        if (mtype === 'pong' || mtype === '') {
          return;
        }
        const cb = this.listeners.get(mtype);
        if (cb !== undefined) {
          cb(msg);
        }
      } catch (e) {
        // 非 JSON 忽略
      }
    });
    ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
      Logger.info('GlobalChannel', `关闭 code=${value.code}`);
      this.stopHeartbeat();
      if (this.ws === ws) {
        this.ws = null;
      }
      this.scheduleRetry();
    });
    ws.on('error', () => {
      Logger.warn('GlobalChannel', 'WS error（由 close 统一重连）');
    });
    ws.connect(url, { skipServerCertVerification: true }, (err: BusinessError) => {
      if (err) {
        Logger.error('GlobalChannel', `connect 失败: ${err.message}`);
        if (this.ws === ws) {
          this.ws = null;
        }
        this.scheduleRetry();
      }
    });
  }

  /** 断开并停止重连（登出/退出时调用） */
  disconnect(): void {
    this.wantRun = false;
    this.stopHeartbeat();
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    const ws = this.ws;
    this.ws = null;
    if (ws !== null) {
      try {
        ws.close({ code: 1000, reason: 'global done' });
      } catch (e) {
        Logger.warn('GlobalChannel', 'close 异常（忽略）');
      }
    }
  }

  /** 心跳清理 */
  private stopHeartbeat(): void {
    if (this.heartbeatTimer !== -1) {
      clearInterval(this.heartbeatTimer);
      this.heartbeatTimer = -1;
    }
  }

  /** 断线退避重连（3s×n 上限 15s；全局通道不设次数上限，open 即清零） */
  private scheduleRetry(): void {
    if (!this.wantRun) {
      return;
    }
    this.retryCount++;
    const delay = Math.min(3000 * this.retryCount, 15000);
    Logger.info('GlobalChannel', `${delay}ms 后重连（第 ${this.retryCount} 次）`);
    if (this.retryTimer !== -1) {
      clearTimeout(this.retryTimer);
    }
    this.retryTimer = setTimeout(() => {
      this.retryTimer = -1;
      if (this.wantRun) {
        this.ensureConnected().catch(() => { return; });
      }
    }, delay);
  }

  /** 发送 JSON 帧（未连接静默丢弃） */
  private sendObj(payload: Record<string, Object>): void {
    if (this.ws !== null) {
      try {
        this.ws.send(JSON.stringify(payload));
      } catch (e) {
        Logger.warn('GlobalChannel', 'send 失败');
      }
    }
  }

  /**
   * PREV 二进制帧解析（帧格式）：
   * 4B 'PREV' + 32B deviceId(ascii,可能 \0 填充) + 1B isKey + 8B ptsUs(BE) + 4B NALU长度(BE) + NALU
   * NALU 段 base64 后交 onPrevFrame（PreviewHost 消费；无消费者直接丢弃）。
   */
  private handleBinary(buf: ArrayBuffer): void {
    if (this.onPrevFrame === null) {
      return;
    }
    const u8 = new Uint8Array(buf);
    if (u8.length < 49) {
      return;
    }
    if (u8[0] !== 0x50 || u8[1] !== 0x52 || u8[2] !== 0x45 || u8[3] !== 0x56) {
      return; // 非 'PREV'
    }
    let dev = '';
    for (let i = 4; i < 36; i++) {
      if (u8[i] === 0) {
        break;
      }
      dev += String.fromCharCode(u8[i]);
    }
    const isKey = u8[36] !== 0;
    let ptsUs = 0;
    for (let j = 37; j <= 44; j++) {
      ptsUs = ptsUs * 256 + u8[j]; // 8B BE；时间戳量级 < 2^53，double 精确
    }
    const len = ((u8[45] << 24) | (u8[46] << 16) | (u8[47] << 8) | u8[48]) >>> 0;
    if (len === 0 || 49 + len > u8.length) {
      return; // 长度越界（防脏帧）
    }
    const nalus = new Uint8Array(u8.subarray(49, 49 + len));
    const b64 = new util.Base64Helper().encodeToStringSync(nalus);
    if (this.onPrevFrame !== null) {
      this.onPrevFrame(dev, isKey, ptsUs, b64);
    }
  }

  /**
   * P1-5：请求开启高频预览（载荷逐字段对齐上游 sendPreviewControl，devices.js:641）。
   * @param bitrateMbps 传 Mbps（<10000 时自动 ×1e6；上游同款双单位逻辑）
   * @returns true=已发送
   */
  startPreview(deviceId: string, fps: number, maxSize: number, bitrateMbps: number, stayAwake: boolean): boolean {
    if (this.ws === null) {
      return false;
    }
    const payload: Record<string, Object> = {
      'message_type': 'start_preview',
      'type': 'start_preview',
      'device_id': deviceId,
      'fps': fps,
      'max_size': maxSize,
      'bitrate': bitrateMbps >= 10000 ? Math.round(bitrateMbps) : Math.round(bitrateMbps * 1000000),
      'stay_awake': stayAwake
    };
    this.sendObj(payload);
    Logger.info('GlobalChannel', `start_preview ${deviceId} ${fps}fps/${maxSize}`);
    return true;
  }

  /** P1-5：停止高频预览（与 startPreview 成对；上游有订阅者保护，页面层自行判重） */
  stopPreview(deviceId: string): boolean {
    if (this.ws === null) {
      return false;
    }
    this.sendObj({ 'message_type': 'stop_preview', 'type': 'stop_preview', 'device_id': deviceId });
    Logger.info('GlobalChannel', `stop_preview ${deviceId}`);
    return true;
  }

  /**
   * 发送已组装的完整 JSON 帧（P1-5 直控 / P1-10 群控复用——帧体由页面按上游
   * group_control_event 规范组装，本方法只负责传输）。
   * @param json 完整帧 JSON 文本
   * @returns true=已发送；未连接返回 false（高频触控路径不打日志，防刷屏）
   */
  sendRaw(json: string): boolean {
    if (this.ws === null) {
      return false;
    }
    try {
      this.ws.send(json);
      return true;
    } catch (e) {
      return false;
    }
  }
}
