/**
 * prevcodec.js —— PREV 高频预览解码（P1-5，WebCodecs + Canvas）
 *
 * 职责（单一）：__pushPrev 帧入口 → AnnexB 解析 → SPS/PPS 变更时组装 avcC 并 configure
 *              → AVCC 切片喂 VideoDecoder → 输出回调直绘 canvas（帧到即画、即 close 释放显存）。
 * 移植来源（v0.3.8 上游，逐段对照）：
 *   DeviceCard.vue  feedFrame(667)/parseAnnexB(539)/avcC 组装(721-740)/codec 串(743)/首帧关键帧门(668)
 *   帧来源：GlobalChannel 解析 PREV → PreviewPage.ets runJavaScript 推入 {d,k,t}。
 * 依赖：preview.html DOM（#prev-canvas/#prev-status）；无 nativeBridge。
 */
'use strict';

/** VideoDecoder 单例（configure 成功前不喂帧） */
var prevDecoder = null;
/** configure 成功标志（SPS/PPS 未到前为 false，丢弃 slice） */
var prevConfigured = false;
/** 上次 SPS/PPS（变更才重新 configure） */
var prevLastSps = null;
var prevLastPps = null;
/** 首帧关键帧门：首个 IDR 之前的 delta 一律丢弃（防花屏，上游 668） */
var prevGotKey = false;
/** FPS 统计（1s 窗口，写状态条） */
var prevFpsCount = 0;
var prevFpsLastTs = 0;
var prevFpsValue = 0;

/**
 * WebCodecs 能力探测（本通路只需 VideoDecoder/EncodedVideoChunk，
 * Insertable Streams 是上游 WebRTC 采集侧要求，PREV 推流不需要）。
 */
function prevSupported() {
  return typeof window.VideoDecoder !== 'undefined' && typeof window.EncodedVideoChunk !== 'undefined';
}

/**
 * AnnexB 字节流 → NALU 数组（忠实移植上游 parseAnnexB：3/4 字节起始码）。
 * @param buffer Uint8Array（可含多 NALU）
 * @returns NALU 数组（已剥起始码）
 */
function parseAnnexB(buffer) {
  const naluList = [];
  const len = buffer.length;
  let i = 0;
  while (i < len) {
    let startCodeLen = 0;
    if (i + 2 < len && buffer[i] === 0 && buffer[i + 1] === 0 && buffer[i + 2] === 1) {
      startCodeLen = 3;
    } else if (i + 3 < len && buffer[i] === 0 && buffer[i + 1] === 0 && buffer[i + 2] === 0 && buffer[i + 3] === 1) {
      startCodeLen = 4;
    }
    if (startCodeLen > 0) {
      const naluStart = i + startCodeLen;
      i = naluStart;
      while (i < len) {
        if (i + 2 < len && buffer[i] === 0 && buffer[i + 1] === 0 && buffer[i + 2] === 1) {
          break;
        }
        if (i + 3 < len && buffer[i] === 0 && buffer[i + 1] === 0 && buffer[i + 2] === 0 && buffer[i + 3] === 1) {
          break;
        }
        i++;
      }
      if (i > naluStart) {
        naluList.push(buffer.subarray(naluStart, i));
      }
    } else {
      i++;
    }
  }
  return naluList;
}

/**
 * SPS+PPS → AVCDecoderConfigurationRecord（avcC）字节（忠实移植上游 721-740）。
 * @returns Uint8Array（configurationVersion/Profile/Level/lengthSize=3/单SPS/单PPS）
 */
function buildAvcConfig(sps, pps) {
  const record = new Uint8Array(11 + sps.length + pps.length);
  record[0] = 1;                 // configurationVersion
  record[1] = sps[1];            // AVCProfileIndication
  record[2] = sps[2];            // profile_compatibility
  record[3] = sps[3];            // AVCLevelIndication
  record[4] = 0xff;              // lengthSizeMinusOne = 3（4 字节长度前缀）
  record[5] = 0xe1;              // numOfSequenceParameterSets = 1
  record[6] = (sps.length >> 8) & 0xff;
  record[7] = sps.length & 0xff;
  record.set(sps, 8);
  const ppsOffset = 8 + sps.length;
  record[ppsOffset] = 1;         // numOfPictureParameterSets
  record[ppsOffset + 1] = (pps.length >> 8) & 0xff;
  record[ppsOffset + 2] = pps.length & 0xff;
  record.set(pps, ppsOffset + 3);
  return record;
}

/** SPS[1..3] → codec 串 'avc1.xxxxxx'（上游 743） */
function codecFromSps(sps) {
  let hex = '';
  for (let i = 1; i <= 3 && i < sps.length; i++) {
    hex += sps[i].toString(16).padStart(2, '0');
  }
  return 'avc1.' + hex;
}

