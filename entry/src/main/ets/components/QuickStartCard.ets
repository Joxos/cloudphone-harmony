/**
 * QuickStartCard —— 快速接入空态引导卡（P2-11，对应上游 quickstart 区 UI）
 *
 * 职责（单一，展示组件）：部署方式切换（ADB 一键 / Magisk 刷机）、OS Tab、设备 ID 输入、
 *   动态命令展示与一键复制、agent 包下载/链接复制。
 * 约定：无 features import——signalingUrl / iceJson 由页面经 QuickStart 域
 *   取好经 @Prop 传入；本组件仅持有展示态（mode/os/deviceId 文本）。
 * 网页 USB 部署入口依赖 WebUSB，列 P3（注记）。
 */
import { common } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { buildRunCommand, buildCpctlCommand } from '../utils/QuickStartCmd';

@Component
export struct QuickStartCard {
  /** 信令地址（页面经 features/onboarding/QuickStart 取好传入） */
  @Prop signalingUrl: string = '';
  /** ICE 列表 JSON（页面经 QuickStart.fetchIceJson 传入） */
  @Prop iceJson: string = '[]';
  /** agent 下载根 http(s)://host（页面传入，组件不做 IO/特征 import） */
  @Prop agentRoot: string = '';

  /** 部署方式：adb=一键脚本 / magisk=刷机模块 */
  @State mode: string = 'adb';
  /** OS：unix=Linux·macOS / win=Windows CMD */
  @State os: string = 'unix';
  /** 拟分配的设备 ID（命令行 -id；默认 device_01 对齐上游占位） */
  @State deviceId: string = 'device_01';

  /** 当前命令文本（纯模板生成，随 mode/os/id/props 联动） */
  private commandText(): string {
    if (this.mode === 'magisk') {
      return buildCpctlCommand(this.deviceId, this.signalingUrl, this.iceJson);
    }
    return buildRunCommand(this.os, this.deviceId, this.signalingUrl, this.iceJson);
  }

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 复制当前命令 */
  private copyCommand(): void {
    const text = this.commandText();
    const pd = pasteboard.createData('text/plain', text);
    pasteboard.getSystemPasteboard().setData(pd).then(() => {
      this.toast('运行指令已复制');
    }).catch(() => {
      this.toast('复制失败');
    });
  }

  /** 打开下载（系统浏览器；http(s) agent 端点，根地址由页面传入） */
  private openDownload(path: string): void {
    if (this.agentRoot.length === 0) {
      this.toast('服务器地址未配置');
      return;
    }
    const uri = `${this.agentRoot}${path}`;
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    ctx.startAbility({
      action: 'ohos.action.view',
      uri: uri
    }).catch(() => {
      // 浏览器唤起失败 → 退回复制链接
      const pd = pasteboard.createData('text/plain', uri);
      pasteboard.getSystemPasteboard().setData(pd).catch(() => { return; });
      this.toast('无法打开浏览器，下载链接已复制');
    });
  }

  @Builder
  tabBar(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(12)
      .padding({ left: 12, right: 12, top: 7, bottom: 7 })
      .backgroundColor(active ? '#0A59F7' : '#EEEEEE')
      .fontColor(active ? '#FFFFFF' : '#666666')
      .borderRadius(15)
      .onClick(onTap)
  }

  build() {
    Column() {
      // 标题与方式切换
      Text('🚀 快速接入空态引导')
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .width('100%')

      Row({ space: 8 }) {
        this.tabBar('ADB 一键部署', this.mode === 'adb', () => { this.mode = 'adb'; })
        this.tabBar('Magisk/KSU 模块', this.mode === 'magisk', () => { this.mode = 'magisk'; })
      }
      .width('100%')
      .margin({ top: 10 })
      .justifyContent(FlexAlign.Start)

      // 第一步：下载
      Text(this.mode === 'adb' ? '第一步：下载 ADB 部署包（含全架构 Agent 与一键脚本）' :
        '第一步：下载 Magisk 模块刷机包（物理真机已 Root）')
        .fontSize(12)
        .fontColor('#666666')
        .margin({ top: 10 })
      Row({ space: 10 }) {
        Button(this.mode === 'adb' ? '下载 agent-deploy.zip' : '下载 agent-magisk.zip')
          .height(34)
          .fontSize(12)
          .backgroundColor('#EEF4FF')
          .fontColor('#0A59F7')
          .onClick(() => {
            this.openDownload(this.mode === 'adb' ? '/agent/agent-deploy.pkg' :
              '/agent/cloudphone-agent-magisk.pkg');
          })
        Text('复制下载链接')
          .fontSize(12)
          .fontColor('#0A59F7')
          .onClick(() => {
            const path = this.mode === 'adb' ? '/agent/agent-deploy.pkg' : '/agent/cloudphone-agent-magisk.pkg';
            const pd = pasteboard.createData('text/plain', `${this.agentRoot}${path}`);
            pasteboard.getSystemPasteboard().setData(pd).catch(() => { return; });
            this.toast('链接已复制');
          })
      }
      .width('100%')
      .margin({ top: 6 })

      // 第二步：命令（ADB 模式带 OS Tab；Magisk 直接给 cpctl）
      Text(this.mode === 'adb' ? '第二步：解压 ZIP，在连接了设备的电脑终端运行命令' :
        '第二步：手机刷入模块重启后，执行命令配置信令服务器')
        .fontSize(12)
        .fontColor('#666666')
        .margin({ top: 10 })

      if (this.mode === 'adb') {
        Row({ space: 8 }) {
          this.tabBar('Linux / macOS', this.os === 'unix', () => { this.os = 'unix'; })
          this.tabBar('Windows CMD', this.os === 'win', () => { this.os = 'win'; })
        }
        .width('100%')
        .margin({ top: 6 })
        .justifyContent(FlexAlign.Start)
      }

      Text('设备 ID（-id）')
        .fontSize(12)
        .fontColor('#999999')
        .margin({ top: 8 })
      TextInput({ text: this.deviceId, placeholder: 'device_01' })
        .width('100%')
        .height(34)
        .fontSize(13)
        .onChange((v: string) => { this.deviceId = v.trim(); })

      // 命令终端视口
      Text(this.commandText())
        .fontSize(11)
        .fontFamily('monospace')
        .fontColor('#7FE07F')
        .backgroundColor('#1C1C1C')
        .padding(10)
        .borderRadius(8)
        .width('100%')
        .margin({ top: 8 })
        .copyOption(CopyOptions.LocalDevice)

      Button('复制运行指令')
        .width('100%')
        .height(36)
        .fontSize(13)
        .margin({ top: 8 })
        .onClick(() => { this.copyCommand(); })

      if (this.signalingUrl.length === 0) {
        Text('⚠️ 服务器地址未配置，命令暂不可用')
          .fontSize(11)
          .fontColor('#A34700')
          .margin({ top: 6 })
      }
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .padding(14)
  }
}
