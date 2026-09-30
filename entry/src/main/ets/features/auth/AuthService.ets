/**
 * 认证服务（AuthService）—— 登录/注册/登出与 token 管理
 *
 * 解耦边界：页面 → AuthService → HttpClient/Prefs；页面不直接触碰网络与存储。
 */
import { HttpClient, normalizeHost, httpScheme } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { LoginPayload, AuthResult, UserPolicy } from '../../model/Model';
import { Logger } from '../../utils/Logger';

/** P2-3b：AI 配置云同步请求体（上游 saveAIConfig 四键契约） */
interface AiConfigBody {
  ai_api_url: string;
  ai_api_key: string;
  ai_model: string;
  ai_provider: string;
}

export class AuthService {
  private static instance: AuthService | null = null;
  private http: HttpClient = new HttpClient();
  private prefs: Prefs = Prefs.getInstance();

  static getInstance(): AuthService {
    if (AuthService.instance === null) {
      AuthService.instance = new AuthService();
    }
    return AuthService.instance;
  }

  /**
   * 登录（或注册）并持久化凭证
   * @returns 成功返回 AuthResult，失败返回 null（错误信息经 error 字段回传）
   */
  async authenticate(serverInput: string, username: string, password: string, isLogin: boolean): Promise<AuthResult> {
    if (serverInput.length === 0) {
      return new AuthResult(false, '请输入服务器地址');
    }
    if (!serverInput.startsWith('http://') && !serverInput.startsWith('https://')) {
      return new AuthResult(false, '地址需包含协议前缀，如 https:// 或 http://');
    }
    if (username.length === 0 || password.length === 0) {
      // P0-12：空凭证 → 先探测服务器是否 NO_AUTH（免登录直连，/api/auth-status）
      const noAuth = await this.checkNoAuth(serverInput);
      if (noAuth) {
        return new AuthResult(true, '服务器免登录（NO_AUTH），已直连',
          '', '', normalizeHost(serverInput), serverInput.startsWith('https://'));
      }
    }
    if (username.length === 0) {
      return new AuthResult(false, '请输入用户名');
    }
    if (password.length === 0) {
      return new AuthResult(false, '请输入密码');
    }

    const useSsl = serverInput.startsWith('https://');
    const host = normalizeHost(serverInput);
    const path = isLogin ? '/api/login' : '/api/register';
    const url = `${httpScheme(useSsl)}${host}${path}`;

    const res = await this.http.postJson(url, new LoginPayload(username, password));
    if (!res.ok) {
      if (isLogin) {
        // P0-12：登录被拒 → 可能是 NO_AUTH 服务器（默认凭证无意义）→ 探测后直连
        const noAuth = await this.checkNoAuth(serverInput);
        if (noAuth) {
          return new AuthResult(true, '服务器免登录（NO_AUTH），已直连',
            '', '', normalizeHost(serverInput), serverInput.startsWith('https://'));
        }
      }
      let msg = `操作失败，代码: ${res.code}`;
      // res.code === 0 是 HttpClient 的哨兵值：请求抛了异常、压根没拿到任何 HTTP 响应
      // （网络不可达 / 证书 / DNS）。此时 res.error 里才有真实原因（如
      // 2300007 Failed to connect to the server），只报「代码 0」对用户毫无意义。
      if (res.code === 0 && res.error.length > 0) {
        Logger.warn('AuthService', `登录请求异常 @ ${host}: ${res.error}`);
        return new AuthResult(false, `连接失败：${res.error}`);
      }
      if (res.body.length > 0) {
        try {
          const obj = JSON.parse(res.body) as Record<string, Object>;
          msg = (obj['error'] as string) ?? msg;
        } catch (e) {
          // 忽略解析失败，使用默认消息
        }
      }
      return new AuthResult(false, msg);
    }
    if (!isLogin) {
      // P0-1：注册成功后自动登录（对齐 web 版"注册→自动进登录态"）
      const auto = await this.authenticate(serverInput, username, password, true);
      if (auto.ok) {
        return new AuthResult(true, '注册成功并已登录', auto.token, auto.username, auto.serverHost, auto.useSsl);
      }
      return new AuthResult(true, '注册成功，请点击登录', '', username, host, useSsl);
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      const token = obj['token'] as string;
      const user = (obj['username'] as string) ?? username;
      await this.prefs.putString('server_ip', host);
      await this.prefs.putBoolean('use_ssl', useSsl);
      await this.prefs.putString('auth_token', token);
      await this.prefs.putString('auth_user', user);
      // P2-3b：登录载荷回填 AI 配置（上游 auth.js data.ai_config → 本地四键同名）
      const aiCfg = obj['ai_config'];
      if (aiCfg !== undefined && aiCfg !== null) {
        const a = aiCfg as Record<string, Object>;
        await this.prefs.putString('ai_api_url', (a['ai_api_url'] as string) ?? '');
        await this.prefs.putString('ai_api_key', (a['ai_api_key'] as string) ?? '');
        await this.prefs.putString('ai_model', (a['ai_model'] as string) ?? '');
        await this.prefs.putString('ai_provider', (a['ai_provider'] as string) ?? '');
      }
      Logger.info('AuthService', `登录成功: ${user} @ ${host}`);
      return new AuthResult(true, '登录成功', token, user, host, useSsl);
    } catch (e) {
      return new AuthResult(false, '登录解析错误');
    }
  }

