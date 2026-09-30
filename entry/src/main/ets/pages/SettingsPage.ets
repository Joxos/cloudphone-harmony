/**
 * 设置页（对应安卓 SettingsActivity；P1-3 全局/按设备作用域 + P1-4 策略置灰）
 *
 * 职责（单一）：画质连接参数编辑、按作用域持久化、全局设置云端下发。
 * 作用域：进入时消费 routeParams.deviceId —— 非空=设备作用域（列表行内 ⚙ 进入），
 *        空=全局（顶栏「设置」进入）；覆盖链/键名契约见 features/settings/SettingsStore。
 * 策略：管理员 forbid_* 维度置灰🔒，有强制值时覆盖表单（AuthService.fetchMe → applyPolicy）。
 * 消费方：SettingsStore → pages/ArkWebView buildScrcpyOptionsJson（P0-9 管道）。
 */
import { common } from '@kit.AbilityKit';
import { RouteParams, UserPolicy } from '../model/Model';
import { ConnectionSettings } from '../features/settings/ConnectionSettings';
import { SettingsStore } from '../features/settings/SettingsStore';
import { AuthService } from '../features/auth/AuthService';
import { Prefs } from '../utils/Prefs';

@Component
export struct SettingsPage {
  @Consume('pathStack') pathStack: NavPathStack;
  @Consume('routeParams') routeParams: RouteParams;

  /** 作用域设备 ID（''=全局）；进入即消费清空，避免污染后续入口 */
  private scope: string = '';
  /** 管理员策略（置灰与强制值来源） */
  private policy: UserPolicy = new UserPolicy();

  // ---- P1-4 置灰标记（forbid_* 四维） ----
  @State lockFps: boolean = false;
  @State lockSize: boolean = false;
  @State lockBitrate: boolean = false;
  @State lockAudio: boolean = false;

  // ---- 表单态 ↔ Prefs 键（字符串态便于 TextInput 直绑；单位见键位契约） ----
  /** 最大帧率 fps（connection_fps，默认 30） */
  @State fps: string = '30';
  /** 最大分辨率最长边（connection_size，默认 2160） */
  @State maxSize: string = '2160';
  /** 固定码率 Mbps（connection_bitrate，默认 12；注入时 ×1e6） */
  @State bitrate: string = '12';
  /** 动态带宽估计开关（connection_bwe，默认 false） */
  @State bwe: boolean = false;
  /** BWE 下限 Mbps（connection_min_bitrate，默认 8） */
  @State minBitrate: string = '8';
  /** BWE 上限 Mbps（connection_max_bitrate，默认 20） */
  @State maxBitrate: string = '20';
  /** 音频回传开关（connection_audio，默认 true） */
  @State audio: boolean = true;
  /** 音频增益 0.5~3.0（connection_audio_gain，默认 1；注入为 audio_gain，上游 SettingsModal 音频 Tab） */
  @State audioGain: number = 1;
  /** 采集源 playback=true 即保本地声（connection_audio_source：'output'|'playback'） */
  @State audioSourcePlayback: boolean = false;
  /** playback 源时保留设备本地声音（connection_audio_dup，默认 true） */
  @State audioDup: boolean = true;
  // ---- P2-3b：AI 配置（上游 localStorage ai_api_* 同名键与默认值） ----
  @State aiUrl: string = 'https://api.openai.com/v1';
  @State aiKey: string = '';
  @State aiModel: string = 'gpt-4o-mini';

  private prefs: Prefs = Prefs.getInstance();

  aboutToAppear(): void {
    this.scope = this.routeParams.deviceId;
    this.routeParams.deviceId = '';
    this.loadSettings();
  }

  /** 进入页面：读作用域设置 → 强制刷新管理员策略 → 应用强制值 → 落表单与置灰态 */
  private async loadSettings(): Promise<void> {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    await this.prefs.init(ctx);
    const cs = await SettingsStore.load(this.scope);
    this.policy = await AuthService.getInstance().getPolicy(true);
    SettingsStore.applyPolicy(cs, this.policy);
    this.fps = String(cs.fps);
    this.maxSize = String(cs.size);
    this.bitrate = String(cs.bitrateMbps);
    this.bwe = cs.bwe;
    this.minBitrate = String(cs.minBitrateMbps);
    this.maxBitrate = String(cs.maxBitrateMbps);
    this.audio = cs.audio;
    this.audioGain = cs.audioGain;
    this.audioSourcePlayback = cs.audioSource === 'playback';
    this.audioDup = cs.audioDup;
    this.lockFps = this.policy.forbidFps;
    this.lockSize = this.policy.forbidResolution;
    this.lockBitrate = this.policy.forbidBitrate;
    this.lockAudio = this.policy.forbidAudio;
    // P2-3b：AI 配置（本地优先；登录回填见 AuthService）
    this.aiUrl = await this.prefs.getString('ai_api_url', 'https://api.openai.com/v1');
    this.aiKey = await this.prefs.getString('ai_api_key', '');
    this.aiModel = await this.prefs.getString('ai_model', 'gpt-4o-mini');
  }

