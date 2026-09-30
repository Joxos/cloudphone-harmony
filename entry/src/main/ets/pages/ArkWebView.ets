/**
 * 云手机控制页（直连被控端，自研控制页）
 *
 * 架构：原生壳提供参数（被控端地址/token/设备 ID）→ ArkWeb 加载本地自研控制页
 *  rawfile/control.html（信令+WebRTC 视频+触控）→ Chromium 内核
 *  执行 RTCPeerConnection（P2P 直连被控端 agent）。
 *
 * 证书处理：页面 wss 由 documentStart polyfill 桥接至鸿蒙原生 webSocket
 * （skipServerCertVerification）——被控端自签证书场景通用，不依赖任何托管网页。
 */
import { webview } from '@kit.ArkWeb';
import { pasteboard, deviceInfo } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Prefs } from '../utils/Prefs';
import { BlobSaver } from '../utils/BlobSaver';
import { HttpClient } from '../utils/HttpClient';
import { Logger } from '../utils/Logger';
import { AuthService } from '../features/auth/AuthService';
import { WebSocketBridge } from '../features/signaling/WebSocketBridge';
import { GlobalChannel } from '../features/signaling/GlobalChannel';
import { SettingsStore } from '../features/settings/SettingsStore';
import { GroupControl } from '../features/groupcontrol/GroupControl';
import { RouteParams } from '../model/Model';
import { ConnectionStatusBadge } from '../components/ConnectionStatusBadge';

@Component
export struct ArkWebView {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  @State pageTitle: string = '云手机控制';
  @State loading: boolean = true;
  /** 横屏：隐藏顶栏、悬浮返回按钮，视频全屏（跟随手机旋转） */
  @State isLandscape: boolean = false;
  /** P0-3：control.html 七态状态机上报（nativeBridge.onState） */
  @State connState: string = 'disconnected';
  @State connText: string = '未连接';
  /** P1-1：页面静音按钮文案态（真实状态以页面 audioEl 为准，点击乐观翻转） */
  @State audioMuted: boolean = false;

  private controller: webview.WebviewController = new webview.WebviewController();
  private wsBridge: WebSocketBridge = new WebSocketBridge();

  /** 被控端地址（host:port，来自路由参数或偏好存储） */
  private serverHost: string = '';
  /** P1-8：键位映射 config JSON（Prefs cloudphone_keymap；桥同步读取用缓存字段） */
  private keymapJson: string = '';
  /** P2-3：AI 配置 JSON 缓存（Prefs ai_api_url/key/model；桥同步读取） */
  private aiConfigJson: string = '{"url":"","key":"","model":""}';
  /** P2-3：LLM 通道专用 HTTP 实例（免 CORS——页面 fetch 外域常被拦） */
  private aiHttp: HttpClient = new HttpClient();
  /** 会话 token（已登录服务器的凭证） */
  private sessionToken: string = '';
  /** 设备 ID */
  private deviceId: string = '';
  /** 服务器是否 TLS（决定页面 ws:// 还是 wss://，B-3 修复） */
  private useSsl: boolean = true;
  /** P0-9：连接设置 → scrcpy_options JSON（进页时读一次，注入页面 requestOffer） */
  private scrcpyOptionsJson: string = '';

  aboutToAppear(): void {
    this.wsBridge.setController(this.controller);
    this.initParams();
    // P1-10：绑定本机为主控（从已选从机中剔除自身；空组=不广播）
    GroupControl.getInstance().bindMaster(this.routeParams.deviceId);
  }

