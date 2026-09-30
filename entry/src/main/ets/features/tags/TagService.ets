/**
 * TagService —— 设备标签域（P2-10，对应上游 stores/tags.js）
 *
 * 职责（单一）：标签与设备映射的内存态、本地持久化、云端同步、tags_update 广播更新。
 * 上游规范逐条对齐：
 *   - 存储键 cloudphone_device_tags_v1（{tags, deviceTags}）；
 *   - 默认 8 色板、name trim 后大小写不敏感唯一、color 须匹配 #rrggbb 否则回落首色；
 *   - id 形如 tag_<36进制时间>_<随机>；deviceTags 只保留合法 tag id 且非空数组；
 *   - 云端 GET/POST /api/tags 均 requireAdmin（服务端收口）——非 200 视为无权限，清本地并提示；
 *   - 本地优先启动（loadLocal → 云端合并），云端失败保留本地（下次 load 自愈）。
 * 同步：变更即 POST；广播经 GlobalChannel('tags_update') → updateFromRemote（DeviceList 装配）。
 * UI 观察：AppStorage('tagsState') 时间戳通知（与 groupState 同模式）。
 * 依赖：utils/{HttpClient,Prefs,Logger}；标签 JSON 为服务端契约，不入 model。
 */
import { HttpClient, httpScheme } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Logger } from '../../utils/Logger';

/** 上游 DEFAULT_TAG_COLORS（唯一样式真源） */
const DEFAULT_TAG_COLORS: string[] = [
  '#38bdf8', '#22c55e', '#f59e0b', '#ef4444',
  '#a78bfa', '#14b8a6', '#f97316', '#e879f9'
];
/** Prefs 存储键（对齐上游 localStorage 同名） */
const TAGS_PREFS_KEY: string = 'cloudphone_device_tags_v1';

/** 单个标签（wire schema 对齐上游 {id,name,color}） */
export class TagItem {
  id: string = '';
  name: string = '';
  color: string = '';
}

/** GET/POST /api/tags 请求体（显式类型规避无类型对象字面量） */
interface TagsBody {
  tags: TagItem[];
  deviceTags: Record<string, string[]>;
}

export class TagService {
  private static instance: TagService | null = null;

  static getInstance(): TagService {
    if (TagService.instance === null) {
      TagService.instance = new TagService();
    }
    return TagService.instance;
  }

  private http: HttpClient = new HttpClient();
  /** 标签表（顺序即展示顺序） */
  tags: TagItem[] = [];
  /** 设备 → tag id 数组（只存合法 id） */
  private deviceTags: Map<string, string[]> = new Map();
  /** 列表筛选选中的标签 id（单选，上游 setSelectedTag 同语义） */
  private selectedTagId: string = '';

  // ===================== 归一化（上游 normalize 同款纯逻辑） =====================

  private normalizeName(name: string): string {
    return name.trim();
  }

  private normalizeColor(color: string): string {
    const v = color.trim();
    return /^#[0-9a-fA-F]{6}$/.test(v) ? v : DEFAULT_TAG_COLORS[0];
  }

  /** name 是否已存在（大小写不敏感；excludeId 用于编辑自身） */
  tagNameExists(name: string, excludeId: string = ''): boolean {
    const n = this.normalizeName(name).toLowerCase();
    if (n.length === 0) {
      return false;
    }
    for (const t of this.tags) {
      if (t.id !== excludeId && t.name.toLowerCase() === n) {
        return true;
      }
    }
    return false;
  }

  /** 上游 createTagId：tag_<36进制毫秒>_<随机 6> */
  private createTagId(): string {
    const rand = Math.random().toString(36).slice(2, 8);
    return `tag_${Date.now().toString(36)}_${rand}`;
  }

  // ===================== 装配与持久化 =====================

  /** 变更后通知 UI（DeviceList @StorageLink('tagsState') 刷新） */
  private notify(): void {
    AppStorage.setOrCreate<number>('tagsState', Date.now());
  }

  /** 内存态 → Prefs（上游 persist） */
  private persist(): void {
    const body: TagsBody = { tags: this.tags, deviceTags: this.mapToObj() };
    Prefs.getInstance().putString(TAGS_PREFS_KEY, JSON.stringify(body)).catch(() => { return; });
  }

