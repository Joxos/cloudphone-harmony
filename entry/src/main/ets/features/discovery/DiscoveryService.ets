/**
 * 局域网发现服务（DiscoveryService）
 *
 * 双通道扫描（互补，不互相替代）：
 *   1) mDNS：扫描 `_scrcpy_wrtc._tcp` 广播（安卓 App 被控端模式/agent -mdns）
 *      —— 真机同网段最快；模拟器 slirp NAT 下多播被截断，扫不到局域网机器。
 *   2) TCP 网段扫描：候选网段逐主机探测 8443 端口 + HTTPS 指纹验证
 *      —— 单播可达即有效（含模拟器 NAT）；不依赖被控端主动广播。
 *
 * 解耦边界：页面通过 DiscoveryListener 订阅回调；服务内部不触碰 UI。
 */
import { mdns, connection, socket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { HttpClient } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { DiscoveredDevice } from '../../model/Model';
import { Logger } from '../../utils/Logger';

export const MDNS_SERVICE_TYPE: string = '_scrcpy_wrtc._tcp';
export const SERVER_PORT: number = 8443;

export interface DiscoveryListener {
  onDeviceFound: (device: DiscoveredDevice) => void;
  onDeviceLost: (serviceName: string) => void;
  onDiscoveryStarted: () => void;
  onDiscoveryStopped: () => void;
  /** 扫描进度/状态文本（TCP 网段扫描阶段消息） */
  onProgress: (msg: string) => void;
  onError: (msg: string) => void;
}

export class DiscoveryService {
  private static instance: DiscoveryService | null = null;
  private mdnsService: mdns.DiscoveryService | null = null;
  private context: common.Context | null = null;
  private listeners: DiscoveryListener[] = [];
  private resolving: Map<string, boolean> = new Map();
  private mdnsHosts: Map<string, string> = new Map(); // mDNS 服务名 → host
  private knownHosts: Set<string> = new Set(); // 已上报 host（mDNS/TCP 去重）
  private tcpScanning: boolean = false;
  private http: HttpClient = new HttpClient();

  static getInstance(): DiscoveryService {
    if (DiscoveryService.instance === null) {
      DiscoveryService.instance = new DiscoveryService();
    }
    return DiscoveryService.instance;
  }

  setContext(context: common.Context): void {
    this.context = context;
  }

  addListener(listener: DiscoveryListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  removeListener(listener: DiscoveryListener): void {
    this.listeners = this.listeners.filter((l: DiscoveryListener) => l !== listener);
  }

  // ===================== mDNS 通道 =====================

  /**
   * 开始 mDNS 扫描（_scrcpy_wrtc._tcp）
   */
  startDiscovery(): void {
    if (this.context === null) {
      this.notifyError('DiscoveryService 未初始化 context');
      return;
    }
    if (this.mdnsService !== null) {
      return; // 已启动
    }
    try {
      const svc = mdns.createDiscoveryService(this.context, MDNS_SERVICE_TYPE);

      svc.on('serviceFound', (info: mdns.LocalServiceInfo) => {
        this.handleServiceFound(info);
      });
      svc.on('serviceLost', (info: mdns.LocalServiceInfo) => {
        Logger.info('Discovery', `mDNS 服务丢失: ${info.serviceName}`);
        const host = this.mdnsHosts.get(info.serviceName);
        if (host !== undefined) {
          this.knownHosts.delete(host);
        }
        this.mdnsHosts.delete(info.serviceName);
        for (const l of this.listeners) {
          l.onDeviceLost(info.serviceName);
        }
      });
      svc.on('discoveryStart', () => {
        Logger.info('Discovery', 'mDNS 扫描已开始');
        for (const l of this.listeners) {
          l.onDiscoveryStarted();
        }
      });
      svc.on('discoveryStop', () => {
        Logger.info('Discovery', 'mDNS 扫描已停止');
        for (const l of this.listeners) {
          l.onDiscoveryStopped();
        }
      });

      this.mdnsService = svc;
      svc.startSearchingMDNS();
    } catch (e) {
      const err = e as Error;
      Logger.error('Discovery', `启动 mDNS 扫描失败: ${err.message}`);
      this.notifyError(`mDNS 扫描不可用: ${err.message}`);
    }
  }

  private handleServiceFound(info: mdns.LocalServiceInfo): void {
    if (this.context === null) {
      return;
    }
    const name = info.serviceName;
    if (this.resolving.has(name)) {
      return;
    }
    this.resolving.set(name, true);
    // 解析出 host/port（TXT 记录不可直接取，解析后获得地址）
    mdns.resolveLocalService(this.context, info).then((resolved: mdns.LocalServiceInfo) => {
      this.resolving.delete(name);
      const host = resolved.host?.address;
      const port = resolved.port ?? SERVER_PORT;
      if (host === undefined || host.length === 0) {
        Logger.warn('Discovery', `解析 ${name} 失败：无地址`);
        return;
      }
      // TXT（uuid、name）——身份统一用服务名前缀（与 onDeviceLost 对账稳定），
      // TXT 仅取友好名展示；无 name 时回落 uuid（服务名前缀）
      let uuid = name.split('.')[0];
      let friendly = '';
      const attrs = resolved.serviceAttribute;
      if (attrs !== undefined && attrs !== null) {
        const decoder = util.TextDecoder.create();
        for (const a of attrs) {
          // TXT value 为字节数组（Array<number>），UTF-8 解码后取友好名
          if (a.key === 'name' && a.value !== undefined && a.value.length > 0) {
            friendly = decoder.decodeWithStream(new Uint8Array(a.value));
          }
        }
      }
      const device = new DiscoveredDevice(uuid, friendly.length > 0 ? friendly : uuid, host, port);
      Logger.info('Discovery', `mDNS 发现设备: ${name} @ ${host}:${port}`);
      this.mdnsHosts.set(name, host);
      this.notifyDeviceFound(device);
    }).catch((e: Error) => {
      this.resolving.delete(name);
      Logger.warn('Discovery', `解析 ${name} 失败: ${e.message}`);
    });
  }

  // ===================== TCP 网段扫描通道 =====================

  /**
   * 开始 TCP 网段扫描（异步，自动结束）
   */
  startTcpScan(): void {
    if (this.tcpScanning) {
      return;
    }
    this.tcpScanning = true;
    this.runTcpScan();
  }

  stopTcpScan(): void {
    this.tcpScanning = false;
  }

  private async runTcpScan(): Promise<void> {
    try {
      const subnets = await this.collectSubnets();
      if (subnets.length === 0) {
        return;
      }
      this.notifyProgress(`网段扫描: ${subnets.join('、')} ...`);
      for (const subnet of subnets) {
        if (!this.tcpScanning) {
          return;
        }
        await this.scanSubnet(subnet);
      }
      this.notifyProgress(this.knownHosts.size > 0 ?
        `扫描完成，共发现 ${this.knownHosts.size} 台被控端` : '扫描完成，未发现被控端');
    } catch (e) {
      const err = e as Error;
      Logger.error('Discovery', `网段扫描异常: ${err.message}`);
      this.notifyError(`网段扫描异常: ${err.message}`);
    } finally {
      this.tcpScanning = false;
    }
  }

  /**
   * 候选网段：
   *   1) 本机所在网段（真机即实际局域网；模拟器为其虚拟网段，无碍）
   *   2) 上次连接过的被控端所在网段
   *   3) 常见家用/办公网段兜底
   */
  private async collectSubnets(): Promise<string[]> {
    const subs: string[] = [];
    const pushSubnet = (ip: string): void => {
      const parts = ip.split('.');
      if (parts.length !== 4) {
        return;
      }
      const a = Number(parts[0]);
      const b = Number(parts[1]);
      const isPrivate = a === 10 ||
        (a === 192 && b === 168) ||
        (a === 172 && b >= 16 && b <= 31);
      if (!isPrivate) {
        return;
      }
      const s = `${parts[0]}.${parts[1]}.${parts[2]}`;
      if (!subs.includes(s)) {
        subs.push(s);
      }
    };

    try {
      const net = await connection.getDefaultNet();
      const props = await connection.getConnectionProperties(net);
      for (const la of props.linkAddresses) {
        const addr = la.address?.address ?? '';
        if (la.address?.family === 1 && addr.length > 0 && !addr.startsWith('127.')) {
          pushSubnet(addr);
        }
      }
    } catch (e) {
      Logger.warn('Discovery', `读取本机网段失败（忽略）: ${(e as Error).message}`);
    }

    const lastServer = await Prefs.getInstance().getServerIp();
    if (lastServer.length > 0) {
      pushSubnet(lastServer);
    }
    for (const s of ['192.168.2', '192.168.1', '192.168.0', '192.168.31']) {
      if (!subs.includes(s)) {
        subs.push(s);
      }
    }
    return subs;
  }

  private async scanSubnet(subnet: string): Promise<void> {
    this.notifyProgress(`正在扫描 ${subnet}.1-254 ...`);
    const BATCH: number = 40;
    for (let base = 1; base <= 254; base += BATCH) {
      if (!this.tcpScanning) {
        return;
      }
      const tasks: Promise<void>[] = [];
      for (let i = base; i < base + BATCH && i <= 254; i++) {
        tasks.push(this.probeHost(`${subnet}.${i}`));
      }
      await Promise.all(tasks);
    }
  }

  /**
   * 单主机探测：8443 TCP 连通 → HTTPS 指纹验证 → 上报
   */
  private async probeHost(ip: string): Promise<void> {
    if (!this.tcpScanning) {
      return;
    }
    const tcp = socket.constructTCPSocketInstance();
    try {
      await tcp.connect({
        address: { address: ip, port: SERVER_PORT, family: 1 },
        timeout: 600
      });
      await tcp.close();
      const device = await this.verifyServer(ip);
      if (device !== null) {
        this.notifyDeviceFound(device);
      }
    } catch (e) {
      // 端口未开/超时：非目标主机，忽略
    }
  }

  /**
   * HTTPS 指纹验证：8443 为本应用专用端口，任何真实 HTTP 响应即视为被控端。
   * 实测 webrtc-signaling v0.3.2：无 token 时 /devices 返回 401 "Unauthorized"（纯文本，
   * 非 JSON），/ 返回 200（web UI）——因此只要求 HTTP 状态码有效（100-599），
   * 不校验响应体结构。非目标 TLS 服务误报代价低（用户点击连接即知失败）。
   */
  private async verifyServer(ip: string): Promise<DiscoveredDevice | null> {
    const res = await this.http.getJson(`https://${ip}:${SERVER_PORT}/devices`);
    if (res.code >= 100) {
      Logger.info('Discovery', `TCP 扫描确认被控端: ${ip}:${SERVER_PORT} (HTTP ${res.code})`);
      return new DiscoveredDevice(`tcp-${ip}`, `被控端 ${ip}`, ip, SERVER_PORT);
    }
    return null;
  }

  // ===================== 公共 =====================

  /**
   * 停止全部扫描（mDNS + TCP）
   */
  stopDiscovery(): void {
    if (this.mdnsService !== null) {
      try {
        this.mdnsService.stopSearchingMDNS();
      } catch (e) {
        Logger.warn('Discovery', '停止 mDNS 扫描异常（忽略）');
      }
      this.mdnsService = null;
    }
    this.resolving.clear();
    this.tcpScanning = false;
  }

  private notifyDeviceFound(device: DiscoveredDevice): void {
    if (this.knownHosts.has(device.host)) {
      return;
    }
    this.knownHosts.add(device.host);
    for (const l of this.listeners) {
      l.onDeviceFound(device);
    }
  }

  private notifyProgress(msg: string): void {
    for (const l of this.listeners) {
      l.onProgress(msg);
    }
  }

  private notifyError(msg: string): void {
    for (const l of this.listeners) {
      l.onError(msg);
    }
  }
}
