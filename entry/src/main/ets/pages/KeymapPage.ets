/**
 * KeymapPage —— 键位映射编辑器（P1-8b，对应上游 KeymapEditor.vue 数据面）
 *
 * 职责（单一）：档案 CRUD（新建/改名/删除/切换）、5 类映射的表单化增改删、
 *   配置 JSON 导入导出（剪贴板）与 Prefs 落盘（cloudphone_keymap）。
 * 交互取舍（如实记录）：上游为画布拖拽编辑，本页采用**表单化编辑**（分数坐标直填）——
 *   数据面/应用面与上游完全一致（engine 消费同一 wire schema），拖拽交互列后续增强。
 * 消费方：rawfile/js/keymap.js（控制页启动经 ArkWebView 桥读取）。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import {
  KeymapConfig, KeymapMapping, KeymapPos, KeymapProfile,
  parseKeymapConfig, keymapConfigToJson, activeProfile, mappingSummary, defaultKeymapConfig
} from '../features/keymap/KeymapModel';
import { Prefs } from '../utils/Prefs';

/** Prefs 持久化键（对齐上游 localStorage cloudphone_keymap） */
const KEYMAP_PREFS_KEY: string = 'cloudphone_keymap';

@Component
export struct KeymapPage {
  @Consume('pathStack') pathStack: NavPathStack;

  /** 全量配置（任何变更整体重赋值触发渲染；序列化即 wire schema） */
  @State cfg: KeymapConfig = defaultKeymapConfig();
  /** 新建档案名输入 */
  @State newProfileName: string = '';

  // ---- 映射表单态（添加/编辑共用；editingId 非空=编辑模式） ----
  @State editingId: string = '';
  @State formType: string = 'tap';
  @State formKey: string = '';
  @State formCmd: string = '';
  @State formX: string = '0.5';
  @State formY: string = '0.5';
  @State formSx: string = '0.2';
  @State formSy: string = '0.8';
  @State formEx: string = '0.8';
  @State formEy: string = '0.2';
  @State formDuration: string = '150';
  @State formJoyU: string = 'i';
  @State formJoyD: string = 'k';
  @State formJoyL: string = 'j';
  @State formJoyR: string = 'l';
  @State formCx: string = '0.3';
  @State formCy: string = '0.7';
  @State formRadius: string = '0.1';
  @State formWheelAction: string = 'scroll';

  private prefs: Prefs = Prefs.getInstance();

  aboutToAppear(): void {
    this.loadConfig();
  }

  /** 读 Prefs → hydrate（首次进入或坏数据回落默认档） */
  private async loadConfig(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.prefs.init(ctx);
    const json = await this.prefs.getString(KEYMAP_PREFS_KEY, '');
    this.cfg = parseKeymapConfig(json);
  }

  /** 落盘（整体序列化；toast 后留在本页供连续编辑） */
  private async persist(): Promise<void> {
    await this.prefs.putString(KEYMAP_PREFS_KEY, keymapConfigToJson(this.cfg));
    this.getUIContext().getPromptAction().showToast({ message: '已保存（控制页下次连接生效）' });
  }

  private back(): void {
    this.pathStack.pop();
  }

  // ===================== 档案操作 =====================

  /** 重赋值触发渲染（cfg 为 @State 根，属性级变更需整体替换） */
  private commit(next: KeymapConfig): void {
    this.cfg = next;
  }

  private newProfile(): void {
    const name = this.newProfileName.trim();
    if (name.length === 0) {
      return;
    }
    const p = new KeymapProfile();
    p.id = 'p_' + Date.now();
    p.name = name;
    this.cfg.profiles.push(p);
    this.cfg.activeProfileId = p.id;
    this.newProfileName = '';
    this.commit(this.cfg);
  }

  private deleteProfile(): void {
    if (this.cfg.profiles.length <= 1) {
      this.getUIContext().getPromptAction().showToast({ message: '至少保留一个档案' });
      return;
    }
    this.cfg.profiles = this.cfg.profiles.filter((p: KeymapProfile) => p.id !== this.cfg.activeProfileId);
    this.cfg.activeProfileId = this.cfg.profiles[0].id;
    this.commit(this.cfg);
    this.resetForm();
  }

  private selectProfile(index: number): void {
    const p = this.cfg.profiles[index];
    if (p !== undefined) {
      this.cfg.activeProfileId = p.id;
      this.commit(this.cfg);
      this.resetForm();
    }
  }

