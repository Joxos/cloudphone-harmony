/**
 * ShareService —— 分享卡密域（P2-4a，对应上游 ShareModal/ShareAdminPage/CardConnectModal）
 *
 * 职责（单一）：/api/share/* REST 封装与 ShareInfo 契约解析、访客链接生成、服务器地址列表。
 * 契约逐条来自 web-app 调用方实读：
 *   - list   GET  /api/share/list[?device_id=]  → {code, data:[ShareInfo]}（键 token_id/expires_at）
 *   - create POST {device_id, expire_seconds, access_mode, password, description,
 *                  forbid_bitrate/fps/resolution/audio} → {code, msg, data}（409=已有活跃分享）
 *   - revoke POST {token: tokenId}
 *   - extend POST {token: tokenId, extend_seconds}     → {code, msg}
 *   - redeem POST /api/share/redeem_card {card_code, password}（**免登录**）→ {data:{token}}
 *   - 地址   GET  /api/server/addresses → {data:{addresses[], current}}（访客链接 host 选择）
 *   - 链接   <scheme>://<host>/share?token=<token_id>（对齐上游 fullShareUrl）
 * 范围注记：/api/share/update（访客设置 guest_settings 编辑器）列 P2-4b 下一批。
 * 依赖：utils/{HttpClient,Prefs,Logger}。
 */
import { HttpClient, httpScheme, normalizeHost } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Logger } from '../../utils/Logger';
import { ConnectionSettings } from '../settings/ConnectionSettings';

/** 分享条目（wire 键 token_id/expires_at；字段防御式解析，缺省空串/关闭） */
export class ShareInfo {
  token_id: string = '';
  device_id: string = '';
  access_mode: string = '';
  description: string = '';
  created_at: string = '';
  expires_at: string = '';
  /** 访客四维锁定（P2-4b 编辑区初值来源） */
  forbid_bitrate: boolean = false;
  forbid_fps: boolean = false;
  forbid_resolution: boolean = false;
  forbid_audio: boolean = false;
  /** 访客画质 JSON（空串=未自定义即继承设备当前配置） */
  guest_settings_json: string = '';
}

/** 创建请求参数（对齐 ShareModal.createShare body 除 forbid_* 外的核心字段） */
export class ShareCreateArgs {
  deviceId: string = '';
  expireSeconds: number = 86400;
  /** 访问模式（取值 view 或 control） */
  accessMode: string = 'view';
  password: string = '';
  description: string = '';
}

/** 操作结果（服务端 code/msg 透出；share 仅 create 时有值） */
export class ShareOpResult {
  ok: boolean = false;
  msg: string = '';
  token: string = '';
}

/** create 请求体（显式类型规避无类型对象字面量；forbid_* 四维与 P1-4 同名） */
interface CreateBody {
  device_id: string;
  expire_seconds: number;
  access_mode: string;
  password: string;
  description: string;
  forbid_bitrate: boolean;
  forbid_fps: boolean;
  forbid_resolution: boolean;
  forbid_audio: boolean;
}

/** revoke 请求体 */
interface TokenBody {
  token: string;
}

/** extend 请求体 */
interface ExtendBody {
  token: string;
  extend_seconds: number;
}

/** redeem_card 请求体（免登录） */
interface RedeemBody {
  card_code: string;
  password: string;
}

/** update 请求体（ShareGuestSettingsModal save 实读：四维 forbid + 访客画质；null=继承） */
interface UpdateBody {
  token: string;
  forbid_bitrate: boolean;
  forbid_fps: boolean;
  forbid_resolution: boolean;
  forbid_audio: boolean;
  guest_settings: ConnectionSettings | null;
}

/** 端点凭据（类字段替代数组解构——arkts-no-destruct-decls 禁令） */
class EndpointParts {
  token: string = '';
  ip: string = '';
  useSsl: boolean = false;
}

export class ShareService {
  private static instance: ShareService | null = null;

  static getInstance(): ShareService {
    if (ShareService.instance === null) {
      ShareService.instance = new ShareService();
    }
    return ShareService.instance;
  }

  private http: HttpClient = new HttpClient();

