/**
 * ShortcutService —— 终端快捷指令域（P2-12 自定义快捷键，对应上游 DeviceConsole shortc—uts）
 *
 * 职责（单一）：{name, cmd} 指令表的加载链、增删改与双端同步。
 * 上游对齐（DeviceConsole.vue:1959-2029 实读）：
 *   - 6 条默认指令（三方应用/型号/当前页面/存储空间/轨迹开关）；
 *   - 加载链：GET /api/shortcuts（Bearer，非空才用）→ 本地 cloudphone_console_shortcuts
 *     → 默认表；
 *   - 保存：本地先落 → POST /api/shortcuts（数组整体提交，失败仅告警不回滚）。
 * UI 观察：AppStorage('shortcutsState') 时间戳（TerminalPage @StorageLink 刷新）。
 * 依赖：utils/{HttpClient,Prefs,Logger}。
 */
import { HttpClient, httpScheme } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Logger } from '../../utils/Logger';

/** Prefs 存储键（对齐上游 localStorage 同名） */
const SHORTCUTS_PREFS_KEY: string = 'cloudphone_console_shortcuts';

/** 单条快捷指令（wire schema 对齐上游 {name, cmd}） */
export class ShortcutItem {
  name: string = '';
  cmd: string = '';

  constructor(name: string = '', cmd: string = '') {
    this.name = name;
    this.cmd = cmd;
  }
}

/** 上游 defaultShortcuts 等价值（本地/云端均不可用时的兜底） */
function defaultShortcuts(): ShortcutItem[] {
  return [
    new ShortcutItem('三方应用', 'pm list packages -3'),
    new ShortcutItem('型号', 'getprop ro.product.model'),
    new ShortcutItem('当前页面', 'dumpsys window | grep mCurrentFocus | grep -v null'),
    new ShortcutItem('存储空间', 'df -h /data'),
    new ShortcutItem('开启触控轨迹', 'settings put system pointer_location 1'),
    new ShortcutItem('关闭轨迹', 'settings put system pointer_location 0')
  ];
}

export class ShortcutService {
  private static instance: ShortcutService | null = null;

  static getInstance(): ShortcutService {
    if (ShortcutService.instance === null) {
      ShortcutService.instance = new ShortcutService();
    }
    return ShortcutService.instance;
  }

  private http: HttpClient = new HttpClient();
  /** 当前指令表（执行区与编辑区共用数据源） */
  items: ShortcutItem[] = defaultShortcuts();
  /** 是否已走完加载链（TerminalPage 进页触发一次即可） */
  private loaded: boolean = false;

  private notify(): void {
    AppStorage.setOrCreate<number>('shortcutsState', Date.now());
  }

  /** wire 数组 JSON → items（逐项过滤 name/cmd 双全；坏 JSON 保留现表） */
  private hydrate(json: string): boolean {
    try {
      const arr = JSON.parse(json) as Object[];
      if (!Array.isArray(arr)) {
        return false;
      }
      const next: ShortcutItem[] = [];
      for (const one of arr) {
        const r = one as Record<string, Object>;
        const name = ((r['name'] as string) ?? '').trim();
        const cmd = ((r['cmd'] as string) ?? '').trim();
        if (name.length > 0 && cmd.length > 0) {
          next.push(new ShortcutItem(name, cmd));
        }
      }
      this.items = next;
      return true;
    } catch (e) {
      Logger.warn('ShortcutService', 'hydrate 失败');
      return false;
    }
  }

  /**
   * 加载链（幂等）：云端非空数组 → 本地缓存 → 默认表（上游顺序）。
   */
  async load(): Promise<void> {
    if (this.loaded) {
      return;
    }
    this.loaded = true;
    // ① 云端
    try {
      const token = await Prefs.getInstance().getToken();
      const ip = await Prefs.getInstance().getServerIp();
      const useSsl = await Prefs.getInstance().getUseSsl();
      if (token.length > 0 && ip.length > 0) {
        const url = `${httpScheme(useSsl)}${ip}/api/shortcuts`;
        const res = await this.http.getJson(url, token);
        if (res.ok) {
          const probe = JSON.parse(res.body) as Object[];
          if (Array.isArray(probe) && probe.length > 0 && this.hydrate(res.body)) {
            this.persistLocal();
            this.notify();
            return;
          }
        }
      }
    } catch (e) {
      Logger.warn('ShortcutService', '云端拉取失败，回退本地');
    }
    // ② 本地缓存
    const raw = await Prefs.getInstance().getString(SHORTCUTS_PREFS_KEY, '');
    if (raw.length > 0 && this.hydrate(raw)) {
      this.notify();
      return;
    }
    // ③ 默认表
    this.items = defaultShortcuts();
    this.notify();
  }

  private persistLocal(): void {
    Prefs.getInstance().putString(SHORTCUTS_PREFS_KEY, JSON.stringify(this.items)).catch(() => { return; });
  }

  /**
   * 保存整表（本地先落 → POST 数组；失败仅告警——上游同容错，下次 load 自愈）。
   * @returns true=云端同步成功
   */
  async save(): Promise<boolean> {
    this.notify();
    this.persistLocal();
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return false;
    }
    const url = `${httpScheme(useSsl)}${ip}/api/shortcuts`;
    const res = await this.http.postJson(url, this.items, token);
    if (!res.ok) {
      Logger.warn('ShortcutService', `云端同步失败: ${res.code}`);
      return false;
    }
    return true;
  }

  /** 追加一条（name/cmd 双全；重名替换） */
  add(name: string, cmd: string): boolean {
    const n = name.trim();
    const c = cmd.trim();
    if (n.length === 0 || c.length === 0) {
      return false;
    }
    this.items = this.items.filter((x: ShortcutItem): boolean => x.name !== n);
    this.items.push(new ShortcutItem(n, c));
    this.save().catch(() => { return; });
    return true;
  }

  /** 删除一条（按 name） */
  remove(name: string): void {
    this.items = this.items.filter((x: ShortcutItem): boolean => x.name !== name);
    this.save().catch(() => { return; });
  }

  /** 恢复默认表（丢弃自定义——用户显式动作） */
  resetToDefaults(): void {
    this.items = defaultShortcuts();
    this.save().catch(() => { return; });
  }
}
