/**
 * SettingsStore —— 画质设置持久化与策略应用（P1-3/P1-4）
 *
 * 职责（单一）：设置的读写与作用域覆盖链、管理员策略应用、全局设置云端下发。
 * 作用域键约定（P1-3）：
 *   全局：connection_<field>；设备：connection_<field>__<deviceId>（双下划线分隔）。
 *   覆盖链 loadMerged(deviceId)：全局为底 ← 仅覆盖"显式设置过"（Prefs.has）的设备键。
 * 云端：pushGlobal → POST /api/default_settings（Bearer，上游"保存全局"语义）。
 * 依赖：utils/Prefs、utils/HttpClient、model/{ConnectionSettings,UserPolicy}。
 */
import { Prefs } from '../../utils/Prefs';
import { HttpClient, httpScheme } from '../../utils/HttpClient';
import { ConnectionSettings } from './ConnectionSettings';
import { UserPolicy } from '../../model/Model';
import { Logger } from '../../utils/Logger';

/** POST /api/default_settings 的 settings 载荷（上游默认画质字段，单位同 ConnectionSettings） */
interface DefaultSettings {
  fps: number;
  size: number;
  bitrate: number;
  bwe: boolean;
  minBitrate: number;
  maxBitrate: number;
  audio: boolean;
  audio_gain: number;
  audio_source: string;
  audio_dup: boolean;
}

/** POST /api/default_settings 请求体 */
interface DefaultSettingsBody {
  settings: DefaultSettings;
}

export class SettingsStore {
  private static http: HttpClient = new HttpClient();

  /** 键拼接（scope 空 = 全局作用域） */
  private static key(base: string, scope: string): string {
    return scope.length > 0 ? `${base}__${scope}` : base;
  }

  /**
   * 读一份设置。
   * @param scope ''=全局；否则为设备 ID（读不到任何设备键时回退默认值）
   */
  static async load(scope: string): Promise<ConnectionSettings> {
    const cs = new ConnectionSettings();
    const p = Prefs.getInstance();
    const k = (base: string): string => SettingsStore.key(base, scope);
    cs.fps = await p.getInt(k('connection_fps'), cs.fps);
    cs.size = await p.getInt(k('connection_size'), cs.size);
    cs.bitrateMbps = await p.getInt(k('connection_bitrate'), cs.bitrateMbps);
    cs.bwe = await p.getBoolean(k('connection_bwe'), cs.bwe);
    cs.minBitrateMbps = await p.getInt(k('connection_min_bitrate'), cs.minBitrateMbps);
    cs.maxBitrateMbps = await p.getInt(k('connection_max_bitrate'), cs.maxBitrateMbps);
    cs.audio = await p.getBoolean(k('connection_audio'), cs.audio);
    cs.audioGain = await p.getFloat(k('connection_audio_gain'), cs.audioGain);
    cs.audioSource = await p.getString(k('connection_audio_source'), cs.audioSource);
    cs.audioDup = await p.getBoolean(k('connection_audio_dup'), cs.audioDup);
    cs.videoCodecOptions = await p.getString(k('connection_video_codec_options'), cs.videoCodecOptions);
    return cs;
  }

  /** 写一份设置（scope 空 = 全局） */
  static async save(scope: string, cs: ConnectionSettings): Promise<void> {
    const p = Prefs.getInstance();
    const k = (base: string): string => SettingsStore.key(base, scope);
    await p.putInt(k('connection_fps'), cs.fps);
    await p.putInt(k('connection_size'), cs.size);
    await p.putInt(k('connection_bitrate'), cs.bitrateMbps);
    await p.putBoolean(k('connection_bwe'), cs.bwe);
    await p.putInt(k('connection_min_bitrate'), cs.minBitrateMbps);
    await p.putInt(k('connection_max_bitrate'), cs.maxBitrateMbps);
    await p.putBoolean(k('connection_audio'), cs.audio);
    await p.putFloat(k('connection_audio_gain'), cs.audioGain);
    await p.putString(k('connection_audio_source'), cs.audioSource);
    await p.putBoolean(k('connection_audio_dup'), cs.audioDup);
    await p.putString(k('connection_video_codec_options'), cs.videoCodecOptions);
    Logger.info('SettingsStore', `已保存（${scope.length > 0 ? '设备 ' + scope : '全局'}）`);
  }

  /**
   * 控制页入口：全局为底 + 设备显式设置过的键覆盖（P1-3 按设备）。
   * 无 deviceId 时等价全局。
   */
  static async loadMerged(deviceId: string): Promise<ConnectionSettings> {
    const base = await SettingsStore.load('');
    if (deviceId.length === 0) {
      return base;
    }
    const p = Prefs.getInstance();
    const marker = SettingsStore.key('connection_fps', deviceId); // 任一设备键作存在性探针
    if (!(await p.has(marker))) {
      return base; // 设备从未显式保存过 → 纯全局
    }
    const dev = await SettingsStore.load(deviceId);
    return dev;
  }

