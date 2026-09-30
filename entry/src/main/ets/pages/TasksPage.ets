/**
 * TasksPage —— 群控批量任务页（P2-5a，对应上游 DeviceConsole 批量任务区 + 任务看板）
 *
 * 职责（单一）：目标选择（群组/全部在线）、shell 命令下发、单任务看板
 *   （running/success/failed 计数、逐设备状态与输出、2s 轮询 + 广播双通道刷新）。
 * 数据：features/tasks/TaskService（契约对齐 DeviceConsole POST /api/tasks + devices.js 追踪）。
 * 目标默认取 P1-10 群控勾选（GroupControl.selectedIds）；admin-only 由服务端收口、错误透出。
 * 入口：DeviceList 群控工具栏「任务」。
 */
import { TaskService, TaskDeviceState } from '../features/tasks/TaskService';
import { GroupControl } from '../features/groupcontrol/GroupControl';
import { DeviceService } from '../features/device/DeviceService';
import { RouteParams } from '../model/Model';
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';

/** 目标模式：group=群控勾选 / online=全部在线 */
const TARGET_GROUP: string = 'group';
const TARGET_ONLINE: string = 'online';
/** 文件整读内存上限（选择器读入后驻留内存——移动端防 OOM；流式列后续） */
const FILE_SIZE_CAP: number = 200 * 1024 * 1024;

/** 看板展示行（服务状态 → 视图数据的预计算，避免闭包内语句） */
class TaskRowData {
  id: string = '';
  statusText: string = '';
  statusColor: string = '';
  output: string = '';
}

@Component
export struct TasksPage {
  @Consume('pathStack') navPathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;
  /** 任务状态（TaskService.notify 写入）→ 看板刷新 */
  @StorageLink('taskState') @Watch('onTaskTick') taskTick: number = 0;

  private service: TaskService = TaskService.getInstance();

  @State targetMode: string = TARGET_GROUP;
  @State command: string = '';
  @State sending: boolean = false;
  @State onlineIds: string[] = [];
  // ---- P2-5b：文件任务 ----
  @State pickedName: string = '';
  @State pickedSize: number = 0;
  @State taskType: string = 'push_file'; // install（.apk）| push_file
  @State destPath: string = '';
  @State fileBusy: boolean = false;
  /** 已选文件字节（整读驻留；非 UI 态不入 @State） */
  private fileBytes: Uint8Array = new Uint8Array(0);

  aboutToAppear(): void {
    this.loadOnline();
  }

  /** 全部在线目标源 */
  private async loadOnline(): Promise<void> {
    const result = await DeviceService.getInstance().fetchDevices();
    const ids: string[] = [];
    for (const d of result.devices) {
      if (d.online) {
        ids.push(d.device_id);
      }
    }
    this.onlineIds = ids;
  }

  /** @Watch：状态在服务单例，@StorageLink 触发渲染 */
  private onTaskTick(): void {
    // 无显式动作
  }