  /** 端点凭据（token/服务器/是否 SSL；类字段替代数组解构） */
  private async baseParts(): Promise<EndpointParts> {
    const ep = new EndpointParts();
    ep.token = await Prefs.getInstance().getToken();
    ep.ip = await Prefs.getInstance().getServerIp();
    ep.useSsl = await Prefs.getInstance().getUseSsl();
    return ep;
  }

  /** wire 项 → ShareInfo（缺省空串/关闭，防御式） */
  private hydrate(raw: Object): ShareInfo {
    const r = raw as Record<string, Object>;
    const s = new ShareInfo();
    s.token_id = (r['token_id'] as string) ?? '';
    s.device_id = (r['device_id'] as string) ?? '';
    s.access_mode = (r['access_mode'] as string) ?? '';
    s.description = (r['description'] as string) ?? '';
    s.created_at = (r['created_at'] as string) ?? '';
    s.expires_at = (r['expires_at'] as string) ?? '';
    s.forbid_bitrate = (r['forbid_bitrate'] as boolean) ?? false;
    s.forbid_fps = (r['forbid_fps'] as boolean) ?? false;
    s.forbid_resolution = (r['forbid_resolution'] as boolean) ?? false;
    s.forbid_audio = (r['forbid_audio'] as boolean) ?? false;
    const gs = r['guest_settings'];
    s.guest_settings_json = (gs !== undefined && gs !== null) ? JSON.stringify(gs) : '';
    return s;
  }

