/**
 * ansiterm.js —— 网格终端模拟器（P2-2，替代上游 xterm 的最小可用实现）
 *
 * 职责（单一）：PTY 裸字节流 → 字符网格状态机（CSI 光标/擦除/SGR/备用屏）→ canvas 单元格渲染；
 *   键盘字节编码（printable/Enter/退格/Tab/方向键/Ctrl 组合）。
 * 支持子集（对齐 shell 交互与 top/vi 常用面）：
 *   - 控制符：CR/LF/BS/TAB/BEL 忽略；ESC 序列进入 CSI
 *   - CSI：A/B/C/D 光标、H 定位、J 擦屏(0/1/2)、K 擦行、m SGR(0/1/22/30-37/39/40-47/49/90-97)、
 *     s/u 光标存取、?1049h/l 备用屏切换（top/vi）、?25 光标显隐（接受不渲染）
 *   - 宽字符：CJK/全角按 2 单元占位（基础宽度表）
 * 渲染：rAF 单次合并（feed 置脏 → 下一帧整屏绘制）；连续同色 run 合并 fillText。
 * 与上游差异：无 xterm 依赖（rawfile 纯脚本环境无法引 npm 包）；scrollback 仅保留屏内。
 * 依赖：仅 DOM canvas（control.html #adb-canvas）。
 */
'use strict';

