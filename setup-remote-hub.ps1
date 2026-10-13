<#
setup-remote-hub.ps1 - 让本机不装 Hub，直接借用另一台机器（经 Tailscale）上的 Hub

适用：团队里只有一台机器跑 WorkBuddy Hub，其他机器只想用，不想装 Docker + 登录账号。
流程：
  [1/5] 确保 Tailscale 已安装并登录（未装则 winget 静默安装）
  [2/5] 探测 tailnet 里哪台机器托管着 Hub（扫 /health，找 api_key_required 特征）
  [3/5] 拿到 Hub API Key（从 -HubKey 参数 / 本地 Hub / 交互输入）
  [4/5] 写用户级环境变量 HUB_BASE_URL + HUB_API_KEY，重启翻译层
  [5/5] 校验：翻译层 /health 的 upstream 指向远端、hubKey=set，并实拉一次模型列表

用法：
  powershell -NoProfile -ExecutionPolicy Bypass -File setup-remote-hub.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File setup-remote-hub.ps1 -HubHost 100.127.69.57 -HubKey <36位key>
  powershell -NoProfile -ExecutionPolicy Bypass -File setup-remote-hub.ps1 -Peer desktop-4e6vmnr
#>
param(
  [string]$HubHost,        # 直接指定 Hub 所在机器的 Tailscale IP 或 MagicDNS 名
  [string]$Peer,           # 直接指定 Tailscale 对端主机名（自动取其 IPv4）
  [string]$HubKey,         # Hub 的 API Key；不给则尝试本地/交互获取
  [int]$HubPort = 8788,
  [switch]$SkipInstall     # 不自动安装 Tailscale
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$tsExe = 'C:\Program Files\Tailscale\tailscale.exe'

function Info($m) { Write-Host "  $m" }

# PS 5.1 的 Invoke-WebRequest 没有 -NoProxy（PS 7 才有）。打 tailnet/局域网地址时，
# 系统代理会把请求劫持成 502，所以按版本分派：有 -NoProxy 就用；没有就临时绕开代理。
function Test-Url([string]$Url, [int]$TimeoutSec = 5) {
  $iwr = Get-Command Invoke-WebRequest
  $hasNoProxy = $iwr.Parameters.ContainsKey('NoProxy')
  if ($hasNoProxy) {
    return Invoke-WebRequest -NoProxy -UseBasicParsing -TimeoutSec $TimeoutSec -Uri $Url
  }
  $old = [System.Net.WebRequest]::DefaultWebProxy
  try {
    [System.Net.WebRequest]::DefaultWebProxy = $null
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Headers.Add('User-Agent', 'codex-setup')
    $body = $wc.DownloadString($Url)
    return [pscustomobject]@{ Content = $body; StatusCode = 200 }
  } finally {
    [System.Net.WebRequest]::DefaultWebProxy = $old
  }
}

# 带自定义请求头的版本（鉴权用）
function Test-UrlWithKey([string]$Url, [string]$Key, [int]$TimeoutSec = 10) {
  $iwr = Get-Command Invoke-WebRequest
  if ($iwr.Parameters.ContainsKey('NoProxy')) {
    return Invoke-WebRequest -NoProxy -UseBasicParsing -TimeoutSec $TimeoutSec -Uri $Url -Headers @{ Authorization = "Bearer $Key" }
  }
  $old = [System.Net.WebRequest]::DefaultWebProxy
  try {
    [System.Net.WebRequest]::DefaultWebProxy = $null
    $wc = New-Object System.Net.WebClient
    $wc.Proxy = $null
    $wc.Headers.Add('Authorization', "Bearer $Key")
    $body = $wc.DownloadString($Url)
    return [pscustomobject]@{ Content = $body; StatusCode = 200 }
  } finally {
    [System.Net.WebRequest]::DefaultWebProxy = $old
  }
}
function Step($n, $m) { Write-Host "[$n] $m" -ForegroundColor Cyan }

Write-Host '=== 接入远端 WorkBuddy Hub（Tailscale）===' -ForegroundColor Green

# ---------- 1. Tailscale ----------
Step '1/5' '检查 Tailscale'
if (-not (Test-Path $tsExe)) {
  if ($SkipInstall) { throw '  Tailscale 未安装，且指定了 -SkipInstall。请先安装：winget install --id Tailscale.Tailscale -e' }
  Info '未安装，正在用 winget 静默安装（需要管理员权限，可能要弹一次 UAC）...'
  $wg = Get-Command winget -ErrorAction SilentlyContinue
  if (-not $wg) { throw '  本机没有 winget。请手动安装 Tailscale：https://tailscale.com/download' }
  & winget install --id Tailscale.Tailscale -e --accept-package-agreements --accept-source-agreements --silent
  Start-Sleep -Seconds 5
  if (-not (Test-Path $tsExe)) { throw "  安装后仍未找到 $tsExe，请手动确认" }
  Info '安装完成'
} else {
  Info "已安装: $((& $tsExe version 2>&1 | Select-Object -First 1))"
}

$state = (& $tsExe status --json 2>$null | ConvertFrom-Json)
if ($state.BackendState -ne 'Running') {
  Info '尚未登录，正在拉起登录（浏览器会打开，请用与 Hub 所在机器相同的账号登录）...'
  & $tsExe up --accept-routes
  Start-Sleep -Seconds 3
  $state = (& $tsExe status --json 2>$null | ConvertFrom-Json)
  if ($state.BackendState -ne 'Running') { throw '  登录未完成。请手动执行：tailscale up' }
}
$selfIp = (& $tsExe ip -4 2>$null | Select-Object -First 1)
Info "本机 Tailscale IP: $selfIp"

# ---------- 2. 找 Hub 所在机器 ----------
Step '2/5' '探测 tailnet 里的 Hub'
$candidates = @()
if ($Peer) {
  $ip = (& $tsExe ip -4 $Peer 2>$null | Select-Object -First 1)
  if (-not $ip) { throw "  找不到对端 '$Peer'。可用对端见：tailscale status" }
  $candidates += $ip
} elseif ($HubHost) {
  $candidates += $HubHost
} else {
  $peers = @()
  foreach ($k in $state.Peer.PSObject.Properties.Name) {
    $p = $state.Peer.$k
    if ($p.Online -and $p.TailscaleIPs) { $peers += ($p.TailscaleIPs | Where-Object { $_ -notmatch ':' } | Select-Object -First 1) }
  }
  $candidates += $peers
}

$found = $null
foreach ($h in $candidates) {
  if (-not $h) { continue }
  try {
    $r = Test-Url "http://${h}:$HubPort/health" 4
    $j = $r.Content | ConvertFrom-Json
    if ($j.PSObject.Properties.Name -contains 'api_key_required') {
      Info "命中 Hub: $h  ($($r.Content))"
      $found = $h
      break
    }
  } catch { }
}
if (-not $found) {
  if (-not $HubHost) {
    Info '未自动探测到 Hub。可能在线的机器没开 Hub，或端口不通。'
    Info '手动指定后重跑，例如：-HubHost 100.127.69.57'
  }
  throw "  未找到可用的 Hub（已尝试 $($candidates.Count) 个地址，端口 $HubPort）"
}

# ---------- 3. Hub API Key ----------
Step '3/5' '获取 Hub API Key'
$key = $HubKey
if (-not $key -and $env:HUB_API_KEY) { $key = $env:HUB_API_KEY; Info '沿用已有的 HUB_API_KEY' }
foreach ($c in @((Join-Path $root 'hub-settings.json'),
                 (Join-Path $env:USERPROFILE '.qwenworkcn\workspace\mu55844kqqe7tm63\workbuddy2api-hub\accounts\settings.json'))) {
  if ($key) { break }
  if (Test-Path $c) {
    try {
      $cfg = Get-Content $c -Raw -Encoding UTF8 | ConvertFrom-Json
      $pick = ($cfg.api_keys | Where-Object { $_.key -and $_.enabled -ne $false } | Select-Object -First 1)
      if ($pick) { $key = [string]$pick.key; Info "从 $c 读取到 key" }
    } catch { }
  }
}
if (-not $key) {
  Info '请粘贴 Hub 的 API Key（36 位；在跑 Hub 那台机器的面板 → 设置 → API Key 里看）'
  $secure = Read-Host -AsSecureString '  Hub API Key'
  $key = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
           [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)).Trim()
}
if (-not $key) { throw '  没有拿到 Hub API Key，无法继续' }