  /** 表单态 → 模型（保存与云端下发的唯一收集点） */
  private collect(): ConnectionSettings {
    const cs = new ConnectionSettings();
    cs.fps = parseInt(this.fps) || 30;
    cs.size = parseInt(this.maxSize) || 2160;
    cs.bitrateMbps = parseInt(this.bitrate) || 12;
    cs.bwe = this.bwe;
    cs.minBitrateMbps = parseInt(this.minBitrate) || 8;
    cs.maxBitrateMbps = parseInt(this.maxBitrate) || 20;
    cs.audio = this.audio;
    cs.audioGain = this.audioGain;
    cs.audioSource = this.audioSourcePlayback ? 'playback' : 'output';
    cs.audioDup = this.audioDup;
    return cs;
  }

  /** 按当前作用域持久化表单（非法数字回退默认），成功后 toast 并返回上一页 */
  private async saveSettings(): Promise<void> {
    await SettingsStore.save(this.scope, this.collect());
    // P2-3b：AI 配置三键落盘 + 异步云同步（上游 local first → saveAIConfig 语义）
    await this.prefs.putString('ai_api_url', this.aiUrl.trim());
    await this.prefs.putString('ai_api_key', this.aiKey.trim());
    await this.prefs.putString('ai_model', this.aiModel.trim());
    AuthService.getInstance()
      .saveAiConfig(this.aiUrl.trim(), this.aiKey.trim(), this.aiModel.trim(), 'openai')
      .catch(() => { return; });
    this.getUIContext().getPromptAction().showToast({ message: '已保存（AI 配置后台云同步）' });
    this.pathStack.pop();
  }

  /** P1-3「保存为全局」：写全局作用域并 POST /api/default_settings（上游保存全局语义） */
  private async pushGlobalAsDefault(): Promise<void> {
    const ok = await SettingsStore.pushGlobal(this.collect());
    this.getUIContext().getPromptAction().showToast({
      message: ok ? '已保存并下发全局' : '已保存到本地（云端下发失败）'
    });
  }

  /** 恢复表单为安卓版默认值（仅重置界面态，需点「保存」才写入 Prefs） */
  private async resetToDefault(): Promise<void> {
    this.fps = '30';
    this.maxSize = '2160';
    this.bitrate = '12';
    this.bwe = false;
    this.minBitrate = '8';
    this.maxBitrate = '20';
    this.audio = true;
    this.audioGain = 1;
    this.audioSourcePlayback = false;
    this.audioDup = true;
  }

  /** 数值设置行：标签 + 尾部输入框；locked=策略锁定（🔒 前缀 + 置灰） */
  @Builder
  Item(label: string, value: string, onChange: (v: string) => void, locked: boolean) {
    Row() {
      Text(locked ? `🔒 ${label}` : label)
        .fontSize(16)
        .fontColor(locked ? '#999999' : '#000000')
      Blank()
      TextInput({ text: value })
        .width(100)
        .height(36)
        .textAlign(TextAlign.End)
        .enabled(!locked)
        .onChange(onChange)
    }
    .width('100%')
    .padding({ left: 18, right: 18, top: 18, bottom: 18 })
  }

