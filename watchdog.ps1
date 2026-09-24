# watchdog.ps1 - keep the Anthropic <-> Hub translation layer alive.
# Invoked every minute by scheduled task CluadeHubBridgeWatchdog:
# if nothing listens on 8820, start the bridge again.
$ErrorActionPreference = 'Continue'

$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
$logDir = Join-Path $root 'logs'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$log = Join-Path $logDir 'watchdog.log'
$stamp = (Get-Date).ToString('s')

function Write-Log([string]$msg) {
  try { Add-Content -LiteralPath $log -Value "$stamp $msg" -Encoding utf8 } catch {}
}

$listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object LocalPort -eq 8820 | Select-Object -First 1

if ($listening) {
  # Healthy. Log at most once per hour to keep the file small.
  $last = Get-Item -LiteralPath $log -ErrorAction SilentlyContinue
  if (-not $last -or ((Get-Date) - $last.LastWriteTime).TotalMinutes -gt 60) {
    Write-Log "OK (pid $($listening.OwningProcess))"
  }
  exit 0
}

Write-Log 'DOWN -> restarting'
$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }
Start-Process -FilePath $node `
  -ArgumentList (Join-Path $root 'anthropic-hub-bridge.mjs') `
  -WindowStyle Hidden -WorkingDirectory $root
Start-Sleep -Seconds 5

$now = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object LocalPort -eq 8820 | Select-Object -First 1
if ($now) { Write-Log "restarted OK (pid $($now.OwningProcess))" }
else { Write-Log 'restart FAILED' }