/**
 * TagsPage —— 设备标签管理页（P2-10，对应上游 Keymap/Tag 弹窗功能的数据面）
 *
 * 职责（单一）：标签 CRUD（建/改/删，name 唯一 + 8 色板）与设备打标（按标签勾选）。
 * 状态模式：全部状态在 TagService 单例（每操作即本地持久化 + POST /api/tags 云同步），
 *   本页仅表单态 + @StorageLink('tagsState') 观察刷新。
 * 权限：服务端 requireAdmin 收口——非管理员在 create/update/delete 的 403 上 toast 提示。
 * 入口：DeviceList 顶栏「标签」/筛选条「管理」。
 */
import { TagService, TagItem } from '../features/tags/TagService';
import { DeviceService } from '../features/device/DeviceService';
import { RouteParams } from '../model/Model';

/** 上游 DEFAULT_TAG_COLORS 同款 8 色（改色选择器数据源） */
const TAG_COLORS: string[] = [
  '#38bdf8', '#22c55e', '#f59e0b', '#ef4444',
  '#a78bfa', '#14b8a6', '#f97316', '#e879f9'
];

@Component
export struct TagsPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;
  /** 标签/打标变更 → 本页列表刷新（TagService.notify 写入） */
  @StorageLink('tagsState') @Watch('onTagsChanged') tagsTick: number = 0;

  private service: TagService = TagService.getInstance();

  // ---- 新建表单 ----
  @State newName: string = '';
  @State newColor: string = TAG_COLORS[0];
  // ---- 编辑表单（editingId 非空=编辑模式） ----
  @State editingId: string = '';
  @State editName: string = '';
  @State editColor: string = TAG_COLORS[0];
  // ---- 设备打标 ----
  @State deviceIds: string[] = [];
  @State assignDeviceId: string = '';

  aboutToAppear(): void {
    this.service.load(); // 本地优先 + 云端合并（幂等）
    this.loadDevices();
  }

  /** 打标区设备源（复用 DeviceService 拉取一次） */
  private async loadDevices(): Promise<void> {
    const result = await DeviceService.getInstance().fetchDevices();
    const ids: string[] = [];
    for (const d of result.devices) {
      if (d.online) {
        ids.push(d.device_id);
      }
    }
    this.deviceIds = ids;
    if (this.assignDeviceId.length === 0 && ids.length > 0) {
      this.assignDeviceId = ids[0];
    }
  }

  /** @Watch：状态在服务单例，@StorageLink 触发渲染即可 */
  private onTagsChanged(): void {
    // 无显式动作
  }

  private back(): void {
    this.pathStack.pop();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  // ---- 操作（结果三态：成功/业务拒绝/服务端 403） ----

  private async createTag(): Promise<void> {
    const name = this.newName.trim();
    if (name.length === 0) {
      this.toast('请输入标签名');
      return;
    }
    if (this.service.tagNameExists(name)) {
      this.toast('标签名已存在');
      return;
    }
    const ok = await this.service.createTag(name, this.newColor);
    if (ok) {
      this.newName = '';
      this.toast('已创建并同步');
    } else {
      this.toast('创建失败（服务端拒绝或需管理员）');
    }
  }

  private startEdit(t: TagItem): void {
    this.editingId = t.id;
    this.editName = t.name;
    this.editColor = t.color;
  }

  private async submitEdit(): Promise<void> {
    const ok = await this.service.updateTag(this.editingId, this.editName, this.editColor);
    if (ok) {
      this.editingId = '';
      this.toast('已更新');
    } else {
      this.toast('更新失败（重名/空名/需管理员）');
    }
  }

  private async removeTag(t: TagItem): Promise<void> {
    await this.service.deleteTag(t.id);
    if (this.editingId === t.id) {
      this.editingId = '';
    }
    this.toast('已删除（设备打标同步清理）');
  }

  private async toggleAssign(tagId: string): Promise<void> {
    if (this.assignDeviceId.length === 0) {
      this.toast('请先选择设备');
      return;
    }
    await this.service.toggleDeviceTag(this.assignDeviceId, tagId);
  }

  private isAssigned(tagId: string): boolean {
    if (this.assignDeviceId.length === 0) {
      return false;
    }
    return this.service.getTagsForDevice(this.assignDeviceId)
      .some((t: TagItem): boolean => t.id === tagId);
  }

  build() {
    Column() {
      // 顶栏
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text('标签管理').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      Scroll() {
        Column() {
          // ---- 新建标签 ----
          Column() {
            Text('新建标签').fontSize(15).fontWeight(FontWeight.Medium)
            Row({ space: 8 }) {
              TextInput({ placeholder: '标签名（唯一）', text: this.newName })
                .layoutWeight(1)
                .height(36)
                .onChange((v: string) => { this.newName = v; })
              Button('新建').height(36).fontSize(13).onClick(() => { this.createTag(); })
            }
            .width('100%')
            .margin({ top: 8 })
            // 8 色板（点选当前新标签色）
            Row({ space: 8 }) {
              ForEach(TAG_COLORS, (c: string) => {
                Circle({ width: 26, height: 26 })
                  .fill(c)
                  .stroke(this.newColor === c ? '#333333' : '#FFFFFF')
                  .strokeWidth(this.newColor === c ? 3 : 1)
                  .onClick(() => { this.newColor = c; })
              }, (c: string) => `${c}_${this.newColor === c}`)
            }
            .margin({ top: 10 })
            .width('100%')
            .justifyContent(FlexAlign.Start)
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)

          // ---- 标签列表（改/删） ----
          Column() {
            Text(`标签列表（${this.service.tags.length}）`).fontSize(15).fontWeight(FontWeight.Medium)
            if (this.service.tags.length === 0) {
              Text('暂无标签（需管理员账号创建；本地可先建，联网后同步）')
                .fontSize(12).fontColor('#999999').margin({ top: 8 })
            }
            ForEach(this.service.tags, (t: TagItem) => {
              Row() {
                Circle({ width: 14, height: 14 }).fill(t.color).margin({ right: 8 })
                Text(t.name).fontSize(14).layoutWeight(1).maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text('改').fontSize(13).fontColor('#0A59F7').padding({ right: 14 })
                  .onClick(() => { this.startEdit(t); })
                Text('删').fontSize(13).fontColor('#CC0000')
                  .onClick(() => { this.removeTag(t); })
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
            }, (t: TagItem) => `${t.id}_${t.name}_${t.color}`)

            // 编辑表单（仅编辑态出现）
            if (this.editingId.length > 0) {
              Divider().margin({ top: 6, bottom: 6 })
              Text('编辑中').fontSize(12).fontColor('#0A59F7')
              Row({ space: 8 }) {
                TextInput({ text: this.editName })
                  .layoutWeight(1)
                  .height(36)
                  .onChange((v: string) => { this.editName = v; })
                Button('更新').height(36).fontSize(13).onClick(() => { this.submitEdit(); })
                Button('取消').height(36).fontSize(13).backgroundColor('#F0F0F0').fontColor('#666666')
                  .onClick(() => { this.editingId = ''; })
              }
              .width('100%')
              .margin({ top: 6 })
              Row({ space: 8 }) {
                ForEach(TAG_COLORS, (c: string) => {
                  Circle({ width: 24, height: 24 })
                    .fill(c)
                    .stroke(this.editColor === c ? '#333333' : '#FFFFFF')
                    .strokeWidth(this.editColor === c ? 3 : 1)
                    .onClick(() => { this.editColor = c; })
                }, (c: string) => `e_${c}_${this.editColor === c}`)
              }
              .margin({ top: 8 })
              .width('100%')
              .justifyContent(FlexAlign.Start)
            }
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
          .margin({ top: 12 })

          // ---- 设备打标 ----
          Column() {
            Text('设备打标').fontSize(15).fontWeight(FontWeight.Medium)
            Select(this.deviceOptions())
              .width('100%')
              .height(36)
              .font({ size: 13 })
              .selected(Math.max(0, this.deviceIds.indexOf(this.assignDeviceId)))
              .onSelect((i: number) => {
                const id = this.deviceIds[i];
                if (id !== undefined) {
                  this.assignDeviceId = id;
                }
              })
            if (this.deviceIds.length === 0) {
              Text('暂无在线设备').fontSize(12).fontColor('#999999').margin({ top: 8 })
            }
            if (this.service.tags.length > 0 && this.assignDeviceId.length > 0) {
              Row({ space: 8 }) {
                ForEach(this.service.tags, (t: TagItem) => {
                  Text(t.name)
                    .fontSize(13)
                    .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                    .borderRadius(14)
                    .backgroundColor(this.isAssigned(t.id) ? t.color : `${t.color}33`)
                    .fontColor(this.isAssigned(t.id) ? '#FFFFFF' : '#333333')
                    .onClick(() => { this.toggleAssign(t.id); })
                }, (t: TagItem) => `a_${t.id}_${this.isAssigned(t.id)}`)
              }
              .width('100%')
              .margin({ top: 10 })
            }
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
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

  /** 打标区选择器数据源（SelectOption[] 签名） */
  private deviceOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const id of this.deviceIds) {
      const so: SelectOption = { value: id };
      arr.push(so);
    }
    return arr;
  }
}
