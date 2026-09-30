/**
 * ShellClient —— 终端命令通道（P1-9，单台 WS command 执行）
 *
 * 职责（单一）：维护一条到信令服务的原生 WebSocket 会话（connect 首帧 +
 *              command 下行 + command_result Promise 化回收，15s 超时对齐上游）。
 * 选择说明：command 是纯 JSON 文本协议，无需 WebRTC/媒体，
 *           因此**原生 webSocket 直连**（与 WebSocketBridge 同一自签证书策略），
 *           不经过 ArkWeb 页面 —— 终端域与遥控域互不耦合。
 * 依赖：utils/HttpClient(端点工具)、utils/Prefs（登录态 server_ip/token/use_ssl）。
 * 协议：C→S command / S→C device_msg{command_result}。
 */
import { webSocket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { normalizeHost, wsScheme } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Logger } from '../../utils/Logger';

/** 单条命令执行结果（对应上游 command_result 载荷） */
export class CmdResult {
  /** true=拿到回执；false=超时/连接失败（error 说明原因） */
  ok: boolean;
  /** 标准输出 */
  stdout: string;
  /** 标准错误 */
  stderr: string;
  /** 进程退出码（-1=未知） */
  exitCode: number;
  /** ok=false 时的失败原因 */
  error: string;

  constructor(ok: boolean, stdout: string = '', stderr: string = '', exitCode: number = -1, error: string = '') {
    this.ok = ok;
    this.stdout = stdout;
    this.stderr = stderr;
    this.exitCode = exitCode;
    this.error = error;
  }
}

/**
 * 连接状态（供页面徽标展示）：'disconnected' | 'connecting' | 'connected' | 'error'
 * （以 string 承载，规避 ArkTS 字面量联合类型限制；页面用状态文案映射表消费）
 */

export class ShellClient {
  private static instance: ShellClient | null = null;

  static getInstance(): ShellClient {
    if (ShellClient.instance === null) {
      ShellClient.instance = new ShellClient();
    }
    return ShellClient.instance;
  }

  /** 原生 WS 句柄（同一时刻仅一条会话；重连前旧会话先 disconnect） */
  private ws: webSocket.WebSocket | null = null;
  /** 当前控制的设备 ID（connect 首帧与 command 均携带） */
  private deviceId: string = '';
  /** request_id → 结果回收器（含 15s 超时定时器） */
  private pending: Map<string, (r: CmdResult) => void> = new Map();
  /** request_id 单调后缀（毫秒时间戳碰撞兜底） */
  private seq: number = 0;
  /** 当前状态（ShellState 取值，见文件头注释） */
  state: string = 'disconnected';
  /** 状态变化回调（页面赋值更新徽标/按钮态） */
  onState: ((s: string) => void) | null = null;

  private setState(s: string): void {
    this.state = s;
    if (this.onState !== null) {
      this.onState(s);
    }
  }

