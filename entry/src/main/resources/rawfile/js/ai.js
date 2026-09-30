/**
 * ai.js —— AI 排障助手引擎（P2-3a，对应上游 DeviceConsole AI 面板脚本区 2780-3050）
 *
 * 职责（单一）：OpenAI 兼容 tools 协议的 **Agent 循环**（≤8 轮）、5 个工具的本地执行
 *   （shell/设备信息/WebRTC 指标/按键/触控）、LLM 调用经原生桥（免 CORS）。
 * 协议逐条对齐上游：
 *   - tools=5 定义（execute_shell_command/get_device_info/get_webrtc_stats/
 *     simulate_keyevent/simulate_touch）+ tool_choice auto；
 *   - systemMessage：云手机诊断员提示词（device_id 注入、中文输出、日志诊断要点）；
 *   - 循环：请求→push assistant→有 tool_calls 执行并 push role:tool→继续；无则 break；
 *   - 触控使用虚拟 pointerId=91（上游用 -1；本端避开真实鼠标 -1 会话——见 doc 注）。
 * 传输：
 *   - LLM：nativeBridge.aiChat(url,key,body,reqId) → __aiResolve 回调（代理无法返回 Promise）；
 *   - shell：signaling.sendCommandWait（request_id 等待 command_result）。
 * 事件出口：window.__aiEvents {onMessage(msg), onLog(level,text)}（面板 UI 与测试订阅）。
 * 配置：bridge getAiConfig → {url,key,model}（Prefs ai_api_* 键；设置面板 P2-3b 接入）。
 */
'use strict';

/** LLM 请求挂起表：reqId → {resolve, reject} */
var aiPending = {};
var aiReqSeq = 0;
/** 对话上下文（含 system；每轮全量发送——上游 aiMessages 同构） */
var aiMessages = [];
/** 循环保护 */
var AI_MAX_ITER = 8;

/** 事件出口（UI/测试订阅；未订阅静默） */
window.__aiEvents = { onMessage: null, onLog: null };

function aiLog(level, text) {
  if (window.__aiEvents.onLog) window.__aiEvents.onLog(level, text);
}

/** ETS 异步回填（ArkWebView.aiChat → runJavaScript 调用本函数） */
window.__aiResolve = function (reqId, ok, bodyText) {
  const h = aiPending[reqId];
  if (!h) return;
  delete aiPending[reqId];
  if (ok) {
    h.resolve(bodyText);
  } else {
    h.reject(new Error(bodyText || 'LLM 请求失败'));
  }
};

