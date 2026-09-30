/**
 * FileCenterPage —— 文件中心页（P2-1a，ArkWeb 路线 A 第三承载页）
 *
 * 职责（单一）：ArkWeb 承载 rawfile/file.html；设备自选（在线列表，默认首台或
 *   routeParams 指定）；桥参数（服务器/凭证/设备/scrcpy_options 同源注入）与
 *   saveFile 落盘出口（utils/BlobSaver，免存储权限）。
 * 数据流：页面内 RTCPeerConnection（fileboot.js 数据通道专用连接）→ fileproto.js 协议
 *   → 本页仅提供参数与保存，不介入协议本身。
 * P2-1b：上传（upload_start 16KB 分块/512KB 流控/sha256）与 APK 安装随后接入同一页面。
 * 入口：DeviceList 顶栏「文件」。
 */
import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { Prefs } from '../utils/Prefs';
import { Logger } from '../utils/Logger';
import { BlobSaver } from '../utils/BlobSaver';
import { SettingsStore } from '../features/settings/SettingsStore';
import { DeviceService } from '../features/device/DeviceService';
import { RouteParams } from '../model/Model';

@Component
export struct FileCenterPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  private controller: webview.WebviewController = new webview.WebviewController();
  /** 在线设备（选择器数据源） */
  @State deviceIds: string[] = [];
  @State deviceId: string = '';
  /** 桥缓存字段（proxy 同步返回用；设备切换时重建） */
  private serverHost: string = '';
  private scrcpyJson: string = '{}';
  /** 页面是否已加载（设备切换用 __fbRestart，不重载页面） */
  @State pageLoaded: boolean = false;
  @State loading: boolean = true;

  aboutToAppear(): void {
    this.initDevices();
  }

  aboutToDisappear(): void {
    try {
      this.controller.removeCache(true);
    } catch (e) {
      // 忽略
    }
  }

  /** 设备装载（routeParams 优先，否则第一台在线）+ 桥参数预备 */
  private async initDevices(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await Prefs.getInstance().init(ctx);
    const result = await DeviceService.getInstance().fetchDevices();
    const ids: string[] = [];
    for (const d of result.devices) {
      if (d.online) {
        ids.push(d.device_id);
      }
    }
    this.deviceIds = ids;
    let pick = this.routeParams.deviceId;
    this.routeParams.deviceId = '';
    if (ids.indexOf(pick) < 0) {
      pick = ids.length > 0 ? ids[0] : '';
    }
    this.deviceId = pick;
    await this.refreshBridgeCache();
    if (this.deviceId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '无在线设备' });
    }
  }

  /** 桥缓存刷新（server/token/ssl/scrcpy_options；设备切换同调——proxy 只读缓存） */
  private async refreshBridgeCache(): Promise<void> {
    const ip = await Prefs.getInstance().getServerIp();
    this.serverHost = ip.replace(/^https?:\/\//, '').replace(/\/+$/, '');
    this.tokenCache = await Prefs.getInstance().getToken();
    this.sslCache = await Prefs.getInstance().getUseSsl();
    this.scrcpyJson = await SettingsStore.buildInjectOptionsJson(this.deviceId);
  }

  /** 设备切换：重建桥缓存 → 通知页面重启信令（不整页重载） */
  private async onSelectDevice(index: number): Promise<void> {
    const id = this.deviceIds[index];
    if (id === undefined || id === this.deviceId) {
      return;
    }
    this.deviceId = id;
    await this.refreshBridgeCache();
    if (this.pageLoaded) {
      this.controller.runJavaScript(`window.__fbRestart && window.__fbRestart('${id}');`)
        .catch(() => { return; });
    }
  }

  /**
   * P2-1：页面下载完成 → 系统选择器写盘（base64 → bytes → DocumentViewPicker）。
   * 结果 toast（取消静默）。
   */
  private async saveFile(b64: string, fileName: string): Promise<void> {
    const bytes = BlobSaver.fromBase64(b64);
    const ctx = this.getUIContext().getHostContext() as common.Context;
    const ret = await BlobSaver.save(ctx, bytes, fileName);
    if (ret === 'ok') {
      this.getUIContext().getPromptAction().showToast({ message: `${fileName} 已保存` });
    } else if (ret === 'error') {
      this.getUIContext().getPromptAction().showToast({ message: '保存失败' });
    }
    // cancel=用户取消（静默）
  }

  private back(): void {
    this.pathStack.pop();
  }

  /** 设备选择器数据源（SelectOption[] 签名） */
  private deviceOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const id of this.deviceIds) {
      const so: SelectOption = { value: id };
      arr.push(so);
    }
    return arr;
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text('文件中心').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      // 设备选择（数据通道专用连接按设备建链）
      Row({ space: 8 }) {
        Text('设备').fontSize(13).fontColor('#666666')
        Select(this.deviceOptions())
          .layoutWeight(1)
          .height(32)
          .font({ size: 13 })
          .selected(Math.max(0, this.deviceIds.indexOf(this.deviceId)))
          .onSelect((i: number) => { this.onSelectDevice(i); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 6, bottom: 6 })
      .backgroundColor('#FFFFFF')

      Stack() {
        Web({ src: '', controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .fileAccess(true)
          // 桥：参数同步读取（缓存字段）+ 下载保存出口（协议与保存解耦）
          .javaScriptProxy({
            object: {
              getServerHost: (): string => { return this.serverHost; },
              getToken: (): string => { return this.sessionToken(); },
              getDeviceId: (): string => { return this.deviceId; },
              getUseSslFlag: (): string => { return this.useSslFlag(); },
              getScrcpyOptions: (): string => { return this.scrcpyJson; },
              saveFile: (b64: string, fileName: string): void => { this.saveFile(b64, fileName); }
            },
            name: 'nativeBridge',
            methodList: ['getServerHost', 'getToken', 'getDeviceId', 'getUseSslFlag',
              'getScrcpyOptions', 'saveFile'],
            controller: this.controller
          })
          .onControllerAttached(() => {
            this.controller.loadUrl('resource://rawfile/file.html');
          })
          .onPageEnd(() => {
            this.pageLoaded = true;
            this.loading = false;
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            Logger.error('FileCenter', `页面错误 ${event.error.getErrorCode()}`);
          })

        if (this.loading) {
          Column() {
            LoadingProgress().width(40).height(40).color('#666666')
            Text('加载文件页…').fontSize(14).fontColor('#666666').margin({ top: 12 })
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor('#F5F5F5')
        }
      }
      .width('100%')
      .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }

  /** 桥同步读取：token（Prefs 缓存） */
  private sessionToken(): string {
    // 同步 proxy 无法 await——token 由 initDevices 后 Prefs 已载入，此处置空会破坏鉴权。
    // 采用惰性缓存：aboutToAppear 已 Prefs.init，读内存字段。
    return this.tokenCache;
  }

  private useSslFlag(): string {
    return this.sslCache ? '1' : '0';
  }

  /** token/ssl 同步缓存（initDevices/refreshBridgeCache 填充） */
  private tokenCache: string = '';
  private sslCache: boolean = false;
}
