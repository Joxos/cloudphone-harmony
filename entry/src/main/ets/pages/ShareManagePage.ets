/**
 * ShareManagePage —— 分享卡密管理页（P2-4a，对应上游 ShareModal 数据面 + ShareAdminPage 列表）
 *
 * 职责（单一）：创建分享（设备/时长/模式/密码/描述）、分享列表（复制链接/延时/撤销）、
 *   卡密兑换（redeem_card → 访客 token）。
 * 消费契约：features/share/ShareService（REST 逐条对齐上游调用方）。
 * 范围注记：/api/share/update（访客设置编辑）与多地址链接选择（server/addresses）列 P2-4b。
 * 入口：DeviceList 顶栏「分享」；访客消费页沿用 SharePage（P0-12）。
 */
import { pasteboard } from '@kit.BasicServicesKit';
import { ShareService, ShareInfo, ShareCreateArgs, ShareOpResult } from '../features/share/ShareService';
import { DeviceService } from '../features/device/DeviceService';
import { SettingsStore } from '../features/settings/SettingsStore';
import { ConnectionSettings } from '../features/settings/ConnectionSettings';
import { RouteParams } from '../model/Model';

/** 时长预设（秒；上游 expireOption 同语义，1小时/1天/7天/30天） */
const EXPIRE_PRESETS: number[] = [3600, 86400, 604800, 2592000];
const EXPIRE_LABELS: string[] = ['1小时', '1天', '7天', '30天'];

