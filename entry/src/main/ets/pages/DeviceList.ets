/**
 * 设备列表页（对应安卓 DeviceListActivity）
 * 数据来自 DeviceService（REST，10s 生命周期轮询）；点击设备直达 ArkWeb 远程控制台。
 *
 * P0 对应：
 *  P0-1：401 → token 已清，回登录页（sessionEvent 通知根页切表单；仅本页在栈顶时 pop）
 *  P0-2：在线/离线分区、10s 轮询、本地模糊搜索（id + name）、设备信息展示
 */
import { DeviceService } from '../features/device/DeviceService';
import { AuthService } from '../features/auth/AuthService';
import { GlobalChannel } from '../features/signaling/GlobalChannel';
import { SettingsStore } from '../features/settings/SettingsStore';
import { GroupControl } from '../features/groupcontrol/GroupControl';
import { TagService, TagItem } from '../features/tags/TagService';
import { QuickStart } from '../features/onboarding/QuickStart';
import { QuickStartCard } from '../components/QuickStartCard';
import { MetricsService } from '../features/metrics/MetricsService';
import { TaskService } from '../features/tasks/TaskService';
import { DemoEngine } from '../features/demo/DemoEngine';
import { Device, RouteParams, UserPolicy } from '../model/Model';

const POLL_INTERVAL_MS: number = 10000;

@Component
export struct DeviceList {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;
  /** P1-7：device_list_update 广播 → 立即刷新（替代等下一轮 10s 轮询） */
  @StorageLink('deviceListEvent') @Watch('onListPush') listEvent: number = 0;
  /** P1-10：群控选择变更 → 行高亮/工具栏计数刷新（GroupControl.notify 写入） */
  @StorageLink('groupState') @Watch('onGroupChange') groupTick: number = 0;
  /** P2-10：标签变更/筛选切换 → 标签条与行徽标刷新（TagService.notify 写入） */
  @StorageLink('tagsState') @Watch('onTagsChange') tagsTick: number = 0;
  /** P2-12：账号到期时间戳（/api/me expires_at；0=永久或未取到，行隐藏） */
  @State accountExpireAt: number = 0;
  /** P2-11：空态引导数据（信令地址 / ICE JSON / 下载根，空列表时装载一次） */
  @State qsSignaling: string = '';
  @State qsIce: string = '[]';
  @State qsRoot: string = '';
  /** 引导数据已装载标记（幂等） */
  private qsLoaded: boolean = false;
  /** P2-12c：Demo 指标推送停止句柄（退出登录时停） */
  private demoStop: (() => void) | null = null;

  @State devices: Device[] = [];
  @State loading: boolean = true;
  @State keyword: string = '';
  /** P1-5/快照半步：snapshot_update 广播的设备缩略图（base64 PNG；整表重赋值触发刷新） */
  @State snapshots: Map<string, string> = new Map();

  private deviceService: DeviceService = DeviceService.getInstance();
  private auth: AuthService = AuthService.getInstance();
  private pollTimer: number = -1;

  aboutToAppear(): void {
    this.wireGlobalChannel();
    this.loadDevices(true);
    this.pollTimer = setInterval(() => {
      this.loadDevices(false);
    }, POLL_INTERVAL_MS);
  }