  /**
   * 会话级登录（不持久化）：为指定服务器获取 token（如 ArkWeb 远程控制台注入用）
   * @returns 成功返回 token，失败返回空串
   */
  async loginForSession(serverInput: string, username: string, password: string): Promise<string> {
    if (serverInput.length === 0 || username.length === 0 || password.length === 0) {
      return '';
    }
    const useSsl = serverInput.startsWith('https://');
    const host = normalizeHost(serverInput);
    const url = `${httpScheme(useSsl)}${host}/api/login`;
    const res = await this.http.postJson(url, new LoginPayload(username, password));
    if (!res.ok) {
      Logger.warn('AuthService', `会话登录失败 @ ${host}: ${res.error}`);
      return '';
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      const token = obj['token'] as string;
      Logger.info('AuthService', `会话登录成功 @ ${host}`);
      return token;
    } catch (e) {
      return '';
    }
  }

  /**
   * 扫描/自动路径快连（修复审计 B-2：原实现连发两次 login 且污染本地凭证）：
   *   ① NO_AUTH 探测——命中即持久化服务器并直连；
   *   ② 否则默认账号**会话登录一次**，token 直接落盘（不再二次 authenticate）。
   * 局限：扫描到的服务器若改过默认密码，快连失败 → 回落手动表单（凭证 UX 属后续批次）。
   */
  async quickConnect(serverUrl: string): Promise<boolean> {
    if (await this.checkNoAuth(serverUrl)) {
      return true; // checkNoAuth 已持久化 server_ip/use_ssl/no_auth_mode
    }
    const token = await this.loginForSession(serverUrl, 'admin', 'admin123');
    if (token.length === 0) {
      return false;
    }
    const useSsl = serverUrl.startsWith('https://');
    const host = normalizeHost(serverUrl);
    await this.prefs.putString('server_ip', host);
    await this.prefs.putBoolean('use_ssl', useSsl);
    await this.prefs.putString('auth_token', token);
    await this.prefs.putString('auth_user', 'admin');
    Logger.info('AuthService', `快连成功: admin @ ${host}`);
    return true;
  }

  /**
   * 登出：彻底清除本地凭证（token + 服务器地址 + 用户）。
   * 退出后回到"未连接"初始态——下次启动不会自动重连，重新显示连接表单。
   */
  async logout(): Promise<void> {
    await this.prefs.putString('auth_token', '');
    await this.prefs.putString('server_ip', '');
    await this.prefs.putBoolean('use_ssl', true);
    await this.prefs.putString('auth_user', '');
    Logger.info('AuthService', '已登出（本地凭证已清除）');
  }

  /**
   * NO_AUTH 探测（P0-12）：GET /api/auth-status → {noAuth}
   * true 时写入 no_auth_mode 并暂存服务器地址，后续 /devices、信令免 token。
   * 探测失败/网络错误一律视为 false（不阻断正常登录路径）。
   */
  async checkNoAuth(serverInput: string): Promise<boolean> {
    if (serverInput.length === 0) {
      return false;
    }
    const useSsl = serverInput.startsWith('https://');
    const host = normalizeHost(serverInput);
    const url = `${httpScheme(useSsl)}${host}/api/auth-status`;
    const res = await this.http.getJson(url);
    if (!res.ok) {
      Logger.warn('AuthService', `auth-status 探测失败 @ ${host}: code=${res.code}`);
      return false;
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      const noAuth = (obj['noAuth'] as boolean) ?? false;
      await this.prefs.putBoolean('no_auth_mode', noAuth);
      if (noAuth) {
        await this.prefs.putString('server_ip', host);
        await this.prefs.putBoolean('use_ssl', useSsl);
        Logger.info('AuthService', `服务器 NO_AUTH 模式 @ ${host}（免登录）`);
      }
      return noAuth;
    } catch (e) {
      return false;
    }
  }