/** 工具定义（上游 runAgentLoop tools 数组逐字移植） */
function aiToolsDef() {
  return [
    {
      type: 'function',
      function: {
        name: 'execute_shell_command',
        description: '在云手机上执行 adb shell 命令并获取 stdout/stderr 结果',
        parameters: {
          type: 'object',
          properties: {
            command: { type: 'string', description: '要执行的 shell 命令，如 pm list packages -3 或 df -h /data' }
          },
          required: ['command']
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'get_device_info',
        description: '获取当前云手机的名称、状态和设备型号及硬件参数',
        parameters: { type: 'object', properties: {} }
      }
    },
    {
      type: 'function',
      function: {
        name: 'get_webrtc_stats',
        description: '读取当前的 WebRTC 传输质量指标 (FPS, RTT 延迟, Jitter Buffer 缓冲、丢包率等)，用于卡顿排障',
        parameters: { type: 'object', properties: {} }
      }
    },
    {
      type: 'function',
      function: {
        name: 'simulate_keyevent',
        description: '发送物理按键事件，如 3 (HOME), 4 (BACK), 26 (POWER)',
        parameters: {
          type: 'object',
          properties: {
            keycode: { type: 'integer', description: 'Android KeyEvent 码值' }
          },
          required: ['keycode']
        }
      }
    },
    {
      type: 'function',
      function: {
        name: 'simulate_touch',
        description: '在屏幕相对坐标上模拟点击操作',
        parameters: {
          type: 'object',
          properties: {
            x: { type: 'integer', description: '横轴 X 坐标点' },
            y: { type: 'integer', description: '纵轴 Y 坐标点' }
          },
          required: ['x', 'y']
        }
      }
    }
  ];
}

/** 系统提示词（上游 systemMessage 逐句移植；device_id 注入） */
function aiSystemMessage(deviceId) {
  return 'You are a cloud phone diagnostic and task execution assistant.\n' +
    'You are running on a virtual machine (device ID: ' + deviceId + ') inside the cloudphone operator panel.\n' +
    'You can execute real shell commands and collect details to troubleshoot network quality, memory leaks, system load, or app crashes.\n\n' +
    'Key requirements:\n' +
    '1. First, call get_device_info to check the device environment if you need basic info.\n' +
    '2. If the user complains about lag or WebRTC frozen, call get_webrtc_stats to diagnose Jitter Buffer (JB), RTT (network lag), and FPS. Explain recommendations to the user in Chinese.\n' +
    '3. Troubleshooting connection failures & blackscreen: If the user complains about connection timeout, failure, or blackscreen, you should directly inspect the Go agent logs located at \'/data/local/tmp/cloudphone-agent.log\' (e.g. by running \'su -c tail -n 200 /data/local/tmp/cloudphone-agent.log\'). Specifically:\n' +
    '   a. Check if "No external NAT mappings configured" is printed. If yes, it indicates the agent is missing the host NAT IP (-external-addr or CP_AGENT_EXTERNAL_ADDR), causing cross-device routing failure.\n' +
    '   b. Inspect the ICE candidate IPs. Check if the device agent only bound local Docker private IPs (like 172.17.x.x) and if the client is using local proxy Tun modes (like Clash Tun 198.18.x.x) which blocks UDP connection checks.\n' +
    '   c. Verify that UDS channels (Video, Control, Touch) are all connected successfully.\n' +
    '   d. Check if CoreService exited unexpectedly, or if keyframe requests were skipped with reason "no-control-conn" or "no active codec" during initiation.\n' +
    '4. Be careful with command execution. Prefer safe, standard queries.\n' +
    '5. Output your responses and summaries exclusively in Chinese (中文).\n';
}

/** LLM 调用（ETS 桥异步回填；返回 choices[0].message 所在的完整 data） */
function aiChatOnce(messages, tools) {
  return new Promise(function (resolve, reject) {
    const cfgRaw = native('getAiConfig', '');
    let cfg = { url: 'https://api.openai.com/v1', key: '', model: 'gpt-4o-mini' };
    try {
      const parsed = JSON.parse(cfgRaw);
      cfg = { url: parsed.url || cfg.url, key: parsed.key || '', model: parsed.model || cfg.model };
    } catch (e) {
      // 回退默认
    }
    if (!cfg.key) {
      reject(new Error('未配置 AI API Key（设置页填 ai_api_key）'));
      return;
    }
    aiReqSeq++;
    const reqId = 'ai_' + aiReqSeq;
    aiPending[reqId] = { resolve: resolve, reject: reject };
    const body = JSON.stringify({
      model: cfg.model,
      messages: messages,
      tools: tools,
      tool_choice: 'auto'
    });
    try {
      window.nativeBridge.aiChat(cfg.url, cfg.key, body, reqId);
    } catch (e) {
      delete aiPending[reqId];
      reject(new Error('aiChat 桥不可用'));
    }
  });
}

/** 虚拟指针 touch 会话（id=91：避开真实鼠标 -1 与 keymap ≥10 段的高频区） */
function aiTouch(x, y) {
  const id = 91;
  if (!pointers[id]) {
    pointers[id] = { seq: 0, x: x, y: y, pending: null, dirty: false, sentMs: 0 };
  }
  const p = { x: x, y: y, w: deviceW, h: deviceH };
  sendTouchJson(p, id, 0); // DOWN
  setTimeout(function () {
    sendTouchJson(p, id, 1); // UP
    delete pointers[id];
  }, 60);
  return { status: 'success', clicked: { x: x, y: y } };
}

/**
 * 工具执行（上游 executeAgentTool switch 同构；传输全部落到本页既有原语）。
 * shell=sendCommandWait；stats=statsOnce；key=injectKey 成对；touch=id91 会话。
 */
function aiExecuteTool(name, args) {
  if (name === 'execute_shell_command') {
    if (!args || !args.command) {
      return Promise.reject(new Error('缺少 command 参数'));
    }
    aiLog('info', '[Shell] ' + args.command);
    return sendCommandWait(args.command).then(function (r) {
      if (r.exit_code < 0) {
        return { exit_code: r.exit_code, stdout: '', stderr: r.stderr || '执行失败' };
      }
      return { exit_code: r.exit_code, stdout: r.stdout || '', stderr: r.stderr || '' };
    });
  }
  if (name === 'get_device_info') {
    return Promise.resolve({
      device_id: native('getDeviceId', ''),
      model: '(client 未缓存型号，可执行 getprop ro.product.model 获取)',
      tags: [],
      webrtc_status: typeof curState !== 'undefined' ? curState : 'unknown',
      agent_version: 'unknown',
      resolution: deviceW + 'x' + deviceH
    });
  }
  if (name === 'get_webrtc_stats') {
    return statsOnce();
  }
  if (name === 'simulate_keyevent') {
    if (!args || args.keycode === undefined) {
      return Promise.reject(new Error('缺少 keycode 参数'));
    }
    const ok = injectKey(args.keycode);
    if (!ok) {
      return Promise.reject(new Error('按键注入失败（信令未连接或只读）'));
    }
    return Promise.resolve({ status: 'success', keycode: args.keycode });
  }
  if (name === 'simulate_touch') {
    if (!args || args.x === undefined || args.y === undefined) {
      return Promise.reject(new Error('缺少坐标参数'));
    }
    return Promise.resolve(aiTouch(args.x, args.y));
  }
  return Promise.reject(new Error('未知的工具: ' + name));
}

/**
 * Agent 循环（上游 runAgentLoop 同构：≤8 轮防死循环）。
 * @param userText 用户输入（空=仅让模型自检一轮）
 * @returns Promise<{final: string}> 最终 content
 */
function aiRunLoop(userText) {
  let iterations = 0;
  const tools = aiToolsDef();
  if (aiMessages.length === 0 || aiMessages[0].role !== 'system') {
    aiMessages.unshift({ role: 'system', content: aiSystemMessage(native('getDeviceId', '')) });
  }
  if (userText && userText.length > 0) {
    aiMessages.push({ role: 'user', content: userText });
  }

  function step() {
    if (iterations >= AI_MAX_ITER) {
      aiLog('warning', 'AI Agent 调用次数达到上限，强制结束思考');
      return Promise.resolve({ final: '(已达最大推理轮数)' });
    }
    iterations++;
    aiLog('info', '发送请求至 LLM (' + iterations + '/' + AI_MAX_ITER + ')...');
    return aiChatOnce(aiMessages, tools).then(function (raw) {
      // aiChatOnce 回传 body 文本（代理通道为字符串）→ 统一解析
      let data = raw;
      if (typeof raw === 'string') {
        data = JSON.parse(raw);
      }
      const choice = data && data.choices && data.choices[0];
      if (!choice) {
        throw new Error('API 返回的数据结构异常，choices 为空');
      }
      const message = choice.message;
      aiMessages.push(message);
      if (window.__aiEvents.onMessage) window.__aiEvents.onMessage(message);
      if (message.content) {
        aiLog('success', 'AI 回复: ' + String(message.content).substring(0, 60) + '...');
      }
      if (message.tool_calls && message.tool_calls.length > 0) {
        aiLog('info', '发现 ' + message.tool_calls.length + ' 个工具调用请求，开始处理...');
        const jobs = message.tool_calls.map(function (toolCall) {
          const fname = toolCall.function.name;
          let toolArgs = {};
          try {
            toolArgs = JSON.parse(toolCall.function.arguments || '{}');
          } catch (e) {
            aiLog('warning', '工具参数解析失败: ' + toolCall.function.arguments);
          }
          aiLog('tool', '正在调用: ' + fname);
          return Promise.resolve()
            .then(function () { return aiExecuteTool(fname, toolArgs); })
            .then(function (result) {
              const content = typeof result === 'object' ? JSON.stringify(result) : String(result);
              aiLog('success', '[' + fname + '] 完成（' + content.length + ' 字节）');
              aiMessages.push({ role: 'tool', tool_call_id: toolCall.id, name: fname, content: content });
            })
            .catch(function (err) {
              aiLog('error', '[' + fname + '] 失败: ' + err.message);
              aiMessages.push({ role: 'tool', tool_call_id: toolCall.id, name: fname, content: 'Error: ' + err.message });
            });
        });
        return Promise.all(jobs).then(step); // 工具结果全部入上下文后进入下一轮
      }
      // 无 tool_calls → 最终结论
      return { final: message.content || '' };
    });
  }
  return step();
}

/** 清空对话（UI 「新会话」调用；system 下轮自动重建） */
function aiReset() {
  aiMessages = [];
}

/** 显式 API（window 出口 → 面板 UI 与测试共用） */
window.__aiApi = {
  runLoop: aiRunLoop,
  reset: aiReset,
  tools: aiToolsDef,
  systemMessage: aiSystemMessage,
  executeTool: aiExecuteTool
};
