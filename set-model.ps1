<#
set-model.ps1 - 切换 claude-hub-bridge 的上游模型

背景：claude 自己传的模型名会被翻译层 pickModel() 改写，所以换模型要改翻译层的
BRIDGE_MODEL，而不是在 claude 里敲 /model。

用法:
  .\set-model.ps1                查看当前模型 + Hub 可用模型列表
  .\set-model.ps1 glm-5.3        切到 glm-5.3（写用户环境变量 -> 重启 -> 校验）
  .\set-model.ps1 -List          只列 Hub 可用模型
  .\set-model.ps1 -Clear         清除设置, 回到默认 deepseek-v4.1-flash

注意：环境变量在进程启动时读取，所以本脚本会重启翻译层；重启后会自动校验并打印结果。
#>
param(
  [Parameter(Position = 0)][string]$Model,
  [switch]$List,
  [switch]$Clear
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$bridgeUrl  = 'http://127.0.0.1:8820'
$hubUrl     = 'http://127.0.0.1:8788'
$envName    = 'BRIDGE_MODEL'
$defaultMdl = 'deepseek-v4.1-flash'

function Get-BridgeHealth {
  try { return (Invoke-WebRequest "$bridgeUrl/health" -TimeoutSec 8 -UseBasicParsing).Content | ConvertFrom-Json }
  catch { return $null }
}

# 与 anthropic-hub-bridge.mjs 相同的 Hub 凭据解析顺序
function Get-HubKey {
  if ($env:HUB_API_KEY) { return $env:HUB_API_KEY.Trim() }
  $candidates = @()
  if ($env:HUB_SETTINGS) { $candidates += $env:HUB_SETTINGS }
  $candidates += (Join-Path $root 'hub-settings.json')
  $candidates += (Join-Path $HOME '.qwenworkcn\workspace\mu55844kqqe7tm63\workbuddy2api-hub\accounts\settings.json')
  foreach ($c in $candidates) {
    if (-not (Test-Path $c)) { continue }
    try {
      $cfg = Get-Content $c -Raw | ConvertFrom-Json
      $pick = ($cfg.api_keys | Where-Object { $_.key -and $_.enabled -ne $false } | Select-Object -First 1)
      if (-not $pick) { $pick = ($cfg.api_keys | Where-Object { $_.key } | Select-Object -First 1) }
      if ($pick) { return ([string]$pick.key).Trim() }
    } catch { }
  }
  return ''
}

function Get-HubModels {
  $key = Get-HubKey
  if (-not $key) { return @() }
  try {
    $r = Invoke-WebRequest "$hubUrl/v1/models" -Headers @{ Authorization = "Bearer $key" } -TimeoutSec 10 -UseBasicParsing
    return @(($r.Content | ConvertFrom-Json).data | ForEach-Object { $_.id })
  } catch { return @() }
}

Write-Host '=== claude-hub-bridge 模型切换 ===' -ForegroundColor Cyan

# ---------- 只列模型 ----------
$available = Get-HubModels

if ($List) {
  if ($available.Count -eq 0) { Write-Host '取不到模型列表（Hub 未运行或凭据读不到）' -ForegroundColor Yellow; exit 1 }
  Write-Host 'Hub 可用模型:'
  $available | ForEach-Object { Write-Host "  $_" }
  exit 0
}

# ---------- 无参数: 看当前状态 ----------
if (-not $Model -and -not $Clear) {
  $h = Get-BridgeHealth
  if ($h) {
    Write-Host "翻译层: $($h.ok)  上游: $($h.upstream)  当前模型: " -NoNewline
    Write-Host $h.model -ForegroundColor Green
  } else {
    Write-Host '翻译层: 未运行（8820 没响应）' -ForegroundColor Yellow
  }

  $userVal = [Environment]::GetEnvironmentVariable($envName, 'User')
  if ($userVal) { Write-Host "用户环境变量 $envName = $userVal" }
  else { Write-Host "用户环境变量 $envName = (未设置, 用默认 $defaultMdl)" }

  if ($available.Count -gt 0) {
    Write-Host ''
    Write-Host 'Hub 可用模型:'
    $available | ForEach-Object { Write-Host "  $_" }
  }
  Write-Host ''
  Write-Host "切换示例: .\set-model.ps1 glm-5.3"
  exit 0
}

# ---------- 清除设置 ----------
if ($Clear) {
  [Environment]::SetEnvironmentVariable($envName, $null, 'User')
  Remove-Item "Env:$envName" -ErrorAction SilentlyContinue
  Write-Host "[1/3] 已清除用户环境变量 $envName" -ForegroundColor Green
} else {
  # ---------- 设置模型 ----------
  if ($available.Count -gt 0 -and $available -notcontains $Model) {
    Write-Host "[!] 警告: '$Model' 不在 Hub 返回的模型列表里" -ForegroundColor Yellow
    Write-Host "    若确认可用可忽略；可用列表见 .\set-model.ps1 -List"
  }
  [Environment]::SetEnvironmentVariable($envName, $Model, 'User')
  $env:BRIDGE_MODEL = $Model
  Write-Host "[1/3] 已写入用户环境变量 $envName = $Model" -ForegroundColor Green
}

# ---------- 重启翻译层 ----------
Write-Host '[2/3] 重启翻译层...'
$restart = Join-Path $root 'restart-bridge.ps1'
if (-not (Test-Path $restart)) { throw "缺少 $restart" }
& $restart | Out-Null
Start-Sleep -Seconds 3

# ---------- 校验 ----------
Write-Host '[3/3] 校验...'
$expect = if ($Clear) { $defaultMdl } else { $Model }
$h = Get-BridgeHealth
if (-not $h) {
  Write-Host '  校验失败: 8820 无响应' -ForegroundColor Red
  Write-Host '  提示: 看门狗会在 1 分钟内自动拉起; 也可手动跑 restart-bridge.ps1'
  exit 1
}

Write-Host "  上游: $($h.upstream)   hubKey: $($h.hubKey)"
if ($h.hubKey -eq 'MISSING') {
  Write-Host '  ⚠ hubKey=MISSING —— 翻译层读不到 Hub 凭据, 请求会失败' -ForegroundColor Yellow
}

if ($h.model -eq $expect) {
  Write-Host "  已生效: $($h.model)" -ForegroundColor Green
} else {
  Write-Host "  未生效: 期望 $expect, 实际 $($h.model)" -ForegroundColor Red
  Write-Host '  可能原因: 看门狗抢先拉起了旧实例。清理后重试:'
  Write-Host '    powershell -NoProfile -Command "Get-Process node | Where-Object { $_.Path -like ''*nodejs*'' } | Stop-Process -Force"'
  Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File .\restart-bridge.ps1'
  exit 1
}

Write-Host ''
Write-Host '完成。' -ForegroundColor Green
