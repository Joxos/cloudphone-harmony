/**
 * fileproto.js —— 文件通道协议（P2-1a，对应上游 FileManagerPage handleFileChannelMessage 与命令族）
 *
 * 职责（单一）：file-channel 的命令下发、8 类 JSON 回复分发、二进制下载块组装。
 * 协议（上游实读）：
 *   命令：list{path}、mkdir{path}、delete{path}、download_start{path,request_id}；
 *        （upload_start/upload_ack/install_apk 属 P2-1b 上传与安装批）
 *   回复：list_reply{success,path,files,error}、mkdir_reply、delete_reply、
 *        download_reply{success,size,error,request_id} + 后续裸二进制块（无 id，单活动会话）；
 *   完成判定：loaded >= total（total=0 空文件直接完成——上游 handleDownloadChunk 同语义）。
 * 事件出口：window.__fp.{onState,onList,onOp,onDownloadProgress,onDownloadDone,onError}
 *   ——file.html 内联 UI 订阅；测试经 window.__fpApi（显式 window 赋值，沙箱可直呼）。
 */
'use strict';

/** 当前通道（peer.js 式反向？否——file-channel 由本页主动创建，fileboot 接线） */
var fpChannel = null;
/** 下载会话表：request_id → {path, parts, total, loaded}（块流无 id，依赖单活动会话约定） */
var fpDownloads = {};
/** 当前活动下载 id（上游 activeDownloadSession 同语义） */
var fpActiveDownload = '';
/** request_id 自增 */
var fpSeq = 0;

/** 事件总线（UI 置空即静默；默认 null） */
window.__fp = {
  onState: null,          // (ready:boolean)
  onList: null,           // (msg)
  onOp: null,             // (type, success, error)
  onDownloadProgress: null, // (path, loaded, total)
  onDownloadDone: null,   // (path, bytes:Uint8Array)
  onUploadProgress: null, // (path, loaded, total)
  onUploadDone: null,     // (path)
  onUploadFail: null,     // (path, reason)
  onInstall: null,        // (status, message, path)
  onError: null,          // (msg)
  onOther: null           // (msg) 未知类型透传
};

/** 上传会话（单活动——上游 hasActiveUpload 同语义）：{file, destPath, offset, installOnFinish} */
var fpUpload = null;
/** 安装会话（单活动）：{path} */
var fpInstall = null;

/** 通道是否可用 */
function fpReady() {
  return fpChannel !== null && fpChannel.readyState === 'open';
}

/** 发送 JSON 命令（未就绪 false——上游 sendFileChannelCmd 同语义） */
function fpSendCmd(cmd) {
  if (!fpReady()) {
    console.warn('[FileChannel] 通道未就绪，命令丢弃: ' + cmd.type);
    return false;
  }
  fpChannel.send(JSON.stringify(cmd));
  return true;
}

/**
 * 接管 file-channel（fileboot 在 pc.createDataChannel('file-channel') 后调用）。
 * 二进制=下载块；文本=回复分发。
 */
function attachFileChannel(ch) {
  fpChannel = ch;
  try {
    ch.binaryType = 'arraybuffer';
  } catch (e) {
    // 只读属性忽略
  }
  ch.onopen = function () {
    if (window.__fp.onState) window.__fp.onState(true);
  };
  ch.onclose = function () {
    fpDownloads = {};
    fpActiveDownload = '';
    if (window.__fp.onState) window.__fp.onState(false);
  };
  ch.onerror = function () {
    if (window.__fp.onState) window.__fp.onState(false);
  };
  ch.onmessage = function (ev) {
    fpDispatch(ev.data);
  };
}

/** 分发入口：ArrayBuffer → 下载块；文本 → JSON 回复族 */
function fpDispatch(data) {
  if (data instanceof ArrayBuffer) {
    fpHandleDownloadChunk(data);
    return;
  }
  try {
    const msg = JSON.parse(data);
    switch (msg.type) {
      case 'list_reply':
        if (!msg.success && window.__fp.onError) {
          window.__fp.onError('读取列表失败: ' + (msg.error || ''));
        }
        if (window.__fp.onList) window.__fp.onList(msg);
        break;
      case 'mkdir_reply':
      case 'delete_reply':
        if (window.__fp.onOp) window.__fp.onOp(msg.type, !!msg.success, msg.error || '');
        if (msg.success === false && window.__fp.onError) {
          window.__fp.onError((msg.type === 'mkdir_reply' ? '建目录失败: ' : '删除失败: ') + (msg.error || ''));
        }
        break;
      case 'download_reply':
        fpHandleDownloadReply(msg);
        break;
      case 'upload_reply':
        fpHandleUploadReply(msg);
        break;
      case 'upload_ack':
        fpHandleUploadAck(msg);
        break;
      case 'install_status':
        fpHandleInstallStatus(msg);
        break;
      default:
        // P2-1b（upload/install）与未知类型透传给通用钩子
        if (window.__fp.onOther) window.__fp.onOther(msg);
        break;
    }
  } catch (e) {
    if (window.__fp.onError) window.__fp.onError('回复解析失败');
  }
}

