/**
 * QuickStartCmd —— 快速接入命令模板（纯函数，P2-11）
 *
 * 职责（单一）：run.sh / run.bat 一键命令与 cpctl 刷机配置命令的字符串生成。
 * 与 IO 分离（ICE 拉取/地址解析在 features/onboarding/QuickStart），使展示组件
 *   （components/QuickStartCard）可按分层规则安全 import utils 而不触碰 features。
 * 模板逐字符对齐上游 DeviceList.vue quickstart 区（470-507）。
 */

/** 一键命令（上游 run.sh / run.bat 模板原样；os='unix'|'win'） */
export function buildRunCommand(os: string, deviceId: string, signaling: string, iceJson: string): string {
  const id = deviceId.length > 0 ? deviceId : 'device_01';
  const exec = os === 'win' ? 'run.bat' : './run.sh';
  const prefix = os === 'win' ?
    ':: 解压后在本地 CMD 窗口执行一键命令 (自动探测手机架构并推送拉起服务)' :
    '# 解压后在本地终端执行一键命令 (自动探测手机架构并推送拉起服务)';
  const head = os === 'win' ? '' : 'chmod +x run.sh\n';
  return `${prefix}\n${head}${exec} -id "${id}" -signaling "${signaling}" -ice-servers "${iceJson}"`;
}

/** Magisk/KSU 刷机配置命令（cpctl；deviceId 有值才追加 CP_AGENT_ID 行） */
export function buildCpctlCommand(deviceId: string, signaling: string, iceJson: string): string {
  let cmd = `su\ncpctl set CP_AGENT_SIGNALING "${signaling}"\ncpctl set CP_AGENT_ICE_SERVERS "${iceJson}"`;
  if (deviceId.length > 0) {
    cmd += `\ncpctl set CP_AGENT_ID "${deviceId}"`;
  }
  cmd += '\ncpctl restart';
  return cmd;
}
