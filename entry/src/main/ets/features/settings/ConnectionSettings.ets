/**
 * ConnectionSettings —— 连接画质设置的数据模型与默认值（P1-3 设置体系）
 *
 * 职责（单一）：定义一份完整画质参数的字段、类型与安卓版默认值。
 * 持久化/覆盖链/策略应用 → features/settings/SettingsStore.ets；
 * 注入 request-offer → pages/ArkWebView.ets buildScrcpyOptionsJson。
 */
export class ConnectionSettings {
  /** 最大帧率 fps（connection_fps，默认 30；0=不限） */
  fps: number = 30;
  /** 最大分辨率最长边（connection_size，默认 2160；0=不限） */
  size: number = 2160;
  /** 固定码率 Mbps（connection_bitrate，默认 12；注入 ×1e6） */
  bitrateMbps: number = 12;
  /** 动态带宽估计（connection_bwe，默认 false） */
  bwe: boolean = false;
  /** BWE 下限 Mbps（connection_min_bitrate，默认 8） */
  minBitrateMbps: number = 8;
  /** BWE 上限 Mbps（connection_max_bitrate，默认 20） */
  maxBitrateMbps: number = 20;
  /** 音频回传（connection_audio，默认 true） */
  audio: boolean = true;
  /** 音频增益 0.5~3.0（connection_audio_gain，默认 1） */
  audioGain: number = 1;
  /** 采集源 'output'|'playback'（connection_audio_source，默认 output） */
  audioSource: string = 'output';
  /** 保留设备本地声音（connection_audio_dup，默认 true） */
  audioDup: boolean = true;
  /** agent 编码参数串（connection_video_codec_options，默认对齐上游 scrcpy 默认） */
  videoCodecOptions: string = 'intra-refresh-period=30,i-frame-interval=2,vendor.rtc-ext-enc-low-latency=1';
}