  /**
   * 401 统一处理（P0-1）：清除本地 token 与 NO_AUTH 标记，保留服务器地址。
   * 调用方（列表页等）收到 401 后调用本方法并跳回登录页。
   */
  async handleUnauthorized(): Promise<void> {
    await this.prefs.putString('auth_token', '');
    await this.prefs.putBoolean('no_auth_mode', false);
    Logger.warn('AuthService', '401 Unauthorized：本地凭证已清除');
  }

  /** 管理员策略缓存（/api/me 拉取，P1-4；null=未拉过） */
  private policy: UserPolicy | null = null;

  /**
   * P1-4：GET /api/me → 解析设置策略（forbid_* 四维 + settings 强制值 + expires_at）。
   * 失败返回空策略（不缓存，下次可重试）。
   */
  async fetchMe(): Promise<UserPolicy> {
    const ip = await this.prefs.getServerIp();
    const token = await this.prefs.getToken();
    const useSsl = await this.prefs.getUseSsl();
    const p = new UserPolicy();
    if (ip.length === 0 || token.length === 0) {
      return p;
    }
    const url = `${httpScheme(useSsl)}${ip}/api/me`;
    const res = await this.http.getJson(url, token);
    if (!res.ok) {
      Logger.warn('AuthService', `fetchMe 失败: ${res.code}`);
      return p;
    }
    try {
      const obj = JSON.parse(res.body) as Record<string, Object>;
      p.forbidBitrate = (obj['forbid_bitrate'] as boolean) ?? false;
      p.forbidFps = (obj['forbid_fps'] as boolean) ?? false;
      p.forbidResolution = (obj['forbid_resolution'] as boolean) ?? false;
      p.forbidAudio = (obj['forbid_audio'] as boolean) ?? false;
      p.expiresAt = (obj['expires_at'] as number) ?? 0;
      const settings = obj['settings'];
      p.settingsJson = settings !== undefined && settings !== null ? JSON.stringify(settings) : '{}';
      this.policy = p;
      Logger.info('AuthService', `策略已拉取: fps=${p.forbidFps} size=${p.forbidResolution} bitrate=${p.forbidBitrate} audio=${p.forbidAudio}`);
    } catch (e) {
      Logger.warn('AuthService', 'fetchMe 解析失败');
    }
    return p;
  }

  /**
   * 取策略（缓存优先）。
   * @param refresh true=强制重新拉取（设置页进入时刷新）
   */
  async getPolicy(refresh: boolean = false): Promise<UserPolicy> {
    if (!refresh && this.policy !== null) {
      return this.policy;
    }
    return this.fetchMe();
  }

  /**
   * 是否已登录（存在 token 且记录过服务器；NO_AUTH 模式下仅有服务器即视为可用）
   */
  async isLoggedIn(): Promise<boolean> {
    const ip = await this.prefs.getServerIp();
    if (ip.length === 0) {
      return false;
    }
    const noAuth = await this.prefs.getBoolean('no_auth_mode', false);
    if (noAuth) {
      return true;
    }
    const token = await this.prefs.getToken();
    return token.length > 0;
  }

  /**
   * 上次登录的服务器地址（带协议前缀，用于登录页回填）
   */
  /** P2-3b：AI 配置云端同步（上游 authStore.saveAIConfig 同契约：四键 Bearer POST） */
  async saveAiConfig(url: string, key: string, model: string, provider: string): Promise<boolean> {
    const ip = await this.prefs.getServerIp();
    const token = await this.prefs.getToken();
    const useSsl = await this.prefs.getUseSsl();
    if (ip.length === 0 || token.length === 0) {
      return false;
    }
    const body: AiConfigBody = {
      ai_api_url: url,
      ai_api_key: key,
      ai_model: model,
      ai_provider: provider
    };
    const url2 = `${httpScheme(useSsl)}${ip}/api/user/ai-config`;
    const res = await this.http.postJson(url2, body, token);
    if (!res.ok) {
      Logger.warn('AuthService', `AI 配置云同步失败: ${res.code}`);
    }
    return res.ok;
  }

  async getLastServerUrl(): Promise<string> {
    const ip = await this.prefs.getServerIp();
    const useSsl = await this.prefs.getUseSsl();
    return ip.length > 0 ? `${httpScheme(useSsl)}${ip}` : '';
  }

  async getLastUser(): Promise<string> {
    return this.prefs.getAuthUser();
  }
}