  /** list（deviceId 空=全部；对齐 ShareAdminPage 全量视图） */
  async listShares(deviceId: string): Promise<ShareInfo[]> {
    const ep = await this.baseParts();
    if (ep.token.length === 0 || ep.ip.length === 0) {
      return [];
    }
    const suffix = deviceId.length > 0 ? `?device_id=${encodeURIComponent(deviceId)}` : '';
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/share/list${suffix}`;
    const res = await this.http.getJson(url, ep.token);
    if (!res.ok) {
      Logger.warn('ShareService', `list 失败: ${res.code}`);
      return [];
    }
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      if ((root['code'] as number) !== 0) {
        return [];
      }
      const data = root['data'];
      const out: ShareInfo[] = [];
      if (Array.isArray(data)) {
        for (const one of data as Object[]) {
          const info = this.hydrate(one);
          if (info.token_id.length > 0) {
            out.push(info);
          }
        }
      }
      return out;
    } catch (e) {
      Logger.warn('ShareService', 'list 解析失败');
      return [];
    }
  }

  /** create（409/非0 → ok=false + msg；上游优先展示服务端 msg） */
  async createShare(args: ShareCreateArgs): Promise<ShareOpResult> {
    const ep = await this.baseParts();
    const r = new ShareOpResult();
    if (ep.token.length === 0 || ep.ip.length === 0) {
      r.msg = '未登录';
      return r;
    }
    const body: CreateBody = {
      device_id: args.deviceId,
      expire_seconds: args.expireSeconds,
      access_mode: args.accessMode,
      password: args.password,
      description: args.description,
      forbid_bitrate: false,
      forbid_fps: false,
      forbid_resolution: false,
      forbid_audio: false
    };
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/share/create`;
    const res = await this.http.postJson(url, body, ep.token);
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      r.msg = (root['msg'] as string) ?? '';
      const data = root['data'];
      if (res.ok && (root['code'] as number) === 0 && data !== undefined && data !== null) {
        const info = this.hydrate(data);
        r.ok = true;
        r.token = info.token_id;
      }
    } catch (e) {
      r.msg = r.msg.length > 0 ? r.msg : `HTTP ${res.code}`;
    }
    if (!r.ok && r.msg.length === 0) {
      r.msg = res.code === 409 ? '该设备已有活跃分享' : `HTTP ${res.code}`;
    }
    return r;
  }

  /** revoke（上游只看 res.ok） */
  async revokeShare(tokenId: string): Promise<boolean> {
    const ep = await this.baseParts();
    if (ep.token.length === 0 || ep.ip.length === 0) {
      return false;
    }
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/share/revoke`;
    const body: TokenBody = { token: tokenId };
    const res = await this.http.postJson(url, body, ep.token);
    return res.ok;
  }

  /** extend（+seconds；失败带服务端 msg） */
  async extendShare(tokenId: string, seconds: number): Promise<ShareOpResult> {
    const ep = await this.baseParts();
    const r = new ShareOpResult();
    if (ep.token.length === 0 || ep.ip.length === 0) {
      r.msg = '未登录';
      return r;
    }
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/share/extend`;
    const body: ExtendBody = { token: tokenId, extend_seconds: seconds };
    const res = await this.http.postJson(url, body, ep.token);
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      r.ok = res.ok && (root['code'] as number) === 0;
      r.msg = (root['msg'] as string) ?? '';
    } catch (e) {
      r.ok = false;
      r.msg = `HTTP ${res.code}`;
    }
    return r;
  }

  /** redeem_card（**免登录**：卡密+密码换 token——上游 CardConnectModal 同形） */
  async redeemCard(cardCode: string, password: string): Promise<ShareOpResult> {
    const ep = await this.baseParts();
    const r = new ShareOpResult();
    if (ep.ip.length === 0) {
      r.msg = '未配置服务器';
      return r;
    }
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/share/redeem_card`;
    const body: RedeemBody = { card_code: cardCode, password: password };
    const res = await this.http.postJson(url, body);
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      r.ok = (root['code'] as number) === 0;
      r.msg = (root['msg'] as string) ?? '';
      const data = root['data'];
      if (r.ok && data !== undefined && data !== null) {
        r.token = ((data as Record<string, Object>)['token'] as string) ?? '';
      }
    } catch (e) {
      r.msg = `HTTP ${res.code}`;
    }
    return r;
  }

  /**
   * P2-4b：更新分享（访客四维锁定 + 访客画质）。
   * @param guestSettings null=访客继承设备当前配置（上游 draftSettings null 语义）；
   *   非空=整份画质设置随更新下发
   */
  async updateShare(tokenId: string, forbidBitrate: boolean, forbidFps: boolean,
    forbidResolution: boolean, forbidAudio: boolean,
    guestSettings: ConnectionSettings | null): Promise<ShareOpResult> {
    const ep = await this.baseParts();
    const r = new ShareOpResult();
    if (ep.token.length === 0 || ep.ip.length === 0) {
      r.msg = '未登录';
      return r;
    }
    const body: UpdateBody = {
      token: tokenId,
      forbid_bitrate: forbidBitrate,
      forbid_fps: forbidFps,
      forbid_resolution: forbidResolution,
      forbid_audio: forbidAudio,
      guest_settings: guestSettings
    };
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/share/update`;
    const res = await this.http.postJson(url, body, ep.token);
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      r.ok = res.ok && (root['code'] as number) === 0;
      r.msg = (root['msg'] as string) ?? '';
    } catch (e) {
      r.ok = false;
      r.msg = `HTTP ${res.code}`;
    }
    return r;
  }

  /** 访客链接（对齐上游 fullShareUrl；address 空=默认服务器 host，否则指定地址） */
  async buildShareUrl(tokenId: string, address: string = ''): Promise<string> {
    const ep = await this.baseParts();
    const host = address.length > 0 ? normalizeHost(address) : normalizeHost(ep.ip);
    if (host.length === 0) {
      return '';
    }
    return `${httpScheme(ep.useSsl)}${host}/share?token=${encodeURIComponent(tokenId)}`;
  }

  /** 服务器地址列表（GET /api/server/addresses；失败返回空——链接退回默认 host） */
  async serverAddresses(): Promise<string[]> {
    const ep = await this.baseParts();
    if (ep.token.length === 0 || ep.ip.length === 0) {
      return [];
    }
    const url = `${httpScheme(ep.useSsl)}${ep.ip}/api/server/addresses`;
    const res = await this.http.getJson(url, ep.token);
    if (!res.ok) {
      return [];
    }
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      if ((root['code'] as number) !== 0) {
        return [];
      }
      const data = root['data'] as Record<string, Object>;
      const list = data['addresses'];
      const out: string[] = [];
      if (Array.isArray(list)) {
        for (const one of list as Object[]) {
          out.push(String(one));
        }
      }
      return out;
    } catch (e) {
      return [];
    }
  }
}