  /**
   * P1-7 装配根：全局信令监听注册（跨域协作经页面装配，features 不互 import）。
   * - global_settings_updated → SettingsStore 热更落盘（下一次控制页进页即生效）
   * - device_list_update → AppStorage 事件触发本页立即刷新
   * - snapshot_update → 本页缩略图状态（列表行内展示）
   */
  private wireGlobalChannel(): void {
    const gc = GlobalChannel.getInstance();
    gc.on('global_settings_updated', (msg: Record<string, Object>): void => {
      const s = msg['settings'] as Record<string, Object>;
      if (s !== undefined && s !== null) {
        SettingsStore.applyServerSettings(s).catch(() => { return; });
      }
    });
    gc.on('device_list_update', (): void => {
      AppStorage.setOrCreate<number>('deviceListEvent', Date.now());
    });
    gc.on('snapshot_update', (msg: Record<string, Object>): void => {
      const id = (msg['device_id'] as string) ?? '';
      const data = (msg['data'] as string) ?? '';
      if (id.length > 0 && data.length > 0) {
        const next = new Map(this.snapshots);
        next.set(id, data);
        this.snapshots = next;
      }
    });
    // P2-10：tags_update 广播 → 标签服务热更（devices.js:805 同款两字段载荷）
    gc.on('tags_update', (msg: Record<string, Object>): void => {
      const tagsJson = JSON.stringify(msg['tags'] ?? []);
      const devTagsJson = JSON.stringify(msg['deviceTags'] ?? {});
      TagService.getInstance().updateFromRemote(tagsJson, devTagsJson);
    });
    gc.ensureConnected().catch(() => { return; });
    MetricsService.register(gc); // P2-9：device_metrics 广播 → 指标域（大盘数据源）
    TaskService.register(gc); // P2-5：task_status_updated 广播 → 任务看板
    TagService.getInstance().load(); // P2-10：本地优先加载标签（get 过滤即生效）
    // P2-12：账号倒计时（复用 P1-4 策略拉取，expires_at 进页即取）
    AuthService.getInstance().getPolicy(true).then((p: UserPolicy) => {
      this.accountExpireAt = p.expiresAt;
    }).catch(() => { return; });
  }

  /**
   * 账号到期文案（P2-12）：单位启发式（<1e12 视为秒级时间戳 ×1000——服务端两种惯例都容）。
   * @returns ''=永久/未取到（UI 隐藏）；否则 '到期 MM-dd · 剩 N 天'
   */
  private expiryText(): string {
    const v = this.accountExpireAt;
    if (v <= 0) {
      return '';
    }
    const ms = v < 1000000000000 ? v * 1000 : v;
    const now = Date.now();
    if (ms <= now) {
      return '账号已到期';
    }
    const days = Math.ceil((ms - now) / 86400000);
    const d = new Date(ms);
    const mm = `${d.getMonth() + 1}`.padStart(2, '0');
    const dd = `${d.getDate()}`.padStart(2, '0');
    return `账号到期 ${mm}-${dd} · 剩 ${days} 天`;
  }

  /** 倒计时配色：≤1 天红、≤7 天橙、其余灰 */
  private expiryColor(): string {
    const v = this.accountExpireAt;
    const ms = v < 1000000000000 ? v * 1000 : v;
    const left = ms - Date.now();
    if (left <= 86400000) {
      return '#CC0000';
    }
    if (left <= 7 * 86400000) {
      return '#A34700';
    }
    return '#999999';
  }

  /** device_list_update 广播回调（@Watch）：立即刷新 */
  private onListPush(): void {
    if (this.listEvent !== 0) {
      this.loadDevices(false);
    }
  }

  /** 群控选择变更（@Watch）：刷新行高亮与工具栏计数（状态在 GroupControl，此处仅触发渲染） */
  private onGroupChange(): void {
    // 无显式动作：@StorageLink 已驱动 build 重算 isSelected/count
  }

  /** 标签变更/筛选切换（@Watch）：刷新标签条与行徽标（状态在 TagService） */
  private onTagsChange(): void {
    // 无显式动作：@StorageLink 已驱动 build 重算标签条与 matchesFilter
  }

  /** P2-10：标签管理页入口 */
  private openTags(): void {
    this.pathStack.pushPathByName('Tags', null);
  }

  /** 在线设备 ID 列表（群控「全选在线」数据源） */
  private onlineIds(): string[] {
    const ids: string[] = [];
    for (const d of this.devices) {
      if (d.online) {
        ids.push(d.device_id);
      }
    }
    return ids;
  }

  aboutToDisappear(): void {
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
  }

