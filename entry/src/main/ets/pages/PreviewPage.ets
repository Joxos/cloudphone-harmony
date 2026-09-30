/**
 * PreviewPage —— 设备实时预览页（P1-5 宿主）
 *
 * 职责（单一）：ArkWeb 承载 rawfile/preview.html；接线 GlobalChannel 的 PREV 帧流
 *   （按 deviceId 过滤 → base64 JSON 单向推入页面）与 start/stop_preview 生命周期。
 * 数据流：GlobalChannel.onPrevFrame → runJavaScript(window.__pushPrev) → prevcodec.js 解码渲染。
 * 直控（P1-5）：prevtouch.js 组装 group_control_event 帧 → previewBridge.sendPreviewEvent
 *   → GlobalChannel.sendRaw（上游 DeviceCard 直控协议，事件体含 touch/keycode）。
 * 与遥控页（ArkWebView）的区别：无信令/无 WebSocket 桥——帧由 ETS 单向推入 + 直控单向出口。
 * 参数：进入即消费 routeParams（deviceId + deviceXRes/YRes 直控坐标基准）；
 *   预览规格对齐上游默认（10fps/360p/1Mbps，不 keepAwake）。
 */
import { webview } from '@kit.ArkWeb';
import { RouteParams } from '../model/Model';
import { GlobalChannel } from '../features/signaling/GlobalChannel';
import { Logger } from '../utils/Logger';

/** 预览帧率（上游 previewFps 默认 10） */
const PREVIEW_FPS: number = 10;
/** 预览最长边（上游 previewSize 默认 360） */
const PREVIEW_MAX_SIZE: number = 360;
/** 预览码率 Mbps（上游 previewBitrate 默认 1；GlobalChannel 内 ×1e6） */
const PREVIEW_BITRATE_MBPS: number = 1;

@Component
export struct PreviewPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  /** 页面加载遮罩 */
  @State loading: boolean = true;
  private controller: webview.WebviewController = new webview.WebviewController();
  /** 目标设备 ID（进入即消费；空则直接退出） */
  private deviceId: string = '';
  /** 直控坐标基准：设备逻辑分辨率（0=不可用，prevtouch 自禁用） */
  private deviceXRes: number = 0;
  private deviceYRes: number = 0;
  /** 预览已启动标志（防重复 start / 退出幂等 stop） */
  private started: boolean = false;

  aboutToAppear(): void {
    this.deviceId = this.routeParams.deviceId;
    this.deviceXRes = this.routeParams.deviceXRes;
    this.deviceYRes = this.routeParams.deviceYRes;
    this.routeParams.deviceId = '';
    this.routeParams.deviceXRes = 0;
    this.routeParams.deviceYRes = 0;
    if (this.deviceId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '未指定预览设备' });
      this.pathStack.pop();
    }
  }

  aboutToDisappear(): void {
    this.stopPreview();
    // 清除页面缓存，避免下次进入复用旧页面 surface（对齐遥控页做法）
    try {
      this.controller.removeCache(true);
    } catch (e) {
      // 忽略
    }
  }

  /**
   * 页面配置注入（onPageEnd 先于 startPreview）：deviceId + 直控坐标基准。
   * __previewInit 收到 {id,w,h}；w/h≤0 时 prevtouch 自禁用直控。
   */
  private pushInitConfig(): void {
    const cfg = JSON.stringify({ id: this.deviceId, w: this.deviceXRes, h: this.deviceYRes });
    this.controller.runJavaScript(`window.__previewInit && window.__previewInit(${JSON.stringify(cfg)});`)
      .catch(() => { return; });
  }

  /**
   * 启动预览（幂等）：挂帧回调（设备过滤 + JSON 推入）→ 发 start_preview。
   * 回调先行注册再请求，避免首帧到达时无消费者被丢弃。
   */
  private async startPreview(): Promise<void> {
    if (this.started || this.deviceId.length === 0) {
      return;
    }
    const gc = GlobalChannel.getInstance();
    await gc.ensureConnected();
    const devId = this.deviceId;
    gc.onPrevFrame = (id: string, isKey: boolean, ptsUs: number, frameB64: string): void => {
      if (id !== devId || frameB64.length === 0) {
        return; // 只投递本设备帧（全局通道混流多设备）
      }
      const payload = JSON.stringify({ d: frameB64, k: isKey ? 1 : 0, t: ptsUs });
      // payload 为 JSON 字符串，双序列化后作为 JS 字面量注入（引号转义安全）
      this.controller.runJavaScript(`window.__pushPrev && window.__pushPrev(${JSON.stringify(payload)});`)
        .catch(() => { return; });
    };
    const ok = gc.startPreview(this.deviceId, PREVIEW_FPS, PREVIEW_MAX_SIZE, PREVIEW_BITRATE_MBPS, false);
    if (!ok) {
      Logger.warn('Preview', 'start_preview 未发出（全局信令未连接，页面将持续等待帧）');
    } else {
      Logger.info('Preview', `预览已请求: ${this.deviceId}`);
    }
    this.started = true;
  }

  /** 停止预览：先撤回调（停帧流）再发 stop_preview（顺序防悬挂帧） */
  private stopPreview(): void {
    if (!this.started) {
      return;
    }
    const gc = GlobalChannel.getInstance();
    gc.onPrevFrame = null;
    gc.stopPreview(this.deviceId);
    this.started = false;
  }

  private back(): void {
    this.pathStack.pop();
  }

  build() {
    Column() {
      // 顶栏（常驻；预览页不随横竖屏隐藏——状态可见优先）
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#0A59F7')
          .onClick(() => { this.back(); })
        Blank()
        Text(`预览 · ${this.deviceId}`)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Blank()
        Text(' ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      // ArkWeb 承载（无 javaScriptProxy——帧仅 ETS → 页面 单向 runJavaScript）
      Stack() {
        Web({ src: '', controller: this.controller })
          .width('100%')
          .height('100%')
          .javaScriptAccess(true)
          .fileAccess(true)
          // P1-5 直控出口：页面组装 group_control_event → 本代理原样发送
          .javaScriptProxy({
            object: {
              sendPreviewEvent: (json: string): boolean => {
                return GlobalChannel.getInstance().sendRaw(json);
              }
            },
            name: 'previewBridge',
            methodList: ['sendPreviewEvent'],
            controller: this.controller
          })
          .onControllerAttached(() => {
            // 空 src 创建（避免复用渲染进程旧 surface 首帧）→ 就绪后再加载
            this.controller.loadUrl('resource://rawfile/preview.html');
          })
          .onPageEnd(() => {
            this.loading = false;
            this.pushInitConfig();
            this.startPreview();
          })
          .onErrorReceive((event: OnErrorReceiveEvent) => {
            console.error(`[Preview] 页面错误: ${event.error.getErrorCode()} ${event.error.getErrorInfo()}`);
          })

        if (this.loading) {
          Column() {
            LoadingProgress()
              .width(40)
              .height(40)
              .color('#666666')
            Text('加载预览页...')
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
    .backgroundColor('#000000')
  }
}
