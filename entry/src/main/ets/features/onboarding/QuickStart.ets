/**
 * QuickStart —— 快速接入引导域（P2-11，对应上游 DeviceList.vue quickstart 372-527）
 *
 * 职责（单一）：ICE 服务拉取（GET /api/ice_servers）与信令/下载地址解析（IO 部分）。
 * 纯命令模板在 utils/QuickStartCmd.ets（展示组件按分层规则 import utils，不触碰本域）。
 * 下载端点：/agent/agent-deploy.pkg（存为 agent-deploy.zip）、/agent/cloudphone-agent-magisk.pkg。
 * 网页 USB 部署入口（上游模式①）依赖 WebUSB——列 P3。
 * 依赖：utils/{HttpClient,Prefs}。
 */
import { HttpClient, httpScheme, normalizeHost, wsScheme } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Logger } from '../../utils/Logger';

export class QuickStart {
  private static http: HttpClient = new HttpClient();

  /**
   * GET /api/ice_servers → 紧凑 JSON 文本（命令行 -ice-servers 参数；失败回退 []）。
   */
  static async fetchIceJson(): Promise<string> {
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return '[]';
    }
    const url = `${httpScheme(useSsl)}${ip}/api/ice_servers`;
    const res = await QuickStart.http.getJson(url, token);
    if (!res.ok) {
      Logger.warn('QuickStart', `ice_servers 拉取失败: ${res.code}`);
      return '[]';
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      const servers = obj['ice_servers'] ?? [];
      return JSON.stringify(servers);
    } catch (e) {
      return '[]';
    }
  }

  /** 信令地址（agent 用）：ws/wss 跟随 use_ssl + 服务器 host（B-3 同规则） */
  static async signalingUrl(): Promise<string> {
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (ip.length === 0) {
      return '';
    }
    return `${wsScheme(useSsl)}${normalizeHost(ip)}`;
  }

  /** agent 下载根：http(s)://host（组件展示下载动作时由页面传入） */
  static async agentRoot(): Promise<string> {
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (ip.length === 0) {
      return '';
    }
    return `${httpScheme(useSsl)}${normalizeHost(ip)}`;
  }
}
