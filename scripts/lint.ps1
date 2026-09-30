<#
  ArkTS Code Linter 包装脚本（DevEco Studio 内置 Code Linter 的命令行入口）

  用法（仓库根目录执行）：
    pwsh scripts/lint.ps1                  # 默认：扫 entry/ 下的 ArkTS 源码，error+warn 非零退出
    pwsh scripts/lint.ps1 -Format json -Out lint-report.json
    pwsh scripts/lint.ps1 -Fix             # 自动修复（仅官方标注可修的规则）
    pwsh scripts/lint.ps1 -ExitOn error    # 仅 error 阻断（pre-commit 用此档）

  依赖：DevEco Studio 内置 node + Code Linter 插件。
  路径可用环境变量 DEVECO_HOME 覆盖；未设置时按常见安装位置探测。
#>
param(
  [string]$Target = 'entry',
  [ValidateSet('default', 'json', 'xml', 'html')]
  [string]$Format = 'default',
  [string]$Out = '',
  [string[]]$ExitOn = @('error', 'warn'),
  [switch]$Fix,
  [switch]$Incremental
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot

# DevEco 位置：优先 $env:DEVECO_HOME，否则按常见安装位置探测
$DevEco = $env:DEVECO_HOME
if (-not $DevEco) {
  foreach ($cand in @('D:\Apps\DevEco Studio', 'C:\Program Files\Huawei\DevEco Studio',
                      "$env:LOCALAPPDATA\Programs\DevEco Studio")) {
    if (Test-Path $cand) { $DevEco = $cand; break }
  }
}
if (-not $DevEco) { Write-Error "未找到 DevEco Studio，请设置环境变量 DEVECO_HOME"; exit 2 }

$Node = Join-Path $DevEco 'tools\node\node.exe'
$Cli = Join-Path $DevEco 'plugins\codelinter\run\index.js'
$Config = Join-Path $RepoRoot 'code-linter.json5'

foreach ($p in @($Node, $Cli, $Config)) {
  if (-not (Test-Path $p)) { Write-Error "缺少依赖: $p"; exit 2 }
}

$cliArgs = @($Cli, '-c', $Config, '-e', ($ExitOn -join ','), '-f', $Format)
if ($Out) { $cliArgs += @('-o', $Out) }
if ($Fix) { $cliArgs += '--fix' }
if ($Incremental) { $cliArgs += '-i' }
if (-not (Test-Path $Target)) { $Target = Join-Path $RepoRoot $Target }
$cliArgs += $Target

& $Node @cliArgs
exit $LASTEXITCODE