  build() {
    Column() {
      Row() {
        Text('‹ 返回')
          .fontSize(15)
          .fontColor('#0A59F7')
          .onClick(() => { this.pathStack.pop(); })
        Blank()
        Text(this.scope.length > 0 ? `画质 · ${this.scope}` : '画质设置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Blank()
        Text('重置')
          .fontSize(15)
          .fontColor('#A34700')
          .onClick(() => { this.resetToDefault(); })
      }
      .width('100%')
      .padding({ left: 24, right: 24, top: 14, bottom: 14 })
      .backgroundColor('#F5F5F5')

      // 横向留白走父容器 padding：width('100%') + margin 会被裁切
      Column() {
        Scroll() {
          Column() {
            this.Item('最大帧率 (fps)', this.fps, (v: string) => { this.fps = v; }, this.lockFps)
            Divider()
            this.Item('最大分辨率', this.maxSize, (v: string) => { this.maxSize = v; }, this.lockSize)
            Divider()
            this.Item('码率 (Mbps)', this.bitrate, (v: string) => { this.bitrate = v; }, this.lockBitrate)
            Divider()
            Row() {
              Text(this.lockBitrate ? '🔒 动态码率 (BWE)' : '动态码率 (BWE)').fontSize(16)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.bwe })
                .enabled(!this.lockBitrate)
                .onChange((isOn: boolean) => { this.bwe = isOn; })
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 18, bottom: 18 })
            Divider()
            this.Item('最小码率 (Mbps)', this.minBitrate, (v: string) => { this.minBitrate = v; }, this.lockBitrate)
            Divider()
            this.Item('最大码率 (Mbps)', this.maxBitrate, (v: string) => { this.maxBitrate = v; }, this.lockBitrate)
            Divider()
            Row() {
              Text(this.lockAudio ? '🔒 音频' : '音频').fontSize(16)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.audio })
                .enabled(!this.lockAudio)
                .onChange((isOn: boolean) => { this.audio = isOn; })
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 18, bottom: 18 })
            Divider()
            // ---- P1-1 音频细项（上游 SettingsModal 音频 Tab；随 forbidAudio 联动置灰） ----
            Row() {
              Text(this.lockAudio ? '🔒 音频增益' : '音频增益').fontSize(16)
              Slider({ value: this.audioGain, min: 0.5, max: 3, step: 0.5 })
                .layoutWeight(1)
                .margin({ left: 12, right: 12 })
                .enabled(!this.lockAudio)
                .onChange((v: number) => { this.audioGain = v; })
              Text(this.audioGain.toFixed(1))
                .fontSize(14)
                .fontColor('#666666')
                .width(30)
                .textAlign(TextAlign.End)
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 18, bottom: 18 })
            Divider()
            Row() {
              Text('采集源 playback（保本地声）').fontSize(16)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.audioSourcePlayback })
                .enabled(!this.lockAudio)
                .onChange((isOn: boolean) => { this.audioSourcePlayback = isOn; })
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 18, bottom: 18 })
            Divider()
            Row() {
              Text('保留设备本地声音（dup）').fontSize(16)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.audioDup })
                .enabled(!this.lockAudio)
                .onChange((isOn: boolean) => { this.audioDup = isOn; })
            }
            .width('100%')
            .padding({ left: 18, right: 18, top: 18, bottom: 18 })
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .margin({ top: 18, bottom: 18 })
        }
        .layoutWeight(1)
        // 边界反馈动效：滑到顶/底时弹簧回弹（应用市场 UX 审核要求）
        .edgeEffect(EdgeEffect.Spring)

          // ---- P2-3b：AI 配置（控制页 AI 引擎同源读取；保存即本地+云同步） ----
          Column() {
            Text('AI 助手配置').fontSize(15).fontWeight(FontWeight.Medium).width('100%')
            Text('控制页「AI」经原生通道调用；登录时服务端 ai_config 会回填覆盖本地')
              .fontSize(11)
              .fontColor('#999999')
              .width('100%')
              .margin({ top: 4 })
            Row() {
              Text('API Base URL').fontSize(14).width(110)
              TextInput({ text: this.aiUrl })
                .layoutWeight(1)
                .height(36)
                .fontSize(13)
                .onChange((v: string) => { this.aiUrl = v; })
            }
            .width('100%')
            .margin({ top: 10 })
            Row() {
              Text('API Key').fontSize(14).width(110)
              TextInput({ text: this.aiKey })
                .type(InputType.Password)
                .layoutWeight(1)
                .height(36)
                .fontSize(13)
                .onChange((v: string) => { this.aiKey = v; })
            }
            .width('100%')
            .margin({ top: 8 })
            Row() {
              Text('模型').fontSize(14).width(110)
              TextInput({ text: this.aiModel })
                .layoutWeight(1)
                .height(36)
                .fontSize(13)
                .onChange((v: string) => { this.aiModel = v; })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('100%')
          .backgroundColor('#FFFFFF')
          .borderRadius(12)
          .padding(14)
          .margin({ top: 12 })

        // P1-3：把当前表单同时写为全局默认并云端下发（上游"保存全局"）
        Button('保存为全局（云端下发）')
          .width('100%')
          .height(44)
          .borderRadius(12)
          .backgroundColor('#EEF4FF')
          .fontColor('#0A59F7')
          .margin({ top: 8 })
          .onClick(() => { this.pushGlobalAsDefault(); })

        Button('保存')
          .width('100%')
          .height(46)
          .borderRadius(12)
          .margin({ top: 8, bottom: 24 })
          .onClick(() => { this.saveSettings(); })
      }
      .width('100%')
      .layoutWeight(1)
      .padding({ left: 24, right: 24 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
