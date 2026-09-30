<#
  安装 git pre-commit 钩子（core.hooksPath 方案，钩子文件入库、天然 LF）。
  执行：git config core.hooksPath <repo>/scripts/git-hooks
  并清理旧式 .git/hooks/pre-commit 残留。

  用法（仓库根）：pwsh scripts/install-hooks.ps1
  卸载：git config --unset core.hooksPath
#>
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$HooksDir = (Join-Path $RepoRoot 'scripts\git-hooks') -replace '\\', '/'

if (-not (Test-Path (Join-Path $RepoRoot '.git'))) { Write-Error '当前不是 git 仓库根目录'; exit 2 }
if (-not (Test-Path (Join-Path $RepoRoot 'scripts\git-hooks\pre-commit'))) { Write-Error '缺少 scripts/git-hooks/pre-commit'; exit 2 }

git -C $RepoRoot config core.hooksPath $HooksDir
if ($LASTEXITCODE -ne 0) { Write-Error "设置 hooksPath 失败: $RepoRoot"; exit 2 }

$old = Join-Path $RepoRoot '.git\hooks\pre-commit'
if (Test-Path $old) { Remove-Item $old -Force; Write-Output "已清理旧式钩子: $old" }
Write-Output "已设置 hooksPath: $RepoRoot -> $HooksDir"
Write-Output '验证：pwsh scripts/lint.ps1 -ExitOn error'