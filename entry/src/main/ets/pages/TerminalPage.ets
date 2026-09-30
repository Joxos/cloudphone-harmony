/**
 * TerminalPage —— 终端页（P1-9，对应上游 DeviceConsole Tab1「单台 Shell」）
 *
 * 职责（单一）：选择设备 → 经 ShellClient 执行 shell 命令并展示输出流；
 *              本地命令历史（100 条，上游同口径）与预设快捷指令。
 * 入口：RootPage 路由 'Terminal'（DeviceList 顶栏「终端」按钮）。
 * 范围说明：单台 WS command（本域核心）；多台并发走 /api/tasks 属 P2-5 群控域；
 *          云端快捷指令同步（/api/shortcuts）随 P2 接入，此处为本地预设。
 * 依赖：features/terminal/ShellClient（协议）、features/device/DeviceService（设备列表）。
 */
import { common } from '@kit.AbilityKit';
import { ShellClient, CmdResult } from '../features/terminal/ShellClient';
import { ShortcutService, ShortcutItem } from '../features/terminal/ShortcutService';
import { DemoEngine } from '../features/demo/DemoEngine';
import { DeviceService } from '../features/device/DeviceService';
import { RouteParams } from '../model/Model';
import { Prefs } from '../utils/Prefs';

/** 输出流单条展示行（页内私有模型：命令回显 / 结果 / 系统消息） */
class OutputLine {
  /** 展示文本（多行以 \n 连接） */
  text: string;
  /** 是否命令回显（前缀 $ 与着色） */
  isCmd: boolean;
  /** 是否错误态（红字） */
  isErr: boolean;

  constructor(text: string, isCmd: boolean = false, isErr: boolean = false) {
    this.text = text;
    this.isCmd = isCmd;
    this.isErr = isErr;
  }
}
/** 历史容量（上游 cloudphone_shell_history 同口径） */
const HISTORY_LIMIT: number = 100;
/** Prefs 键：命令历史（JSON 数组字符串） */
const HISTORY_KEY: string = 'shell_history_json';

