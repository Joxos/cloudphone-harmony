/**
 * TaskService —— 群控批量任务域（P2-5a，对应上游 DeviceConsole 批量任务 + devices.js 追踪）
 *
 * 职责（单一）：POST /api/tasks 创建、GET /api/tasks/details 轮询追踪、
 *   task_status_updated 广播合并、任务看板状态通知。
 * 契约（DeviceConsole/devices.js 实读）：
 *   - create：POST 载荷含 type、targets 设备数组、payload 命令与可选 dest_path；
 *     成功返回 status success 加 task_id；失败体带 error 字段（均据此透出）
 *   - details：GET ?task_id= → **直接** {devices:{id:{status, output?}}}（无外层包裹）
 *   - 追踪：2s 轮询直至全部终态（success/failed）；广播可提前合并（双通道）
 *   - 后端 admin-only（DeviceConsole:1312 注）——403 由 create 的 error 透出
 * UI 观察：AppStorage('taskState') 时间戳。
 * 依赖：utils/{HttpClient,Prefs,Logger}；model.ChannelLike（名义类型订阅）。
 */
import { HttpClient, httpScheme, normalizeHost } from '../../utils/HttpClient';
import { Prefs } from '../../utils/Prefs';
import { Logger } from '../../utils/Logger';
import { ChannelLike } from '../../model/Model';

/** 单设备任务子状态 */
export class TaskDeviceState {
  /** 状态取值：running、success、failed 三态 */
  status: string = '';
  output: string = '';
}

/** 追踪中/最近一次任务的看板状态 */
export class TaskBoard {
  taskId: string = '';
  /** deviceId → 子状态 */
  devices: Map<string, TaskDeviceState> = new Map();

  /** 统计（看板头部） */
  counts(): number[] {
    let running = 0;
    let success = 0;
    let failed = 0;
    this.devices.forEach((s: TaskDeviceState) => {
      if (s.status === 'running') {
        running++;
      } else if (s.status === 'success') {
        success++;
      } else if (s.status === 'failed') {
        failed++;
      }
    });
    return [running, success, failed];
  }

  /** 是否全部终态 */
  allDone(): boolean {
    if (this.devices.size === 0) {
      return true;
    }
    let done = true;
    this.devices.forEach((s: TaskDeviceState) => {
      if (s.status !== 'success' && s.status !== 'failed') {
        done = false;
      }
    });
    return done;
  }

  /** 展示行序（device_id 升序不必要——Map 插入序即下发序） */
  deviceIds(): string[] {
    const out: string[] = [];
    this.devices.forEach((_v: TaskDeviceState, id: string) => {
      out.push(id);
    });
    return out;
  }
}

/** create 请求体（显式 interface 规避字面量禁令；dest_path 仅 push_file 需要） */
interface CreateTaskBody {
  type: string;
  targets: string[];
  payload: string;
  dest_path: string;
}

export class TaskService {
  private static instance: TaskService | null = null;

  static getInstance(): TaskService {
    if (TaskService.instance === null) {
      TaskService.instance = new TaskService();
    }
    return TaskService.instance;
  }

  private http: HttpClient = new HttpClient();
  /** 看板状态（服务单例持有，页面 @StorageLink 观察） */
  board: TaskBoard = new TaskBoard();
  /** 轮询句柄（2s；全终态自停） */
  private timer: number = -1;

  private notify(): void {
    AppStorage.setOrCreate<number>('taskState', Date.now());
  }