/** download_reply：失败→结束会话并报错；成功→登记 total（0=空文件立即完成） */
function fpHandleDownloadReply(msg) {
  const rid = String(msg.request_id ?? '');
  const key = (rid !== 'undefined' && fpDownloads[rid]) ? rid : fpActiveDownload;
  const session = fpDownloads[key];
  if (!session) {
    return;
  }
  if (!msg.success) {
    delete fpDownloads[key];
    if (fpActiveDownload === key) fpActiveDownload = '';
    if (window.__fp.onError) window.__fp.onError('下载失败: ' + (msg.error || '未知错误'));
    if (window.__fp.onOp) window.__fp.onOp('download_reply', false, msg.error || '');
    return;
  }
  session.total = Number(msg.size ?? session.total) || 0;
  if (session.total === 0) {
    fpFinishDownload(key);
  } else if (window.__fp.onDownloadProgress) {
    window.__fp.onDownloadProgress(session.path, session.loaded, session.total);
  }
}

/** 裸二进制块：推进活动会话（无 request_id，上游单活动会话约定） */
function fpHandleDownloadChunk(buf) {
  const session = fpDownloads[fpActiveDownload];
  if (!session) {
    return;
  }
  session.parts.push(buf);
  session.loaded += buf.byteLength;
  if (window.__fp.onDownloadProgress) {
    window.__fp.onDownloadProgress(session.path, session.loaded, session.total);
  }
  if (session.total > 0 && session.loaded >= session.total) {
    fpFinishDownload(fpActiveDownload);
  }
}

/** 组装并回调（parts 拼接为 Uint8Array；会话出队） */
function fpFinishDownload(key) {
  const session = fpDownloads[key];
  if (!session) {
    return;
  }
  let bytes = new Uint8Array(session.loaded);
  let off = 0;
  for (const part of session.parts) {
    const u8 = new Uint8Array(part);
    bytes.set(u8, off);
    off += u8.length;
  }
  delete fpDownloads[key];
  if (fpActiveDownload === key) fpActiveDownload = '';
  if (window.__fp.onDownloadDone) window.__fp.onDownloadDone(session.path, bytes);
}

/** 浏览目录 */
function fpList(path) {
  return fpSendCmd({ type: 'list', path: path });
}

/** 建目录 */
function fpMkdir(path) {
  return fpSendCmd({ type: 'mkdir', path: path });
}

/** 删除（文件或目录） */
function fpDelete(path) {
  return fpSendCmd({ type: 'delete', path: path });
}

/**
 * 发起下载：登记会话并下发 download_start。
 * @returns false=通道不可用或已有活动下载（顺序队列由 UI 层调度——上游 startNextDownload 语义）
 */
function fpDownloadStart(path) {
  if (!fpReady() || fpActiveDownload !== '') {
    return false;
  }
  fpSeq++;
  const rid = 'dl_' + fpSeq;
  fpDownloads[rid] = { path: path, parts: [], total: 0, loaded: 0 };
  fpActiveDownload = rid;
  const sent = fpSendCmd({ type: 'download_start', path: path, request_id: rid });
  if (!sent) {
    delete fpDownloads[rid];
    fpActiveDownload = '';
  }
  return sent;
}

/** 显式 API（window 赋值 → 测试沙箱可直呼；UI 也用同一入口） */
window.__fpApi = {
  attach: attachFileChannel,
  ready: fpReady,
  list: fpList,
  mkdir: fpMkdir,
  del: fpDelete,
  downloadStart: fpDownloadStart,
  uploadStart: fpUploadStart,
  installApk: fpInstallApk,
  dispatch: fpDispatch
};

// ===================== P2-1b：上传（sha256 → upload_start → 16KB 分块 → ack） =====================

/** 单分片发送：就绪 + 512KB 流控（上游 sendFileChannelChunk 同语义） */
function fpSendChunk(buf) {
  if (!fpReady()) {
    return false;
  }
  if (fpChannel.bufferedAmount > 512 * 1024) {
    return false;
  }
  try {
    fpChannel.send(buf);
    return true;
  } catch (e) {
    return false;
  }
}

/**
 * 发起上传（单活动；sha256 增量计算后下发 upload_start）。
 * @param file 类 Blob（size/slice().arrayBuffer()/name）
 * @param destPath 目标路径（UI 用 joinPath(当前目录, 文件名) 计算）
 * @param installOnFinish 传 true=APK 上传完成后安装（上游 confirm 语义由 UI 决定）
 * @returns Promise<boolean> false=通道不可用/已在上传（上游 alert 语义由 UI 承接）
 */
