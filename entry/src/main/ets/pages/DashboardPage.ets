/**
 * DashboardPage —— 监控大盘（P2-9a，对应上游 views/Dashboard.vue）
 *
 * 职责（单一）：六指标汇总卡、设备热力状态矩阵、单设备单指标趋势折线。
 * 数据：MetricsService（device_metrics 广播 → 最新快照 + 360 点环形历史），
 *   @StorageLink('metricsState') 联动刷新。
 * 阈值与配色（对齐 Dashboard currentMetricConfig）：
 *   cpu 70/85、内存 75/90、磁盘 80/90、温度 65/75（正常/告警/严重）；速率列无阈值（信息色）。
 * 渲染：热力矩阵用色块 + 数值；趋势用 ArkUI Canvas（CanvasRenderingContext2D 折线，
 *   展示历史尾 60 点，窗口外点不画）。
 * 入口：DeviceList 顶栏「大盘」。
 */
import { MetricsService, METRIC_KEYS } from '../features/metrics/MetricsService';
import { RouteParams } from '../model/Model';

/** 趋势图可视点数（历史 360 点取尾 60 展示） */
const SPARK_POINTS: number = 60;
/** 趋势画布逻辑尺寸（vp；贴合手机内容区宽度） */
const SPARK_W: number = 340;
const SPARK_H: number = 88;

/** 阈值指标（汇总卡四格；顺序=展示序） */
const CARD_KEYS: string[] = ['cpu', 'memory', 'disk', 'temp'];