  /**
   * 建立会话（依赖页面已 Prefs.init + 处于登录态）。
   * @returns true=已连上（收到服务端 config/device_info 任一）；false=失败（lastError 说明）
   */
  async connect(deviceId: string): Promise<boolean> {
    this.disconnect();
    this.deviceId = deviceId;
    const ip = await Prefs.getInstance().getServerIp();
    const token = await Prefs.getInstance().getToken();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (ip.length === 0 || token.length === 0) {
      this.setState('error');
      return false;
    }
    this.setState('connecting');
    const url = `${wsScheme(useSsl)}${normalizeHost(ip)}/connect_client?token=${encodeURIComponent(token)}`;
    const ws = webSocket.createWebSocket();
    this.ws = ws;

    return new Promise<boolean>((resolve) => {
      let settled = false;
      const failConnect = (why: string) => {
        if (!settled) {
          settled = true;
          Logger.warn('Shell', `连接失败: ${why}`);
          this.setState('error');
          resolve(false);
        }
      };
      // 连接超时（10s）
      const timer = setTimeout(() => { failConnect('连接超时(10s)'); }, 10000);

      ws.on('open', () => {
        Logger.info('Shell', `WS open → connect frame (device=${deviceId})`);
        ws.send(JSON.stringify({ message_type: 'connect', device_id: deviceId }));
      });
      ws.on('message', (err: BusinessError, value: string | ArrayBuffer) => {
        if (typeof value !== 'string') {
          return; // 终端域仅文本帧（B-6 二进制不涉及本域）
        }
        let msg: Record<string, Object> | null = null;
        try {
          msg = JSON.parse(value) as Record<string, Object>;
        } catch (e) {
          return;
        }
        const mtype = (msg['message_type'] as string) ?? '';
        // 连接确认：服务端进入会话后下发 config / device_info
        if (!settled && (mtype === 'config' || mtype === 'device_info')) {
          settled = true;
          clearTimeout(timer);
          this.setState('connected');
          resolve(true);
          return;
        }
        if (mtype === 'error' && !settled) {
          failConnect((msg['error'] as string) ?? '服务端错误');
          return;
        }
        if (mtype === 'device_msg') {
          this.handleDeviceMsg(msg['payload'] as Record<string, Object>);
        }
      });
      ws.on('close', (err: BusinessError, value: webSocket.CloseResult) => {
        Logger.info('Shell', `WS close code=${value.code}`);
        if (!settled) {
          failConnect(`连接被关闭(code=${value.code})`);
        } else if (this.state === 'connected') {
          this.setState('disconnected');
          this.failAllPending('信令断开');
        }
      });
      ws.on('error', () => {
        if (!settled) {
          failConnect('WS error');
        }
      });
      ws.connect(url, { skipServerCertVerification: true }, (err: BusinessError) => {
        if (err) {
          failConnect(err.message);
        }
      });
    });
  }

  /** device_msg 分发：仅关心 command_result（按 request_id 回收） */
  private handleDeviceMsg(payload: Record<string, Object> | null | undefined): void {
    if (!payload) {
      return;
    }
    if ((payload['type'] as string) !== 'command_result') {
      return;
    }
    const rid = (payload['request_id'] as string) ?? '';
    const result = new CmdResult(true,
      (payload['stdout'] as string) ?? '',
      (payload['stderr'] as string) ?? '',
      (payload['exit_code'] as number) ?? -1);
    const resolver = this.pending.get(rid);
    if (resolver !== undefined) {
      this.pending.delete(rid);
      resolver(result);
    }
  }

  /** 未回收的 pending 全部以失败结算（断开时调用，防 Promise 悬挂） */
  private failAllPending(why: string): void {
    this.pending.forEach((resolver: (r: CmdResult) => void) => {
      resolver(new CmdResult(false, '', '', -1, why));
    });
    this.pending.clear();
  }

  /**
   * 执行 shell 命令（P1-9 核心）：下发 command 帧，Promise 等待回执。
   * @param command shell 命令文本
   * @returns CmdResult（15s 超时 / 未连接 / 视图只读均返回 ok=false + error）
   */
  sendCommand(command: string): Promise<CmdResult> {
    if (this.state !== 'connected' || this.ws === null) {
      return Promise.resolve(new CmdResult(false, '', '', -1, '未连接终端'));
    }
    this.seq++;
    const requestId = `${Date.now()}_${this.seq}`;
    return new Promise<CmdResult>((resolve) => {
      // 15s 超时（对齐上游 executeCommand）
      const t = setTimeout(() => {
        if (this.pending.has(requestId)) {
          this.pending.delete(requestId);
          resolve(new CmdResult(false, '', '', -1, '执行超时(15s)'));
        }
      }, 15000);
      this.pending.set(requestId, (r: CmdResult) => {
        clearTimeout(t);
        resolve(r);
      });
      try {
        this.ws?.send(JSON.stringify({
          message_type: 'command',
          device_id: this.deviceId,
          request_id: requestId,
          command: command
        }));
        Logger.info('Shell', `→ ${command}`);
      } catch (e) {
        this.pending.delete(requestId);
        clearTimeout(t);
        resolve(new CmdResult(false, '', '', -1, '发送失败'));
      }
    });
  }

  /** 断开并清理（页面 aboutToDisappear 调用） */
  disconnect(): void {
    this.failAllPending('会话已关闭');
    if (this.ws !== null) {
      const w = this.ws;
      this.ws = null;
      try {
        w.close({ code: 1000, reason: 'shell done' });
      } catch (e) {
        Logger.warn('Shell', 'close 异常（忽略）');
      }
    }
    this.setState('disconnected');
  }
}
