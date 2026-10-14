<#
set-effort.ps1 - 设置「千问办公 → claude → 翻译层 → Hub」这条路的思考强度

背景：翻译层默认不传强度，各模型用 Hub 目录里的默认档（多为 high）。
本脚本设置 BRIDGE_EFFORT，让翻译层在转发时带上强度。

用法:
  .\set-effort.ps1                 查看当前设置 + 每个模型实际会用的档
  .\set-effort.ps1 strongest       每个模型用「自己支持的最高档」（推荐）
  .\set-effort.ps1 high            指定档；模型不支持时自动退回该模型的最高档
  .\set-effort.ps1 -Clear          清空，回到「各模型用 Hub 默认档」

注意：小任务（claude 的 haiku 档，跑标题/摘要）默认不抬高，避免浪费额度；
      要连它一起抬高就再设 BRIDGE_EFFORT_INCLUDE_SMALL=1。
      模型档位取自 Hub 的 /v1/models（上游声明的 supportedEfforts）。
#>
param(
  [Parameter(Position = 0)][string]$Level,
  [switch]$Clear
)

$ErrorActionPreference = 'Stop'
# 只在输出被重定向（管道/文件）时强制 UTF-8，避免我的抓取乱码；交互式控制台保持系统默认
if ([Console]::IsOutputRedirected) { try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {} }
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$envName = 'BRIDGE_EFFORT'
$bridgeUrl = 'http://127.0.0.1:8820'

function Get-Health {
  try { return (Invoke-WebRequest "$bridgeUrl/health" -TimeoutSec 8 -UseBasicParsing).Content | ConvertFrom-Json }
  catch { return $null }
}

function Show-Plan($h) {
  if (-not $h -or -not $h.effort) { Write-Host '  （翻译层没有上报强度信息，可能还是旧版本）' -ForegroundColor Yellow; return }
  $mode = $h.effort.mode
  if ($mode) { Write-Host "  强度模式: $mode" -ForegroundColor Green }
  else { Write-Host '  强度模式: 未设置（各模型用 Hub 默认档）' -ForegroundColor Yellow }
  if ($h.effort.note) { Write-Host "  $($h.effort.note)" }
  if ($h.effort.plan) {
    Write-Host '  各模型实际档位:'
    $h.effort.plan.PSObject.Properties | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Name, $_.Value) }
  }
}

Write-Host '=== 翻译层思考强度 ===' -ForegroundColor Cyan

if (-not $Level -and -not $Clear) {
  Show-Plan (Get-Health)
  Write-Host ''
  Write-Host '示例: .\set-effort.ps1 strongest' -ForegroundColor Cyan
  exit 0
}

if ($Clear) {
  [Environment]::SetEnvironmentVariable($envName, $null, 'User')
  Remove-Item "Env:$envName" -ErrorAction SilentlyContinue
  Write-Host "[1/3] 已清除用户级 $envName" -ForegroundColor Green
} else {
  [Environment]::SetEnvironmentVariable($envName, $Level, 'User')
  $env:BRIDGE_EFFORT = $Level
  Write-Host "[1/3] 已写入用户级 $envName = $Level" -ForegroundColor Green
}

Write-Host '[2/3] 重启翻译层...'
$restart = Join-Path $root 'restart-bridge.ps1'
if (-not (Test-Path $restart)) { throw "缺少 $restart" }
& $restart | Out-Null
Start-Sleep -Seconds 3

Write-Host '[3/3] 校验...'
$h = Get-Health
if (-not $h) { Write-Host '  翻译层无响应，看门狗会在 1 分钟内拉起' -ForegroundColor Yellow; exit 1 }
Show-Plan $h
Write-Host ''
Write-Host '完成。' -ForegroundColor Green
