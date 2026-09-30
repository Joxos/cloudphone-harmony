/**
 * 首屏（自动连接页）
 *
 * 正常路径（零输入直达）：
 *   扫描/路由带回的服务器地址 → 自动会话登录 → 设备列表；
 *   有本地凭证 → 直达设备列表；
 *   有服务器地址但无凭证 → 默认账号(admin/admin123)自动会话登录 → 设备列表。
 *
 * 兜底路径（首页）：默认先扫描局域网被控端（mDNS + TCP 网段双通道），
 *   扫描结果点击即连；下方保留地址登录表单（手动填被控端地址与凭证）。
 */
import { common } from '@kit.AbilityKit';
import { AuthService } from '../features/auth/AuthService';
import { DiscoveryService, DiscoveryListener } from '../features/discovery/DiscoveryService';
import { Prefs } from '../utils/Prefs';
import { RouteParams, DiscoveredDevice } from '../model/Model';

@Component
export struct Index {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  @State serverInput: string = '';
  @State usernameInput: string = 'admin';
  @State passwordInput: string = 'admin123';
  @State loading: boolean = false;
  /** 首屏状态：auto=自动连接中；form=扫描 + 手动登录表单 */
  @State showForm: boolean = false;
  @State statusText: string = '正在自动连接被控端...';
  /** 局域网扫描状态 */
  @State discovered: DiscoveredDevice[] = [];
  @State scanning: boolean = false;
  @State scanStatus: string = '';
  /**
   * 会话事件时间戳（AppStorage）：Index 是 Navigation 常驻根内容（栈底），
   * 从设备列表页 pop 回来不会重跑 aboutToAppear —— 退出登录等跨页状态变化
   * 由其它页面写 AppStorage 通知本页。
   */
  @StorageLink('sessionEvent') @Watch('onSessionEvent') sessionEvent: number = 0;
  /** 自动连接评估进行中标记：防止首帧可见性回调与 aboutToAppear 重入 */
  private evaluating: boolean = false;

  private auth: AuthService = AuthService.getInstance();
  private discovery: DiscoveryService = DiscoveryService.getInstance();

