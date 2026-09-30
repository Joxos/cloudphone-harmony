# CloudPhoneHarmony

**HarmonyOS 云手机客户端** —— [ScrcpyOverWebRTC](https://github.com/buutuubot/ScrcpyOverWebRTC) 协议的官方 ArkTS 适配实现。

登录 → 设备列表 → WebRTC 投屏 → 触控/键盘/滚动注入 → 终端/文件/群控/分享，全链路打通。

| | |
|---|---|
| BundleName | `com.joxos.cloudphone` |
| 版本 | 1.0.4 (versionCode 1000004) |
| SDK | targetSdk `6.1.1(24)` / compatibleSdk `5.0.0(12)` |
| 工具链 | DevEco Studio 6.0.0+，hvigor 5.0.0，ArkTS |
| 许可 | Apache-2.0 |

---

## ⚠️ 使用须知

- 本工程为 [ScrcpyOverWebRTC](https://github.com/buutuubot/ScrcpyOverWebRTC) 协议的 HarmonyOS 客户端实现；文中的任何声明均不代表任意一方。
- 仓库**仅包含客户端代码**，不含服务端与被控端（cloudphone-agent）实现，也不含任何第三方源码或二进制产物。
- 使用者需自行确保其使用行为符合所在司法辖区的法律法规。
- 本工程按「现状」提供，不作任何明示或默示担保。

## 环境要求

- DevEco Studio **6.0.0**（HarmonyOS SDK 6.0.0 / API 20）或 5.1.x（API 18）
- 真机或模拟器；**音视频与注入链路必须真机验证**
- 权限：`INTERNET`、`GET_NETWORK_INFO`、`CAMERA`（摄像头注入可选，无 Camera HAL 时禁用）
- 门禁脚本需要 **pwsh 7+** 与 **Python 3.9+**

## 构建

仓库根目录即 DevEco 工程根，无需再进入子目录：

```powershell
$env:DEVECO_SDK_HOME='<DevEco>\sdk'          # 按你的 SDK 位置改
& '<DevEco>\tools\node\node.exe' `
  '<DevEco>\tools\hvigor\bin\hvigorw.js' `
  --mode module -p module=entry@default -p product=default `
  -p requiredDeviceType=phone assembleHap
```

产物：`entry/build/default/outputs/default/entry-default-unsigned.hap`

### 关于签名

**本仓库不携带任何签名材料**（`signing/` 已被 `.gitignore` 排除，`build-profile.json5` 也已清空 `signingConfigs`），因此任何人 clone 后都能直接构建出**未签名**包。

未签名包**无法安装到真机**。要出可安装的已签名包，用你自己的证书：

1. 在 DevEco Studio 里 **File → Project Structure → Signing Configs** 自动签名（最省事），或
2. 把 [`docs/signing.template.json5`](docs/signing.template.json5) 里的片段贴回 `build-profile.json5` 的 `app` 内，
   给 `products[]` 加回 `"signingConfig": "default"`，并把 `.cer` / `.p7b` / `.p12` 放进 `signing/`。

> 口令字段是华为工具链的**加密态**口令（由 `.p12` 派生），不是 p12 的明文口令；即便如此仍属密钥材料，故不入仓。
> 留空字符串会触发 hvigor `00303116`（口令长度 <32），所以是整块移除而非置空。

## 目录结构

```
CloudPhoneHarmony/
├── AppScope/                      # 应用级配置（bundleName、vendor、图标）
├── entry/src/main/
│   ├── ets/
│   │   ├── entryability/          # Stage 模型入口
│   │   ├── pages/                 # 登录 / 设备列表 / 控制台 / 设置 / 群控 / 终端 / 文件 …
│   │   ├── features/              # 按域拆分的服务（16 个）
│   │   │   ├── auth/              # 登录、注册、会话登录、NO_AUTH 探测
│   │   │   ├── signaling/         # GlobalChannel（全局信令单例）/ WebSocketBridge
│   │   │   ├── device/  tasks/  share/  groupcontrol/  terminal/
│   │   │   ├── settings/  keymap/  tags/  metrics/  discovery/
│   │   │   └── demo/  onboarding/
│   │   ├── components/  model/  utils/    # HTTP、Prefs、模型、通用组件
│   │   └── pages/                 # ArkWeb 承载的远端页面
│   └── resources/rawfile/         # 页面侧引擎（ArkTS 只做壳）
│       ├── control.html  file.html  preview.html
│       └── js/                    # 20 个模块：信令、输入、编解码、终端、文件、AI …
├── scripts/                       # 四门质量门禁（见下）
├── docs/signing.template.json5    # 签名配置模板
├── build-profile.json5            # 工程构建配置（不含签名）
├── code-linter.json5              # ArkTS Code Linter 配置
└── oh-package.json5
```

### 架构要点：为什么媒体栈在 ArkWeb 里

HarmonyOS **没有公开的原生 WebRTC API**。本工程取「路线 A」：把音视频、WebCodecs/WASM 解码、
输入注入、终端、文件协议、AI 循环全部放在 `rawfile/` 的 Web 页面侧，ArkTS 只负责
**页面组装、REST、系统能力**（剪贴板、选择器写盘、权限）。代价是能做的地方多，边界上更薄。

## 客户端功能面

| 优先级 | 面数 | 状态 |
|---|---|---|
| **P0** 核心闭环 | 12 | ✅ 12/12 |
| **P1** 重要 | 10 | ✅ 10/10 |
| **P2** 增强 | 12 | ✅ 12/12 |
| P3 | — | 不适用（服务端/部署类，非客户端主体） |

几个值得一提的实现点：

- **七条 DataChannel**：`file` / `adb` / `input` / `clipboard` / `camera` / `ai-command` / `device-control`
- **WebADB 终端**：用 `rawfile/js/ansiterm.js` 自研网格终端模拟器（CSI 光标、SGR 16 色、备用屏 1049），
  **零 npm 依赖**，替掉 xterm
- **高频预览**：`PREV` 二进制 H.264 NALU 通道，WebCodecs / WASM 双解码路径
- **键位映射引擎**：tap / swipe / joystick / wheel 四类，虚拟 pointerId，rAF 插值

## 质量门禁

四门联合全绿才允许提交。装一次 pre-commit 钩子即可自动拦截：

```powershell
pwsh scripts/install-hooks.ps1
```

| 门 | 命令 | 规模 | 检查什么 |
|---|---|---|---|
| 1. Code Linter | `pwsh scripts/lint.ps1` | 0 缺陷 | ArkTS 风格与规范（pre-commit 跑此门） |
| 2. 构建 | `hvigorw … assembleHap` | 115 条 `arkts-*` 编译期硬约束 | 类型 + 语言级约束 |
| 3. 控制台测试台 | `node scripts/control_html_test.mjs` | **157** 断言 | node:vm 沙箱跑真实页面脚本，覆盖信令状态机 / 触控 / 编解码 / 终端 / 文件 / AI |
| 4. 协议回放 | 先 `python scripts/mock_signaling_server.py`，再 `python scripts/mock_signaling_test.py` | **33** 断言 | REST 全族 + WS 状态机，对本地 mock 服务端回放 |

门 4 需要先起 mock 服务端（默认 `127.0.0.1:18080`）。

此外还有一套可对**真实服务器**跑的协议一致性测试：

```powershell
python scripts/remote_matrix_test.py --base https://<host>:8443
```

覆盖 REST 全表与 WS 消息全表，判定为 `PASS` / `FAIL` / `ABSENT`——服务端版本未实现的端点
记为 ABSENT 而非失败。对全局状态类端点做「读-改-写-还原」，自建的用户/分享资源在收尾统一清理。
加 `--ws-only` 可只跑 WS 段而不改动服务端状态。

## 已知限制

- **真机冒烟未完成**：控制/预览/文件/终端/任务全链路 + CAMERA 权限弹窗仍待真机走查
- **上传为整读内存**（200MB 上限），大文件未流式化
- **IPv6 地址规整**：`normalizeHost` 对「不带端口的裸 IPv6」不会补 `:8443`，需填 `[addr]:8443`
- 模拟器通常**没有 IPv6**，连 IPv6-only 服务器需在宿主机做 IPv4→IPv6 端口转发
- 部分服务端版本的 `device_metrics` 广播帧缺少判别键，本工程已按消息形状兜底路由

## 致谢

- [ScrcpyOverWebRTC](https://github.com/buutuubot/ScrcpyOverWebRTC) —— 协议与 web-app 实现参考
- [scrcpy](https://github.com/Genymobile/scrcpy) —— 推流内核（被控端由服务端部署，不在本仓库）

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。