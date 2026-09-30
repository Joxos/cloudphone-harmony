/**
 * 设备模型（对应安卓 Device.java / 服务端 /devices 返回）
 */
export class Device {
  /** 设备唯一 ID（信令 connect/device_id 消息主键） */
  device_id: string;
  /** 展示名（服务端可编辑，空时 UI 显示「未命名设备」） */
  name: string;
  /** 在线状态（列表分区依据） */
  online: boolean;
  /** 首次注册时间戳（离线档案展示，可缺省） */
  first_seen?: number;
  /** 最后在线时间戳（离线档案展示，可缺省） */
  last_seen?: number;
  /** 备注（服务端 device note，可缺省） */
  note?: string;
  // device_info.displays[0]：设备逻辑分辨率——触控坐标换算基准（P0-5，来自 device_info 信令/REST）
  /** 逻辑宽（px）；0 = 未拿到 device_info */
  x_res: number = 0;
  /** 逻辑高（px）；0 = 未拿到 device_info */
  y_res: number = 0;
  /** 当前控制该设备的连接数（列表「N 人在控」展示） */
  client_count: number = 0;
  /** 被控端 Agent 版本串（可缺省展示） */
  app_version: string = '';

  constructor(device_id: string, name: string = '', online: boolean = false) {
    this.device_id = device_id;
    this.name = name;
    this.online = online;
  }
}

/**
 * 登录/注册请求体（对应 /api/login、/api/register）
 */
export class LoginPayload {
  username: string;
  password: string;

  constructor(username: string, password: string) {
    this.username = username;
    this.password = password;
  }
}

/**
 * 认证结果（AuthService 返回）
 */
export class AuthResult {
  ok: boolean;
  message: string;
  token: string;
  username: string;
  serverHost: string;
  useSsl: boolean;

  constructor(ok: boolean, message: string, token: string = '', username: string = '',
    serverHost: string = '', useSsl: boolean = true) {
    this.ok = ok;
    this.message = message;
    this.token = token;
    this.username = username;
    this.serverHost = serverHost;
    this.useSsl = useSsl;
  }
}

/**
 * 路由参数（页面间传递，RootPage @Provide 共享，跳转前设置）
 * 约定：源页面跳转前写入目标字段，目标页面消费后按需清空（如 Index 消费 serverUrl）。
 */
export class RouteParams {
  /** 目标设备 ID（控制页信令 connect 首帧使用；分享流程由 /api/share/info 解析后写入） */
  deviceId: string = '';
  /** 只读访客模式（SharePage 写入 → control.html viewOnly 五处源头拦截） */
  viewOnly: boolean = false;
  /** 分享卡密（连接串 ?share_token=；非空时优先于 login token） */
  shareToken: string = '';
  /** 分享访问密码（?share_pwd=，可空） */
  sharePwd: string = '';
  /** 预览直控坐标基准：设备逻辑宽（P1-5；0=未拿到 device_info，直控禁用） */
  deviceXRes: number = 0;
  /** 预览直控坐标基准：设备逻辑高（P1-5；与 deviceXRes 成对） */
  deviceYRes: number = 0;
  /** 扫描/发现带回的服务器地址（Index 消费后清空；空 = 用 Prefs 已存服务器） */
  serverUrl: string = ''; // 从扫描/发现进入时的服务器地址（Index 消费后清空）
}

/**
 * mDNS 发现的设备（安卓端 _scrcpy_wrtc._tcp）
 */
export class DiscoveredDevice {
  uuid: string;
  name: string;
  host: string;
  port: number;

  constructor(uuid: string, name: string, host: string, port: number) {
    this.uuid = uuid;
    this.name = name;
    this.host = host;
    this.port = port;
  }

  getUrl(): string {
    return `https://${this.host}:${this.port}`;
  }
}

/**
 * 可注册监听的信令通道（GlobalChannel 的结构契约——放 model 供跨域共享类型，
 * features 只依赖 model 不互 import；实现方需显式 implements 满足名义类型校验）。
 */
export interface ChannelLike {
  on: (type: string, cb: (msg: Record<string, Object>) => void) => void;
}

/**
 * 管理员对当前用户的设置策略（GET /api/me 返回，P1-4）
 * 对应上游 auth.js userPolicy：forbid_* 四维置灰 + settings 强制值 + 账号有效期。
 */
export class UserPolicy {
  /** 锁定码率维度（含 BWE 上下限） */
  forbidBitrate: boolean = false;
  /** 锁定帧率维度 */
  forbidFps: boolean = false;
  /** 锁定分辨率维度 */
  forbidResolution: boolean = false;
  /** 锁定音频维度（含增益/采集源/dup） */
  forbidAudio: boolean = false;
  /** 强制值 JSON（{fps?,size?,bitrate?,audio?,audio_gain?}）——字符串承载规避无类型对象字面量 */
  settingsJson: string = '{}';
  /** 账号到期时间戳（0=永久；到期倒计时属授权面板 P3） */
  expiresAt: number = 0;
}