  aboutToAppear(): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.discovery.setContext(ctx);
    this.discovery.addListener(this.buildListener());
    this.initPrefs();
  }

  private buildListener(): DiscoveryListener {
    return {
      onDeviceFound: (device: DiscoveredDevice) => {
        const exists = this.discovered.some((d: DiscoveredDevice) => d.host === device.host);
        if (!exists) {
          this.discovered = [...this.discovered, device];
        }
        this.scanStatus = `发现被控端 ${device.host}:${device.port}，点击连接`;
      },
      onDeviceLost: (serviceName: string) => {
        const uuid = serviceName.split('.')[0];
        this.discovered = this.discovered.filter((d: DiscoveredDevice) => d.uuid !== uuid);
      },
      onDiscoveryStarted: () => {
        this.scanning = true;
      },
      onDiscoveryStopped: () => {
        // mDNS 先停时 TCP 扫描可能仍在进行：scanning 由页面显式管理，此处不置 false
      },
      onProgress: (msg: string) => {
        this.scanStatus = msg;
      },
      onError: (msg: string) => {
        this.scanStatus = msg;
      }
    };
  }

  private async initPrefs(): Promise<void> {
    if (this.evaluating) {
      return;
    }
    this.evaluating = true;
    try {
      const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
      await Prefs.getInstance().init(ctx);
      // 1) 扫描/路由传入的被控端地址优先（首页点击扫描结果也走这里）
      let server = this.routeParams.serverUrl;
      if (server.length > 0) {
        this.routeParams.serverUrl = '';
      } else if (await this.auth.isLoggedIn()) {
        // 2) 已有本地凭证：直达设备列表
        this.pathStack.pushPathByName('DeviceList', null);
        return;
      } else {
        // 3) 上次连接过的服务器地址
        server = await this.auth.getLastServerUrl();
      }
      if (server.length > 0) {
        this.serverInput = server;
        const ok = await this.connectToServer(server);
        if (ok) {
          return;
        }
        this.statusText = '自动连接失败，请检查被控端地址与凭证';
      } else {
        this.statusText = '未发现被控端，正在扫描局域网...';
      }
      this.usernameInput = await this.loadUsernameOrDefault();
      this.showForm = true;
      this.startScan();
    } finally {
      this.evaluating = false;
    }
  }

  /**
   * 用户名回填：优先用上次保存的账号；从未保存过（新装/重装/退出登录清空）时默认 admin
   */
  private async loadUsernameOrDefault(): Promise<string> {
    const last = await this.auth.getLastUser();
    return last.length > 0 ? last : 'admin';
  }

  /**
   * 对指定服务器执行快连（NO_AUTH 探测 → 默认账号会话登录，见 AuthService.quickConnect）并进入设备列表
   */
  private async connectToServer(serverUrl: string): Promise<boolean> {
    const ok = await this.auth.quickConnect(serverUrl);
    if (!ok) {
      return false;
    }
    this.pathStack.pushPathByName('DeviceList', null);
    return true;
  }

  // ===================== 局域网扫描 =====================

  private startScan(): void {
    if (this.scanning) {
      return;
    }
    this.scanning = true;
    this.scanStatus = '正在扫描局域网被控端...';
    this.discovery.startDiscovery();
    this.discovery.startTcpScan();
  }

  private stopScan(): void {
    this.discovery.stopDiscovery();
    this.scanning = false;
  }

  private restartScan(): void {
    this.discovered = [];
    this.discovery.stopDiscovery();
    this.startScan();
  }

  /** 点击扫描到的被控端：自动登录直连 */
  private async connectDiscovered(device: DiscoveredDevice): Promise<void> {
    if (this.evaluating) {
      return;
    }
    this.evaluating = true;
    try {
      const ok = await this.connectToServer(device.getUrl());
      if (!ok) {
        this.getUIContext().getPromptAction().showToast({ message: `连接 ${device.host}:${device.port} 失败` });
      }
    } finally {
      this.evaluating = false;
    }
  }

  // ===================== 会话/可见性 =====================

  /**
   * 会话事件处理：退出登录（DeviceList 写入 AppStorage）→ 切换为连接表单并恢复扫描
   */
  private onSessionEvent(): void {
    if (this.sessionEvent === 0) {
      return;
    }
    this.showLoginForm('已退出登录，请重新连接', true);
    this.startScan();
  }

  /**
   * 显示连接表单（兜底）。
   * 已显示表单时默认保留原提示；force=true 用于退出登录等必须覆盖提示的场景。
   */
  private async showLoginForm(status: string, force: boolean = false): Promise<void> {
    if (this.showForm && !force) {
      return;
    }
    this.statusText = status;
    if (!this.showForm) {
      this.serverInput = await this.auth.getLastServerUrl();
      this.usernameInput = await this.loadUsernameOrDefault();
      this.showForm = true;
    }
  }

  /**
   * Index 重新可见（栈页弹出、返回本页）：
   *   扫描页带回的被控端地址 → 自动连接；
   *   否则显示连接表单并恢复扫描（避免"退出后立刻弹回设备列表"）。
   */
  private onReShown(): void {
    if (this.evaluating) {
      return;
    }
    if (this.routeParams.serverUrl.length > 0) {
      this.initPrefs();
      return;
    }
    this.showLoginForm('已返回，请登录连接');
    this.startScan();
  }

  private async handleAuth(isLogin: boolean): Promise<void> {
    this.loading = true;
    const result = await this.auth.authenticate(this.serverInput, this.usernameInput, this.passwordInput, isLogin);
    this.loading = false;
    if (!result.ok) {
      this.getUIContext().getPromptAction().showToast({ message: result.message });
      return;
    }
    this.getUIContext().getPromptAction().showToast({ message: result.message });
    if (isLogin) {
      this.pathStack.pushPathByName('DeviceList', null);
    }
  }

  build() {
    Column() {
      if (!this.showForm) {
        // 自动连接中：品牌画面 + 状态（非空白）
        Column() {
          Text('云机伴侣')
            .fontSize(34)
            .fontWeight(FontWeight.Bold)
          Text('直连被控端 · WebRTC 远程控制')
            .fontSize(13)
            .fontColor('#666666')
            .margin({ top: 8 })
          LoadingProgress()
            .width(40)
            .height(40)
            .color('#0A59F7')
            .margin({ top: 40 })
          Text(this.statusText)
            .fontSize(13)
            .fontColor('#666666')
            .margin({ top: 14 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
      } else {
        // 首页：默认先扫描局域网 + 下方地址登录表单
        Scroll() {
          Column() {
            // 标题
            Column() {
              Text('云机伴侣')
                .fontSize(34)
                .fontWeight(FontWeight.Bold)
              Text(this.statusText)
                .fontSize(13)
                .fontColor('#A34700')
                .margin({ top: 8 })
            }
            .margin({ top: 18, bottom: 18 })

            // ===== 局域网扫描区（默认先扫描） =====
            // 外边距 16 由外层无底色 Column 撑出：子容器 width('100%') + margin 会被裁切，
            // 故横向留白一律走"父容器 padding"，卡片本身不再写 margin
            Column() {
              Column() {
              Row() {
                Column() {
                  Text(this.scanStatus)
                    .fontSize(14)
                    .fontColor(this.scanning ? '#0A59F7' : '#666666')
                    .maxLines(2)
                  if (this.scanning) {
                    Row() {
                      LoadingProgress()
                        .width(14)
                        .height(14)
                        .color('#0A59F7')
                      Text('扫描中...')
                        .fontSize(12)
                        .fontColor('#0A59F7')
                        .margin({ left: 6 })
                    }
                    .margin({ top: 6 })
                  }
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)

                Button(this.scanning ? '停止' : '重新扫描')
                  .height(32)
                  .fontSize(13)
                  .onClick(() => {
                    if (this.scanning) {
                      this.stopScan();
                    } else {
                      this.restartScan();
                    }
                  })
              }
              .width('100%')

              if (this.discovered.length > 0) {
                ForEach(this.discovered, (device: DiscoveredDevice) => {
                  Row() {
                    Column() {
                      Text(device.name)
                        .fontSize(15)
                        .fontWeight(FontWeight.Medium)
                      Text(`${device.host}:${device.port}`)
                        .fontSize(12)
                        .fontColor('#666666')
                        .margin({ top: 3 })
                    }
                    .alignItems(HorizontalAlign.Start)

                    Blank()

                    Button('连接')
                      .height(30)
                      .fontSize(13)
                      .onClick(() => { this.connectDiscovered(device); })
                  }
                  .width('100%')
                  .backgroundColor('#FFFFFF')
                  .padding(18)
                  .borderRadius(10)
                  .margin({ left: 6, right: 6, top: 10 })
                }, (device: DiscoveredDevice) => device.uuid)
              } else {
                Text('未发现设备（扫描持续进行，也可直接下方填写地址）')
                  .fontSize(12)
                  .fontColor('#666666')
                  .margin({ top: 10 })
              }
            }
            .width('100%')
            .padding(18)
            .backgroundColor('#F0F6FF')
            .borderRadius(12)
              }
              .width('100%')
              .padding({ left: 24, right: 24 })

            // ===== 地址登录（兜底） =====
            Text('─── 地址登录 ───')
              .fontSize(13)
              .fontColor('#666666')
              .margin({ top: 24, bottom: 8 })

            Column() {
              TextInput({ placeholder: '服务器地址，如 https://192.168.2.10:8443', text: this.serverInput })
                .height(48)
                .margin({ bottom: 8 })
                .onChange((v: string) => { this.serverInput = v; })

              TextInput({ placeholder: '用户名', text: this.usernameInput })
                .height(48)
                .margin({ bottom: 8 })
                .onChange((v: string) => { this.usernameInput = v; })

              TextInput({ placeholder: '密码', text: this.passwordInput })
                .type(InputType.Password)
                .height(48)
                .margin({ bottom: 16 })
                .onChange((v: string) => { this.passwordInput = v; })

              Button(this.loading ? '登录中...' : '登 录')
                .width('100%')
                .height(46)
                .borderRadius(12)
                // 禁用态不用系统默认的 40% 透明（会让白字压在淡蓝上掉到约 1.7:1），
                // 改用深一档实心底色，白字对比度保持 5.1:1
                .backgroundColor(this.loading ? '#08409E' : '#0A59F7')
                .opacity(1)
                .enabled(!this.loading)
                .onClick(() => { this.handleAuth(true); })
              Button('注 册')
                .width('100%')
                .height(46)
                .borderRadius(12)
                .backgroundColor(this.loading ? '#08409E' : '#0A59F7')
                .opacity(1)
                .margin({ top: 8 })
                .enabled(!this.loading)
                .onClick(() => { this.handleAuth(false); })

              // P0-12：分享访客入口（卡密直连，见 pages/SharePage.ets）
              Button('卡密连接（分享访客）')
                .width('100%')
                .height(44)
                .borderRadius(12)
                .margin({ top: 16 })
                .backgroundColor('#F0F0F0')
                .fontColor('#0A59F7')
                .enabled(!this.loading)
                .onClick(() => { this.pathStack.pushPathByName('Share', null); })

              // P2-12c：Demo 入口（无服务器演示矩阵 + 指标模拟；退出登录即清）
              Button('体验 Demo（无服务器）')
                .width('100%')
                .height(44)
                .borderRadius(12)
                .margin({ top: 8 })
                .backgroundColor('#EEF4FF')
                .fontColor('#0A59F7')
                .enabled(!this.loading)
                .onClick(() => {
                  AppStorage.setOrCreate<boolean>('demoMode', true);
                  this.pathStack.pushPathByName('DeviceList', null);
                })
            }
            .width('100%')
            .padding({ left: 24, right: 24 })
          }
          .width('100%')
        }
        .width('100%')
        .height('100%')
        .scrollBar(BarState.Off)
        // 边界反馈动效：滑到顶/底时弹簧回弹（应用市场 UX 审核要求）
        .edgeEffect(EdgeEffect.Spring)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#FFFFFF')
    .onVisibleAreaChange([0.0, 1.0], (isVisible: boolean, currentRatio: number) => {
      if (isVisible && currentRatio >= 1.0) {
        // 栈页弹出后本页重新完全可见 → 连接/恢复扫描（首启由 evaluating 标记兜底跳过）
        this.onReShown();
      } else if (!isVisible) {
        // 被栈页覆盖（如进入设备列表）：停止扫描，避免后台空转
        this.stopScan();
      }
    })
  }
}
