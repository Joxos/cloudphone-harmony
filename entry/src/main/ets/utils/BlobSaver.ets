/**
 * BlobSaver —— 字节落盘工具（P2-1a/P2-6 共用）
 *
 * 职责（单一）：Uint8Array → 系统文件选择器写盘（DocumentViewPicker 免存储权限，
 *   用户选位置即获授权），结果以回调透出（调用方决定 toast 语义）。
 * 消费方：ArkWebView.saveShotPng（P2-6 截图）、FileCenterPage.saveFile（P2-1 下载）。
 */
import { common } from '@kit.AbilityKit';
import { picker, fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../utils/Logger';

export class BlobSaver {
  /**
   * 保存字节数组为文件。
   * @param context  UI 上下文（选择器需要）
   * @param bytes    文件内容
   * @param fileName 建议文件名（DocumentSaveOptions.newFileNames 数组承载）
   * @returns 'ok'=写盘成功；'cancel'=用户取消（空数组）；'error'=异常
   */
  static async save(context: common.Context, bytes: Uint8Array, fileName: string): Promise<string> {
    try {
      const ctx = context as common.UIAbilityContext;
      const view = new picker.DocumentViewPicker(ctx);
      // DocumentSaveOptions 字段为 newFileNames: string[]（本 SDK 无 fileName）
      const uris = await view.save({ newFileNames: [fileName] });
      if (uris.length === 0) {
        return 'cancel';
      }
      const file = fileIo.openSync(uris[0],
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, bytes.buffer);
      fileIo.closeSync(file);
      return 'ok';
    } catch (e) {
      Logger.warn('BlobSaver', '保存取消或失败');
      return 'error';
    }
  }

  /** base64 → Uint8Array（页面 saveFile 出口用） */
  static fromBase64(b64: string): Uint8Array {
    return new util.Base64Helper().decodeSync(b64);
  }
}
