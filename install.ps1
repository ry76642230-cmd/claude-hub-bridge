# install.ps1 - 在新机器上装配 claude-hub-bridge
#   1. 注册看门狗计划任务（每 1 分钟检查 8820，挂了就拉起）
#   2. 写开机自启（启动文件夹里的 vbs）
#   3. 立刻启动一次并做健康检查
# 全部路径由本脚本位置推导，换机器可直接跑。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$taskName   = 'ClaudeHubBridgeWatchdog'
$vbsHidden  = Join-Path $root 'watchdog-hidden.vbs'
$bridgeJs   = Join-Path $root 'anthropic-hub-bridge.mjs'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupVbs = Join-Path $startupDir 'claude-hub-bridge.vbs'

Write-Host '=== claude-hub-bridge 安装 ===' -ForegroundColor Cyan
Write-Host "仓库目录: $root"

# ---- 0. 前置检查 ----
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
  foreach ($c in @('C:\Program Files\nodejs\node.exe', "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
    if (Test-Path $c) { $node = $c; break }
  }
}
if (-not $node) { throw '未找到 node.exe，请先安装 Node.js' }
Write-Host "[0/3] node : $node"

if (-not (Test-Path $bridgeJs))  { throw "缺少 $bridgeJs" }
if (-not (Test-Path $vbsHidden)) { throw "缺少 $vbsHidden" }

# ---- 1. 看门狗计划任务 ----
# 坑1: /SC MINUTE 默认只重复 10 分钟就永久停止。
# 坑2: RepetitionDuration 用 [TimeSpan]::MaxValue 会报
#      "The task XML contains a value which is incorrectly formatted or out of range"
#      （P99999999D 超出任务计划允许范围）。
#      用「-Once + 1 分钟间隔 + 3650 天时长」等效无限，且能被任务计划接受。
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host '[1/3] 计划任务已存在，先删除'
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action   = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsHidden`""
$trigger  = New-ScheduledTaskTrigger -Once -At (Get-Date) `
              -RepetitionInterval (New-TimeSpan -Minutes 1) `
              -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Settings $settings -Principal $principal | Out-Null
Write-Host "[1/3] 计划任务 $taskName 已注册（每 1 分钟）"

# ---- 2. 开机自启 ----
if (-not (Test-Path $startupDir)) { New-Item -ItemType Directory -Path $startupDir -Force | Out-Null }
$vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "$root"
sh.Run """$node"" ""$bridgeJs""", 0, False
"@
Set-Content -LiteralPath $startupVbs -Value $vbs -Encoding ASCII
Write-Host "[2/3] 开机自启已写入 $startupVbs"

# ---- 3. 启动 + 健康检查 ----
Write-Host '[3/3] 启动翻译层...'
$listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
             Where-Object LocalPort -eq 8820 | Select-Object -First 1
if (-not $listening) {
  Start-Process -FilePath $node -ArgumentList $bridgeJs -WindowStyle Hidden -WorkingDirectory $root
  Start-Sleep -Seconds 4
}
try {
  $h = (Invoke-WebRequest 'http://127.0.0.1:8820/health' -TimeoutSec 8 -UseBasicParsing).Content
  Write-Host "健康检查: $h" -ForegroundColor Green
  if ($h -match 'MISSING') {
    Write-Host '  ⚠ hubKey=MISSING —— 请配置 Hub 凭据（见 README「Hub 凭据」）' -ForegroundColor Yellow
  }
} catch {
  Write-Host "健康检查失败: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host '  若 hubKey=MISSING，请配置: $env:HUB_API_KEY 或仓库内 hub-settings.json'
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