  /** 本页是否仍是栈顶（被控制页覆盖时后台轮询不得 pop，否则会弹掉上层页面） */
  private isTop(): boolean {
    const names: string[] = this.pathStack.getAllPathName();
    return names.length > 0 && names[names.length - 1] === 'DeviceList';
  }

  private backToLogin(): void {
    // 通知根页 Index 切换回连接表单（时间戳保证每次都是新值）
    AppStorage.setOrCreate<number>('sessionEvent', Date.now());
    if (this.isTop()) {
      this.pathStack.pop();
    }
  }

  private async loadDevices(showLoading: boolean): Promise<void> {
    // P2-12c：Demo 模式——本地演示矩阵直出，不走 REST（ticker 幂等启动）
    if (AppStorage.get<boolean>('demoMode') === true) {
      this.loading = false;
      this.devices = DemoEngine.getInstance().buildDevices();
      if (this.demoStop === null) {
        this.demoStop = DemoEngine.getInstance().startTicker(
          (id: string, metrics: Record<string, Object>): void => {
            MetricsService.getInstance().ingest(id, metrics); // 大盘/热力在 Demo 下同样工作
          });
      }
      return;
    }
    if (showLoading) {
      this.loading = true;
    }
    const result = await this.deviceService.fetchDevices();
    this.loading = false;
    if (!result.ok) {
      if (result.unauthorized) {
        // P0-1：401 —— token 已被 DeviceService 清除
        this.getUIContext().getPromptAction().showToast({ message: '登录已过期，请重新登录' });
        this.devices = [];
        this.backToLogin();
        return;
      }
      if (result.error === '未登录') {
        this.getUIContext().getPromptAction().showToast({ message: '未登录' });
        this.backToLogin();
        return;
      }
      // 轮询失败：保留上次数据，仅提示
      this.getUIContext().getPromptAction().showToast({ message: result.error });
      return;
    }
    this.devices = result.devices;
    if (result.devices.length === 0 && !this.qsLoaded) {
      this.loadQuickStart(); // P2-11：空列表时装载引导数据（幂等）
    }
  }

  /** P2-11：信令地址 / ICE / 下载根（一次装载，命令随卡片输入联动重算） */
  private async loadQuickStart(): Promise<void> {
    this.qsLoaded = true;
    this.qsSignaling = await QuickStart.signalingUrl();
    this.qsIce = await QuickStart.fetchIceJson();
    this.qsRoot = await QuickStart.agentRoot();
  }

  // ---------- 过滤（P0-2 搜索 + P2-10 标签筛选 + 在线/离线分区） ----------
  private filtered(): Device[] {
    const kw: string = this.keyword.trim().toLowerCase();
    const tags = TagService.getInstance();
    return this.devices.filter((d: Device) => {
      if (!tags.matchesFilter(d.device_id)) {
        return false; // P2-10：标签筛选（未选标签时恒通）
      }
      if (kw.length === 0) {
        return true;
      }
      return d.device_id.toLowerCase().indexOf(kw) >= 0 || d.name.toLowerCase().indexOf(kw) >= 0;
    });
  }

  private onlineList(): Device[] {
    return this.filtered().filter((d: Device) => d.online);
  }

  private offlineList(): Device[] {
    return this.filtered().filter((d: Device) => !d.online);
  }

  private openDevice(dev: Device): void {
    // 直连被控端：进入自研控制页（rawfile/control.html），加载已登录服务器的设备
    this.routeParams.serverUrl = '';
    this.routeParams.deviceId = dev.device_id;
    this.routeParams.viewOnly = false;
    this.routeParams.shareToken = '';
    this.pathStack.pushPathByName('ArkWebView', null);
  }

  /**
   * 扫描：回首页（首页即扫描页，自动扫描局域网被控端）
   */
  private backHome(): void {
    this.pathStack.pop();
  }

