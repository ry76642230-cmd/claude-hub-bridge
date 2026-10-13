# install.ps1 - 在新机器上装配 claude-hub-bridge
#
# 流程：
#   [0/5] 前置检查：node / 千问办公（缺千问办公只给下载链接，不阻塞）
#   [1/5] 自动安装 / 校验 Claude Code CLI（npm 用户级全局，无需管理员）
#   [2/5] 写 ~/.claude/settings.json 的 env 块（指向本层 8820；原文件自动备份）
#   [3/5] 注册看门狗计划任务（每 1 分钟检查 8820，挂了就拉起）
#   [4/5] 写开机自启（启动文件夹里的 vbs，无窗口）
#   [5/5] 立刻启动一次并做健康检查
#
# 全部路径由本脚本位置推导，换机器可直接跑。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1 -SkipClaude -SkipClaudeSettings
param(
  [switch]$SkipClaude,
  [switch]$SkipClaudeSettings,
  [switch]$RemoteHub,        # 本机不装 Hub，改用 Tailscale 上另一台机器的 Hub
  [string]$RemoteHubHost,    # 远端 Hub 的 Tailscale IP / MagicDNS 名（不给则自动探测）
  [string]$RemoteHubPeer,    # 远端机器的 Tailscale 主机名（与 RemoteHubHost 二选一）
  [string]$RemoteHubKey      # 远端 Hub 的 API Key（不给则读本地/交互输入）
 )

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$taskName   = 'ClaudeHubBridgeWatchdog'
$vbsHidden  = Join-Path $root 'watchdog-hidden.vbs'
$bridgeJs   = Join-Path $root 'anthropic-hub-bridge.mjs'
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
$startupVbs = Join-Path $startupDir 'claude-hub-bridge.vbs'
$qwRoot     = if ($env:QWENWORK_ROOT) { $env:QWENWORK_ROOT } else { 'C:\Program Files\QwenWorkCN' }
$qwUrl      = 'https://www.qwenwork.cn/download'

Write-Host '=== claude-hub-bridge 安装 ===' -ForegroundColor Cyan
Write-Host "仓库目录: $root"

# ---- 0. 前置检查 ----
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) {
  foreach ($c in @('C:\Program Files\nodejs\node.exe', "$env:LOCALAPPDATA\Programs\nodejs\node.exe")) {
    if (Test-Path $c) { $node = $c; break }
  }
}
if (-not $node) { throw '未找到 node.exe，请先安装 Node.js（建议 22 以上）' }
$nodeVer = (& $node -v) -replace '^v', ''
Write-Host "[0/5] node : $node (v$nodeVer)"

$nodeMajor = [int]($nodeVer.Split('.')[0])
if ($nodeMajor -lt 22) {
  Write-Host "  ! Node $nodeVer 偏低，Claude Code 最新版要求 >= 22，建议升级" -ForegroundColor Yellow
}

$qwExe = $null
if (Test-Path $qwRoot) {
  $qwExe = Get-ChildItem -Path $qwRoot -Directory -ErrorAction SilentlyContinue |
           Sort-Object Name -Descending |
           ForEach-Object { Join-Path $_.FullName 'QwenWorkCN.exe' } |
           Where-Object { Test-Path $_ } | Select-Object -First 1
}
if ($qwExe) {
  Write-Host "[0/5] 千问办公 : $qwExe"
} else {
  Write-Host "[0/5] 千问办公 : 未检测到（仅影响换芯那一步，本层可先装）" -ForegroundColor Yellow
  Write-Host "      下载: $qwUrl" -ForegroundColor Yellow
}

if (-not (Test-Path $bridgeJs))  { throw "缺少 $bridgeJs" }
if (-not (Test-Path $vbsHidden)) { throw "缺少 $vbsHidden" }

# ---- 0.5 上游来源：本机 Hub 还是远端 Hub（Tailscale）----
# 不装 Hub 的机器用 -RemoteHub 一步接好：装 Tailscale → 找到托管 Hub 的机器 → 配好上游和 key。
if ($RemoteHub) {
  Write-Host '[0.5] 配置远端 Hub（Tailscale）...' -ForegroundColor Cyan
  $setup = Join-Path $root 'setup-remote-hub.ps1'
  if (-not (Test-Path $setup)) { throw "缺少 $setup" }
  $setupArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $setup)
  if ($RemoteHubHost) { $setupArgs += @('-HubHost', $RemoteHubHost) }
  if ($RemoteHubPeer) { $setupArgs += @('-Peer', $RemoteHubPeer) }
  if ($RemoteHubKey)  { $setupArgs += @('-HubKey', $RemoteHubKey) }
  & powershell @setupArgs
  if ($LASTEXITCODE -ne 0) { throw '远端 Hub 配置失败，见上面的输出' }
  Write-Host '[0.5] 远端 Hub 已接好' -ForegroundColor Green
} else {
  $localHub = $false
  try {
    $probe = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 'http://127.0.0.1:8788/health'
    if ($probe.StatusCode -eq 200) { $localHub = $true }
  } catch { }
  if ($localHub) {
    Write-Host '[0.5] 检测到本机 8788 有 Hub，使用本机 Hub' -ForegroundColor Green
  } else {
    Write-Host '[0.5] 本机没有 Hub（8788 无响应）' -ForegroundColor Yellow
    Write-Host '      两种选择：'
    Write-Host '        A. 本机自己装 Hub：见 docs\INSTALL-NEW-PC.md 第一步（需 Docker + 账号 OAuth）'
    Write-Host '        B. 借用别的机器上的 Hub（需 Tailscale）：重跑本安装器并加 -RemoteHub'
    Write-Host '           例: powershell -ExecutionPolicy Bypass -File install.ps1 -RemoteHub'
    Write-Host '     继续安装也可以，稍后随时用 setup-remote-hub.ps1 补上网关。' -ForegroundColor Yellow
  }
}

