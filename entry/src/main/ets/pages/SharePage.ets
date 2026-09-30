/**
 * 分享访客页（P0-12 骨架，对应上游 /share?token= 访客免登录页）
 *
 * 流程：填 服务器地址 + 卡密(+可选密码) → GET /api/share/info 解析 device_id
 *      → RouteParams(serverUrl/shareToken/sharePwd/viewOnly) → ArkWebView
 *      → control.html 以 ?share_token[&share_pwd] 建连（viewOnly 源头拦截注入）。
 * 完整版（倒计时/权限徽标/密码重试/失效处理）随 P2 落地。
 */
import { HttpClient, normalizeHost, httpScheme } from '../utils/HttpClient';
import { RouteParams } from '../model/Model';

@Component
export struct SharePage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  @State serverUrl: string = '';
  @State cardCode: string = '';
  @State pwd: string = '';
  /** 安全默认：只读（上游 view_only 访客模式） */
  @State viewOnly: boolean = true;
  @State connecting: boolean = false;

  private http: HttpClient = new HttpClient();

  aboutToAppear(): void {
    if (this.routeParams.serverUrl.length > 0) {
      this.serverUrl = this.routeParams.serverUrl;
    }
  }

  /** 规范化输入：裸 host 补 https://（http 明文服务器需显式带 http:// 前缀） */
  private normalizeInput(raw: string): string {
    const s = raw.trim();
    if (s.startsWith('https://') || s.startsWith('http://')) {
      return s;
    }
    return `https://${s}`;
  }

  private async connect(): Promise<void> {
    const server = this.normalizeInput(this.serverUrl);
    const token = this.cardCode.trim();
    if (server.length <= 8 || token.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '请填写服务器地址与卡密' });
      return;
    }
    this.connecting = true;
    // 1) 兑换访客会话信息（/api/share/info?token&password → device_id）
    const host = normalizeHost(server);
    const useSsl = server.startsWith('https://');
    const infoUrl = `${httpScheme(useSsl)}${host}/api/share/info?token=${encodeURIComponent(token)}` +
      (this.pwd.trim().length > 0 ? `&password=${encodeURIComponent(this.pwd.trim())}` : '');
    const res = await this.http.getJson(infoUrl);
    this.connecting = false;
    let deviceId = '';
    if (res.ok) {
      try {
        const obj = JSON.parse(res.body) as Record<string, Object>;
        const data = obj['data'] as Record<string, Object>;
        if (data !== undefined && data !== null) {
          deviceId = (data['device_id'] as string) ?? '';
        }
      } catch (e) {
        deviceId = '';
      }
    }
    if (deviceId.length === 0) {
      const tip = res.code === 401 ? '卡密或密码无效（401）' : `获取分享信息失败: ${res.code}`;
      this.getUIContext().getPromptAction().showToast({ message: tip });
      return;
    }
    // 2) 写入路由参数 → 控制页（share_token 连接 + view_only 门）
    this.routeParams.serverUrl = `${useSsl ? 'https://' : 'http://'}${host}`;
    this.routeParams.deviceId = deviceId;
    this.routeParams.shareToken = token;
    this.routeParams.sharePwd = this.pwd.trim();
    this.routeParams.viewOnly = this.viewOnly;
    this.pathStack.pushPathByName('ArkWebView', null);
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#0A59F7')
          .onClick(() => { this.pathStack.pop(); })
        Blank()
        Text('卡密连接')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(' ')
          .fontSize(15)
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      TextInput({ placeholder: '服务器地址（如 https://192.168.1.10:8443）', text: this.serverUrl })
        .type(InputType.Normal)
        .height(44)
        .backgroundColor('#FFFFFF')
        .margin({ left: 24, right: 24, top: 28 })
        .onChange((v: string) => { this.serverUrl = v; })

      TextInput({ placeholder: '卡密（8 位）', text: this.cardCode })
        .type(InputType.Number)
        .height(44)
        .backgroundColor('#FFFFFF')
        .margin({ left: 24, right: 24, top: 14 })
        .onChange((v: string) => { this.cardCode = v; })

      TextInput({ placeholder: '访问密码（卡密未设密码则留空）', text: this.pwd })
        .type(InputType.Password)
        .height(44)
        .backgroundColor('#FFFFFF')
        .margin({ left: 24, right: 24, top: 14 })
        .onChange((v: string) => { this.pwd = v; })

      Row() {
        Text('只读模式（禁用触控/按键注入）')
          .fontSize(14)
          .fontColor('#666666')
        Blank()
        Toggle({ type: ToggleType.Switch, isOn: this.viewOnly })
          .selectedColor('#0A59F7')
          .onChange((v: boolean) => { this.viewOnly = v; })
      }
      .width('100%')
      .margin({ left: 24, right: 24, top: 20 })

      Button(this.connecting ? '连接中…' : '进入观看')
        .width('88%')
        .height(46)
        .borderRadius(12)
        .margin({ top: 32 })
        .enabled(!this.connecting)
        .onClick(() => { this.connect(); })

      Text('说明：访客连接由服务器按卡密解析设备；只读模式在客户端与服务端双重生效')
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 24, left: 32, right: 32 })
        .textAlign(TextAlign.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