/** 终端实例工厂（单屏单会话——与 adb 会话一一对应） */
function createAnsiTerm(canvas, cols, rows) {
  const CELL_W = 8;
  const CELL_H = 16;
  const term = {
    canvas: canvas,
    ctx: canvas.getContext('2d'),
    cols: cols,
    rows: rows,
    // 主屏与备用屏（?1049 切换）：cell = {ch, fg, bg, bold}
    screen: null,
    altScreen: null,
    altMode: false,
    cur: { r: 0, c: 0 },
    saved: { r: 0, c: 0 },
    attrs: { fg: '', bg: '', bold: false },
    scrollTop: 0,
    scrollBot: rows - 1,
    cursorVisible: true,
    dirty: true,
    raf: 0,
    decoder: new TextDecoder('utf-8'),
    onData: null, // (bytes:Uint8Array) 由 adbproto 注入
    onRender: null // (stats) 状态条回调
  };

  function blankRow() {
    const row = [];
    for (let i = 0; i < term.cols; i++) {
      row.push({ ch: ' ', fg: '', bg: '', bold: false });
    }
    return row;
  }

  function blankScreen() {
    const scr = [];
    for (let i = 0; i < term.rows; i++) {
      scr.push(blankRow());
    }
    return scr;
  }

  function screen() {
    return term.altMode ? term.altScreen : term.screen;
  }

  term.screen = blankScreen();
  term.altScreen = blankScreen();

  term.resize = function (c, r) {
    term.cols = c;
    term.rows = r;
    term.screen = blankScreen();
    term.altScreen = blankScreen();
    term.cur = { r: 0, c: 0 };
    term.scrollTop = 0;
    term.scrollBot = r - 1;
    canvas.width = c * CELL_W;
    canvas.height = r * CELL_H;
    term.dirty = true;
  };

  // ===================== 渲染 =====================

  function scheduleRender() {
    if (term.raf) {
      return;
    }
    term.raf = requestAnimationFrame(() => {
      term.raf = 0;
      draw();
    });
  }

  function draw() {
    const ctx = term.ctx;
    const scr = screen();
    ctx.fillStyle = '#0d1117';
    ctx.fillRect(0, 0, term.cols * CELL_W, term.rows * CELL_H);
    ctx.font = '13px monospace';
    ctx.textBaseline = 'top';
    for (let r = 0; r < term.rows; r++) {
      let c = 0;
      while (c < term.cols) {
        const cell = scr[r][c];
        // 单元格背景
        if (cell.bg) {
          ctx.fillStyle = cell.bg;
          ctx.fillRect(c * CELL_W, r * CELL_H, CELL_W, CELL_H);
        }
        // 同色连续 run 合并一次 fillText
        let run = cell.ch;
        let rr = cell;
        let end = c + 1;
        while (end < term.cols) {
          const nx = scr[r][end];
          if (nx.ch !== ' ' && (nx.fg === rr.fg && nx.bg === rr.bg && nx.bold === rr.bold)) {
            run += nx.ch;
            rr = nx;
            end++;
          } else if (nx.ch === ' ' && rr.ch === ' ' && nx.bg === rr.bg) {
            end++;
          } else {
            break;
          }
        }
        if (rr.ch !== ' ') {
          ctx.fillStyle = rr.fg || '#c9d1d9';
          if (rr.bold) {
            ctx.font = 'bold 13px monospace';
          } else {
            ctx.font = '13px monospace';
          }
          ctx.fillText(run, c * CELL_W, r * CELL_H);
        }
        c = end;
      }
    }
    // 光标（块状）
    if (term.cursorVisible) {
      ctx.fillStyle = '#58a6ff';
      ctx.globalAlpha = 0.85;
      ctx.fillRect(term.cur.c * CELL_W, term.cur.r * CELL_H, CELL_W, CELL_H);
      ctx.globalAlpha = 1;
    }
    if (term.onRender) {
      term.onRender({ cols: term.cols, rows: term.rows, alt: term.altMode });
    }
  }

  term.requestRender = function () {
    term.dirty = true;
    scheduleRender();
  };

  // ===================== 屏幕操作 =====================

  function clampCur() {
    if (term.cur.r < 0) term.cur.r = 0;
    if (term.cur.r >= term.rows) term.cur.r = term.rows - 1;
    if (term.cur.c < 0) term.cur.c = 0;
    if (term.cur.c >= term.cols) term.cur.c = term.cols - 1;
  }

  function scrollUp(n) {
    const scr = screen();
    for (let i = 0; i < n; i++) {
      scr.splice(term.scrollTop, 1);
      scr.splice(term.scrollBot, 0, blankRow());
    }
  }

  function scrollDown(n) {
    const scr = screen();
    for (let i = 0; i < n; i++) {
      scr.splice(term.scrollBot, 1);
      scr.splice(term.scrollTop, 0, blankRow());
    }
  }

  function eraseBelow() {
    const scr = screen();
    eraseLineFrom(term.cur.c);
    for (let r = term.cur.r + 1; r < term.rows; r++) {
      scr[r] = blankRow();
    }
  }

  function eraseAbove() {
    const scr = screen();
    for (let r = 0; r < term.cur.r; r++) {
      scr[r] = blankRow();
    }
    for (let c = 0; c <= term.cur.c; c++) {
      scr[term.cur.r][c] = { ch: ' ', fg: '', bg: '', bold: false };
    }
  }

  function eraseLineFrom(fromC) {
    const scr = screen();
    for (let c = fromC; c < term.cols; c++) {
      scr[term.cur.r][c] = { ch: ' ', fg: '', bg: '', bold: false };
    }
  }

  function putChar(ch, width) {
    const scr = screen();
    if (term.cur.c >= term.cols) {
      // 行尾自动换行
      term.cur.c = 0;
      lineFeed();
    }
    const cell = scr[term.cur.r][term.cur.c];
    cell.ch = ch;
    cell.fg = term.attrs.fg;
    cell.bg = term.attrs.bg;
    cell.bold = term.attrs.bold;
    if (width === 2 && term.cur.c + 1 < term.cols) {
      const nx = scr[term.cur.r][term.cur.c + 1];
      nx.ch = '';
      nx.fg = term.attrs.fg;
      nx.bg = term.attrs.bg;
      nx.bold = term.attrs.bold;
    }
    term.cur.c += width;
  }

  function lineFeed() {
    if (term.cur.r === term.scrollBot) {
      scrollUp(1);
    } else if (term.cur.r < term.rows - 1) {
      term.cur.r++;
    }
  }

  // ===================== 解析（流式） =====================

  let state = 'ground'; // ground | esc | csi | osc
  let csiBuf = '';
  let oscBuf = '';

  function isWide(ch) {
    const code = ch.codePointAt(0);
    return (code >= 0x1100 && code <= 0x115F) ||
      (code >= 0x2E80 && code <= 0xA4CF) ||
      (code >= 0xAC00 && code <= 0xD7A3) ||
      (code >= 0xF900 && code <= 0xFAFF) ||
      (code >= 0xFE30 && code <= 0xFE6F) ||
      (code >= 0xFF00 && code <= 0xFF60) ||
      (code >= 0xFFE0 && code <= 0xFFE6) ||
      (code >= 0x1F300 && code <= 0x1FAFF) ||
      (code >= 0x20000 && code <= 0x3FFFD);
  }

  function sgr(params) {
    if (params.length === 0) {
      params = [0];
    }
    for (let i = 0; i < params.length; i++) {
      const p = params[i];
      if (p === 0) {
        term.attrs = { fg: '', bg: '', bold: false };
      } else if (p === 1) {
        term.attrs.bold = true;
      } else if (p === 22) {
        term.attrs.bold = false;
      } else if ((p >= 30 && p <= 37) || p === 39) {
        term.attrs.fg = p === 39 ? '' : TERM_COLORS[p - 30];
      } else if (p === 90 || (p >= 91 && p <= 97)) {
        term.attrs.fg = TERM_COLORS[p - 90 + 8];
      } else if (p === 39) {
        term.attrs.fg = '';
      } else if ((p >= 40 && p <= 47) || p === 49) {
        term.attrs.bg = p === 49 ? '' : TERM_COLORS[p - 40];
      }
      // 其余（斜体/下划线等）接受但不渲染
    }
  }

  const TERM_COLORS = ['#000000', '#cd3131', '#0dbc79', '#e5e510', '#2472c8', '#bc3fbc', '#11a8cd', '#e5e5e5',
    '#666666', '#f14c4c', '#23d18b', '#f5f543', '#3b8eea', '#d670d6', '#29b8db', '#ffffff'];

  function csiDispatch(seq) {
    let privateMark = '';
    if (seq.startsWith('?')) {
      privateMark = '?';
      seq = seq.substring(1);
    }
    const parts = seq.split(';');
    const fin = parts[parts.length - 1].replace(/[^0-9]/g, '');
    const cmd = seq[seq.length - 1];
    const params = parts.map((x) => parseInt(x.replace(/[^0-9]/g, ''), 10) || 0);
    const p0 = params[0] || 0;

    if (privateMark === '?') {
      if (cmd === 'h' && p0 === 1049) {
        term.altMode = true;
        term.cur = { r: 0, c: 0 };
      } else if (cmd === 'l' && p0 === 1049) {
        term.altMode = false;
        term.cur = { r: 0, c: 0 };
      } else if (cmd === 'h' && p0 === 25) {
        term.cursorVisible = true;
      } else if (cmd === 'l' && p0 === 25) {
        term.cursorVisible = false;
      }
      return;
    }
    switch (cmd) {
      case 'A': term.cur.r = Math.max(0, term.cur.r - Math.max(1, p0)); break;
      case 'B': term.cur.r = Math.min(term.rows - 1, term.cur.r + Math.max(1, p0)); break;
      case 'C': term.cur.c = Math.min(term.cols - 1, term.cur.c + Math.max(1, p0)); break;
      case 'D': term.cur.c = Math.max(0, term.cur.c - Math.max(1, p0)); break;
      case 'H': case 'f':
        term.cur.r = Math.min(term.rows - 1, Math.max(0, (params[0] || 1) - 1));
        term.cur.c = Math.min(term.cols - 1, Math.max(0, (params[1] || 1) - 1));
        break;
      case 'J':
        if (p0 === 2) { term.screen = blankScreen(); term.altScreen = blankScreen(); term.cur = { r: 0, c: 0 }; }
        else if (p0 === 1) eraseAbove();
        else eraseBelow();
        break;
      case 'K':
        if (p0 === 1) { eraseLineFrom(0); eraseLineFrom(term.cur.c); for (let c = 0; c < term.cur.c; c++) { screen()[term.cur.r][c] = { ch: ' ', fg: '', bg: '', bold: false }; } }
        else if (p0 === 2) { screen()[term.cur.r] = blankRow(); }
        else eraseLineFrom(term.cur.c);
        break;
      case 'm': sgr(params); break;
      case 's': term.saved = { r: term.cur.r, c: term.cur.c }; break;
      case 'u': term.cur = { r: term.saved.r, c: term.saved.c }; break;
      case 'r':
        term.scrollTop = Math.max(0, (params[0] || 1) - 1);
        term.scrollBot = Math.min(term.rows - 1, (params[1] || term.rows) - 1);
        term.cur = { r: term.scrollTop, c: 0 };
        break;
      default: break; // 其余 CSI 接受不渲染（fin 变量占位避免未用）
    }
    void fin;
    clampCur();
  }

  function handleControl(ch) {
    switch (ch) {
      case '\r': term.cur.c = 0; break;
      case '\n': case '\x0b': case '\x0c': lineFeed(); break;
      case '\b': term.cur.c = Math.max(0, term.cur.c - 1); break;
      case '\t': term.cur.c = Math.min(term.cols - 1, (Math.floor(term.cur.c / 8) + 1) * 8); break;
      default: break; // BEL 等忽略
    }
  }

  function step(text) {
    for (const ch of text) {
      if (state === 'ground') {
        if (ch === '\x1b') { state = 'esc'; continue; }
        if (ch < ' ' && ch !== '\n' && ch !== '\r' && ch !== '\t' && ch !== '\b') {
          handleControl(ch);
          continue;
        }
        if (ch >= ' ' || ch === '\n' || ch === '\r' || ch === '\t' || ch === '\b') {
          if (ch === '\r' || ch === '\n' || ch === '\t' || ch === '\b') {
            handleControl(ch);
            continue;
          }
          putChar(ch, isWide(ch) ? 2 : 1);
        }
        continue;
      }
      if (state === 'esc') {
        if (ch === '[') { state = 'csi'; csiBuf = ''; continue; }
        if (ch === ']') { state = 'osc'; oscBuf = ''; continue; }
        if (ch === 'c') { term.screen = blankScreen(); term.cur = { r: 0, c: 0 }; }
        state = 'ground'; // 单字符 ESC 序列（7/8 等）忽略
        continue;
      }
      if (state === 'csi') {
        if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch === '?') {
          if ((ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z')) {
            csiDispatch(csiBuf + ch);
            state = 'ground';
          } else {
            csiBuf += ch; // '?' 前缀保留在 buf
          }
          continue;
        }
        csiBuf += ch;
        if (csiBuf.length > 64) { state = 'ground'; } // 防御：异常序列截断
        continue;
      }
      if (state === 'osc') {
        if (ch === '\x07' || ch === '\x1b') { state = 'ground'; oscBuf = ''; continue; }
        oscBuf += ch;
        if (oscBuf.length > 256) { state = 'ground'; }
      }
    }
  }

  /** 字节流入口（PTY onmessage → 解码流式喂入） */
  term.feed = function (bytes) {
    const text = term.decoder.decode(bytes, { stream: true });
    if (text.length > 0) {
      step(text);
      scheduleRender();
    }
  };

  /** 纯文本入口（状态行/横幅；上游 writeln 语义） */
  term.writeln = function (str) {
    step(str + '\r\n');
    scheduleRender();
  };

  /** 键盘字节编码（input → onData；返回 null=不处理） */
  function encodeKey(ev) {
    const key = ev.key;
    if (ev.ctrlKey && key.length === 1 && key >= 'a' && key <= 'z') {
      return new Uint8Array([key.charCodeAt(0) - 96]);
    }
    if (ev.ctrlKey && key.length === 1 && key >= 'A' && key <= 'Z') {
      return new Uint8Array([key.charCodeAt(0) - 64]);
    }
    switch (key) {
      case 'Enter': return new Uint8Array([13]);
      case 'Backspace': return new Uint8Array([127]);
      case 'Tab': return new Uint8Array([9]);
      case 'Escape': return new Uint8Array([27]);
      case 'ArrowUp': return new TextEncoder().encode('\x1b[A');
      case 'ArrowDown': return new TextEncoder().encode('\x1b[B');
      case 'ArrowRight': return new TextEncoder().encode('\x1b[C');
      case 'ArrowLeft': return new TextEncoder().encode('\x1b[D');
      case 'Home': return new TextEncoder().encode('\x1b[H');
      case 'End': return new TextEncoder().encode('\x1b[F');
      case 'Delete': return new TextEncoder().encode('\x1b[3~');
      case 'PageUp': return new TextEncoder().encode('\x1b[5~');
      case 'PageDown': return new TextEncoder().encode('\x1b[6~');
      default: break;
    }
    if (ev.ctrlKey && key === '[') {
      return new Uint8Array([27]);
    }
    if (key.length === 1 && !ev.altKey) {
      return new TextEncoder().encode(key);
    }
    if (ev.altKey && key.length === 1) {
      return new Uint8Array([27, key.charCodeAt(0)]);
    }
    return null;
  }
  term.encodeKey = encodeKey;

  /** 状态观察口（测试/调试：当前屏文本快照，行以 \n 连接） */
  term.dump = function () {
    const scr = screen();
    const lines = [];
    for (let r = 0; r < term.rows; r++) {
      let s = '';
      for (let c = 0; c < term.cols; c++) {
        s += scr[r][c].ch;
      }
      lines.push(s.replace(/\s+$/, ''));
    }
    return lines.join('\n');
  };

  /** 单元格样式观察口（测试：{ch,fg,bold}） */
  term.cellAt = function (r, c) {
    const cell = screen()[r][c];
    return { ch: cell.ch, fg: cell.fg, bold: cell.bold };
  };

  /** 运行态（光标/备用屏，测试） */
  term.state = function () {
    return { cur: { r: term.cur.r, c: term.cur.c }, alt: term.altMode, cols: term.cols, rows: term.rows };
  };

  // 初始尺寸与首绘
  term.resize(cols, rows);
  return term;
}

window.createAnsiTerm = createAnsiTerm;
