/**
 * GroupControl —— 群控从机组状态（P1-10，对应上游 stores/groupControl.js）
 *
 * 职责（单一）：从机选择集 + 主控绑定；跨页面同步经 AppStorage（列表选、控制页消费）。
 * 协作模型（对齐上游）：设备列表勾选从机 → 进入控制页即绑定为主控 →
 *   控制页输入事件**同时**走本机 input-channel 与 group_control_event 广播（input.js）。
 * 同步键：'groupSlavesJson'（从机 ID 数组 JSON，控制页启动时读取）、'groupState'（变更时间戳，
 *   DeviceList @StorageLink 刷新高亮）。
 */
import { Logger } from '../../utils/Logger';

export class GroupControl {
  private static instance: GroupControl | null = null;

  static getInstance(): GroupControl {
    if (GroupControl.instance === null) {
      GroupControl.instance = new GroupControl();
    }
    return GroupControl.instance;
  }

  /** 已勾选的从机设备 ID 集 */
  private slaves: Set<string> = new Set();
  /** 当前主控设备 ID（''=未绑定；控制页进入时 bindMaster） */
  masterId: string = '';

  /** 已选数量（工具栏展示） */
  get count(): number {
    return this.slaves.size;
  }

  /** 是否勾选（DeviceList 行高亮） */
  isSelected(deviceId: string): boolean {
    return this.slaves.has(deviceId);
  }

  /** 已选从机清单副本（P2-5 任务下发的目标源） */
  selectedIds(): string[] {
    const out: string[] = [];
    this.slaves.forEach((id: string) => {
      out.push(id);
    });
    return out;
  }

  /** 勾选/取消（行内「选」按钮；master 自身不入组） */
  toggle(deviceId: string): void {
    if (this.slaves.has(deviceId)) {
      this.slaves.delete(deviceId);
    } else {
      this.slaves.add(deviceId);
    }
    this.notify();
  }

  /** 全选一组（工具栏；ids 由调用方给在线列表） */
  selectAll(ids: string[]): void {
    for (const id of ids) {
      this.slaves.add(id);
    }
    this.notify();
  }

  /** 清空选择 */
  clear(): void {
    this.slaves.clear();
    this.notify();
  }

  /**
   * 控制页进入时绑定主控（P1-10）：从已选从机中剔除本机。
   * @returns 从机 ID 数组（空=未组成群组，控制页不广播）
   */
  bindMaster(masterDeviceId: string): string[] {
    this.masterId = masterDeviceId;
    const list: string[] = [];
    for (const id of this.slaves) {
      if (id !== masterDeviceId) {
        list.push(id);
      }
    }
    AppStorage.setOrCreate<string>('groupSlavesJson', JSON.stringify(list));
    Logger.info('GroupControl', `主控绑定 ${masterDeviceId} → 从机 ${list.length} 台`);
    return list;
  }

  /** 控制页退出：解除主控并清空从机组（对上游"退出即解散"语义简化） */
  unbindMaster(): void {
    if (this.masterId.length > 0) {
      this.slaves.clear();
      this.masterId = '';
      AppStorage.setOrCreate<string>('groupSlavesJson', '[]');
      this.notify();
      Logger.info('GroupControl', '主控解除，群组解散');
    }
  }

  /** 变更通知（DeviceList @StorageLink('groupState') 触发高亮刷新） */
  private notify(): void {
    AppStorage.setOrCreate<number>('groupState', Date.now());
  }
}