  /** 档案选择器数据源（本 SDK Select 构造签名为 SelectOption[]） */
  private profileOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const p of this.cfg.profiles) {
      const so: SelectOption = { value: p.name };
      arr.push(so);
    }
    return arr;
  }

  /** 映射类型顺序（Select 数据源与索引换算共用） */
  private typeList(): string[] {
    return ['tap', 'swipe', 'joystick', 'wheel', 'command'];
  }

  /** 类型选择器数据源（本 SDK Select 构造签名为 SelectOption[]） */
  private typeOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const t of this.typeList()) {
      const so: SelectOption = { value: t };
      arr.push(so);
    }
    return arr;
  }

  // ===================== 映射表单 =====================

  /** 分数/数值解析（非法回退默认，与设置页同约定） */
  private fx(s: string, def: number): number {
    const v = parseFloat(s);
    return isNaN(v) ? def : v;
  }

  private resetForm(): void {
    this.editingId = '';
    this.formType = 'tap';
    this.formKey = '';
    this.formCmd = '';
    this.formX = '0.5';
    this.formY = '0.5';
    this.formSx = '0.2';
    this.formSy = '0.8';
    this.formEx = '0.8';
    this.formEy = '0.2';
    this.formDuration = '150';
    this.formJoyU = 'i';
    this.formJoyD = 'k';
    this.formJoyL = 'j';
    this.formJoyR = 'l';
    this.formCx = '0.3';
    this.formCy = '0.7';
    this.formRadius = '0.1';
    this.formWheelAction = 'scroll';
  }

  /** 表单 → 映射（必填校验：tap/swipe/command 需 key；joystick 至少一键；command 需 cmd） */
  private buildMapping(): KeymapMapping | null {
    const m = new KeymapMapping();
    m.id = this.editingId.length > 0 ? this.editingId : ('m_' + Date.now());
    m.type = this.formType;
    if (this.formType === 'tap') {
      if (this.formKey.trim().length === 0) { return null; }
      m.key = this.formKey.trim().toLowerCase();
      m.pos = this.mkPos(this.formX, this.formY, 0.5, 0.5);
    } else if (this.formType === 'swipe') {
      if (this.formKey.trim().length === 0) { return null; }
      m.key = this.formKey.trim().toLowerCase();
      m.startPos = this.mkPos(this.formSx, this.formSy, 0.2, 0.8);
      m.endPos = this.mkPos(this.formEx, this.formEy, 0.8, 0.2);
      m.duration = Math.max(50, Math.min(2000, this.fx(this.formDuration, 150)));
    } else if (this.formType === 'joystick') {
      m.keys.up = this.formJoyU.trim().toLowerCase();
      m.keys.down = this.formJoyD.trim().toLowerCase();
      m.keys.left = this.formJoyL.trim().toLowerCase();
      m.keys.right = this.formJoyR.trim().toLowerCase();
      if (m.keys.up.length === 0 && m.keys.down.length === 0 && m.keys.left.length === 0 && m.keys.right.length === 0) {
        return null;
      }
      m.center = this.mkPos(this.formCx, this.formCy, 0.3, 0.7);
      m.radius = Math.max(0.05, Math.min(0.3, this.fx(this.formRadius, 0.1)));
    } else if (this.formType === 'wheel') {
      m.action = this.formWheelAction;
      m.pos = this.mkPos(this.formX, this.formY, 0.5, 0.5);
    } else if (this.formType === 'command') {
      if (this.formKey.trim().length === 0 || this.formCmd.trim().length === 0) { return null; }
      m.key = this.formKey.trim().toLowerCase();
      m.cmd = this.formCmd.trim();
    }
    return m;
  }

  private mkPos(xs: string, ys: string, dx: number, dy: number): KeymapPos {
    const p = new KeymapPos();
    p.x = Math.max(0, Math.min(1, this.fx(xs, dx)));
    p.y = Math.max(0, Math.min(1, this.fx(ys, dy)));
    return p;
  }

  /** 添加或更新（编辑模式按 id 替换） */
  private submitMapping(): void {
    const profile = activeProfile(this.cfg);
    if (profile === null) {
      return;
    }
    const m = this.buildMapping();
    if (m === null) {
      this.getUIContext().getPromptAction().showToast({ message: '必填项缺失（键/命令/方向键）' });
      return;
    }
    if (this.editingId.length > 0) {
      profile.mappings = profile.mappings.map((old: KeymapMapping) => (old.id === m.id ? m : old));
    } else {
      profile.mappings.push(m);
    }
    this.commit(this.cfg);
    this.resetForm();
  }

  /** 行点击 → 载入表单编辑 */
  private startEdit(m: KeymapMapping): void {
    this.editingId = m.id;
    this.formType = m.type;
    this.formKey = m.key;
    this.formCmd = m.cmd;
    this.formX = String(m.pos.x);
    this.formY = String(m.pos.y);
    this.formSx = String(m.startPos.x);
    this.formSy = String(m.startPos.y);
    this.formEx = String(m.endPos.x);
    this.formEy = String(m.endPos.y);
    this.formDuration = String(m.duration);
    this.formJoyU = m.keys.up;
    this.formJoyD = m.keys.down;
    this.formJoyL = m.keys.left;
    this.formJoyR = m.keys.right;
    this.formCx = String(m.center.x);
    this.formCy = String(m.center.y);
    this.formRadius = String(m.radius);
    this.formWheelAction = m.action;
  }

  private deleteMapping(id: string): void {
    const profile = activeProfile(this.cfg);
    if (profile !== null) {
      profile.mappings = profile.mappings.filter((m: KeymapMapping) => m.id !== id);
      this.commit(this.cfg);
      if (this.editingId === id) {
        this.resetForm();
      }
    }
  }

  // ===================== 导入导出（剪贴板 JSON） =====================

  /** 导出：config JSON → 系统剪贴板 */
  private async exportJson(): Promise<void> {
    const text = keymapConfigToJson(this.cfg);
    const pd = pasteboard.createData('text/plain', text);
    await pasteboard.getSystemPasteboard().setData(pd);
    this.getUIContext().getPromptAction().showToast({ message: `已复制 ${text.length} 字符` });
  }

  /** 导入：系统剪贴板 → 解析替换（坏 JSON 提示并保持原状） */
  private async importJson(): Promise<void> {
    try {
      const pd = await pasteboard.getSystemPasteboard().getData();
      const text = pd.getPrimaryText();
      if (!text || text.length === 0) {
        this.getUIContext().getPromptAction().showToast({ message: '剪贴板为空' });
        return;
      }
      const next = parseKeymapConfig(text);
      const broken = next.profiles.length === 1 && next.profiles[0].id === 'default' && text.indexOf('profiles') < 0;
      if (broken) {
        this.getUIContext().getPromptAction().showToast({ message: 'JSON 无法解析' });
        return;
      }
      this.cfg = next;
      this.resetForm();
      this.getUIContext().getPromptAction().showToast({ message: '已导入，记得保存' });
    } catch (e) {
      this.getUIContext().getPromptAction().showToast({ message: '读取剪贴板失败' });
    }
  }

  // ===================== 视图 =====================

  /** 数值输入行（label+input，onChange 直绑页面态字符串） */
  @Builder
  NumRow(label: string, value: string, onChange: (v: string) => void) {
    Row() {
      Text(label).fontSize(14).width(84).fontColor('#666666')
      TextInput({ text: value })
        .layoutWeight(1)
        .height(34)
        .fontSize(13)
        .onChange(onChange)
    }
    .width('100%')
    .margin({ top: 6 })
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text('键位映射').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text('保存').fontSize(15).fontColor('#0A59F7').onClick(() => { this.persist(); })
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      Scroll() {
        Column() {
          // ---- 档案区 ----
          Column() {
            Row() {
              Text('档案').fontSize(15).fontWeight(FontWeight.Medium)
              Blank()
              Select(this.profileOptions())
                .width(160)
                .height(32)
                .font({ size: 13 })
                .selected(Math.max(0, this.cfg.profiles.findIndex(
                  (p: KeymapProfile): boolean => p.id === this.cfg.activeProfileId)))
                .onSelect((index: number) => { this.selectProfile(index); })
            }
            .width('100%')

            Row() {
              TextInput({ placeholder: '新档案名', text: this.newProfileName })
                .layoutWeight(1)
                .height(34)
                .onChange((v: string) => { this.newProfileName = v; })
              Button('新建').height(34).fontSize(13).margin({ left: 8 }).onClick(() => { this.newProfile(); })
              Button('删除').height(34).fontSize(13).backgroundColor('#FDEEEE').fontColor('#CC0000')
                .margin({ left: 6 }).onClick(() => { this.deleteProfile(); })
            }
            .width('100%')
            .margin({ top: 8 })

            Text('档案名（直接改字即改名，保存生效）').fontSize(11).fontColor('#999999').margin({ top: 8 })
            TextInput({ text: (activeProfile(this.cfg)?.name) ?? '' })
              .width('100%')
              .height(34)
              .onChange((v: string) => {
                const p = activeProfile(this.cfg);
                if (p !== null && v.trim().length > 0) {
                  p.name = v;
                  this.commit(this.cfg);
                }
              })
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)

          // ---- 映射表单（添加/编辑） ----
          Column() {
            Text(this.editingId.length > 0 ? '编辑映射' : '添加映射')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)

            Row({ space: 8 }) {
              Select(this.typeOptions())
                .width(130)
                .height(32)
                .font({ size: 13 })
                .selected(Math.max(0, this.typeList().indexOf(this.formType)))
                .onSelect((i: number) => {
                  const arr = this.typeList();
                  if (arr[i] !== undefined) {
                    this.formType = arr[i];
                  }
                })
              Text('类型').fontSize(13).fontColor('#999999')
            }
            .width('100%')
            .margin({ top: 8 })

            if (this.formType === 'tap' || this.formType === 'swipe' || this.formType === 'command') {
              this.NumRow('触发键', this.formKey, (v: string) => { this.formKey = v; })
            }
            if (this.formType === 'command') {
              this.NumRow('命令', this.formCmd, (v: string) => { this.formCmd = v; })
            }
            if (this.formType === 'tap') {
              this.NumRow('x (0~1)', this.formX, (v: string) => { this.formX = v; })
              this.NumRow('y (0~1)', this.formY, (v: string) => { this.formY = v; })
            }
            if (this.formType === 'swipe') {
              this.NumRow('起点x', this.formSx, (v: string) => { this.formSx = v; })
              this.NumRow('起点y', this.formSy, (v: string) => { this.formSy = v; })
              this.NumRow('终点x', this.formEx, (v: string) => { this.formEx = v; })
              this.NumRow('终点y', this.formEy, (v: string) => { this.formEy = v; })
              this.NumRow('时长ms', this.formDuration, (v: string) => { this.formDuration = v; })
            }
            if (this.formType === 'joystick') {
              this.NumRow('上键', this.formJoyU, (v: string) => { this.formJoyU = v; })
              this.NumRow('下键', this.formJoyD, (v: string) => { this.formJoyD = v; })
              this.NumRow('左键', this.formJoyL, (v: string) => { this.formJoyL = v; })
              this.NumRow('右键', this.formJoyR, (v: string) => { this.formJoyR = v; })
              this.NumRow('中心x', this.formCx, (v: string) => { this.formCx = v; })
              this.NumRow('中心y', this.formCy, (v: string) => { this.formCy = v; })
              this.NumRow('半径', this.formRadius, (v: string) => { this.formRadius = v; })
            }
            if (this.formType === 'wheel') {
              this.NumRow('动作', this.formWheelAction, (v: string) => {
                this.formWheelAction = (v === 'zoom') ? 'zoom' : 'scroll';
              })
              this.NumRow('x (0~1)', this.formX, (v: string) => { this.formX = v; })
              this.NumRow('y (0~1)', this.formY, (v: string) => { this.formY = v; })
            }

            Row({ space: 8 }) {
              Button(this.editingId.length > 0 ? '更新' : '添加')
                .layoutWeight(1)
                .height(38)
                .onClick(() => { this.submitMapping(); })
              if (this.editingId.length > 0) {
                Button('取消')
                  .layoutWeight(1)
                  .height(38)
                  .backgroundColor('#F0F0F0')
                  .fontColor('#666666')
                  .onClick(() => { this.resetForm(); })
              }
            }
            .width('100%')
            .margin({ top: 12 })
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
          .margin({ top: 12 })

          // ---- 已有映射列表 ----
          Column() {
            Text(`映射列表（${(activeProfile(this.cfg)?.name) ?? '-'} · ${activeProfile(this.cfg)?.mappings.length ?? 0} 条）`)
              .fontSize(15)
              .fontWeight(FontWeight.Medium)

            ForEach((activeProfile(this.cfg)?.mappings) ?? [], (m: KeymapMapping) => {
              Row() {
                Text(mappingSummary(m))
                  .fontSize(13)
                  .layoutWeight(1)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .onClick(() => { this.startEdit(m); })
                Text('✕')
                  .fontSize(16)
                  .fontColor('#CC0000')
                  .padding({ left: 12, right: 4 })
                  .onClick(() => { this.deleteMapping(m.id); })
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .onClick(() => { this.startEdit(m); })
            }, (m: KeymapMapping) => `${m.id}_${m.type}_${m.key}`)

            if ((activeProfile(this.cfg)?.mappings.length ?? 0) === 0) {
              Text('暂无映射——用上方表单添加（控制页下次连接生效）')
                .fontSize(12)
                .fontColor('#999999')
                .margin({ top: 10 })
            }
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
          .margin({ top: 12 })

          // ---- 导入导出 ----
          Row({ space: 10 }) {
            Button('导出到剪贴板')
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .backgroundColor('#EEF4FF')
              .fontColor('#0A59F7')
              .onClick(() => { this.exportJson(); })
            Button('从剪贴板导入')
              .layoutWeight(1)
              .height(40)
              .fontSize(13)
              .backgroundColor('#EEF4FF')
              .fontColor('#0A59F7')
              .onClick(() => { this.importJson(); })
          }
          .width('100%')
          .margin({ top: 12, bottom: 24 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .edgeEffect(EdgeEffect.Spring)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
