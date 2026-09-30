/**
 * PeripheralPage —— 外设模拟页（P2-8，对应上游 AdvancedPage.vue 外设区）
 *
 * 职责（单一）：GPS 与传感器两类设备外设数据的编辑、预设动画与下发。
 * 协议（devices.js sendInjectData 实读）：全局信令帧
 *   `{message_type:'inject_data', channel:'gps'|'sensor', payload, target_device_ids:[id]}`
 *   ——经 GlobalChannel.sendRaw 直发（无 device_id，仅目标数组）。
 * 范围取舍（如实注记）：
 *   - GPS：坐标直填 + 瞬间传送 + 起终点路径模式（走5/跑12/驾60 km/h、1s 大圆插值，
 *     GeoPath 纯函数）；Leaflet 地图拖点列后续（需 Map Kit 接入）。
 *   - 传感器：滑块（accel/gyro/hinge/light/temp/proximity）+ 三预设动画
 *     （摇一摇 60ms×33、颠簸 100ms 噪声、翻转 50ms×24——步频与幅度对齐上游）。
 *   - 批量目标（target_device_ids 多台）随 P2-5 群控页统一接入。
 */
import { GlobalChannel } from '../features/signaling/GlobalChannel';
import { haversineMeters, bearingDeg, destinationPoint } from '../utils/GeoPath';
import { RouteParams } from '../model/Model';

/** 路径速度预设（km/h；上游 走5/跑12/驾60） */
const SPEED_WALK: number = 5;
const SPEED_RUN: number = 12;
const SPEED_DRIVE: number = 60;

/** 传感器数值行模型（label+value+量程；下发族由调用方 family 决定） */
class SensorField {
  label: string = '';
  value: number = 0;
  min: number = 0;
  max: number = 100;
  step: number = 1;

  constructor(label: string, value: number, min: number, max: number, step: number) {
    this.label = label;
    this.value = value;
    this.min = min;
    this.max = max;
    this.step = step;
  }
}