@Component
export struct DashboardPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;
  /** 指标更新（MetricsService.notify 写入）→ 卡片/矩阵/趋势刷新 */
  @StorageLink('metricsState') @Watch('onMetricsTick') metricsTick: number = 0;

  /** 趋势选择：设备 + 指标 */
  @State trendDeviceId: string = '';
  @State trendMetric: string = 'cpu';
  /** Canvas 2D 上下文（组件参数；onReady 后可绘制） */
  private sparkCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D();
  /** 画布就绪开关（防 ready 前绘制） */
  @State sparkReady: boolean = false;

  private service: MetricsService = MetricsService.getInstance();

  aboutToAppear(): void {
    const ids = this.service.deviceIds();
    if (ids.length > 0 && this.trendDeviceId.length === 0) {
      this.trendDeviceId = ids[0];
    }
  }

  private back(): void {
    this.pathStack.pop();
  }

  /** @Watch：重绘趋势并顺带刷新（矩阵/卡直接依赖 @StorageLink 重建） */
  private onMetricsTick(): void {
    const ids = this.service.deviceIds();
    if (this.trendDeviceId.length === 0 && ids.length > 0) {
      this.trendDeviceId = ids[0];
    }
    this.drawSpark();
  }

  // ===================== 汇总卡 =====================

  /** 单指标告警文案（'n 台告警' / '暂无数据'） */
  private cardText(key: string): string {
    const total = this.service.deviceIds().length;
    if (total === 0) {
      return '暂无数据';
    }
    const warn = this.service.warningCount(key);
    return warn > 0 ? `${warn} 台告警` : `${total} 台正常`;
  }

  /** 单卡配色（有告警红/正常绿/无数据灰） */
  private cardColor(key: string): string {
    const total = this.service.deviceIds().length;
    if (total === 0) {
      return '#999999';
    }
    return this.service.warningCount(key) > 0 ? '#C62828' : '#007A00';
  }

  // ===================== 热力矩阵 =====================

  /** 单元格取值展示（速率无数据时 '—'） */
  private cellText(deviceId: string, key: string): string {
    const m = this.service.getMetrics(deviceId);
    if (m === null) {
      return '—';
    }
    if ((key === 'down' || key === 'up') && MetricsService.valueOf(m, key) === 0) {
      return '0';
    }
    return MetricsService.formatOf(key, MetricsService.valueOf(m, key));
  }

  /** 单元格底色（level 0/1/2 + 速率信息色） */
  private cellBg(deviceId: string, key: string): string {
    const m = this.service.getMetrics(deviceId);
    if (m === null) {
      return '#F5F5F5';
    }
    const v = MetricsService.valueOf(m, key);
    const lv = MetricsService.levelOf(key, v);
    if (lv === 3) {
      return v > 0 ? '#E3F2FD' : '#F5F5F5'; // 速率：有流量蓝 / 无流量灰
    }
    if (lv === 2) {
      return '#FFCDD2'; // 严重
    }
    if (lv === 1) {
      return '#FFE0B2'; // 告警
    }
    return '#C8E6C9'; // 正常
  }

  private cellFont(deviceId: string, key: string): string {
    const m = this.service.getMetrics(deviceId);
    if (m === null) {
      return '#BBBBBB';
    }
    const lv = MetricsService.levelOf(key, MetricsService.valueOf(m, key));
    if (lv === 3) {
      return '#1565C0';
    }
    if (lv === 2) {
      return '#B71C1C';
    }
    if (lv === 1) {
      return '#E65100';
    }
    return '#1B5E20';
  }

  // ===================== 趋势折线 =====================

  /** 趋势统计（min/avg/max 展示在图外） */
  private trendStatText(): string {
    const track = this.service.getTrack(this.trendDeviceId, this.trendMetric);
    if (track.length === 0) {
      return '暂无历史';
    }
    const view = track.slice(-SPARK_POINTS);
    let min = view[0];
    let max = view[0];
    let sum = 0;
    for (const v of view) {
      if (v < min) {
        min = v;
      }
      if (v > max) {
        max = v;
      }
      sum += v;
    }
    const unit = this.trendMetric === 'temp' ? '℃' : '%';
    return `近${view.length}点 · min ${min.toFixed(1)}${unit} · avg ${(sum / view.length).toFixed(1)}${unit} · max ${max.toFixed(1)}${unit}`;
  }

  /** 绘制折线（onReady / 指标切换 / 数据更新时调用；空数据仅清屏） */
  private drawSpark(): void {
    if (!this.sparkReady) {
      return;
    }
    const ctx = this.sparkCtx;
    ctx.clearRect(0, 0, SPARK_W, SPARK_H);
    const track = this.service.getTrack(this.trendDeviceId, this.trendMetric);
    const view = track.slice(-SPARK_POINTS);
    if (view.length < 2) {
      return;
    }
    let min = view[0];
    let max = view[0];
    for (const v of view) {
      if (v < min) {
        min = v;
      }
      if (v > max) {
        max = v;
      }
    }
    if (max - min < 0.001) {
      max = min + 1; // 平线兜底（避免除零）
    }
    const pad = 6;
    const w = SPARK_W - pad * 2;
    const h = SPARK_H - pad * 2;
    // 网格基线（上下边界）
    ctx.strokeStyle = '#E0E0E0';
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(pad, pad);
    ctx.lineTo(SPARK_W - pad, pad);
    ctx.moveTo(pad, SPARK_H - pad);
    ctx.lineTo(SPARK_W - pad, SPARK_H - pad);
    ctx.stroke();
    // 折线
    ctx.strokeStyle = '#0A59F7';
    ctx.lineWidth = 2;
    ctx.beginPath();
    for (let i = 0; i < view.length; i++) {
      const x = pad + (i / (view.length - 1)) * w;
      const y = pad + (1 - (view[i] - min) / (max - min)) * h;
      if (i === 0) {
        ctx.moveTo(x, y);
      } else {
        ctx.lineTo(x, y);
      }
    }
    ctx.stroke();
  }

  // ===================== 视图 =====================

  @Builder
  cardGrid() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(CARD_KEYS, (key: string) => {
        Column({ space: 3 }) {
          Text(MetricsService.labelOf(key))
            .fontSize(12)
            .fontColor('#666666')
          Text(this.cardText(key))
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.cardColor(key))
        }
        .layoutWeight(1)
        .padding({ top: 10, bottom: 10, left: 6, right: 6 })
        .margin(4)
        .backgroundColor('#FFFFFF')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Center)
      }, (key: string) => `${key}_${this.cardText(key)}`)
    }
    .width('100%')
  }

  @Builder
  matrixTable() {
    Column() {
      // 列头
      Row({ space: 4 }) {
        Text('设备').fontSize(11).fontColor('#999999').width(78)
        ForEach(METRIC_KEYS, (key: string) => {
          Text(MetricsService.labelOf(key))
            .fontSize(11)
            .fontColor('#999999')
            .layoutWeight(1)
            .textAlign(TextAlign.Center)
        }, (key: string) => `h_${key}`)
      }
      .width('100%')
      .margin({ top: 4 })

      // 行：设备 × 六指标
      ForEach(this.service.deviceIds(), (id: string) => {
        Row({ space: 4 }) {
          Text(id.length > 9 ? `${id.substring(0, 8)}…` : id)
            .fontSize(11)
            .fontColor('#333333')
            .width(78)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          ForEach(METRIC_KEYS, (key: string) => {
            Text(this.cellText(id, key))
              .fontSize(10)
              .fontColor(this.cellFont(id, key))
              .backgroundColor(this.cellBg(id, key))
              .layoutWeight(1)
              .textAlign(TextAlign.Center)
              .padding({ top: 6, bottom: 6 })
              .borderRadius(4)
          }, (key: string) => `c_${id}_${key}_${this.cellText(id, key)}`)
        }
        .width('100%')
        .margin({ top: 4 })
      }, (id: string) => `r_${id}_${this.metricsTick}`)

      if (this.service.deviceIds().length === 0) {
        Text('暂无 metrics 数据——设备上报后自动出现')
          .fontSize(12)
          .fontColor('#999999')
          .margin({ top: 8 })
      }

      // 图例
      Row({ space: 10 }) {
        Text('■ 正常').fontSize(10).fontColor('#1B5E20')
        Text('■ 告警').fontSize(10).fontColor('#E65100')
        Text('■ 严重').fontSize(10).fontColor('#B71C1C')
        Text('■ 速率').fontSize(10).fontColor('#1565C0')
        Text('阈值: CPU 70/85 · 内存 75/90 · 磁盘 80/90 · 温度 65/75')
          .fontSize(9)
          .fontColor('#BBBBBB')
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Start)
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .padding(12)
    .margin({ top: 10 })
  }

  @Builder
  trendSection() {
    Column() {
      Text('趋势（单设备 · 单指标 · 尾 60 点）').fontSize(15).fontWeight(FontWeight.Medium).width('100%')

      Row({ space: 8 }) {
        Select(this.deviceOptions())
          .layoutWeight(1)
          .height(34)
          .font({ size: 12 })
          .selected(Math.max(0, this.service.deviceIds().indexOf(this.trendDeviceId)))
          .onSelect((i: number) => {
            const ids = this.service.deviceIds();
            if (ids[i] !== undefined) {
              this.trendDeviceId = ids[i];
              this.drawSpark();
            }
          })
      }
      .width('100%')
      .margin({ top: 8 })

      // 指标 chips（阈值四项）
      Row({ space: 8 }) {
        ForEach(CARD_KEYS, (key: string) => {
          Text(MetricsService.labelOf(key))
            .fontSize(12)
            .padding({ left: 14, right: 14, top: 6, bottom: 6 })
            .borderRadius(14)
            .backgroundColor(this.trendMetric === key ? '#0A59F7' : '#EEEEEE')
            .fontColor(this.trendMetric === key ? '#FFFFFF' : '#666666')
            .onClick(() => {
              this.trendMetric = key;
              this.drawSpark();
            })
        }, (key: string) => `t_${key}_${this.trendMetric === key}`)
      }
      .width('100%')
      .margin({ top: 8 })
      .justifyContent(FlexAlign.Start)

      Text(this.trendStatText())
        .fontSize(11)
        .fontColor('#999999')
        .margin({ top: 8 })
        .width('100%')

      // 折线画布（onReady 后首绘；数据/选择变化经 drawSpark 重绘）
      Canvas(this.sparkCtx)
        .width(SPARK_W)
        .height(SPARK_H)
        .margin({ top: 6 })
        .backgroundColor('#FAFAFA')
        .borderRadius(8)
        .onReady(() => {
          this.sparkReady = true;
          this.drawSpark();
        })
    }
    .width('100%')
    .backgroundColor('#FFFFFF')
    .borderRadius(12)
    .padding(12)
    .margin({ top: 10, bottom: 24 })
  }

  /** 趋势设备选择数据源（SelectOption[] 签名） */
  private deviceOptions(): SelectOption[] {
    const arr: SelectOption[] = [];
    for (const id of this.service.deviceIds()) {
      const so: SelectOption = { value: id };
      arr.push(so);
    }
    return arr;
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text('监控大盘').fontSize(16).fontWeight(FontWeight.Medium)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 10, bottom: 10 })
      .backgroundColor('#F0F0F0')

      Scroll() {
        Column() {
          this.cardGrid()
          this.matrixTable()
          this.trendSection()
        }
        .width('100%')
        .padding({ left: 12, right: 12, top: 8 })
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