if ($SkipClaude) {
  Write-Host '[1/5] 跳过 Claude CLI 安装（-SkipClaude）'
} else {
  $claudeExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
  if (-not $claudeExe) {
     = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (Test-Path $guess) { $claudeExe = $guess }
  }
  if ($claudeExe) {
    $cv = (& $claudeExe --version 2>&1 | Select-Object -First 1)
    Write-Host "[1/5] Claude CLI 已装 : $cv"
  } else {
    $npm = (Get-Command npm -ErrorAction SilentlyContinue).Source
    if (-not $npm) { throw '未找到 npm，无法自动安装 Claude Code CLI' }
    Write-Host '[1/5] 安装 Claude Code CLI（npm 全局，用户级，无需管理员）...'
    &  install -g '@anthropic-ai/claude-code' 2>&1 | Select-Object -Last 5
    $guess = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (Test-Path $guess) {
      Write-Host "[1/5] 安装完成 : $(& $guess --version 2>&1 | Select-Object -First 1)" -ForegroundColor Green
    } else {
      Write-Host '[1/5] 安装后仍未找到 claude.exe，请开新终端后重试' -ForegroundColor Yellow
    }
  }
}

# ---- 2. ~/.claude/settings.json ----
if ($SkipClaudeSettings) {
  Write-Host '[2/5] 跳过 claude 配置写入（-SkipClaudeSettings）'
} else {
  $claudeDir = Join-Path $env:USERPROFILE '.claude'
  $settings  = Join-Path $claudeDir 'settings.json'
  if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

  $cfg = [ordered]@{}
  if (Test-Path $settings) {
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $settings -Destination "$settings.bak-$stamp" -Force
    Write-Host "[2/5] 已备份原配置 -> settings.json.bak-$stamp"
    try {
      $old = Get-Content -LiteralPath $settings -Raw | ConvertFrom-Json
      foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
    } catch {
      Write-Host '  ! 原配置不是合法 JSON，将覆盖写入（备份已留）' -ForegroundColor Yellow
      $cfg = [ordered]@{}
    }
    if (-not $cfg.Contains('env')) { $cfg['env'] = [ordered]@{} }
  } else {
    $cfg['env'] = [ordered]@{}
  }

  $envObj = [ordered]@{}
  if ($cfg['env']) { foreach ($p in $cfg['env'].PSObject.Properties) { $envObj[$p.Name] = $p.Value } }
  $envObj['ANTHROPIC_BASE_URL'] = 'http://127.0.0.1:8820'
  if (-not $envObj.Contains('ANTHROPIC_AUTH_TOKEN')) { $envObj['ANTHROPIC_AUTH_TOKEN'] = 'hub-local' }
  $envObj['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
  $envObj['DISABLE_TELEMETRY'] = '1'
  $envObj['DISABLE_ERROR_REPORTING'] = '1'
  $envObj['DISABLE_AUTOUPDATER'] = '1'
  $cfg['env'] = $envObj

  $json = $cfg | ConvertTo-Json -Depth 12
  [System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "[2/5] 已写入 $settings（ANTHROPIC_BASE_URL -> 127.0.0.1:8820）" -ForegroundColor Green
}

# ---- 3. 看门狗计划任务 ----
# 坑1: /SC MINUTE 默认只重复 10 分钟就永久停止。
# 坑2: RepetitionDuration 用 [TimeSpan]::MaxValue 会报 out of range。
#      用「-Once + 1 分钟间隔 + 3650 天时长」等效无限，且能被任务计划接受。
$existing = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existing) {
  Write-Host '[3/5] 计划任务已存在，先删除'
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

$action    = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbsHidden`""
$trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date) `
               -RepetitionInterval (New-TimeSpan -Minutes 1) `
               -RepetitionDuration (New-TimeSpan -Days 3650)
$taskCfg   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
               -StartWhenAvailable -MultipleInstances IgnoreNew `
               -ExecutionTimeLimit ([TimeSpan]::Zero)
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
  -Settings $taskCfg -Principal $principal | Out-Null
Write-Host "[3/5] 计划任务 $taskName 已注册（每 1 分钟）"

# ---- 4. 开机自启 ----
if (-not (Test-Path $startupDir)) { New-Item -ItemType Directory -Path $startupDir -Force | Out-Null }
$vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.CurrentDirectory = "$root"
sh.Run """$node"" ""$bridgeJs""", 0, False
"@
Set-Content -LiteralPath $startupVbs -Value $vbs -Encoding ASCII
Write-Host "[4/5] 开机自启已写入 $startupVbs"

# ---- 5. 启动 + 健康检查 ----
Write-Host '[5/5] 启动翻译层...'
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
    Write-Host '  ⚠ hubKey=MISSING —— 请配置 Hub 凭据（见 README「换台机器怎么用」）' -ForegroundColor Yellow
  }
} catch {
  Write-Host "健康检查失败: $($_.Exception.Message)" -ForegroundColor Red
  Write-Host '  若 hubKey=MISSING，请配置: $env:HUB_API_KEY 或仓库内 hub-settings.json'
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
Write-Host '提示：换芯千问办公还需在其仓库里跑 pnpm apply，或双击 scripts\start-qwenwork.bat。' -ForegroundColor Cyan