Info '验证 key 是否被远端 Hub 接受...'
try {
  $r = Test-UrlWithKey "http://${found}:$HubPort/v1/models" $key 10
  $cnt = (($r.Content | ConvertFrom-Json).data | Measure-Object).Count
  Info "key 有效，远端 Hub 提供 $cnt 个模型" -ForegroundColor Green
} catch {
  throw "  key 校验失败（$($_.Exception.Message)）。请确认 key 属于这台 Hub"
}

# ---------- 4. 写配置 + 重启翻译层 ----------
$baseUrl = "http://${found}:$HubPort"
Step '4/5' "写入上游配置：$baseUrl"
[Environment]::SetEnvironmentVariable('HUB_BASE_URL', $baseUrl, 'User')
[Environment]::SetEnvironmentVariable('HUB_API_KEY', $key, 'User')
$env:HUB_BASE_URL = $baseUrl
$env:HUB_API_KEY = $key
Info '已写入用户级 HUB_BASE_URL / HUB_API_KEY'

$restart = Join-Path $root 'restart-bridge.ps1'
if (Test-Path $restart) { & $restart | Out-Null; Info '翻译层已重启' }
else { Info "未找到 restart-bridge.ps1，稍后需手动重启翻译层" }

# ---------- 5. 校验 ----------
Step '5/5' '校验端到端'
Start-Sleep -Seconds 3
try {
  $hB = Test-Url 'http://127.0.0.1:8820/health' 8
  $h = $hB.Content | ConvertFrom-Json
  Info "翻译层 upstream = $($h.upstream)"
  Info "翻译层 hubKey   = $($h.hubKey)"
  if ($h.upstream -ne $baseUrl) { Info '上游与预期不一致，可能读到了旧环境变量（完全重启终端/翻译层）' -ForegroundColor Yellow }
  if ($h.hubKey -eq 'MISSING') { Info 'hubKey 仍是 MISSING，请重启翻译层后再看' -ForegroundColor Yellow }
} catch { Info "翻译层没响应：$($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host ''
Write-Host '完成。本机现在不跑 Hub，直接借用远端 Hub。' -ForegroundColor Green
Write-Host "  远端 Hub : $baseUrl" -ForegroundColor Green
Write-Host '  换模型   : .\set-model.ps1 <模型名>' -ForegroundColor Green
Write-Host "  前提     : 远端机器开机、Tailscale 在线；它关机你就连不上（这是借用的代价）" -ForegroundColor Yellow