/** 字节数组内容相等（上游 areBuffersEqual 等价——每帧解析出的是新对象，必须按内容比） */
function sameBytes(a, b) {
  if (a === b) {
    return true;
  }
  if (!a || !b || a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 惰性创建解码器（output 直绘 + 即 close；error 复位 configure 态） */
function ensurePrevDecoder(canvas, ctx) {
  if (prevDecoder && prevDecoder.state !== 'closed') {
    return prevDecoder;
  }
  prevDecoder = new window.VideoDecoder({
    output: function (frame) {
      // 动态对齐 canvas 物理分辨率后直绘（上游 DeviceCard output 分支）
      if (canvas.width !== frame.displayWidth || canvas.height !== frame.displayHeight) {
        canvas.width = frame.displayWidth;
        canvas.height = frame.displayHeight;
      }
      ctx.drawImage(frame, 0, 0, canvas.width, canvas.height);
      frame.close();
      prevFpsCount++;
      const now = Date.now();
      if (prevFpsLastTs === 0) {
        prevFpsLastTs = now;
      }
      if (now - prevFpsLastTs >= 1000) {
        prevFpsValue = Math.round(prevFpsCount * 1000 / (now - prevFpsLastTs));
        prevFpsCount = 0;
        prevFpsLastTs = now;
        prevUpdateStatus(canvas.width, canvas.height);
      }
    },
    error: function () {
      prevConfigured = false; // 出错后等下一个 SPS/PPS 重新 configure
    }
  });
  return prevDecoder;
}

/** 状态条刷新（等待→预览中·fps·分辨率） */
function prevUpdateStatus(w, h) {
  const el = document.getElementById('prev-status');
  if (el) {
    el.textContent = '预览中 · ' + prevFpsValue + 'fps · ' + w + '×' + h;
    el.className = '';
  }
}

/**
 * 单帧喂入（移植自上游 feedFrame，webcodecs 分支）：
 * 首帧关键帧门 → 深拷贝 → parseAnnexB → SPS/PPS 变更组装 avcC+configure
 * → type5/1 切片转 AVCC（4B BE 长度前缀）→ EncodedVideoChunk 解码。
 * @param raw Uint8Array 原始帧（AnnexB）
 * @param isKey PREV 帧头关键帧标志
 * @param ptsUs 时间戳（微秒，作为 chunk.timestamp）
 */
function prevFeedFrame(raw, isKey, ptsUs) {
  const canvas = document.getElementById('prev-canvas');
  if (!canvas) {
    return;
  }
  const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });
  // 首帧关键帧门（上游 668-675）
  if (!prevGotKey) {
    if (!isKey) {
      return;
    }
    prevGotKey = true;
  }
  const cleanNalu = new Uint8Array(raw.length); // 深拷贝，规避底层内存共享（上游 677-679）
  cleanNalu.set(raw);
  const dec = ensurePrevDecoder(canvas, ctx);
  const naluList = parseAnnexB(cleanNalu);
  let sps = null;
  let pps = null;
  const slices = [];
  for (const n of naluList) {
    if (n.length === 0) {
      continue;
    }
    const naluType = n[0] & 0x1f;
    if (naluType === 7) {
      sps = n;
    } else if (naluType === 8) {
      pps = n;
    } else if (naluType === 5 || naluType === 1) {
      slices.push(n);
    }
  }
  // SPS/PPS 变更 → 重组 avcC 并 configure（上游 717-757，内容比较防每帧重配）
  if (sps && pps && (!sameBytes(sps, prevLastSps) || !sameBytes(pps, prevLastPps))) {
    prevLastSps = sps;
    prevLastPps = pps;
    const record = buildAvcConfig(sps, pps);
    try {
      dec.configure({
        codec: codecFromSps(sps),
        description: record,
        optimizeForLatency: true
      });
      prevConfigured = true;
    } catch (e) {
      prevConfigured = false;
      return;
    }
  }
  if (!prevConfigured || slices.length === 0) {
    return;
  }
  // AVCC 组装（每 slice 4B BE 长度前缀，上游 762-790）
  let total = 0;
  for (const s of slices) {
    total += 4 + s.length;
  }
  const avcc = new Uint8Array(total);
  let off = 0;
  for (const s of slices) {
    const L = s.length;
    avcc[off] = (L >> 24) & 0xff;
    avcc[off + 1] = (L >> 16) & 0xff;
    avcc[off + 2] = (L >> 8) & 0xff;
    avcc[off + 3] = L & 0xff;
    avcc.set(s, off + 4);
    off += 4 + L;
  }
  try {
    if (dec.state === 'configured') {
      dec.decode(new window.EncodedVideoChunk({
        type: isKey ? 'key' : 'delta',
        timestamp: ptsUs,
        data: avcc
      }));
    }
  } catch (e) {
    // 单帧失败不中断（等下一个 SPS/IDR 自愈）
  }
}

/**
 * ETS 推入入口：PreviewPage.ets runJavaScript 调用。
 * @param json JSON 字符串 {"d":<NALU base64>,"k":0|1,"t":ptsUs}
 */
function pushPrevFrame(json) {
  try {
    const o = JSON.parse(json);
    const bin = atob(o.d);
    const u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) {
      u8[i] = bin.charCodeAt(i);
    }
    prevFeedFrame(u8, o.k === 1 || o.k === true, o.t || 0);
  } catch (e) {
    // 坏帧忽略
  }
}
window.__pushPrev = pushPrevFrame;

// 页面 boot：能力检查 + 初始状态
(function () {
  const el = document.getElementById('prev-status');
  if (!prevSupported()) {
    if (el) {
      el.textContent = '当前内核不支持 WebCodecs，无法预览';
      el.className = 'err';
    }
    return;
  }
  if (el) {
    el.textContent = '等待预览帧…';
  }
})();