  private mapToObj(): Record<string, string[]> {
    const obj: Record<string, string[]> = {};
    this.deviceTags.forEach((ids: string[], devId: string) => {
      obj[devId] = ids;
    });
    return obj;
  }

  /**
   * wire JSON → 内存态（容错：tags 逐项归一化，deviceTags 过滤非法 id/空数组）。
   * @param json {tags, deviceTags} 形状 JSON 文本
   * @returns 是否解析出至少一个合法标签（false=视为无数据）
   */
  hydrate(json: string): boolean {
    this.tags = [];
    this.deviceTags = new Map();
    if (json.length === 0) {
      return false;
    }
    try {
      const root = JSON.parse(json) as Record<string, Object>;
      const tagArr = root['tags'];
      if (Array.isArray(tagArr)) {
        for (const tv of tagArr as Object[]) {
          const tr = tv as Record<string, Object>;
          const name = this.normalizeName((tr['name'] as string) ?? '');
          if (name.length === 0) {
            continue;
          }
          const t = new TagItem();
          t.id = ((tr['id'] as string) ?? '').length > 0 ? (tr['id'] as string) : this.createTagId();
          t.name = name;
          t.color = this.normalizeColor((tr['color'] as string) ?? '');
          this.tags.push(t);
        }
      }
      const allowed = new Set(this.tags.map((t: TagItem): string => t.id));
      const dt = root['deviceTags'];
      if (dt !== undefined && dt !== null) {
        const dtr = dt as Record<string, Object>;
        for (const devId of Object.keys(dtr)) {
          const ids = dtr[devId];
          if (devId.length === 0 || !Array.isArray(ids)) {
            continue;
          }
          const next: string[] = [];
          const seen = new Set<string>();
          for (const one of ids as Object[]) {
            if (typeof one === 'string' && allowed.has(one) && !seen.has(one)) {
              seen.add(one);
              next.push(one);
            }
          }
          if (next.length > 0) {
            this.deviceTags.set(devId, next);
          }
        }
      }
      this.notify();
      return this.tags.length > 0;
    } catch (e) {
      Logger.warn('TagService', 'hydrate 解析失败');
      return false;
    }
  }

  /** 本地优先加载：先 Prefs 再云端合并（上游 load 顺序） */
  async load(): Promise<void> {
    Prefs.getInstance().getString(TAGS_PREFS_KEY, '').then((raw: string) => {
      if (raw.length > 0) {
        this.hydrate(raw);
      }
      return this.fetchRemote();
    }).catch(() => { return; });
  }