  /**
   * 下发批量任务（上游 DeviceConsole 同形；admin-only 失败透出 error）。
   * @param destPath push_file 类必填（手机端目标绝对路径）；其余类型传 ''
   */
  async createTask(type: string, targets: string[], payload: string, destPath: string = ''): Promise<string> {
    if (targets.length === 0) {
      return '未选择目标设备';
    }
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return '未登录';
    }
    const body: CreateTaskBody = {
      type: type,
      targets: targets,
      payload: payload,
      dest_path: destPath
    };
    const url = `${httpScheme(useSsl)}${ip}/api/tasks`;
    const res = await this.http.postJson(url, body, token);
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      if (res.ok && (root['status'] as string) === 'success') {
        const taskId = (root['task_id'] as string) ?? '';
        this.startTracking(taskId);
        Logger.info('TaskService', `任务已下发 ${taskId} targets=${targets.length}`);
        return '';
      }
      return (root['error'] as string) ?? `HTTP ${res.code}`;
    } catch (e) {
      return `HTTP ${res.code}`;
    }
  }

  /** 立即拉一次详情并启动 2s 轮询（全终态自停——上游 startTrackingTask 语义） */
  startTracking(taskId: string): void {
    this.stopTracking();
    this.board = new TaskBoard();
    this.board.taskId = taskId;
    this.notify();
    this.pollOnce(taskId);
    this.timer = setInterval(() => {
      this.pollOnce(taskId);
    }, 2000);
  }

  /** 停止轮询（新任务/页面退出可调；看板状态保留供回看） */
  stopTracking(): void {
    if (this.timer !== -1) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  /** 手动立即刷新（看板「刷新」按钮；无任务时无操作） */
  manualRefresh(): void {
    if (this.board.taskId.length > 0) {
      this.pollOnce(this.board.taskId).catch(() => { return; });
    }
  }

  /** 单次详情拉取（GET /api/tasks/details → 直形状 {devices}） */
  private async pollOnce(taskId: string): Promise<void> {
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (ip.length === 0) {
      return;
    }
    const url = `${httpScheme(useSsl)}${ip}/api/tasks/details?task_id=${encodeURIComponent(taskId)}`;
    const res = await this.http.getJson(url, token);
    if (!res.ok) {
      Logger.warn('TaskService', `details 拉取失败: ${res.code}`);
      return;
    }
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      this.hydrateDevices(root['devices']);
      this.notify();
      if (this.board.allDone()) {
        this.stopTracking();
        Logger.info('TaskService', `任务完成 ${taskId}`);
      }
    } catch (e) {
      Logger.warn('TaskService', 'details 解析失败');
    }
  }

  /** devices 映射 → 看板（全量替换——上游 currentTask 整体赋值同语义） */
  private hydrateDevices(raw: Object | undefined): void {
    if (raw === undefined || raw === null) {
      return;
    }
    const map = raw as Record<string, Object>;
    const next = new Map<string, TaskDeviceState>();
    for (const id of Object.keys(map)) {
      const sub = map[id] as Record<string, Object>;
      const st = new TaskDeviceState();
      st.status = (sub['status'] as string) ?? '';
      st.output = (sub['output'] as string) ?? '';
      next.set(id, st);
    }
    this.board.devices = next;
  }

  /**
   * task_status_updated 广播合并（经 DeviceList 装配注册；task 形状同 details 子集）。
   * 仅当广播 task_id 与当前看板一致（或看板未设）时覆盖，防串台。
   */
  onChannelMessage(msg: Record<string, Object>): void {
    const task = msg['task'];
    if (task === undefined || task === null) {
      return;
    }
    const t = task as Record<string, Object>;
    const broadcastId = (t['task_id'] as string) ?? '';
    if (broadcastId.length > 0 && this.board.taskId.length > 0 && broadcastId !== this.board.taskId) {
      return; // 别的任务的广播，忽略
    }
    if (broadcastId.length > 0 && this.board.taskId.length === 0) {
      this.board.taskId = broadcastId;
    }
    this.hydrateDevices(t['devices']);
    this.notify();
    if (this.board.allDone()) {
      this.stopTracking();
    }
  }

  /** 接线用：GlobalChannel 监听注册（DeviceList 装配根调用） */
  static register(channel: ChannelLike): void {
    channel.on('task_status_updated', (msg: Record<string, Object>): void => {
      TaskService.getInstance().onChannelMessage(msg);
    });
    Logger.info('TaskService', 'task_status_updated 监听已注册');
  }

  // ===================== P2-5b：文件任务（/upload 上传 + 签名 URL） =====================

  /**
   * 上传文件到服务器（上游 uploadFileToServer 同形：POST /upload?name= 原始字节体）。
   * @returns ''=成功；否则错误说明（网络/HTTP 状态透出）
   */
  async uploadFile(fileName: string, bytes: Uint8Array): Promise<string> {
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return '未登录';
    }
    const url = `${httpScheme(useSsl)}${ip}/upload?name=${encodeURIComponent(fileName)}`;
    const res = await this.http.postRaw(url, bytes, token);
    if (!res.ok) {
      Logger.warn('TaskService', `上传失败: ${res.code} ${res.error}`);
      return res.code > 0 ? `HTTP ${res.code}` : res.error;
    }
    Logger.info('TaskService', `已上传 ${fileName}（${bytes.length} 字节）`);
    return '';
  }

  /**
   * 获取签名下载地址（上游 fetchSignedFileURL 同形：/api/files/url → {url}，
   * 10 分钟有效；客户端拼 scheme://host 前缀）。
   * @returns 成功返回完整 URL；失败返回空串
   */
  async signedFileUrl(fileName: string): Promise<string> {
    const token = await Prefs.getInstance().getToken();
    const ip = await Prefs.getInstance().getServerIp();
    const useSsl = await Prefs.getInstance().getUseSsl();
    if (token.length === 0 || ip.length === 0) {
      return '';
    }
    const url = `${httpScheme(useSsl)}${ip}/api/files/url?name=${encodeURIComponent(fileName)}`;
    const res = await this.http.getJson(url, token);
    if (!res.ok) {
      Logger.warn('TaskService', `签名失败: ${res.code} ${res.body}`);
      return '';
    }
    try {
      const root = JSON.parse(res.body) as Record<string, Object>;
      const path = (root['url'] as string) ?? '';
      if (path.length === 0) {
        return '';
      }
      return `${httpScheme(useSsl)}${normalizeHost(ip)}${path}`;
    } catch (e) {
      return '';
    }
  }
}
