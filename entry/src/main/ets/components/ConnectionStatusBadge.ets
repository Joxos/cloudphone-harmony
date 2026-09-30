/**
 * 连接状态徽标（P0-3 七态状态机的 ETS 展示端）
 *
 * 数据流：control.html 状态机 → nativeBridge.onState(state, text) → ControlPage(ArkWebView)
 *         @State → 本组件（@Prop 单向）→ 圆点着色 + 文本。
 * 七态：disconnected / connecting / signaling / waiting_offer / connecting_webrtc / connected / error
 * （对齐 ConnectionStatus 组件，色板与 web 版一致）
 */

@Component
// 单一使用点暂以组件承载（P2 SharePage 访客播放器将复用第二处）
// eslint-disable-next-line @performance/avoid-overusing-custom-component-check
export struct ConnectionStatusBadge {
  /** 状态机状态（见文件头七态） */
  @Prop state: string = 'disconnected';
  /** 展示文本（状态 · 明细，由页面上报） */
  @Prop text: string = '未连接';

  private dotColor(): string {
    if (this.state === 'connected') {
      return '#007A00';
    }
    if (this.state === 'error') {
      return '#CC0000';
    }
    if (this.state === 'disconnected') {
      return '#999999';
    }
    // 主题蓝：连接过程中的其余状态（见文件头七态清单）
    return '#0A59F7';
  }

  build() {
    Row() {
      Circle({ width: 8, height: 8 })
        .fill(this.dotColor())
      Text(this.text)
        .fontSize(12)
        .fontColor('#FFFFFF')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ left: 6 })
    }
    .padding({ left: 10, right: 10, top: 5, bottom: 5 })
    .backgroundColor('rgba(0, 0, 0, 0.62)')
    .borderRadius(14)
    .constraintSize({ maxWidth: '70%' })
  }
}
