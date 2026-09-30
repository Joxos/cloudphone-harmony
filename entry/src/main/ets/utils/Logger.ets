/**
 * 轻量日志封装（统一 tag 前缀，便于 hilog 过滤）
 */
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x3A01; // 自定义 domain

export class Logger {
  static info(tag: string, msg: string): void {
    hilog.info(DOMAIN, tag, '%{public}s', msg);
  }

  static warn(tag: string, msg: string): void {
    hilog.warn(DOMAIN, tag, '%{public}s', msg);
  }

  static error(tag: string, msg: string): void {
    hilog.error(DOMAIN, tag, '%{public}s', msg);
  }

  static debug(tag: string, msg: string): void {
    hilog.debug(DOMAIN, tag, '%{public}s', msg);
  }
}