  private openSettings(): void {
    this.routeParams.deviceId = ''; // 顶栏设置=全局作用域（设备作用域由行内 ⚙ 进入）
    this.pathStack.pushPathByName('Settings', null);
  }

  /** P1-3：按设备作用域进入设置页（deviceId 由 SettingsPage 消费后清空） */
  private openDeviceSettings(dev: Device): void {
    this.routeParams.deviceId = dev.device_id;
    this.pathStack.pushPathByName('Settings', null);
  }

  /** P1-5：进入实时预览页（消费式带参：deviceId + 逻辑分辨率直控基准；行内按钮与缩略图共用） */
  private openPreview(dev: Device): void {
    this.routeParams.deviceId = dev.device_id;
    this.routeParams.deviceXRes = dev.x_res;
    this.routeParams.deviceYRes = dev.y_res;
    this.pathStack.pushPathByName('Preview', null);
  }

  /** P1-9：进入终端页（设备由页内选择器自选；不带 deviceId → 默认第一台在线） */
  private openTerminal(): void {
    this.routeParams.deviceId = '';
    this.routeParams.viewOnly = false;
    this.pathStack.pushPathByName('Terminal', null);
  }

  private async logout(): Promise<void> {
    await this.auth.logout();
    GlobalChannel.getInstance().disconnect(); // P1-7：登出即断全局信令
    // P2-12c：退出 Demo（停指标推送并清标记）
    if (this.demoStop !== null) {
      this.demoStop();
      this.demoStop = null;
    }
    AppStorage.setOrCreate<boolean>('demoMode', false);
    // Index 是 Navigation 常驻根内容（栈底），pop 回来不会重跑 aboutToAppear：
    // 经 AppStorage 会话事件通知它切换为连接表单（时间戳保证每次都是新值）
    AppStorage.setOrCreate<number>('sessionEvent', Date.now());
    this.pathStack.pop();
  }

  @Builder
  sectionTitle(title: string, count: number, color: string) {
    Text(`${title} ${count}`)
      .fontSize(13)
      .fontColor(color)
      .fontWeight(FontWeight.Medium)
      .margin({ top: 6, bottom: 2 })
  }

