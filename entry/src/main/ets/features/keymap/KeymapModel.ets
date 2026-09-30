/**
 * KeymapModel —— 键位映射编辑域的数据模型与编解码（P1-8b）
 *
 * 职责（单一）：config/profile/mapping 类型（**镜像上游 wire schema**，嵌套 pos/keys/center
 *   ——持久化 JSON 与 rawfile/js/keymap.js 引擎期望的格式逐字段一致，零转换落盘）、
 *   JSON hydrate（容错解析/缺省回落）与映射摘要文案。
 * 持久化键：cloudphone_keymap（ArkData preferences，对齐上游 localStorage 同名键）。
 * 上游基准：stores/keymap.js DEFAULT_CONFIG；utils/keymapEngine.js 消费字段。
 */

/** 位置（分数 0..1）：tap/wheel=pos；swipe=startPos/endPos；joystick=center */
export class KeymapPos {
  x: number = 0;
  y: number = 0;
}

/** 摇杆四键 */
export class KeymapKeys {
  up: string = '';
  down: string = '';
  left: string = '';
  right: string = '';
}

/** 单条映射（字段并集；engine 按 type 取用，多余字段无害） */
export class KeymapMapping {
  /** 唯一 id（p_ 时间戳或 m_ 时间戳，上游同款） */
  id: string = '';
  /** 映射类型（五选一）：tap、swipe、joystick、wheel、command */
  type: string = '';
  /** tap/swipe/command 触发键（小写比较） */
  key: string = '';
  /** command 型命令文本 */
  cmd: string = '';
  /** tap/wheel 位置 */
  pos: KeymapPos = new KeymapPos();
  /** swipe 起终点（duration 默认 150） */
  startPos: KeymapPos = new KeymapPos();
  endPos: KeymapPos = new KeymapPos();
  duration: number = 150;
  /** joystick 四键/中心/半径（半径按宽度比例） */
  keys: KeymapKeys = new KeymapKeys();
  center: KeymapPos = new KeymapPos();
  radius: number = 0.1;
  /** wheel 动作：scroll | zoom */
  action: string = 'scroll';
}

/** 档案 */
export class KeymapProfile {
  id: string = '';
  name: string = '';
  mappings: KeymapMapping[] = [];
}

/** 顶层配置（对齐上游 config 形状） */
export class KeymapConfig {
  activeProfileId: string = 'default';
  profiles: KeymapProfile[] = [];
}

/** 上游 DEFAULT_CONFIG 等价值（空存储/坏 JSON 的回落） */
export function defaultKeymapConfig(): KeymapConfig {
  const cfg = new KeymapConfig();
  const p = new KeymapProfile();
  p.id = 'default';
  p.name = 'Default Profile';
  cfg.activeProfileId = 'default';
  cfg.profiles = [p];
  return cfg;
}

/** 位置字段 hydrate（缺省 0） */
function hydratePos(v: Object | undefined): KeymapPos {
  const pos = new KeymapPos();
  if (v !== undefined && v !== null) {
    const r = v as Record<string, Object>;
    if (typeof r['x'] === 'number') {
      pos.x = r['x'] as number;
    }
    if (typeof r['y'] === 'number') {
      pos.y = r['y'] as number;
    }
  }
  return pos;
}

/** 单条映射 hydrate（坏 JSON 元素跳过；engine 消费字段全量对齐） */
function hydrateMapping(v: Object): KeymapMapping | null {
  const r = v as Record<string, Object>;
  const type = (r['type'] as string) ?? '';
  if (type.length === 0) {
    return null;
  }
  const m = new KeymapMapping();
  m.type = type;
  m.id = (r['id'] as string) ?? ('m_' + Date.now());
  m.key = (r['key'] as string) ?? '';
  m.cmd = (r['cmd'] as string) ?? '';
  m.action = (r['action'] as string) ?? 'scroll';
  m.pos = hydratePos(r['pos']);
  m.startPos = hydratePos(r['startPos']);
  m.endPos = hydratePos(r['endPos']);
  m.center = hydratePos(r['center']);
  if (typeof r['duration'] === 'number') {
    m.duration = r['duration'] as number;
  }
  if (typeof r['radius'] === 'number') {
    m.radius = r['radius'] as number;
  }
  const keys = r['keys'];
  if (keys !== undefined && keys !== null) {
    const kr = keys as Record<string, Object>;
    m.keys.up = (kr['up'] as string) ?? '';
    m.keys.down = (kr['down'] as string) ?? '';
    m.keys.left = (kr['left'] as string) ?? '';
    m.keys.right = (kr['right'] as string) ?? '';
  }
  return m;
}

/**
 * config JSON hydrate（容错：空串/坏 JSON/缺 profile → 默认配置；单条坏映射跳过）。
 */
export function parseKeymapConfig(json: string): KeymapConfig {
  if (json.length === 0) {
    return defaultKeymapConfig();
  }
  try {
    const root = JSON.parse(json) as Record<string, Object>;
    const cfg = new KeymapConfig();
    const profiles = root['profiles'];
    if (!Array.isArray(profiles) || profiles.length === 0) {
      return defaultKeymapConfig();
    }
    for (const pv of profiles as Object[]) {
      const pr = pv as Record<string, Object>;
      const profile = new KeymapProfile();
      profile.id = (pr['id'] as string) ?? ('p_' + Date.now());
      profile.name = (pr['name'] as string) ?? 'Profile';
      const ms = pr['mappings'];
      if (Array.isArray(ms)) {
        for (const mv of ms as Object[]) {
          const m = hydrateMapping(mv);
          if (m !== null) {
            profile.mappings.push(m);
          }
        }
      }
      cfg.profiles.push(profile);
    }
    cfg.activeProfileId = (root['activeProfileId'] as string) ?? cfg.profiles[0].id;
    return cfg;
  } catch (e) {
    return defaultKeymapConfig();
  }
}

/** 序列化（class → plain，嵌套结构与引擎期望逐字段一致） */
export function keymapConfigToJson(cfg: KeymapConfig): string {
  return JSON.stringify(cfg);
}

/** 当前激活档案（activeProfileId 失效时回落首个，上游同语义） */
export function activeProfile(cfg: KeymapConfig): KeymapProfile | null {
  for (const p of cfg.profiles) {
    if (p.id === cfg.activeProfileId) {
      return p;
    }
  }
  return cfg.profiles.length > 0 ? cfg.profiles[0] : null;
}

/** 映射摘要文案（列表行展示） */
export function mappingSummary(m: KeymapMapping): string {
  if (m.type === 'tap') {
    return `tap ${m.key} → (${m.pos.x.toFixed(2)}, ${m.pos.y.toFixed(2)})`;
  }
  if (m.type === 'swipe') {
    return `swipe ${m.key} (${m.startPos.x.toFixed(2)},${m.startPos.y.toFixed(2)})→(${m.endPos.x.toFixed(2)},${m.endPos.y.toFixed(2)}) ${m.duration}ms`;
  }
  if (m.type === 'joystick') {
    return `摇杆 ${m.keys.up}${m.keys.down}${m.keys.left}${m.keys.right} 心(${m.center.x.toFixed(2)},${m.center.y.toFixed(2)}) 半径${m.radius}`;
  }
  if (m.type === 'wheel') {
    return `wheel ${m.action} → (${m.pos.x.toFixed(2)}, ${m.pos.y.toFixed(2)})`;
  }
  if (m.type === 'command') {
    return `command ${m.key} → ${m.cmd}`;
  }
  return m.type;
}