  aboutToDisappear(): void {
    GroupControl.getInstance().unbindMaster(); // P1-10：退出即解散群组
    this.wsBridge.destroy();
    // 清除页面缓存，避免下次进入复用旧页面 surface（闪旧页面根因）
    try {
      this.controller.removeCache(true);
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 参数来源：
   *  1) routeParams.serverUrl（设备列表/扫描传入，如 192.168.2.2:8443）
   *  2) Prefs 已登录服务器（登录页登录过）
   * token：routeParams 指定服务器时用默认账号会话登录（不污染本地配置），否则用 Prefs token
   */
  private async initParams(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as Context;
    await Prefs.getInstance().init(ctx);

    let rawServer = this.routeParams.serverUrl;
    if (rawServer.length === 0) {
      const ip = await Prefs.getInstance().getServerIp();
      this.useSsl = await Prefs.getInstance().getUseSsl();
      if (ip.length > 0) {
        rawServer = `${this.useSsl ? 'https://' : 'http://'}${ip}`;
      }
    } else {
      // 显式指定的地址：scheme 按地址推导（http:// 明文服务器 → 页面用 ws://）
      this.useSsl = this.routeParams.serverUrl.startsWith('https://');
    }
    // 规范化：去掉协议前缀
    this.serverHost = rawServer.replace(/^https?:\/\//, '').replace(/\/+$/, '');
    if (this.serverHost.length === 0) {
      this.serverHost = '192.168.2.2:8443';
    }
    this.deviceId = this.routeParams.deviceId;

    if (this.routeParams.serverUrl.length > 0) {
      if (this.routeParams.shareToken.length > 0) {
        // P0-12：分享访客连接——不登录默认账号，凭 share_token 建连（token 字段留空）
        this.sessionToken = '';
      } else {
        // 显式指定被控端：默认账号会话登录（不污染本地配置）
        const auth = AuthService.getInstance();
        this.sessionToken = await auth.loginForSession(this.routeParams.serverUrl, 'admin', 'admin123');
      }
    } else {
      this.sessionToken = await Prefs.getInstance().getToken();
    }
    this.scrcpyOptionsJson = await this.buildScrcpyOptionsJson();
    this.keymapJson = await Prefs.getInstance().getString('cloudphone_keymap', ''); // P1-8
    // P2-3：AI 配置（上游 localStorage ai_api_* 同名键与默认值）
    const aiUrl = await Prefs.getInstance().getString('ai_api_url', 'https://api.openai.com/v1');
    const aiKey = await Prefs.getInstance().getString('ai_api_key', '');
    const aiModel = await Prefs.getInstance().getString('ai_model', 'gpt-4o-mini');
    this.aiConfigJson = JSON.stringify({ url: aiUrl, key: aiKey, model: aiModel });
  }

  /**
   * P2-3：LLM 调用（页面 Agent 循环经此回填——代理方法无法返回 Promise，
   * 结果经 runJavaScript __aiResolve 注入）。
   */
  private async aiChatAsync(url: string, key: string, bodyJson: string, reqId: string): Promise<void> {
    try {
      const payload = JSON.parse(bodyJson) as Record<string, Object>;
      const res = await this.aiHttp.postJson(url, payload, key);
      const js = `window.__aiResolve && window.__aiResolve(${JSON.stringify(reqId)},` +
        `${res.ok ? 'true' : 'false'}, ${JSON.stringify(res.body)});`;
      this.controller.runJavaScript(js).catch(() => { return; });
    } catch (e) {
      const js = `window.__aiResolve && window.__aiResolve(${JSON.stringify(reqId)}, false, ${JSON.stringify('请求异常')});`;
      this.controller.runJavaScript(js).catch(() => { return; });
    }
  }

  /**
   * P0-9/P1-3：设置 → request-offer.scrcpy_options。
   * 下沉 SettingsStore.buildInjectOptionsJson（与文件页同源；含按设备覆盖链与单位换算）。
   */
  private async buildScrcpyOptionsJson(): Promise<string> {
    return SettingsStore.buildInjectOptionsJson(this.deviceId);
  }

  private refresh(): void {
    this.controller.refresh();
  }

  // ===================== P1-2 双向剪贴板（ETS 侧） =====================

  /** P1-2：设备 → 本地（clipboard.js 上报后写系统剪贴板）。createData 为 @since 24。 */
  private writeSystemClipboard(text: string): void {
    if (text.length === 0) {
      return;
    }
    if (deviceInfo.sdkApiVersion < 24) {
      this.getUIContext().getPromptAction().showToast({ message: '剪贴板同步需 API 24+ 设备' });
      return;
    }
    try {
      const data = pasteboard.createData('text/plain', text);
      pasteboard.getSystemPasteboard().setData(data).catch(() => { return; });
      Logger.info('Clipboard', `设备剪贴板已写入本地（${text.length} 字符）`);
    } catch (e) {
      Logger.warn('Clipboard', '写系统剪贴板失败');
    }
  }

  /** P1-2：「送剪贴板」——读系统剪贴板 → 注入页面发送 set_clipboard（viewOnly 由页面拦截） */
  private async sendClipboardToDevice(): Promise<void> {
    if (deviceInfo.sdkApiVersion < 24) {
      this.getUIContext().getPromptAction().showToast({ message: '剪贴板同步需 API 24+ 设备' });
      return;
    }
    let text = '';
    try {
      const pd = await pasteboard.getSystemPasteboard().getData();
      text = pd.getPrimaryText();
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '读取剪贴板失败' });
      return;
    }
    if (text.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '剪贴板为空' });
      return;
    }
    // 文本经 JSON 字面量注入，转义安全；页面 window.setClipboardFromNative 收口
    this.controller.runJavaScript(
      `window.setClipboardFromNative && window.setClipboardFromNative(${JSON.stringify(text)});`)
      .catch(() => { return; });
  }

  /** P1-2：「取剪贴板」——让设备把其剪贴板发回（回包经 onClipboard 写入本地） */
  private requestDeviceClipboard(): void {
    this.controller.runJavaScript('window.requestClipboard && window.requestClipboard();')
      .catch(() => { return; });
  }

  /**
   * P2-6：截图保存——base64 PNG 解码后经系统文件选择器写盘
   * （落盘逻辑下沉 utils/BlobSaver 与文件中心共用）；结果 toast 反馈。
   */
  private async saveShotPng(b64: string, fileName: string): Promise<void> {
    const bytes = BlobSaver.fromBase64(b64);
    const ctx = this.getUIContext().getHostContext() as common.Context;
    const ret = await BlobSaver.save(ctx, bytes, fileName);
    if (ret === 'ok') {
      this.getUIContext().getPromptAction().showToast({ message: '截图已保存' });
    } else if (ret === 'error') {
      Logger.info('ArkWebView', '截图保存失败');
    }
    // cancel=用户在选择器取消（静默）
  }

  /** P0-10 工具条单键（经页面 window.injectKey 注入；viewOnly 时页面侧自行拦截） */
  @Builder
  fabKey(label: string, keycode: number) {
    Text(label)
      .fontSize(11)
      .fontColor('#FFFFFF')
      .padding({ left: 10, right: 10, top: 7, bottom: 7 })
      .backgroundColor('rgba(255, 255, 255, 0.14)')
      .borderRadius(16)
      .onClick(() => {
        this.controller.runJavaScript(
          `window.injectKey && window.injectKey(${keycode});`)
          .catch(() => { return; }); // 页面未就绪时静默忽略
      })
  }

  private back(): void {
    this.pathStack.pop();
  }

  build() {
    Column() {
      // 顶栏（竖屏显示；横屏隐藏以全屏显示视频，返回走悬浮按钮）
      if (!this.isLandscape) {
        Row() {
          Text('‹ 返回')
            .fontSize(15)
            .fontColor('#0A59F7')
            .onClick(() => { this.back(); })
          Blank()
          Text(this.pageTitle)
            .fontSize(16)
            .fontWeight(FontWeight.Medium)
          Blank()
          Text('刷新')
            .fontSize(15)
            .fontColor('#0A59F7')
            .onClick(() => { this.refresh(); })
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 10, bottom: 10 })
        .backgroundColor('#F0F0F0')
      }

      // 本地自研控制页（rawfile）+ 加载遮挡层
      Stack() {
        Web({ src: '', controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .fileAccess(true)
          .domStorageAccess(true)
          .onControllerAttached(() => {
            // 空 src 创建（避免复用渲染进程旧 surface 首帧）→ 控制器就绪后再加载
            this.controller.loadUrl('resource://rawfile/control.html');
          })
          .javaScriptProxy({
            object: {
              // 页面参数注入（同步返回）
              getServerHost: (): string => { return this.serverHost; },
              getToken: (): string => { return this.sessionToken; },
              getDeviceId: (): string => { return this.deviceId; },
              // B-3：服务器 TLS 标志（0=ws:// 明文，1=wss://）——页面按此选 scheme
              getUseSslFlag: (): string => { return this.useSsl ? '1' : '0'; },
              // P0-3：七态状态机上报 → ETS 徽标
              onState: (state: string, text: string): void => {
                this.connState = state;
                this.connText = text;
              },
              // P0-9：连接设置 → scrcpy_options（页面 requestOffer 消费，空则用页面默认）
              getScrcpyOptions: (): string => { return this.scrcpyOptionsJson; },
              // P0-12：分享访客参数（RouteParams 由 SharePage/DeviceList 写入）
              getShareToken: (): string => { return this.routeParams.shareToken; },
              getSharePwd: (): string => { return this.routeParams.sharePwd; },
              getViewOnly: (): string => { return this.routeParams.viewOnly ? '1' : '0'; },
              // P1-10：群控从机组（本机绑定主控后，input.js 启动时读取）
              getGroupSlaves: (): string => {
                return AppStorage.get<string>('groupSlavesJson') ?? '[]';
              },
              // P1-8：键位映射 profile（KeymapPage 编辑写 Prefs，控制页只读）
              getKeymapProfiles: (): string => {
                return this.keymapJson;
              },
              // P2-12d：Demo 模式位（页面 boot 分支：仿真屏替代信令）
              getDemoMode: (): string => {
                return AppStorage.get<boolean>('demoMode') === true ? '1' : '0';
              },
              // P2-3：AI 引擎（配置读取 + LLM 异步调用回填）
              getAiConfig: (): string => { return this.aiConfigJson; },
              aiChat: (url: string, key: string, bodyJson: string, reqId: string): void => {
                this.aiChatAsync(url, key, bodyJson, reqId);
              },
              // P2-6：截图保存（页面预览层「保存 PNG」调用；base64 + 建议文件名）
              saveScreenshot: (b64: string, fileName: string): void => {
                this.saveShotPng(b64, fileName);
              },
              // P1-10：群控广播出口（group_control_event 帧 → 全局信令）
              sendGroupEvent: (json: string): boolean => {
                return GlobalChannel.getInstance().sendRaw(json);
              },
              // P1-2：设备剪贴板 → 系统剪贴板（clipboard.js 收到 'clipboard' 后经此写入）
              onClipboard: (text: string): void => {
                this.writeSystemClipboard(text);
              },
              // WebSocket 桥：页面 wss → 原生 webSocket（skipServerCertVerification）
              wsConnect: (id: string, url: string, protocols: string) => {
                this.wsBridge.wsConnect(id, url, protocols);
              },
              wsSend: (id: string, data: string) => {
                this.wsBridge.wsSend(id, data);
              },
              wsClose: (id: string, code: number, reason: string) => {
                this.wsBridge.wsClose(id, code, reason);
              }
            },
            name: 'nativeBridge',
            methodList: ['getServerHost', 'getToken', 'getDeviceId', 'getUseSslFlag', 'onState',
              'getScrcpyOptions', 'getShareToken', 'getSharePwd', 'getViewOnly', 'onClipboard',
              'getGroupSlaves', 'sendGroupEvent', 'getKeymapProfiles', 'saveScreenshot', 'getDemoMode',
              'getAiConfig', 'aiChat',
              'wsConnect', 'wsSend', 'wsClose'],
            controller: this.controller
          })
          .runJavaScriptOnDocumentStart([{
            script: WebSocketBridge.polyfillScript(),
            scriptRules: ['*']
          }])
          .onPageBegin(() => {
            this.loading = true;
          })
          .onPageEnd(() => {
            this.loading = false;
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            console.error(`[Control] 页面错误: ${event.error.getErrorCode()} ${event.error.getErrorInfo()}`);
          })

        // P0-3 连接状态徽标（右上角；数据来自 control.html 状态机上报）
        ConnectionStatusBadge({ state: this.connState, text: this.connText })
          .align(Alignment.TopEnd)
          .margin({ top: 12, right: 12 })

        // P0-10：错误覆盖层（重试=重载页面重启状态机；退出=返回列表）
        if (this.connState === 'error' && !this.loading) {
          Column() {
            Text(this.connText)
              .fontSize(14)
              .fontColor('#FF8A8A')
              .textAlign(TextAlign.Center)
              .margin({ left: 32, right: 32 })
            Row({ space: 16 }) {
              Button('重试')
                .height(38)
                .backgroundColor('#0A59F7')
                .onClick(() => { this.refresh(); })
              Button('退出')
                .height(38)
                .backgroundColor('#666666')
                .onClick(() => { this.back(); })
            }
            .margin({ top: 16 })
          }
          .position({ x: '50%', y: '50%' })
          .translate({ x: '-50%', y: '-50%' })
        }

        // P0-10：悬浮工具条（对齐上游侧栏物理键；经页面 injectKey 注入，viewOnly 自动拦截）
        if (!this.loading) {
          Column({ space: 10 }) {
            this.fabKey('电源', 26)
            this.fabKey('首页', 3)
            this.fabKey('返回', 4)
            this.fabKey('音量+', 24)
            this.fabKey('音量-', 25)
            // P1-2：剪贴板双向动作（送=本地→设备；取=设备→本地）
            Text('送剪贴板')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => { this.sendClipboardToDevice(); })
            Text('取剪贴板')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => { this.requestDeviceClipboard(); })
            // P1-1：页面静音（仅本地开声音，不发协议；页面 audio.js toggleAudioMuted）
            Text(this.audioMuted ? '开声音' : '静音')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => {
                this.audioMuted = !this.audioMuted;
                this.controller.runJavaScript('window.toggleAudioMuted && window.toggleAudioMuted();')
                  .catch(() => { return; });
              })

            // P2-6：实时截图（页面发 screenshot_request，响应经预览层展示/保存）
            Text('截图')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => {
                this.controller.runJavaScript('window.requestScreenshot && window.requestScreenshot();')
                  .catch(() => { return; });
              })

            // P2-8：外设页（GPS/传感器模拟，目标=当前设备；viewOnly 拒绝注入类操作）
            Text('外设')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => {
                if (this.routeParams.viewOnly) {
                  this.getUIContext().getPromptAction().showToast({ message: '只读模式不可用' });
                  return;
                }
                this.routeParams.deviceId = this.deviceId;
                this.pathStack.pushPathByName('Peripheral', null);
              })

            // P2-2：WebADB 终端（面板开合经 __adbApi；只读/Demo 由页面侧拦截提示）
            Text('ADB')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => {
                this.controller.runJavaScript('window.__adbApi && window.__adbApi.open();')
                  .catch(() => { return; });
              })

            // P2-3：AI 助手面板（消息流/技能；viewOnly 拦截在页面发送处）
            Text('AI')
              .fontSize(11)
              .fontColor('#FFFFFF')
              .padding({ left: 10, right: 10, top: 7, bottom: 7 })
              .backgroundColor('rgba(255, 255, 255, 0.14)')
              .borderRadius(16)
              .onClick(() => {
                this.controller.runJavaScript('window.__aiPanel && window.__aiPanel.open();')
                  .catch(() => { return; });
              })
          }
          .align(Alignment.End)
          .position({ x: '100%', y: '55%' })
          .translate({ x: '-120%', y: '-50%' })
          .padding(6)
          .backgroundColor('rgba(0, 0, 0, 0.5)')
          .borderRadius(24)
        }

        // 横屏悬浮返回按钮（半透明，不挡视频主体）
        // 不透明度 0.68：即使压在视频最亮（纯白）画面上，白字对比度仍 ≥5:1
        if (this.isLandscape) {
          Text('‹')
            .width(44)
            .height(44)
            .fontSize(26)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .backgroundColor('rgba(0, 0, 0, 0.68)')
            .borderRadius(22)
            .position({ x: 10, y: 10 })
            .onClick(() => { this.back(); })
        }

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#666666')
            Text('加载控制页...')
              .fontSize(14)
              .fontColor('#666666')
              .margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#000000')
        }
      }
      .width('100%')
      .height('100%')
    }
    .width('100%')
    .height('100%')
    .onAreaChange((oldValue: Area, newValue: Area) => {
      // 手机旋转 → 页面尺寸变化 → 切换横竖屏布局（视频 object-fit:contain 自适应）
      this.isLandscape = (newValue.width as number) > (newValue.height as number);
    })
  }
}
