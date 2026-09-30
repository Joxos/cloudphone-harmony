/**
 * 设备服务（DeviceService）—— 设备列表 REST 与设备发现统一入口
 *
 * 解耦边界：页面 → DeviceService → HttpClient/Prefs/DiscoveryService
 * P0 对应：P0-2（列表/信息/401）、P0-12（NO_AUTH 模式下免 token 拉取）
 */
import { HttpClient, httpScheme } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Device } from '../../model/Model';
import { Logger } from '../../utils/Logger';

/** 拉取结果：unauthorized=true 表示 401（token 已清除，页面应跳回登录页） */
export class DeviceListResult {
  ok: boolean;
  devices: Device[];
  error: string;
  unauthorized: boolean;

  constructor(ok: boolean, devices: Device[], error: string = '', unauthorized: boolean = false) {
    this.ok = ok;
    this.devices = devices;
    this.error = error;
    this.unauthorized = unauthorized;
  }
}

export class DeviceService {
  private static instance: DeviceService | null = null;
  private http: HttpClient = new HttpClient();
  private prefs: Prefs = Prefs.getInstance();

  static getInstance(): DeviceService {
    if (DeviceService.instance === null) {
      DeviceService.instance = new DeviceService();
    }
    return DeviceService.instance;
  }

  /**
   * 拉取服务器设备列表（GET /devices，Bearer 认证；NO_AUTH 模式免 token）
   */
  async fetchDevices(): Promise<DeviceListResult> {
    const token = await this.prefs.getToken();
    const noAuth = await this.prefs.getBoolean('no_auth_mode', false);
    const ip = await this.prefs.getServerIp();
    const useSsl = await this.prefs.getUseSsl();
    if (ip.length === 0) {
      return new DeviceListResult(false, [], '未登录');
    }
    if (token.length === 0 && !noAuth) {
      return new DeviceListResult(false, [], '未登录');
    }
    const url = `${httpScheme(useSsl)}${ip}/devices`;
    const res = await this.http.getJson(url, token);
    if (res.code === 401) {
      // 对齐 web 行为：401 → 清 token（保留服务器地址），页面据此回登录页
      await this.prefs.putString('auth_token', '');
      await this.prefs.putBoolean('no_auth_mode', false);
      Logger.warn('DeviceService', '401 Unauthorized：本地 token 已清除');
      return new DeviceListResult(false, [], '登录已过期（401），请重新登录', true);
    }
    if (!res.ok) {
      return new DeviceListResult(false, [], `获取设备列表失败: ${res.code}`);
    }
    try {
      const parsed: Object = JSON.parse(res.body);
      // 兼容两种响应格式：{"devices":[...]} 或裸数组 [...]
      let list: Record<string, Object>[] = [];
      if (Array.isArray(parsed)) {
        list = parsed as Record<string, Object>[];
      } else {
        const obj = parsed as Record<string, Object>;
        if (obj['devices'] !== undefined) {
          list = obj['devices'] as Record<string, Object>[];
        }
      }
      const devices: Device[] = [];
      for (const d of list) {
        const dev = new Device(
          d['device_id'] as string,
          (d['name'] as string) ?? '',
          (d['online'] as boolean) ?? false
        );
        dev.first_seen = d['first_seen'] as number;
        dev.last_seen = d['last_seen'] as number;
        dev.client_count = (d['client_count'] as number) ?? 0;
        dev.app_version = (d['app_version'] as string) ?? '';
        // device_info.displays[0] → 逻辑分辨率（触控坐标换算基准）
        const info = d['device_info'] as Record<string, Object>;
        if (info !== undefined && info !== null && info['displays'] !== undefined) {
          const displays = info['displays'] as Record<string, Object>[];
          if (Array.isArray(displays) && displays.length > 0) {
            dev.x_res = (displays[0]['x_res'] as number) ?? 0;
            dev.y_res = (displays[0]['y_res'] as number) ?? 0;
          }
        }
        devices.push(dev);
      }
      Logger.info('DeviceService', `获取设备列表: ${devices.length} 台`);
      return new DeviceListResult(true, devices);
    } catch (e) {
      return new DeviceListResult(false, [], '解析设备列表失败');
    }
  }
}