function fpUploadStart(file, destPath, installOnFinish) {
  if (!fpReady()) {
    return Promise.resolve(false);
  }
  if (fpUpload !== null) {
    return Promise.resolve(false);
  }
  return Promise.resolve(window.hashFileIncremental(file)).then((sha) => {
    fpUpload = { file: file, destPath: destPath, offset: 0, installOnFinish: !!installOnFinish };
    const sent = fpSendCmd({
      type: 'upload_start',
      path: destPath,
      size: file.size,
      sha256: sha,
      install_on_finish: !!installOnFinish
    });
    if (!sent) {
      fpUpload = null;
      return false;
    }
    if (window.__fp.onUploadProgress) window.__fp.onUploadProgress(destPath, 0, file.size);
    return true;
  }).catch(() => false);
}

/** upload_reply 成功 → 启动分块泵；失败 → 会话清理并报错 */
function fpHandleUploadReply(msg) {
  if (!fpUpload) {
    return;
  }
  if (!msg.success) {
    const path = fpUpload.destPath;
    fpUpload = null;
    if (window.__fp.onUploadFail) window.__fp.onUploadFail(path, msg.error || '上传启动失败');
    return;
  }
  fpPumpUpload();
}

/**
 * 分块泵（上游 sendNextChunks 逐段对齐）：16KB 分片；缓冲 >512KB 等 10ms 重试；
 * 每 32 分片让出 1ms（防卡死 UI）；通道断开 → 失败 '文件通道已断开'。
 */
function fpPumpUpload() {
  const session = fpUpload;
  if (!session) {
    return;
  }
  const CHUNK = 16384; // 16KB：WebRTC 单包最兼容尺寸（防 SCTP 超限）
  const file = session.file;
  let yields = 0;

  function step() {
    if (fpUpload !== session) {
      return; // 会话已被终止（失败/取消）
    }
    if (session.offset >= file.size) {
      return; // 全部分片已发，等待 upload_ack 收尾
    }
    if (!fpReady()) {
      const path = session.destPath;
      fpUpload = null;
      if (window.__fp.onUploadFail) window.__fp.onUploadFail(path, '文件通道已断开');
      return;
    }
    if (fpChannel.bufferedAmount > 512 * 1024) {
      setTimeout(step, 10);
      return;
    }
    const start = session.offset;
    const end = Math.min(start + CHUNK, file.size);
    file.slice(start, end).arrayBuffer().then((buf) => {
      if (fpUpload !== session) {
        return;
      }
      if (fpSendChunk(buf)) {
        session.offset = end;
        if (window.__fp.onUploadProgress) {
          window.__fp.onUploadProgress(session.destPath, session.offset, file.size);
        }
        yields++;
        if (yields >= 32) {
          yields = 0;
          setTimeout(step, 1);
        } else {
          step();
        }
      } else {
        setTimeout(step, 10); // 流控/瞬时失败退避
      }
    }).catch(() => {
      setTimeout(step, 50); // 分片读取异常重试（上游 catch 同语义）
    });
  }
  step();
}

/** upload_ack：finished+success=false → 校验失败；finished → 完成（或转安装）；否则推进进度 */
function fpHandleUploadAck(msg) {
  if (!fpUpload) {
    return;
  }
  const session = fpUpload;
  const uploaded = msg.uploaded ?? session.offset;
  if (msg.finished && msg.success === false) {
    fpUpload = null;
    if (window.__fp.onUploadFail) window.__fp.onUploadFail(session.destPath, msg.error || '完整性校验失败');
    return;
  }
  if (window.__fp.onUploadProgress) {
    window.__fp.onUploadProgress(session.destPath, uploaded, session.file.size);
  }
  if (msg.finished) {
    fpUpload = null;
    if (window.__fp.onUploadDone) window.__fp.onUploadDone(session.destPath, !!session.installOnFinish);
  }
}

/**
 * 发起 APK 安装（单活动；回复族 install_status 由 fpHandleInstallStatus 分发）。
 * @returns false=通道不可用/已在安装
 */
function fpInstallApk(path) {
  if (!fpReady() || fpInstall !== null) {
    return false;
  }
  fpSeq++;
  const rid = 'ia_' + fpSeq;
  const sent = fpSendCmd({ type: 'install_apk', path: path, request_id: rid });
  if (sent) {
    fpInstall = { path: path, requestId: rid };
  }
  return sent;
}

/** install_status：installing/success/error 三态（对齐上游 handleInstallStatus） */
function fpHandleInstallStatus(msg) {
  if (!fpInstall) {
    return;
  }
  const status = msg.status || '';
  if (status === 'installing') {
    if (window.__fp.onInstall) window.__fp.onInstall('installing', '', fpInstall.path);
    return;
  }
  const path = fpInstall.path;
  fpInstall = null;
  if (status === 'success') {
    if (window.__fp.onInstall) window.__fp.onInstall('success', '', path);
  } else {
    if (window.__fp.onInstall) window.__fp.onInstall('error', msg.message || '安装失败', path);
    if (window.__fp.onError) window.__fp.onError(msg.message || '安装失败');
  }
}
