/**
 * REST API 客户端（原生壳：登录/设备列表用）
 *
 * ⚠️ 模块归属（调研确认）：http 属于 @kit.NetworkKit（@ohos.net.http），
 *    不属于 @kit.BasicServicesKit。BusinessError 从 @kit.BasicServicesKit 导入。
 *
 * ✅ 自签证书方案：被控端/服务器为自签 HTTPS —— https 请求统一
 *    remoteValidation:'skip'（API 18+，跳过证书与主机名校验）。
 *    对外分发场景应改用受信证书。
 */
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

export class ApiResult {
  ok: boolean;
  code: number;
  body: string;
  error: string;

  constructor(ok: boolean, code: number, body: string, error: string = '') {
    this.ok = ok;
    this.code = code;
    this.body = body;
    this.error = error;
  }
}

export class HttpClient {
  private client: http.HttpRequest;

  constructor() {
    this.client = http.createHttp();
  }

  /**
   * POST JSON
   */
  async postJson(url: string, payload: object, token: string = ''): Promise<ApiResult> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json; charset=utf-8'
    };
    if (token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: JSON.stringify(payload),
      connectTimeout: 10000,
      readTimeout: 15000,
      expectDataType: http.HttpDataType.STRING
    };
    return this.request(url, options);
  }

  /**
   * GET（带 Bearer）
   */
  async getJson(url: string, token: string = ''): Promise<ApiResult> {
    const headers: Record<string, string> = {};
    if (token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.GET,
      header: headers,
      connectTimeout: 10000,
      readTimeout: 15000,
      expectDataType: http.HttpDataType.STRING
    };
    return this.request(url, options);
  }

  /**
   * POST 原始字节体（P2-5b：/upload 等非 JSON 端点——上游 xhr.send(file) 同形）。
   * 大文件上行放宽读超时（默认 120s）。
   */
  async postRaw(url: string, bytes: Uint8Array, token: string = ''): Promise<ApiResult> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/octet-stream'
    };
    if (token.length > 0) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST,
      header: headers,
      extraData: bytes.buffer,
      connectTimeout: 10000,
      readTimeout: 120000,
      expectDataType: http.HttpDataType.STRING
    };
    return this.request(url, options);
  }

  private async request(url: string, options: http.HttpRequestOptions): Promise<ApiResult> {
    try {
      // 云手机服务器为自签 HTTPS 且证书主机名与当前 IP 不匹配（设备重启 IP 变更）：
      // remoteValidation: 'skip'（since 18）跳过服务器证书/主机名验证（对外分发应使用受信证书）
      if (url.startsWith('https://')) {
        options.remoteValidation = 'skip';
      }
      const resp = await this.client.request(url, options);
      const code = resp.responseCode;
      const body = typeof resp.result === 'string' ? resp.result : JSON.stringify(resp.result);
      return new ApiResult(code >= 200 && code < 300, code, body);
    } catch (e) {
      const err = e as BusinessError;
      Logger.error('HttpClient', `请求失败 ${url}: ${err.code} ${err.message}`);
      return new ApiResult(false, 0, '', `${err.code}: ${err.message}`);
    }
  }

  destroy(): void {
    this.client.destroy();
  }
}

/**
 * 服务器地址规范化：https://host[:port] → host[:port]
 */
export function normalizeHost(url: string): string {
  let host = url.trim();
  if (host.startsWith('https://')) {
    host = host.substring(8);
  } else if (host.startsWith('http://')) {
    host = host.substring(7);
  }
  // 去掉尾部斜杠
  while (host.endsWith('/')) {
    host = host.substring(0, host.length - 1);
  }
  // 无端口时补 8443
  const idx = host.lastIndexOf(':');
  if (idx === -1) {
    host = `${host}:8443`;
  }
  return host;
}

/** REST 协议方案：use_ssl=true → 'https://'，false → 'http://'（与 normalizeHost 配对使用） */
export function httpScheme(useSsl: boolean): string {
  return useSsl ? 'https://' : 'http://';
}

/** 信令 WS 方案：与 REST 同源决策（B-3：页面 ws/wss 跟随同一 use_ssl） */
export function wsScheme(useSsl: boolean): string {
  return useSsl ? 'wss://' : 'ws://';
}