@Component
export struct ShareManagePage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  private service: ShareService = ShareService.getInstance();

  /** 分享列表（全量） */
  @State shares: ShareInfo[] = [];
  /** 创建表单 */
  @State deviceIds: string[] = [];
  @State createDeviceId: string = '';
  @State expireIdx: number = 1;
  @State accessMode: string = 'view';
  @State createPassword: string = '';
  @State createDesc: string = '';
  @State createdToken: string = '';
  @State createdLink: string = '';
  @State busy: boolean = false;
  /** 卡密兑换 */
  @State cardCode: string = '';
  @State cardPwd: string = '';
  @State cardToken: string = '';
  // ---- P2-4b：访客设置编辑（选中分享）与链接地址选择 ----
  @State editingToken: string = '';
  @State edForbidBitrate: boolean = false;
  @State edForbidFps: boolean = false;
  @State edForbidResolution: boolean = false;
  @State edForbidAudio: boolean = false;
  /** 自定义访客画质（开=用全局当前设置作 guest_settings；关=null 继承） */
  @State edUseCustom: boolean = false;
  /** 访客链接地址（空=默认服务器 host；GET /api/server/addresses） */
  @State addresses: string[] = [];
  @State selectedAddress: string = '';

  aboutToAppear(): void {
    this.reload();
    this.loadDevices();
    this.loadAddresses();
  }

  /** P2-4b：链接地址列表（首项为默认 host，故默认 selectedAddress=''） */
  private loadAddresses(): void {
    this.service.serverAddresses().then((list: string[]) => {
      this.addresses = list;
    }).catch(() => { return; });
  }

  private reload(): void {
    this.service.listShares('').then((list: ShareInfo[]) => {
      this.shares = list;
    }).catch(() => { return; });
  }

  private async loadDevices(): Promise<void> {
    const result = await DeviceService.getInstance().fetchDevices();
    const ids: string[] = [];
    for (const d of result.devices) {
      ids.push(d.device_id);
    }
    this.deviceIds = ids;
    if (this.createDeviceId.length === 0 && ids.length > 0) {
      this.createDeviceId = ids[0];
    }
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  private back(): void {
    this.pathStack.pop();
  }

  private copy(text: string, tip: string): void {
    if (text.length === 0) {
      return;
    }
    const pd = pasteboard.createData('text/plain', text);
    pasteboard.getSystemPasteboard().setData(pd).then(() => {
      this.toast(tip);
    }).catch(() => {
      this.toast('复制失败');
    });
  }

  // ===================== 操作 =====================

  /** 创建（结果 → 访客链接展示区） */
  private async doCreate(): Promise<void> {
    if (this.createDeviceId.length === 0) {
      this.toast('请选择设备');
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    const args = new ShareCreateArgs();
    args.deviceId = this.createDeviceId;
    args.expireSeconds = EXPIRE_PRESETS[this.expireIdx];
    args.accessMode = this.accessMode;
    args.password = this.createPassword;
    args.description = this.createDesc;
    const r: ShareOpResult = await this.service.createShare(args);
    this.busy = false;
    if (!r.ok) {
      this.toast(`创建失败：${r.msg}`);
      return;
    }
    this.createdToken = r.token;
    this.createdLink = await this.service.buildShareUrl(r.token, this.selectedAddress);
    this.toast('分享已创建');
    this.reload();
  }

  /** 列表行复制链接（带所选访问地址） */
  private async doCopyLink(tokenId: string): Promise<void> {
    const url = await this.service.buildShareUrl(tokenId, this.selectedAddress);
    this.copy(url, '访客链接已复制');
  }

  /** P2-4b：进入分享编辑（回填四维与自定义画质初值） */
  private startEditShare(s: ShareInfo): void {
    this.editingToken = s.token_id;
    this.edForbidBitrate = s.forbid_bitrate;
    this.edForbidFps = s.forbid_fps;
    this.edForbidResolution = s.forbid_resolution;
    this.edForbidAudio = s.forbid_audio;
    this.edUseCustom = s.guest_settings_json.length > 0;
  }

  /** P2-4b：保存访客设置（自定义=全局当前画质作 guest_settings；关=null 继承设备配置） */
  private async saveEditShare(): Promise<void> {
    let guest: ConnectionSettings | null = null;
    if (this.edUseCustom) {
      guest = await SettingsStore.load('');
    }
    const r = await this.service.updateShare(
      this.editingToken, this.edForbidBitrate, this.edForbidFps,
      this.edForbidResolution, this.edForbidAudio, guest);
    if (r.ok) {
      this.toast('访客设置已更新');
      this.editingToken = '';
      this.reload();
    } else {
      this.toast(`更新失败：${r.msg}`);
    }
  }

  /** 延时 +1 天 */
  private async doExtend(tokenId: string): Promise<void> {
    const r = await this.service.extendShare(tokenId, 86400);
    if (r.ok) {
      this.toast('已延时 1 天');
      this.reload();
    } else {
      this.toast(`延时失败：${r.msg}`);
    }
  }

  /** 撤销（上游语义：链接与卡密立即失效） */
  private async doRevoke(tokenId: string): Promise<void> {
    const ok = await this.service.revokeShare(tokenId);
    if (ok) {
      this.toast('已撤销');
      this.reload();
    } else {
      this.toast('撤销失败');
    }
  }

  /** 卡密兑换（免登录 redeem_card → token） */
  private async doRedeem(): Promise<void> {
    if (this.cardCode.trim().length === 0) {
      this.toast('请输入卡密');
      return;
    }
    const r = await this.service.redeemCard(this.cardCode.trim(), this.cardPwd);
    if (r.ok && r.token.length > 0) {
      this.cardToken = r.token;
      this.toast('兑换成功，可复制访客链接');
    } else {
      this.toast(`兑换失败：${r.msg.length > 0 ? r.msg : '卡密无效'}`);
    }
  }

  /** 展示用：到期时间格式化（ISO 可解析→MM-dd HH:mm；否则原样/永久） */
  private formatExpires(expiresAt: string): string {
    if (expiresAt.length === 0) {
      return '永久';
    }
    const t = Date.parse(expiresAt);
    if (isNaN(t)) {
      return expiresAt;
    }
    const d = new Date(t);
    const mm = `${d.getMonth() + 1}`.padStart(2, '0');
    const dd = `${d.getDate()}`.padStart(2, '0');
    const hh = `${d.getHours()}`.padStart(2, '0');
    const mi = `${d.getMinutes()}`.padStart(2, '0');
    return `${mm}-${dd} ${hh}:${mi}`;
  }

  // ===================== 视图 =====================

  @Builder
  createSection() {
    Column() {
      Text('创建分享').fontSize(15).fontWeight(FontWeight.Medium).width('100%')

      Row({ space: 8 }) {
        Select(this.deviceOptions())
          .layoutWeight(1)
          .height(34)
          .font({ size: 13 })
          .selected(Math.max(0, this.deviceIds.indexOf(this.createDeviceId)))
          .onSelect((i: number) => {
            const id = this.deviceIds[i];
            if (id !== undefined) {
              this.createDeviceId = id;
            }
          })
        Button('创建').height(34).fontSize(13).enabled(!this.busy)
          .onClick(() => { this.doCreate(); })
      }
      .width('100%')
      .margin({ top: 8 })

      // 时长预设
      Row({ space: 8 }) {
        ForEach(EXPIRE_LABELS, (label: string, idx: number) => {
          Text(label)
            .fontSize(12)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(this.expireIdx === idx ? '#0A59F7' : '#EEEEEE')
            .fontColor(this.expireIdx === idx ? '#FFFFFF' : '#666666')
            .onClick(() => { this.expireIdx = idx; })
        }, (label: string, idx: number) => `${label}_${this.expireIdx === idx}`)
      }
      .width('100%')
      .margin({ top: 10 })
      .justifyContent(FlexAlign.Start)

      // 访问模式
      Row({ space: 8 }) {
        Text(this.modeChipLabel('view', '只读观看'))
          .fontSize(12).padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(14)
          .backgroundColor(this.accessMode === 'view' ? '#0A59F7' : '#EEEEEE')
          .fontColor(this.accessMode === 'view' ? '#FFFFFF' : '#666666')
          .onClick(() => { this.accessMode = 'view'; })
        Text(this.modeChipLabel('control', '可控'))
          .fontSize(12).padding({ left: 12, right: 12, top: 6, bottom: 6 }).borderRadius(14)
          .backgroundColor(this.accessMode === 'control' ? '#0A59F7' : '#EEEEEE')
          .fontColor(this.accessMode === 'control' ? '#FFFFFF' : '#666666')
          .onClick(() => { this.accessMode = 'control'; })
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Start)

      TextInput({ placeholder: '访问密码（可空）', text: this.createPassword })
        .width('100%').height(34).fontSize(13).margin({ top: 8 })
        .onChange((v: string) => { this.createPassword = v; })
      TextInput({ placeholder: '备注描述（可空）', text: this.createDesc })
        .width('100%').height(34).fontSize(13).margin({ top: 8 })
        .onChange((v: string) => { this.createDesc = v; })

      // 创建结果
      if (this.createdToken.length > 0) {
        Divider().margin({ top: 10, bottom: 6 })
        Text(`已创建 token: ${this.createdToken}`).fontSize(12).fontColor('#007A00').width('100%')
        Row({ space: 8 }) {
          Button('复制访客链接').fontSize(12).height(32).layoutWeight(1)
            .onClick(() => { this.copy(this.createdLink, '链接已复制'); })
          Button('复制 token').fontSize(12).height(32).layoutWeight(1)
            .backgroundColor('#F0F0F0').fontColor('#666666')
            .onClick(() => { this.copy(this.createdToken, 'token 已复制'); })
        }
        .width('100%').margin({ top: 6 })
      }
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .padding(14)
  }

  private modeChipLabel(mode: string, label: string): string {
    return this.accessMode === mode ? `● ${label}` : label;
  }

  @Builder
  listSection() {
    Column() {
      Row() {
        Text(`分享列表（${this.shares.length}）`).fontSize(15).fontWeight(FontWeight.Medium)
        Blank()
        Text('刷新').fontSize(13).fontColor('#0A59F7').onClick(() => { this.reload(); })
      }
      .width('100%')

      // P2-4b：访客链接访问地址（GET /api/server/addresses；首项默认=服务器 host）
      if (this.addresses.length > 0) {
        Row({ space: 8 }) {
          Text('链接地址').fontSize(12).fontColor('#999999')
          Select(this.addressOptions())
            .layoutWeight(1)
            .height(30)
            .font({ size: 12 })
            .selected(Math.max(0, this.addresses.indexOf(this.selectedAddress)))
            .onSelect((i: number) => {
              const list = [''].concat(this.addresses);
              const v = list[i];
              this.selectedAddress = v !== undefined ? v : '';
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }

      if (this.shares.length === 0) {
        Text('暂无分享——创建后访客可用链接或卡密接入').fontSize(12).fontColor('#999999').margin({ top: 8 })
      }

      ForEach(this.shares, (s: ShareInfo) => {
        Column() {
          Row() {
            Text(`…${s.token_id.slice(-8)}`)
              .fontSize(13).fontWeight(FontWeight.Medium).layoutWeight(1)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(s.access_mode.length > 0 ? s.access_mode : '-')
              .fontSize(11).fontColor('#666666').padding({ left: 6, right: 6 })
            Text(this.formatExpires(s.expires_at))
              .fontSize(11).fontColor('#999999')
          }
          .width('100%')

          if (s.device_id.length > 0 || s.description.length > 0) {
            Text(`${s.device_id}${s.description.length > 0 ? ` · ${s.description}` : ''}`)
              .fontSize(11).fontColor('#999999').width('100%').maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }

          Row({ space: 8 }) {
            Button('复制链接').fontSize(11).height(28).layoutWeight(1)
              .onClick(() => { this.doCopyLink(s.token_id); })
            Button('设置').fontSize(11).height(28).layoutWeight(1)
              .backgroundColor('#EEF4FF').fontColor('#0A59F7')
              .onClick(() => { this.startEditShare(s); })
            Button('+1天').fontSize(11).height(28).layoutWeight(1)
              .backgroundColor('#EEF4FF').fontColor('#0A59F7')
              .onClick(() => { this.doExtend(s.token_id); })
            Button('撤销').fontSize(11).height(28).layoutWeight(1)
              .backgroundColor('#FDEEEE').fontColor('#CC0000')
              .onClick(() => { this.doRevoke(s.token_id); })
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .backgroundColor('#FAFAFA')
        .borderRadius(8)
        .padding(10)
        .margin({ top: 8 })
      }, (s: ShareInfo) => `${s.token_id}_${s.expires_at}_${s.description}`)

      // ---- P2-4b：访客设置编辑区（行内「设置」唤起） ----
      if (this.editingToken.length > 0) {
        Divider().margin({ top: 10, bottom: 6 })
        Text(`编辑访客设置 · …${this.editingToken.slice(-8)}`)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0A59F7')
          .width('100%')

        Row() {
          Text('锁定码率').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.edForbidBitrate })
            .onChange((v: boolean) => { this.edForbidBitrate = v; })
        }
        .width('100%').padding({ top: 8 })
        Row() {
          Text('锁定帧率').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.edForbidFps })
            .onChange((v: boolean) => { this.edForbidFps = v; })
        }
        .width('100%').padding({ top: 6 })
        Row() {
          Text('锁定分辨率').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.edForbidResolution })
            .onChange((v: boolean) => { this.edForbidResolution = v; })
        }
        .width('100%').padding({ top: 6 })
        Row() {
          Text('锁定音频').fontSize(14).layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.edForbidAudio })
            .onChange((v: boolean) => { this.edForbidAudio = v; })
        }
        .width('100%').padding({ top: 6 })
        Row() {
          Text('自定义访客画质（关=继承设备当前配置）').fontSize(13).layoutWeight(1).fontColor('#666666')
          Toggle({ type: ToggleType.Switch, isOn: this.edUseCustom })
            .onChange((v: boolean) => { this.edUseCustom = v; })
        }
        .width('100%').padding({ top: 6 })

        Row({ space: 8 }) {
          Button('保存设置').fontSize(12).height(32).layoutWeight(1)
            .onClick(() => { this.saveEditShare(); })
          Button('取消').fontSize(12).height(32).layoutWeight(1)
            .backgroundColor('#F0F0F0').fontColor('#666666')
            .onClick(() => { this.editingToken = ''; })
        }
        .width('100%').margin({ top: 8 })
      }
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .padding(14)
    .margin({ top: 12 })
  }

  @Builder
  redeemSection() {
    Column() {
      Text('卡密兑换').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
      TextInput({ placeholder: '卡密（st_…）', text: this.cardCode })
        .width('100%').height(34).fontSize(13).margin({ top: 8 })
        .onChange((v: string) => { this.cardCode = v; })
      Row({ space: 8 }) {
        TextInput({ placeholder: '密码（可空）', text: this.cardPwd })
          .layoutWeight(1).height(34).fontSize(13)
          .onChange((v: string) => { this.cardPwd = v; })
        Button('兑换').height(34).fontSize(13).onClick(() => { this.doRedeem(); })
      }
      .width('100%').margin({ top: 8 })

      if (this.cardToken.length > 0) {
        Text(`token: ${this.cardToken}`).fontSize(12).fontColor('#007A00').width('100%').margin({ top: 8 })
        Button('复制访客链接').fontSize(12).height(32).width('100%').margin({ top: 6 })
          .onClick(async () => {
            const url = await this.service.buildShareUrl(this.cardToken, this.selectedAddress);
            this.copy(url, '链接已复制');
          })
      }
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .padding(14)
    .margin({ top: 12, bottom: 24 })
  }

  /** 创建区设备选择器数据源（SelectOption[] 签名） */
  private deviceOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const id of this.deviceIds) {
      const so: SelectOption = { value: id };
      arr.push(so);
    }
    return arr;
  }

  /** P2-4b：地址选择数据源（首项=默认服务器 host，其后为 addresses 列表） */
  private addressOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    const first: SelectOption = { value: '默认 host' };
    arr.push(first);
    for (const a of this.addresses) {
      const so: SelectOption = { value: a };
      arr.push(so);
    }
    return arr;
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text('分享卡密').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      Scroll() {
        Column() {
          this.createSection()
          this.listSection()
          this.redeemSection()
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 8 })
      }
      .layoutWeight(1)
      .width('100%')
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