@Component
export struct TerminalPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  /** 连接状态徽标文案（由 ShellClient.onState 驱动） */
  @State connText: string = '未连接';
  @State connOk: boolean = false;
  /** P2-12：快捷指令表变更 → 执行区/编辑区刷新（ShortcutService.notify 写入） */
  @StorageLink('shortcutsState') @Watch('onShortcutsChanged') shortcutsTick: number = 0;
  /** P2-12：编辑模式与新增表单 */
  @State editingShortcuts: boolean = false;
  @State newShortName: string = '';
  @State newShortCmd: string = '';
  /** 在线设备（选择器数据源：id 展示，离线不入列） */
  @State deviceOptions: string[] = [];
  @State selectedId: string = '';
  /** 输出流与输入态 */
  @State lines: OutputLine[] = [];
  @State inputText: string = '';
  @State sending: boolean = false;

  private client: ShellClient = ShellClient.getInstance();
  private deviceService: DeviceService = DeviceService.getInstance();
  /** 输出流滚动控制器（Scroll 绑定，pushLine 后滚到底） */
  private scrollCtl: Scroller = new Scroller();
  /** 命令历史（加载于 init，成功发送后追加并落盘） */
  private history: string[] = [];
  /** 历史浏览游标（history.length=正在输入新命令） */
  private historyIndex: number = 0;

  aboutToAppear(): void {
    this.client.onState = (s: string): void => {
      this.connText = `${this.stateText(s)} · ${this.selectedId}`;
      this.connOk = (s === 'connected');
    };
    this.loadHistory();
    ShortcutService.getInstance().load(); // P2-12：云端/local/默认三层加载（幂等）
    this.initDevices();
  }

  /** 快捷指令表变更（@Watch）：状态在服务单例，@StorageLink 触发渲染即可 */
  private onShortcutsChanged(): void {
    // 无显式动作
  }

  /** P2-12：新增快捷指令（校验双全后入表并双端同步） */
  private addShortcut(): void {
    const ok = ShortcutService.getInstance().add(this.newShortName, this.newShortCmd);
    if (ok) {
      this.newShortName = '';
      this.newShortCmd = '';
    } else {
      this.getUIContext().getPromptAction().showToast({ message: '名称与命令均不可为空' });
    }
  }

  aboutToDisappear(): void {
    this.client.disconnect();
    this.client.onState = null;
  }

  /** ShellClient 状态 → 展示文案（纯函数，未识别状态原样透传） */
  private stateText(s: string): string {
    if (s === 'connected') {
      return '已连接';
    }
    if (s === 'connecting') {
      return '连接中';
    }
    if (s === 'error') {
      return '连接失败';
    }
    return '未连接';
  }

  /** Prefs 初始化 + 拉取在线设备并自动选中（routeParams 优先，否则第一台在线） */
  private async initDevices(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await Prefs.getInstance().init(ctx);
    const result = await this.deviceService.fetchDevices();
    const online: string[] = [];
    for (const d of result.devices) {
      if (d.online) {
        online.push(d.device_id);
      }
    }
    this.deviceOptions = online;
    if (online.length === 0) {
      this.pushLine('当前无在线设备（请先在设备列表确认）', false, true);
      this.connText = '无在线设备';
      return;
    }
    let pick = this.routeParams.deviceId;
    if (online.indexOf(pick) < 0) {
      pick = online[0];
    }
    this.selectedId = pick;
    this.connectSelected();
  }

  /** 连接当前选中设备（重连前 ShellClient 内部先断旧会话） */
  private async connectSelected(): Promise<void> {
    if (this.selectedId.length === 0) {
      return;
    }
    const ok = await this.client.connect(this.selectedId);
    if (!ok) {
      this.getUIContext().getPromptAction().showToast({ message: '终端连接失败，请检查网络与登录态' });
    }
  }

  /** 设备切换（选择器回调） */
  private onSelectDevice(index: number): void {
    const id = this.deviceOptions[index];
    if (id === undefined || id === this.selectedId) {
      return;
    }
    this.selectedId = id;
    this.pushLine(`—— 已切换设备 ${id} ——`, false, false);
    this.connectSelected();
  }

  // ===================== 输出流与历史 =====================

  /** 追加一行并滚动到底（Scroller.scrollToIndex 指向末位） */
  private pushLine(text: string, isCmd: boolean, isErr: boolean): void {
    this.lines = [...this.lines, new OutputLine(text, isCmd, isErr)];
    if (this.lines.length > 0) {
      this.scrollCtl.scrollToIndex(this.lines.length - 1, true);
    }
  }

  /** string[] → SelectOption[]（本 SDK Select 构造签名为 SelectOption[] 数组） */
  private toSelectOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const id of this.deviceOptions) {
      const so: SelectOption = { value: id };
      arr.push(so);
    }
    return arr;
  }

  /** 清屏（仅清展示，不动历史） */
  private clearOutput(): void {
    this.lines = [];
  }

  /** 从 Prefs 载入命令历史（损坏 JSON 容错为空表） */
  private loadHistory(): void {
    Prefs.getInstance().getString(HISTORY_KEY, '[]').then((v: string) => {
      try {
        const arr = JSON.parse(v.length > 0 ? v : '[]') as string[];
        this.history = Array.isArray(arr) ? arr : [];
      } catch (e) {
        this.history = [];
      }
      this.historyIndex = this.history.length;
    });
  }

  /** 成功发送后写入历史（去重连续重复，截断至上限）并落盘 */
  private appendHistory(cmd: string): void {
    if (this.history.length > 0 && this.history[this.history.length - 1] === cmd) {
      this.historyIndex = this.history.length;
      return;
    }
    this.history.push(cmd);
    if (this.history.length > HISTORY_LIMIT) {
      this.history = this.history.slice(this.history.length - HISTORY_LIMIT);
    }
    this.historyIndex = this.history.length;
    Prefs.getInstance().putString(HISTORY_KEY, JSON.stringify(this.history)).catch(() => { return; });
  }

  /** 历史回填：dir=-1 上一条（更早），dir=+1 下一条（更新；到底恢复输入框原值） */
  private browseHistory(dir: number): void {
    if (this.history.length === 0) {
      return;
    }
    const next = this.historyIndex + dir;
    if (next < 0 || next > this.history.length) {
      return;
    }
    this.historyIndex = next;
    this.inputText = next === this.history.length ? '' : this.history[next];
  }

  // ===================== 命令执行 =====================

  /** 发送当前输入（viewOnly 拦截；仅已连接态可发） */
  private async sendCurrent(cmd: string): Promise<void> {
    const text = cmd.trim();
    if (text.length === 0 || this.sending) {
      return;
    }
    // P2-12c：Demo 分支——本地仿真输出直回（不建 WS/不发命令）
    if (AppStorage.get<boolean>('demoMode') === true) {
      this.sending = true;
      this.pushLine(`$ ${text}`, true, false);
      this.pushLine(DemoEngine.getInstance().mockShell(text), false, false);
      this.appendHistory(text);
      this.sending = false;
      return;
    }
    if (this.routeParams.viewOnly) {
      // 只读访客不允许执行 shell（比注入更高的权限面）
      this.getUIContext().getPromptAction().showToast({ message: '只读模式不可执行命令' });
      return;
    }
    if (!this.connOk) {
      this.getUIContext().getPromptAction().showToast({ message: '尚未连接设备' });
      return;
    }
    this.sending = true;
    this.pushLine(`$ ${text}`, true, false);
    const r: CmdResult = await this.client.sendCommand(text);
    this.sending = false;
    if (!r.ok) {
      this.pushLine(`✗ ${r.error}`, false, true);
      return;
    }
    const out = (r.stdout ?? '') + (r.stderr ?? '');
    this.appendHistory(text);
    if (out.trim().length === 0) {
      this.pushLine(`(exit ${r.exitCode}, 无输出)`, false, r.exitCode !== 0);
    } else {
      this.pushLine(out, false, r.exitCode !== 0);
    }
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#0A59F7')
          .onClick(() => { this.pathStack.pop(); })
        Blank()
        Text('终端')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
        Blank()
        Text('清屏')
          .fontSize(15)
          .fontColor('#0A59F7')
          .onClick(() => { this.clearOutput(); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      // 状态行：连接徽标 + 设备选择器（仅在线设备入列）
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(this.connOk ? '#007A00' : (this.connText === '连接失败' ? '#CC0000' : '#999999'))
        Text(this.connText)
          .fontSize(12)
          .fontColor('#666666')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ left: 6 })
          .layoutWeight(1)
        Select(this.toSelectOptions())
          .width(160)
          .height(32)
          .font({ size: 13 })
          .selected(Math.max(0, this.deviceOptions.indexOf(this.selectedId)))
          .enabled(this.deviceOptions.length > 0)
          .onSelect((index: number) => { this.onSelectDevice(index); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#FFFFFF')

      // 输出流（深底浅字；Scroll+Column 承载，pushLine 后自动滚到底）
      Scroll(this.scrollCtl) {
        Column({ space: 6 }) {
          ForEach(this.lines, (item: OutputLine) => {
            Text(item.text)
              .fontSize(12)
              .fontColor(item.isErr ? '#FF8A8A' : (item.isCmd ? '#7FE07F' : '#D8D8D8'))
              .width('100%')
              .backgroundColor('#1C1C1C')
              .padding(10)
              .borderRadius(6)
              .copyOption(CopyOptions.LocalDevice)
          }, (item: OutputLine, idx: number) => `${idx}_${item.isCmd}_${item.isErr}_${item.text.length}`)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
      }
      .layoutWeight(1)
      .width('100%')
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .backgroundColor('#121212')
      .scrollBar(BarState.Off)

      // 快捷指令（P2-12：三层加载的执行区 + 编辑模式；行内「编辑」切换）
      if (!this.editingShortcuts) {
        Scroll() {
          Row({ space: 8 }) {
            ForEach(ShortcutService.getInstance().items, (s: ShortcutItem) => {
              Button(s.name.length > 14 ? s.name.substring(0, 12) + '…' : s.name)
                .height(30)
                .fontSize(12)
                .backgroundColor('#EEF4FF')
                .fontColor('#0A59F7')
                .onClick(() => { this.sendCurrent(s.cmd); })
            }, (s: ShortcutItem) => `${s.name}_${s.cmd.length}`)
            Text('编辑')
              .fontSize(12)
              .fontColor('#0A59F7')
              .padding({ left: 6, right: 4 })
              .onClick(() => { this.editingShortcuts = true; })
          }
          .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
      } else {
        // 编辑模式：逐条删除 + 新增 + 恢复默认（每次操作即本地+云端同步）
        Column() {
          ForEach(ShortcutService.getInstance().items, (s: ShortcutItem) => {
            Row() {
              Text(s.name).fontSize(12).fontColor('#0A59F7').width(84)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(s.cmd).fontSize(11).fontColor('#666666').layoutWeight(1)
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('✕').fontSize(14).fontColor('#CC0000').padding({ left: 10 })
                .onClick(() => { ShortcutService.getInstance().remove(s.name); })
            }
            .width('100%')
            .padding({ top: 5, bottom: 5 })
          }, (s: ShortcutItem) => `e_${s.name}_${s.cmd.length}`)

          Row({ space: 6 }) {
            TextInput({ placeholder: '名称', text: this.newShortName })
              .layoutWeight(1).height(30).fontSize(12)
              .onChange((v: string) => { this.newShortName = v; })
            TextInput({ placeholder: '命令', text: this.newShortCmd })
              .layoutWeight(2).height(30).fontSize(12)
              .onChange((v: string) => { this.newShortCmd = v; })
            Button('添加').height(30).fontSize(12).onClick(() => { this.addShortcut(); })
          }
          .width('100%')
          .margin({ top: 6 })

          Row({ space: 8 }) {
            Text('恢复默认').fontSize(12).fontColor('#A34700')
              .onClick(() => { ShortcutService.getInstance().resetToDefaults(); })
            Blank()
            Text('完成').fontSize(13).fontColor('#0A59F7').fontWeight(FontWeight.Medium)
              .onClick(() => { this.editingShortcuts = false; })
          }
          .width('100%')
          .margin({ top: 6 })
        }
        .width('100%')
        .backgroundColor('#1C1C1C')
        .borderRadius(8)
        .padding({ left: 10, right: 10, top: 6, bottom: 8 })
        .margin({ left: 12, right: 12, top: 4, bottom: 4 })
      }

      // 输入行：历史回溯 + 输入 + 发送
      Row({ space: 8 }) {
        Button('↑')
          .width(38)
          .height(40)
          .onClick(() => { this.browseHistory(-1); })
        Button('↓')
          .width(38)
          .height(40)
          .onClick(() => { this.browseHistory(1); })
        TextInput({ placeholder: 'shell 命令…', text: this.inputText })
          .layoutWeight(1)
          .height(40)
          .onChange((v: string) => { this.inputText = v; })
          .onSubmit(() => { this.sendCurrent(this.inputText); })
        Button(this.sending ? '…' : '发送')
          .height(40)
          .fontSize(14)
          .onClick(() => { this.sendCurrent(this.inputText); })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 8, bottom: 16 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#121212')
  }
}