  /**
   * P1-4：应用管理员策略——forbid 维度取 settingsJson 强制值（若有），返回改动后的设置。
   * 维度映射：forbidResolution→size、forbidFps→fps、forbidBitrate→bitrateMbps、forbidAudio→audio/audioGain。
   */
  static applyPolicy(cs: ConnectionSettings, policy: UserPolicy): ConnectionSettings {
    let forced: Record<string, Object> | null = null;
    try {
      const parsed: Object = JSON.parse(policy.settingsJson.length > 0 ? policy.settingsJson : '{}');
      forced = parsed as Record<string, Object>;
    } catch (e) {
      forced = null;
    }
    if (forced !== null) {
      if (policy.forbidFps && forced['fps'] !== undefined) {
        cs.fps = forced['fps'] as number;
      }
      if (policy.forbidResolution && forced['size'] !== undefined) {
        cs.size = forced['size'] as number;
      }
      if (policy.forbidBitrate && forced['bitrate'] !== undefined) {
        cs.bitrateMbps = forced['bitrate'] as number;
      }
      if (policy.forbidAudio && forced['audio'] !== undefined) {
        cs.audio = forced['audio'] as boolean;
      }
      if (policy.forbidAudio && forced['audio_gain'] !== undefined) {
        cs.audioGain = forced['audio_gain'] as number;
      }
    }
    return cs;
  }

  /**
   * P1-3「保存全局」：本地写入全局作用域 + 云端 POST /api/default_settings。
   * @returns true=云端下发成功（本地已存，云端失败不回滚但如实报 false）
   */
  static async pushGlobal(cs: ConnectionSettings): Promise<boolean> {
    await SettingsStore.save('', cs);
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return false;
    }
    const body: DefaultSettingsBody = {
      settings: {
        fps: cs.fps,
        size: cs.size,
        bitrate: cs.bitrateMbps,
        bwe: cs.bwe,
        minBitrate: cs.minBitrateMbps,
        maxBitrate: cs.maxBitrateMbps,
        audio: cs.audio,
        audio_gain: cs.audioGain,
        audio_source: cs.audioSource,
        audio_dup: cs.audioDup
      }
    };
    const url = `${httpScheme(useSsl)}${ip}/api/default_settings`;
    const res = await SettingsStore.http.postJson(url, body, token);
    if (!res.ok) {
      Logger.warn('SettingsStore', `云端下发失败: ${res.code}`);
      return false;
    }
    Logger.info('SettingsStore', '云端 default_settings 下发成功');
    return true;
  }

  /**
   * P0-9/P1-3：scrcpy_options 注入载荷（控制页与文件页 request-offer 同源复用）。
   * @param deviceId 按设备覆盖链（空=纯全局）；码率类 Mbps → bps ×1e6
   */
  static async buildInjectOptionsJson(deviceId: string): Promise<string> {
    const cs = await SettingsStore.loadMerged(deviceId);
    const opts: Record<string, Object> = {
      'max_fps': cs.fps,
      'max_size': cs.size,
      'bitrate': cs.bitrateMbps * 1000000,
      'min_bitrate': cs.minBitrateMbps * 1000000,
      'max_bitrate': cs.maxBitrateMbps * 1000000,
      'bwe': cs.bwe,
      'audio': cs.audio,
      'audio_gain': cs.audioGain,
      'audio_source': cs.audioSource,
      'audio_dup': cs.audioDup,
      'audio_low_latency': false,
      'video_codec_options': cs.videoCodecOptions
    };
    return JSON.stringify(opts);
  }

  /**
   * P1-3 热更闭环：服务端 global_settings_updated 广播 → 覆写**全局**键。
   * 只写 JSON 中出现的字段（部分下发安全）；由 DeviceList 装配监听时调用。
   */
  static async applyServerSettings(s: Record<string, Object>): Promise<void> {
    const p = Prefs.getInstance();
    if (s['fps'] !== undefined) {
      await p.putInt('connection_fps', s['fps'] as number);
    }
    if (s['size'] !== undefined) {
      await p.putInt('connection_size', s['size'] as number);
    }
    if (s['bitrate'] !== undefined) {
      await p.putInt('connection_bitrate', s['bitrate'] as number);
    }
    if (s['bwe'] !== undefined) {
      await p.putBoolean('connection_bwe', s['bwe'] as boolean);
    }
    if (s['minBitrate'] !== undefined) {
      await p.putInt('connection_min_bitrate', s['minBitrate'] as number);
    }
    if (s['maxBitrate'] !== undefined) {
      await p.putInt('connection_max_bitrate', s['maxBitrate'] as number);
    }
    if (s['audio'] !== undefined) {
      await p.putBoolean('connection_audio', s['audio'] as boolean);
    }
    if (s['audio_gain'] !== undefined) {
      await p.putFloat('connection_audio_gain', s['audio_gain'] as number);
    }
    if (s['audio_source'] !== undefined) {
      await p.putString('connection_audio_source', s['audio_source'] as string);
    }
    if (s['audio_dup'] !== undefined) {
      await p.putBoolean('connection_audio_dup', s['audio_dup'] as boolean);
    }
    Logger.info('SettingsStore', '已应用服务端全局设置热更新');
  }
}