@Component
export struct PeripheralPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  /** 目标设备（进入即消费 routeParams.deviceId，由控制页 FAB 携带） */
  private deviceId: string = '';
  /** Tab：gps | sensor */
  @State tab: string = 'gps';

  // ---- GPS 表单 ----
  @State gpsLat: string = '31.2304';
  @State gpsLon: string = '121.4737';
  @State gpsAlt: string = '10';
  @State gpsSpd: string = '0';
  @State gpsBea: string = '0';
  // ---- 路径模式 ----
  @State pathEndLat: string = '';
  @State pathEndLon: string = '';
  @State pathSpeed: number = SPEED_WALK;
  @State pathActive: boolean = false;
  /** 路径 tick 计时器（1s）与剩余米数 */
  private pathTimer: number = -1;
  private pathRemainM: number = 0;

  // ---- 传感器 ----
  @State accelX: SensorField = new SensorField('加速度 X', 0, -20, 20, 0.1);
  @State accelY: SensorField = new SensorField('加速度 Y', 9.8, -20, 20, 0.1);
  @State accelZ: SensorField = new SensorField('加速度 Z', 0, -20, 20, 0.1);
  @State gyroX: SensorField = new SensorField('陀螺 X', 0, -10, 10, 0.1);
  @State gyroY: SensorField = new SensorField('陀螺 Y', 0, -10, 10, 0.1);
  @State gyroZ: SensorField = new SensorField('陀螺 Z', 0, -10, 10, 0.1);
  @State hingeAngle: SensorField = new SensorField('折叠角', 180, 0, 180, 1);
  @State lightVal: SensorField = new SensorField('光线 (lux)', 200, 0, 1000, 10);
  @State tempVal: SensorField = new SensorField('温度 (°C)', 25, -10, 60, 0.5);
  @State proximityVal: SensorField = new SensorField('距离 (cm)', 5, 0, 10, 1);

  // ---- 预设动画计时器 ----
  private presetTimer: number = -1;
  @State presetRunning: string = '';

  aboutToAppear(): void {
    this.deviceId = this.routeParams.deviceId;
    this.routeParams.deviceId = '';
    if (this.deviceId.length === 0) {
      this.getUIContext().getPromptAction().showToast({ message: '未指定目标设备' });
      this.pathStack.pop();
    }
  }

  aboutToDisappear(): void {
    this.stopPath();
    this.stopPreset(true);
  }

  private back(): void {
    this.pathStack.pop();
  }

  // ===================== 下发 =====================

  /** 注入一帧（全局信令 inject_data，target 单设备——帧形对齐 devices.js sendInjectData） */
  private inject(channel: string, payload: Record<string, Object>): void {
    const frame: Record<string, Object> = {
      'message_type': 'inject_data',
      'channel': channel,
      'payload': payload,
      'target_device_ids': [this.deviceId]
    };
    GlobalChannel.getInstance().sendRaw(JSON.stringify(frame));
  }

  /** 分数/数值解析（非法回退默认，与设置页同约定） */
  private fx(s: string, def: number): number {
    const v = parseFloat(s);
    return isNaN(v) ? def : v;
  }

  /** 瞬间传送：当前表单坐标单发（bea/spd 随表单） */
  private sendGpsOnce(): void {
    this.inject('gps', {
      'lat': this.fx(this.gpsLat, 0),
      'lon': this.fx(this.gpsLon, 0),
      'alt': this.fx(this.gpsAlt, 0),
      'bea': this.fx(this.gpsBea, 0),
      'spd': this.fx(this.gpsSpd, 0)
    });
    this.toast('已下发坐标');
  }

  // ===================== 路径模式（1s 大圆插值） =====================

  private toast(msg: string): void {
    this.getUIContext().getPromptAction().showToast({ message: msg });
  }

  /** 启动路径：以当前坐标为起点、终点表单为目标，按速度预设插值下发 */
  private startPath(): void {
    const endLat = this.fx(this.pathEndLat, NaN);
    const endLon = this.fx(this.pathEndLon, NaN);
    if (isNaN(endLat) || isNaN(endLon)) {
      this.toast('请填写终点经纬度');
      return;
    }
    const startLat = this.fx(this.gpsLat, 0);
    const startLon = this.fx(this.gpsLon, 0);
    this.pathRemainM = haversineMeters(startLat, startLon, endLat, endLon);
    if (this.pathRemainM < 1) {
      this.toast('起点与终点过近');
      return;
    }
    this.pathActive = true;
    // 每秒 tick：朝终点走 min(步长,剩余) 米（步长 = 速度 m/s；bea 取实时方位）
    this.pathTimer = setInterval(() => {
      const curLat = this.fx(this.gpsLat, 0);
      const curLon = this.fx(this.gpsLon, 0);
      const bea = bearingDeg(curLat, curLon, endLat, endLon);
      const stepM = this.pathSpeed / 3.6; // km/h → m/s（1s 步长）
      const moveM = Math.min(stepM, this.pathRemainM);
      const next = destinationPoint(curLat, curLon, bea, moveM);
      this.gpsLat = next.lat.toFixed(6);
      this.gpsLon = next.lon.toFixed(6);
      this.gpsBea = bea.toFixed(1);
      this.gpsSpd = (this.pathSpeed / 3.6).toFixed(2);
      this.inject('gps', {
        'lat': next.lat,
        'lon': next.lon,
        'alt': this.fx(this.gpsAlt, 0),
        'bea': bea,
        'spd': this.pathSpeed / 3.6
      });
      this.pathRemainM -= moveM;
      if (this.pathRemainM <= 0.5) {
        this.stopPath();
        this.toast('已到达终点');
      }
    }, 1000);
  }

  private stopPath(): void {
    if (this.pathTimer !== -1) {
      clearInterval(this.pathTimer);
      this.pathTimer = -1;
    }
    this.pathActive = false;
  }

  // ===================== 传感器下发 =====================

  /** 单滑块变更 → 按族组装 payload（accel/gyro 三轴整发；其余 {type,value}——上游 sendSingleSensor 同形） */
  private sendSensor(f: SensorField, family: string): void {
    if (family === 'accel') {
      this.inject('sensor', {
        'type': 'accel',
        'x': this.accelX.value,
        'y': this.accelY.value,
        'z': this.accelZ.value
      });
      return;
    }
    if (family === 'gyro') {
      this.inject('sensor', {
        'type': 'gyro',
        'x': this.gyroX.value,
        'y': this.gyroY.value,
        'z': this.gyroZ.value
      });
      return;
    }
    this.inject('sensor', { 'type': family, 'value': f.value });
  }

  /** 预设动画：摇一摇（2000ms/60ms，±17.5 随机加速度，结束复位 0/9.8/0） */
  private runShake(): void {
    this.startPreset('shake', () => {
      const rx = (Math.random() - 0.5) * 35;
      const ry = (Math.random() - 0.5) * 35;
      const rz = (Math.random() - 0.5) * 35;
      this.accelX.value = Number(rx.toFixed(2));
      this.accelY.value = Number(ry.toFixed(2));
      this.accelZ.value = Number(rz.toFixed(2));
      this.inject('sensor', { 'type': 'accel', 'x': rx, 'y': ry, 'z': rz });
    }, 60, 33, () => {
      this.accelX.value = 0;
      this.accelY.value = 9.8;
      this.accelZ.value = 0;
      this.inject('sensor', { 'type': 'accel', 'x': 0, 'y': 9.8, 'z': 0 });
    });
  }

  /** 颠簸路面（100ms，y=9.8±0.75 噪声；再次点击停止并复位——上游 toggleDrivingBump） */
  private toggleBump(): void {
    if (this.presetRunning === 'bump') {
      this.stopPreset(false);
      this.accelY.value = 9.8;
      this.inject('sensor', { 'type': 'accel', 'x': 0, 'y': 9.8, 'z': 0 });
      return;
    }
    this.stopPreset(false);
    this.presetRunning = 'bump';
    this.presetTimer = setInterval(() => {
      const nx = (Math.random() - 0.5) * 1.5;
      const ny = 9.8 + (Math.random() - 0.5) * 1.5;
      const nz = (Math.random() - 0.5) * 1.5;
      this.inject('sensor', { 'type': 'accel', 'x': nx, 'y': ny, 'z': nz });
    }, 100);
  }

  /** 360° 翻转（50ms×24 步，angle+=15°，gyro.z=2.0，sin/cos 加速度——上游 triggerFlip） */
  private runFlip(): void {
    let angle = 0;
    this.startPreset('flip', () => {
      angle += 15;
      const gx = 0;
      const gy = 0;
      const ax = Math.sin(angle * Math.PI / 180) * 9.8;
      const ay = Math.cos(angle * Math.PI / 180) * 9.8;
      this.accelX.value = Number(ax.toFixed(2));
      this.accelY.value = Number(ay.toFixed(2));
      this.gyroZ.value = 2.0;
      this.inject('sensor', { 'type': 'accel', 'x': ax, 'y': ay, 'z': 0 });
      this.inject('sensor', { 'type': 'gyro', 'x': gx, 'y': gy, 'z': 2.0 });
      if (angle >= 360) {
        this.stopPreset(false);
        this.accelX.value = 0;
        this.accelY.value = 9.8;
        this.gyroZ.value = 0;
        this.inject('sensor', { 'type': 'accel', 'x': 0, 'y': 9.8, 'z': 0 });
        this.inject('sensor', { 'type': 'gyro', 'x': 0, 'y': 0, 'z': 0 });
      }
    }, 50, 100, () => { return; });
  }

  /** 定时预设通用骨架：每 stepMs 执行一次（steps=上限保险），完成后 onDone */
  private startPreset(name: string, tick: () => void, stepMs: number, steps: number, onDone: () => void): void {
    this.stopPreset(false);
    this.presetRunning = name;
    let count = 0;
    this.presetTimer = setInterval(() => {
      tick();
      count++;
      if (count >= steps) {
        this.stopPreset(false);
        onDone();
      }
    }, stepMs);
  }

  /** 停止预设动画（clearInterval + 可选状态清理） */
  private stopPreset(_reset: boolean): void {
    if (this.presetTimer !== -1) {
      clearInterval(this.presetTimer);
      this.presetTimer = -1;
    }
    this.presetRunning = '';
  }

  // ===================== 视图 =====================

  @Builder
  gpsSection() {
    Column() {
      // 坐标直填
      Row() { Text('纬度').fontSize(14).width(60); TextInput({ text: this.gpsLat }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.gpsLat = v; }) }
        .width('100%').margin({ top: 8 })
      Row() { Text('经度').fontSize(14).width(60); TextInput({ text: this.gpsLon }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.gpsLon = v; }) }
        .width('100%').margin({ top: 8 })
      Row() { Text('海拔(m)').fontSize(14).width(60); TextInput({ text: this.gpsAlt }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.gpsAlt = v; }) }
        .width('100%').margin({ top: 8 })
      Row() { Text('速度(m/s)').fontSize(14).width(60); TextInput({ text: this.gpsSpd }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.gpsSpd = v; }) }
        .width('100%').margin({ top: 8 })
      Row() { Text('朝向(°)').fontSize(14).width(60); TextInput({ text: this.gpsBea }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.gpsBea = v; }) }
        .width('100%').margin({ top: 8 })

      Button('瞬间传送（下发当前坐标）')
        .width('100%').height(40).fontSize(13).margin({ top: 12 })
        .onClick(() => { this.sendGpsOnce(); })

      // 路径模式
      Divider().margin({ top: 14, bottom: 6 })
      Text('路径模式（1s 大圆插值；终点为 WGS84）').fontSize(13).fontColor('#666666')
      Row() { Text('终点纬').fontSize(14).width(60); TextInput({ text: this.pathEndLat, placeholder: '如 31.2400' }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.pathEndLat = v; }) }
        .width('100%').margin({ top: 8 })
      Row() { Text('终点经').fontSize(14).width(60); TextInput({ text: this.pathEndLon, placeholder: '如 121.4800' }).layoutWeight(1).height(34).fontSize(13).onChange((v: string) => { this.pathEndLon = v; }) }
        .width('100%').margin({ top: 8 })

      Row({ space: 8 }) {
        Button('走 5 km/h').fontSize(12).layoutWeight(1).height(34)
          .enabled(!this.pathActive)
          .onClick(() => { this.pathSpeed = SPEED_WALK; this.startPath(); })
        Button('跑 12 km/h').fontSize(12).layoutWeight(1).height(34)
          .enabled(!this.pathActive)
          .onClick(() => { this.pathSpeed = SPEED_RUN; this.startPath(); })
        Button('驾 60 km/h').fontSize(12).layoutWeight(1).height(34)
          .enabled(!this.pathActive)
          .onClick(() => { this.pathSpeed = SPEED_DRIVE; this.startPath(); })
      }
      .width('100%').margin({ top: 10 })

      if (this.pathActive) {
        Row({ space: 10 }) {
          Text(`移动中 · ${this.pathSpeed} km/h · 剩 ${this.pathRemainM.toFixed(0)} m`)
            .fontSize(12).fontColor('#007A00').layoutWeight(1)
          Text('停止').fontSize(13).fontColor('#CC0000').onClick(() => { this.stopPath(); })
        }
        .width('100%').margin({ top: 8 })
      }
      Text('注：Leaflet 地图拖点列后续（需 Map Kit 接入）').fontSize(11).fontColor('#999999').margin({ top: 10 })
    }
    .width('100%')
  }

  @Builder
  sensorRow(f: SensorField, family: string) {
    Row() {
      Text(f.label).fontSize(13).width(84)
      Slider({ value: f.value, min: f.min, max: f.max, step: f.step })
        .layoutWeight(1)
        .onChange((v: number) => { f.value = v; this.sendSensor(f, family); })
      Text(f.value.toFixed(1)).fontSize(12).fontColor('#666666').width(46).textAlign(TextAlign.End)
    }
    .width('100%')
    .margin({ top: 6 })
  }

  @Builder
  sensorSection() {
    Column() {
      Text('加速度计 (m/s²)').fontSize(13).fontWeight(FontWeight.Medium).margin({ top: 8 })
      this.sensorRow(this.accelX, 'accel')
      this.sensorRow(this.accelY, 'accel')
      this.sensorRow(this.accelZ, 'accel')

      Text('陀螺仪 (rad/s)').fontSize(13).fontWeight(FontWeight.Medium).margin({ top: 10 })
      this.sensorRow(this.gyroX, 'gyro')
      this.sensorRow(this.gyroY, 'gyro')
      this.sensorRow(this.gyroZ, 'gyro')

      Text('其余传感器').fontSize(13).fontWeight(FontWeight.Medium).margin({ top: 10 })
      this.sensorRow(this.hingeAngle, 'hinge_angle')
      this.sensorRow(this.lightVal, 'light')
      this.sensorRow(this.tempVal, 'temp')
      this.sensorRow(this.proximityVal, 'proximity')

      Divider().margin({ top: 14, bottom: 8 })
      Row({ space: 8 }) {
        Button('摇一摇').fontSize(12).layoutWeight(1).height(34)
          .enabled(this.presetRunning.length === 0)
          .onClick(() => { this.runShake(); })
        Button(this.presetRunning === 'bump' ? '停止颠簸' : '颠簸路面').fontSize(12).layoutWeight(1).height(34)
          .onClick(() => { this.toggleBump(); })
        Button('360°翻转').fontSize(12).layoutWeight(1).height(34)
          .enabled(this.presetRunning.length === 0)
          .onClick(() => { this.runFlip(); })
      }
      .width('100%').margin({ top: 6 })
      if (this.presetRunning.length > 0) {
        Text(`动画中：${this.presetRunning}`).fontSize(11).fontColor('#A34700').margin({ top: 6 })
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回').fontSize(15).fontColor('#0A59F7').onClick(() => { this.back(); })
        Blank()
        Text(`外设 · ${this.deviceId}`).fontSize(16).fontWeight(FontWeight.Medium)
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1).textAlign(TextAlign.Center)
        Blank()
        Text(' ').fontSize(15)
      }
      .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 }).backgroundColor('#F0F0F0')

      // Tab 切换
      Row({ space: 8 }) {
        Button('GPS').fontSize(13).layoutWeight(1).height(36)
          .backgroundColor(this.tab === 'gps' ? '#0A59F7' : '#EEEEEE')
          .fontColor(this.tab === 'gps' ? '#FFFFFF' : '#666666')
          .onClick(() => { this.tab = 'gps'; })
        Button('传感器').fontSize(13).layoutWeight(1).height(36)
          .backgroundColor(this.tab === 'sensor' ? '#0A59F7' : '#EEEEEE')
          .fontColor(this.tab === 'sensor' ? '#FFFFFF' : '#666666')
          .onClick(() => { this.tab = 'sensor'; })
      }
      .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })

      Scroll() {
        Column() {
          if (this.tab === 'gps') {
            this.gpsSection()
          } else {
            this.sensorSection()
          }
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 32 })
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