  private back(): void {
    this.navPathStack.pop();
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 当前目标清单 */
  private targets(): string[] {
    if (this.targetMode === TARGET_ONLINE) {
      return this.onlineIds;
    }
    return GroupControl.getInstance().selectedIds();
  }

  /**
   * P2-5b：选择文件（系统文档选择器 → 整读入内存 → 类型自动）。
   * 上限 200MB（读入内存防移动端 OOM；流式上传列后续）。
   */
  private async pickFile(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const vp = new picker.DocumentViewPicker(ctx);
    const uris = await vp.select({ maxSelectNumber: 1 });
    if (uris === undefined || uris.length === 0) {
      return;
    }
    try {
      // 大小经 statSync（File 句柄只有 fd/path，无 length）；超限在打开前拒绝
      const st = fileIo.statSync(uris[0]);
      if (st.size > FILE_SIZE_CAP) {
        this.toast(`文件超过 200MB 上限（当前 ${(st.size / 1048576).toFixed(0)}MB）`);
        return;
      }
      const file = fileIo.openSync(uris[0], fileIo.OpenMode.READ_ONLY);
      const bytes = new Uint8Array(st.size);
      fileIo.readSync(file.fd, bytes.buffer); // 返回读入字节数，数据进 buffer
      fileIo.closeSync(file);
      this.fileBytes = bytes;
      const seg = uris[0].split('/').pop() || 'file.bin';
      this.pickedName = decodeURIComponent(seg);
      this.pickedSize = st.size;
      this.taskType = /\.apk$/i.test(this.pickedName) ? 'install' : 'push_file';
      if (this.taskType === 'push_file' && this.destPath.length === 0) {
        this.destPath = `/sdcard/Download/${this.pickedName}`;
      }
    } catch (e) {
      this.toast('读取文件失败');
    }
  }

  /**
   * P2-5b 下发文件任务：上传（/upload 原始体）→ 签名 URL → createTask。
   * 类型：.apk → install；其余 push_file（dest_path 必填）。
   */
  private async submitFileTask(): Promise<void> {
    const targets = this.targets();
    if (targets.length === 0) {
      this.toast('目标为空——请先勾选群组或切到全部在线');
      return;
    }
    if (this.pickedName.length === 0 || this.fileBytes.length === 0) {
      this.toast('请先选择文件');
      return;
    }
    if (this.taskType === 'push_file' && this.destPath.trim().length === 0) {
      this.toast('请输入手机目标绝对路径');
      return;
    }
    if (this.fileBusy) {
      return;
    }
    this.fileBusy = true;
    const upErr = await this.service.uploadFile(this.pickedName, this.fileBytes);
    if (upErr.length > 0) {
      this.fileBusy = false;
      this.toast(`上传失败：${upErr}`);
      return;
    }
    const url = await this.service.signedFileUrl(this.pickedName);
    if (url.length === 0) {
      this.fileBusy = false;
      this.toast('获取签名地址失败');
      return;
    }
    const err = await this.service.createTask(
      this.taskType, targets, url,
      this.taskType === 'push_file' ? this.destPath.trim() : '');
    this.fileBusy = false;
    if (err.length === 0) {
      this.toast(`文件任务已下发 ${targets.length} 台`);
      this.pickedName = '';
      this.pickedSize = 0;
      this.fileBytes = new Uint8Array(0);
      this.destPath = '';
    } else {
      this.toast(`下发失败：${err}`);
    }
  }

  /** 下发 shell 批量任务 */
  private async submit(): Promise<void> {
    const cmd = this.command.trim();
    if (cmd.length === 0) {
      this.toast('请输入命令');
      return;
    }
    const targets = this.targets();
    if (targets.length === 0) {
      this.toast('目标为空——请在列表勾选群组或切到全部在线');
      return;
    }
    if (this.sending) {
      return;
    }
    this.sending = true;
    const err = await this.service.createTask('shell', targets, cmd);
    this.sending = false;
    if (err.length === 0) {
      this.toast(`已下发 ${targets.length} 台`);
      this.command = '';
    } else {
      this.toast(`下发失败：${err}`);
    }
  }

  /** 状态 → 状态条文案/配色 */
  private statusLabel(s: TaskDeviceState): string {
    if (s.status === 'success') {
      return '成功';
    }
    if (s.status === 'failed') {
      return '失败';
    }
    if (s.status === 'running') {
      return '执行中';
    }
    return s.status.length > 0 ? s.status : '—';
  }

  private statusColor(s: TaskDeviceState): string {
    if (s.status === 'success') {
      return '#007A00';
    }
    if (s.status === 'failed') {
      return '#CC0000';
    }
    return '#A34700';
  }

  /** 看板 → 展示行数组（纯函数预计算——ForEach 闭包只读属性） */
  private boardRows(): TaskRowData[] {
    const rows: TaskRowData[] = [];
    for (const id of this.service.board.deviceIds()) {
      const st = this.service.board.devices.get(id) ?? new TaskDeviceState();
      const row = new TaskRowData();
      row.id = id;
      row.statusText = this.statusLabel(st);
      row.statusColor = this.statusColor(st);
      row.output = st.output;
      rows.push(row);
    }
    return rows;
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text('群控任务').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      Scroll() {
        Column() {
          // ---- 下发区 ----
          Column() {
            Text('批量 Shell').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
            Row({ space: 8 }) {
              Text(this.targetMode === TARGET_GROUP ? '● 群控勾选' : '群控勾选')
                .fontSize(12)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(14)
                .backgroundColor(this.targetMode === TARGET_GROUP ? '#0A59F7' : '#EEEEEE')
                .fontColor(this.targetMode === TARGET_GROUP ? '#FFFFFF' : '#666666')
                .onClick(() => { this.targetMode = TARGET_GROUP; })
              Text(this.targetMode === TARGET_ONLINE ? '● 全部在线' : '全部在线')
                .fontSize(12)
                .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                .borderRadius(14)
                .backgroundColor(this.targetMode === TARGET_ONLINE ? '#0A59F7' : '#EEEEEE')
                .fontColor(this.targetMode === TARGET_ONLINE ? '#FFFFFF' : '#666666')
                .onClick(() => { this.targetMode = TARGET_ONLINE; })
              Text(`目标 ${this.targets().length} 台`)
                .fontSize(12)
                .fontColor('#999999')
            }
            .width('100%')
            .margin({ top: 8 })
            .justifyContent(FlexAlign.Start)

            TextInput({ placeholder: 'shell 命令（如 input keyevent 3）', text: this.command })
              .width('100%')
              .height(36)
              .fontSize(13)
              .margin({ top: 8 })
              .onChange((v: string) => { this.command = v; })
            Button(this.sending ? '下发中…' : '下发任务')
              .width('100%')
              .height(38)
              .fontSize(13)
              .margin({ top: 8 })
              .enabled(!this.sending)
              .onClick(() => { this.submit(); })
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)

          // ---- P2-5b：批量文件任务（/upload → 签名 URL → createTask） ----
          Column() {
            Text('批量文件任务（APK 安装 / 推送）')
              .fontSize(15)
              .fontWeight(FontWeight.Medium)
              .width('100%')

            Row({ space: 8 }) {
              Button('选择文件').fontSize(13).height(34)
                .onClick(() => { this.pickFile(); })
              Text(this.pickedName.length > 0 ?
                `${this.pickedName} · ${(this.pickedSize / 1048576).toFixed(1)}MB` : '未选择文件')
                .fontSize(12)
                .fontColor(this.pickedName.length > 0 ? '#333333' : '#999999')
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              if (this.pickedName.length > 0) {
                Text(this.taskType === 'install' ? '安装' : '推送')
                  .fontSize(11)
                  .fontColor('#0A59F7')
                  .backgroundColor('#EEF4FF')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .borderRadius(10)
              }
            }
            .width('100%')
            .margin({ top: 8 })

            if (this.taskType === 'push_file' && this.pickedName.length > 0) {
              TextInput({ placeholder: '手机目标绝对路径', text: this.destPath })
                .width('100%')
                .height(34)
                .fontSize(13)
                .margin({ top: 8 })
                .onChange((v: string) => { this.destPath = v; })
            }

            Button(this.fileBusy ? '上传下发中…' : '下发文件任务')
              .width('100%')
              .height(38)
              .fontSize(13)
              .margin({ top: 8 })
              .enabled(!this.fileBusy && this.pickedName.length > 0)
              .onClick(() => { this.submitFileTask(); })
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
          .margin({ top: 12 })

          // ---- 看板 ----
          Column() {
            Row() {
              Text(this.service.board.taskId.length > 0 ? `任务 ${this.service.board.taskId.slice(-10)}` :
                '任务看板')
                .fontSize(15)
                .fontWeight(FontWeight.Medium)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text('刷新').fontSize(13).fontColor('#0A59F7')
                .onClick(() => { this.service.manualRefresh(); })
            }
            .width('100%')

            if (this.service.board.taskId.length > 0) {
              Row({ space: 12 }) {
                Text(`执行中 ${this.service.board.counts()[0]}`).fontSize(12).fontColor('#A34700')
                Text(`成功 ${this.service.board.counts()[1]}`).fontSize(12).fontColor('#007A00')
                Text(`失败 ${this.service.board.counts()[2]}`).fontSize(12).fontColor('#CC0000')
                Text('2s 自动刷新').fontSize(10).fontColor('#BBBBBB')
              }
              .width('100%')
              .margin({ top: 6 })
              .justifyContent(FlexAlign.Start)
            }

            if (this.service.board.deviceIds().length === 0) {
              Text('尚无任务——上方选择目标并下发命令')
                .fontSize(12)
                .fontColor('#999999')
                .margin({ top: 8 })
            }

            ForEach(this.boardRows(), (r: TaskRowData) => {
              Column() {
                Row() {
                  Text(r.id)
                    .fontSize(12)
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(r.statusText)
                    .fontSize(11)
                    .fontColor(r.statusColor)
                    .fontWeight(FontWeight.Medium)
                    .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                    .backgroundColor('#F5F5F5')
                    .borderRadius(10)
                }
                .width('100%')

                if (r.output.length > 0) {
                  Text(r.output)
                    .fontSize(10)
                    .fontColor('#666666')
                    .width('100%')
                    .maxLines(4)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 4 })
                    .copyOption(CopyOptions.LocalDevice)
                }
              }
              .width('100%')
              .backgroundColor('#FAFAFA')
              .borderRadius(8)
              .padding(10)
              .margin({ top: 6 })
            }, (r: TaskRowData) => `${r.id}_${r.statusText}_${r.output.length}`)
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
          .margin({ top: 12, bottom: 24 })
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
