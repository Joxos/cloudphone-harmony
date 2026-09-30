# 内测分发发布指南（AGC 云端签名，无需 UDID）

> 适用：小范围（朋友/同事）通过华为应用市场「内测」通道安装，不走上架审核/备案强制项。
> 路线核心：**发布证书 + 云端签名**（AGC 自动签名），**不需要**收集每台设备 UDID。
> 工程侧前置已完成：bundleName 已改为 `com.joxos.cloudphone`（`AppScope/app.json5`），release 未签名 HAP 构建已验证。

## 总览

```
华为开发者账号(实名) → AGC 建应用(绑定 bundleName) → 补齐应用资料
→ 上传 release unsigned HAP → AGC 云端签名 → 创建内测版本 → 添加测试者
→ 测试者应用市场邀请链接安装 → 后续版本迭代重传
```

## 第 1 步：开发者账号（只能你自己做）

1. 打开 [华为开发者联盟](https://developer.huawei.com/consumer/cn/) 注册/登录华为账号。
2. 「管理中心」→ 成为开发者 → **实名认证**（个人：身份证 + 人脸识别/银行卡验证，免费）。

## 第 2 步：移动应用备案（提前办，内测也可能被要求）

- 国内分发（含内测/公测）通常要求完成**移动互联网应用备案**（工信部，经接入商提交）。
- 华为在提交版本时校验备案号；若 AGC 页面要求，需先备案（个人可经接入商办理，周期约 1-2 周）。
- 若你的 AGC 内测提交不强制，可暂缓；正式上架前必须完成。
- 参考：华为[应用审核 Checklist](https://developer.huawei.com/consumer/cn/doc/App/50170)。

## 第 3 步：AGC 创建项目与应用

1. 登录 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html) →「我的项目」→ 新建项目。
2. 新建应用 → 选择 **HarmonyOS 应用** → 填入：
   - **包名**：`com.joxos.cloudphone`（必须与工程一致，唯一不可改）
   - 应用名称：`云手机`
   - 分类：工具 / 效率
3. 进入应用 →「用户与访问 → 证书、APP ID 和 Profile」→ 创建 **发布证书**：
   - 证书类型：**发布证书**
   - 证书名称：如「云手机」
   - **证书请求文件（CSR）**：选 `signing/release_ec.csr`（**必须 EC 密钥**，见下方说明；AGC 用 CSR 里的公钥签发证书，私钥留在本地 `release_ec.p12`）
   - 创建后下载签发的 **.cer 证书** → 继续创建**发布 Profile**（发布 Profile 不需要设备 UDID）
   - **启用云端签名**（云端签名模式下证书材料由 AGC 托管，后续直接上传 unsigned HAP 即可）

> ⚠️ **密钥算法必须用 EC**：华为官方 FAQ（"上传的CSR文件无效"）明确答复——生成证书请求文件时 `-keyalg` 必须为 `"EC"`（鸿蒙签名算法 SHA256withECDSA，RSA 密钥的 CSR 会被 AGC 拒绝）。已生成的 `release_ec.csr` 为 secp256r1(P-256) EC 密钥；如要自行重新生成：
> ```powershell
> $kt = 'D:\Apps\DevEco Studio\jbr\bin\keytool.exe'
> & $kt -genkeypair -alias release -keyalg EC -groupname secp256r1 -keystore release_ec.p12 -storetype PKCS12 -validity 9125 -storepass <密码> -keypass <密码> -dname "CN=cloudphone,OU=Dev,O=Joxos,L=Beijing,ST=Beijing,C=CN"
> & $kt -certreq -alias release -keystore release_ec.p12 -file release_ec.csr -storepass <密码>
> ```
> （RSA 版 `release.csr`/`release.p12` 已废弃，可删）

## 第 4 步：补齐应用资料（内测基础审核需要）

- 应用图标：`216×216` PNG（建议正式图标，模板图标可能被拒；可先放一张自制图）
- 应用简介 / 隐私政策 URL：内测阶段也需要一个可访问的隐私政策页面（可先用 GitHub Pages / 语雀公开链接占位）
- 开发者信息与联系方式

## 第 5 步：构建发布产物（本仓库已就绪，本地签名配置完成）

**已签名 HAP**（真机直装/自验用）：
```powershell
$env:HVIGOR_USER_HOME='D:\source\dsh\cloudmobile_harmony\CloudPhoneHarmony\.hvigor'
$env:DEVECO_SDK_HOME='D:\Apps\DevEco Studio\sdk'
$env:npm_config_cache='D:\source\dsh\cloudmobile_harmony\.npm-cache'
& 'D:\Apps\DevEco Studio\tools\node\node.exe' `
  'D:\Apps\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module `
  -p product=default -p buildMode=release assembleHap --no-daemon
```
产物：`entry/build/default/outputs/default/entry-default-signed.hap`

**已签名 APP Pack**（AGC 内测/上架上传用 ⭐）：
```powershell
& 'D:\Apps\DevEco Studio\tools\node\node.exe' `
  'D:\Apps\DevEco Studio\tools\hvigor\bin\hvigorw.js' assembleApp `
  -p product=default -p buildMode=release --no-daemon
```
产物：`build/outputs/default/CloudPhoneHarmony-default-signed.app`
（.app 为容器：内含未签名 HAP + 容器级签名块，正是 AGC 版本上传要求的格式）

## 第 6 步：上传与内测版本

1. AGC 应用内 →「版本管理 / 分发」→ **内测（Beta）** → 创建版本。
2. 上传第 5 步的 **`CloudPhoneHarmony-default-signed.app`**（已本地签名，无需云签名）。
3. 填版本说明 → 提交 → 等待**基础审核**（一般数小时~1-2 天）。

## 第 7 步：添加测试者并分发

1. 内测页面 →「测试者管理」→ 添加测试者（华为账号邮箱/手机号，个人开发者上限约 100 人）。
2. 生成**邀请链接 / 二维码** 发给朋友。
3. 朋友：登录华为账号 → 打开邀请链接（或应用市场内测专区）→ 安装「云手机」内测版。

## 第 8 步：迭代更新

- 每次更新：`AppScope/app.json5` 的 `versionCode` **必须递增**（+1）→ 重新构建 release unsigned HAP → 上传创建新内测版本 → 测试者自动收到更新提示。

## 常见问题

| 问题 | 说明 |
|---|---|
| 需要 UDID 吗？ | **不需要**。云端签名走发布证书，内测不限设备；仅 DevEco 真机调试（调试证书）才需要 UDID |
| 测试者装不上 / 提示未受信任 | 确认测试者用**华为账号登录应用市场**，且已被加入内测名单 |
| 审核被拒常见原因 | 模板图标、无隐私政策 URL、备案号缺失、应用名与功能不符 |
| 模拟器还能用吗 | 换 bundleName 后模拟器需重新安装（`hdc install -r` 新包即可，旧数据隔离） |
| 安全提醒 | 应用内默认账号 `admin/admin123` 自动登录、跳过证书校验——仅限受信局域网小范围使用，正式上架前需改成受信证书 + 用户自定义凭据 |

## 参考链接

- 华为官方[开放式测试（公测）发布文档](https://developer.huawei.com/consumer/cn/doc/AppGallery-connect-Guides/agc-betatest-release-0000001071228673)（内测流程同源，页面叫法略有差异）
- 华为[应用审核 Checklist](https://developer.huawei.com/consumer/cn/doc/App/50170)
- 第三方[HarmonyOS 应用内部测试全面指南](https://www.cnblogs.com/xiaozhaoxueHM/p/18936356)