  /** GET /api/tags → 合并 + 回存（非 200=无权限/失败，清本地对齐上游非管理员行为） */
  private async fetchRemote(): Promise<void> {
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return;
    }
    const url = `${httpScheme(useSsl)}${ip}/api/tags`;
    const res = await this.http.getJson(url, token);
    if (res.ok) {
      if (this.hydrate(res.body)) {
        this.persist();
      }
      Logger.info('TagService', `云端标签同步: ${this.tags.length} 个`);
    } else if (res.code === 401 || res.code === 403) {
      // 非管理员（requireAdmin 收口）：清空本地，避免旧标签残留展示（上游同策略）
      this.tags = [];
      this.deviceTags = new Map();
      this.selectedTagId = '';
      Prefs.getInstance().putString(TAGS_PREFS_KEY, '').catch(() => { return; });
      this.notify();
      Logger.info('TagService', `非管理员(${res.code})，标签清空`);
    } else {
      Logger.warn('TagService', `标签拉取失败: ${res.code}（保留本地缓存）`);
    }
  }

  /** POST /api/tags（本地先行，服务端失败下次 load 自愈——上游 saveAndSync 同容错） */
  private async save(): Promise<boolean> {
    this.persist();
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return false;
    }
    const url = `${httpScheme(useSsl)}${ip}/api/tags`;
    const body: TagsBody = { tags: this.tags, deviceTags: this.mapToObj() };
    const res = await this.http.postJson(url, body, token);
    if (!res.ok) {
      Logger.warn('TagService', `标签保存失败: ${res.code}`);
      return false;
    }
    return true;
  }

  // ===================== 变更操作（上游 create/update/delete/toggle） =====================

  /** 新建标签（name 唯一校验；color 回落首色） */
  async createTag(name: string, color: string): Promise<boolean> {
    const n = this.normalizeName(name);
    if (n.length === 0 || this.tagNameExists(n)) {
      return false;
    }
    const t = new TagItem();
    t.id = this.createTagId();
    t.name = n;
    t.color = this.normalizeColor(color);
    this.tags.push(t);
    this.notify();
    await this.save();
    return true;
  }

  /** 编辑标签（name 唯一校验，排除自身） */
  async updateTag(id: string, name: string, color: string): Promise<boolean> {
    const idx = this.tags.findIndex((t: TagItem): boolean => t.id === id);
    if (idx < 0) {
      return false;
    }
    const n = this.normalizeName(name);
    if (n.length === 0 || this.tagNameExists(n, id)) {
      return false;
    }
    const t = this.tags[idx];
    t.name = n;
    t.color = this.normalizeColor(color);
    this.notify();
    await this.save();
    return true;
  }

  /** 删除标签（连带清各设备映射） */
  async deleteTag(id: string): Promise<void> {
    this.tags = this.tags.filter((t: TagItem): boolean => t.id !== id);
    this.deviceTags.forEach((ids: string[], devId: string) => {
      const next = ids.filter((x: string): boolean => x !== id);
      if (next.length > 0) {
        this.deviceTags.set(devId, next);
      } else {
        this.deviceTags.delete(devId);
      }
    });
    if (this.selectedTagId === id) {
      this.selectedTagId = '';
    }
    this.notify();
    await this.save();
  }

  /** 设备打标切换（toggle；空集删除映射） */
  async toggleDeviceTag(deviceId: string, tagId: string): Promise<void> {
    if (deviceId.length === 0 || !this.tags.some((t: TagItem): boolean => t.id === tagId)) {
      return;
    }
    const cur = this.deviceTags.get(deviceId) ?? [];
    let next: string[];
    if (cur.indexOf(tagId) >= 0) {
      next = cur.filter((x: string): boolean => x !== tagId);
    } else {
      next = [...cur, tagId];
    }
    if (next.length > 0) {
      this.deviceTags.set(deviceId, next);
    } else {
      this.deviceTags.delete(deviceId);
    }
    this.notify();
    await this.save();
  }

  // ===================== 查询与筛选 =====================

  /** 设备当前标签（无则空数组） */
  getTagsForDevice(deviceId: string): TagItem[] {
    const ids = this.deviceTags.get(deviceId) ?? [];
    const out: TagItem[] = [];
    for (const id of ids) {
      const t = this.tags.find((x: TagItem): boolean => x.id === id);
      if (t !== undefined) {
        out.push(t);
      }
    }
    return out;
  }

  /** 设备是否命中当前筛选（未选=全通） */
  matchesFilter(deviceId: string): boolean {
    if (this.selectedTagId.length === 0) {
      return true;
    }
    const ids = this.deviceTags.get(deviceId) ?? [];
    return ids.indexOf(this.selectedTagId) >= 0;
  }

  /** 列表筛选选中（'' = 清除，上游 setSelectedTag 同语义） */
  setSelectedTag(id: string): void {
    this.selectedTagId = (id === this.selectedTagId) ? '' : id;
    this.notify();
  }

  get selectedId(): string {
    return this.selectedTagId;
  }

  // ===================== 广播入口 =====================

  /**
   * tags_update 广播（GlobalChannel → DeviceList 装配调用）。
   * @param tagsJson / devTagsJson 服务端载荷字段的序列化文本
   */
  updateFromRemote(tagsJson: string, devTagsJson: string): void {
    // 组装成 hydrate 期望的 {tags, deviceTags} 形状（广播载荷是两字段分发）；
    // 空数组也照常应用（管理员删光标签时清空陈旧本地态）
    const composed = `{"tags":${tagsJson.length > 0 ? tagsJson : '[]'},"deviceTags":${devTagsJson.length > 0 ? devTagsJson : '{}'}}`;
    this.hydrate(composed);
    this.persist();
  }
}