  @Builder
  deviceRow(dev: Device) {
    Row() {
      // P1-5 快照半步：有 snapshot_update 广播数据则展示缩略图（点击进入实时预览）
      if ((this.snapshots.get(dev.device_id) ?? '').length > 0) {
        Image(this.snapshots.get(dev.device_id) ?? '')
          .width(40)
          .height(40)
          .borderRadius(6)
          .margin({ right: 10 })
          .onClick(() => { this.openPreview(dev); })
      }
      Column() {
        Text(dev.device_id)
          .fontSize(17)
          .fontWeight(FontWeight.Medium)
        // P2-10：设备标签徽标（彩色圆点，随 tagsState 联动刷新）
        Row({ space: 3 }) {
          ForEach(TagService.getInstance().getTagsForDevice(dev.device_id), (t: TagItem) => {
            Circle({ width: 6, height: 6 })
              .fill(t.color)
          }, (t: TagItem) => t.id)
        }
        .margin({ top: 3 })
        Text(dev.name.length > 0 ? dev.name : '未命名设备')
          .fontSize(13)
          .fontColor('#666666')
          .margin({ top: 4 })
        if (dev.x_res > 0) {
          Text(`${dev.x_res}×${dev.y_res}${dev.client_count > 0 ? ` · ${dev.client_count} 人在控` : ''}`)
            .fontSize(11)
            .fontColor('#999999')
            .margin({ top: 3 })
        }
      }
      .alignItems(HorizontalAlign.Start)

      Blank()

      // P1-3/P1-5 行内动作：群控勾选 / 预览 / 按设备设置；child 点击不冒泡到行点击
      Text(GroupControl.getInstance().isSelected(dev.device_id) ? '✓选' : '选')
        .fontSize(13)
        .fontColor(GroupControl.getInstance().isSelected(dev.device_id) ? '#007A00' : '#0A59F7')
        .fontWeight(GroupControl.getInstance().isSelected(dev.device_id) ? FontWeight.Medium : FontWeight.Normal)
        .margin({ right: 10 })
        .onClick(() => { GroupControl.getInstance().toggle(dev.device_id); })

      Text('预览')
        .fontSize(13)
        .fontColor('#0A59F7')
        .margin({ right: 12 })
        .onClick(() => { this.openPreview(dev); })

      // P1-3：按设备画质设置入口
      Text('⚙')
        .fontSize(16)
        .fontColor('#0A59F7')
        .margin({ right: 12 })
        .onClick(() => { this.openDeviceSettings(dev); })

      Text(dev.online ? '在线' : '离线')
        .fontSize(13)
        .fontColor(dev.online ? '#007A00' : '#666666')
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .padding(18)
    .borderRadius(12)
    .onClick(() => { this.openDevice(dev); })
  }

  build() {
    Column() {
      // 顶栏：标题 + 操作行（8 项横向滚动防溢出）
      Column() {
        Text('设备列表')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
        Scroll() {
          Row({ space: 16 }) {
            Text('扫描')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.backHome(); })
            Text('终端')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.openTerminal(); })
            Text('大盘')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.pathStack.pushPathByName('Dashboard', null); })
            Text('文件')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.pathStack.pushPathByName('FileCenter', null); })
            Text('键位')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.pathStack.pushPathByName('Keymap', null); })
            Text('标签')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.openTags(); })
            Text('分享')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.pathStack.pushPathByName('ShareManage', null); })
            Text('设置')
              .fontSize(14)
              .fontColor('#0A59F7')
              .onClick(() => { this.openSettings(); })
            Text('退出')
              .fontSize(14)
              .fontColor('#CC0000')
              .onClick(() => { this.logout(); })
          }
          .padding({ left: 24, right: 24, top: 6 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .padding({ left: 24, right: 24, top: 14, bottom: 10 })
      .backgroundColor('#F5F5F5')

      // 搜索（P0-2：id + name 模糊匹配）
      TextInput({ placeholder: '搜索设备 ID / 名称', text: this.keyword })
        .type(InputType.Normal)
        .height(40)
        .backgroundColor('#FFFFFF')
        .margin({ left: 24, right: 24, top: 4 })
        .onChange((value: string) => {
          this.keyword = value;
        })

      // P1-10 群控工具栏：勾选从机（进入控制页即绑定主控，输入事件同步广播）
      Row({ space: 8 }) {
        Button('全选在线')
          .height(30)
          .fontSize(12)
          .backgroundColor('#EEF4FF')
          .fontColor('#0A59F7')
          .onClick(() => { GroupControl.getInstance().selectAll(this.onlineIds()); })
        Button('清空')
          .height(30)
          .fontSize(12)
          .backgroundColor('#F0F0F0')
          .fontColor('#666666')
          .onClick(() => { GroupControl.getInstance().clear(); })
        Button('任务')
          .height(30)
          .fontSize(12)
          .backgroundColor('#EEF4FF')
          .fontColor('#0A59F7')
          .onClick(() => { this.pathStack.pushPathByName('Tasks', null); })
        Text(GroupControl.getInstance().count > 0 ?
          `已选 ${GroupControl.getInstance().count} 台 · 进入控制页即主控广播` :
          '群控：勾选从机后进入控制页，你的操作将同步广播')
          .fontSize(11)
          .fontColor('#999999')
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 6, bottom: 2 })

      // P2-12：账号倒计时（expires_at>0 才显示；配色按剩余天数分级）
      if (this.expiryText().length > 0) {
        Text(this.expiryText())
          .fontSize(11)
          .fontColor(this.expiryColor())
          .padding({ left: 24, right: 24, top: 2 })
      }

      // P2-10 标签筛选条：点选切换过滤（selectedId 反色高亮；「管理」进 Tags 页）
      Scroll() {
        Row({ space: 6 }) {
          Text('标签').fontSize(12).fontColor('#999999')
          Text('全部')
            .fontSize(12)
            .padding({ left: 10, right: 10, top: 4, bottom: 4 })
            .borderRadius(12)
            .backgroundColor(TagService.getInstance().selectedId === '' ? '#0A59F7' : '#F0F0F0')
            .fontColor(TagService.getInstance().selectedId === '' ? '#FFFFFF' : '#666666')
            .onClick(() => { TagService.getInstance().setSelectedTag(''); })
          ForEach(TagService.getInstance().tags, (t: TagItem) => {
            Text(t.name)
              .fontSize(12)
              .padding({ left: 10, right: 10, top: 4, bottom: 4 })
              .borderRadius(12)
              .backgroundColor(TagService.getInstance().selectedId === t.id ? t.color : `${t.color}33`)
              .fontColor(TagService.getInstance().selectedId === t.id ? '#FFFFFF' : '#333333')
              .fontWeight(TagService.getInstance().selectedId === t.id ? FontWeight.Medium : FontWeight.Normal)
              .onClick(() => { TagService.getInstance().setSelectedTag(t.id); })
          }, (t: TagItem) => `${t.id}_${TagService.getInstance().selectedId === t.id}`)
          Text('管理')
            .fontSize(12)
            .fontColor('#0A59F7')
            .padding({ left: 6, right: 4 })
            .onClick(() => { this.openTags(); })
        }
        .padding({ left: 24, right: 24, top: 4, bottom: 4 })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')

      if (this.loading) {
        LoadingProgress()
          .width(40)
          .height(40)
          .margin({ top: 100 })
      } else if (this.devices.length === 0) {
        // P2-11：空态快速接入引导（上游 quickstart 区；WebUSB 入口列 P3）
        Scroll() {
          Column({ space: 10 }) {
            Text('暂无可用云手机')
              .fontSize(16)
              .fontColor('#666666')
            Text('当前服务器未接入设备——按下方引导部署 Agent 后回到本页刷新')
              .fontSize(12)
              .fontColor('#999999')
            QuickStartCard({
              signalingUrl: this.qsSignaling,
              iceJson: this.qsIce,
              agentRoot: this.qsRoot
            })
          }
          .width('100%')
          .padding({ left: 24, right: 24, top: 16, bottom: 32 })
        }
        .layoutWeight(1)
        .width('100%')
        .edgeEffect(EdgeEffect.Spring)
      } else if (this.filtered().length === 0) {
        Text('无匹配设备')
          .fontSize(15)
          .fontColor('#666666')
          .margin({ top: 60 })
      } else {
        List({ space: 10 }) {
          if (this.onlineList().length > 0) {
            this.sectionTitle('在线', this.onlineList().length, '#007A00')
          }
          Repeat(this.onlineList())
            .each((ri: RepeatItem<Device>) => {
              ListItem() {
                this.deviceRow(ri.item)
              }
            })
            .key((item: Device) => item.device_id)

          if (this.offlineList().length > 0) {
            this.sectionTitle('离线', this.offlineList().length, '#666666')
          }
          Repeat(this.offlineList())
            .each((ri: RepeatItem<Device>) => {
              ListItem() {
                this.deviceRow(ri.item)
              }
            })
            .key((item: Device) => item.device_id)
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ left: 24, right: 24, top: 18 })
        // 边界反馈动效：滑到顶/底时弹簧回弹（应用市场 UX 审核要求）
        // List 的 alwaysEnabled 默认为 false，内容不满屏时不会触发，必须显式打开
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      }

      // 横向留白走父容器 padding：width('100%') + margin 会被裁切
      Column() {
        Button('刷新')
          .width('100%')
          .height(44)
          .borderRadius(12)
          .margin({ top: 8, bottom: 24 })
          .onClick(() => { this.loadDevices(true); })
      }
      .width('100%')
      .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
