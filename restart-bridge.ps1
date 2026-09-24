# restart-bridge.ps1 - restart the translation layer and health-check it
$root = $PSScriptRoot
if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { $node = 'C:\Program Files\nodejs\node.exe' }

& (Join-Path $root 'stop-bridge.ps1')
Start-Sleep -Seconds 2
Start-Process -FilePath $node -ArgumentList (Join-Path $root 'anthropic-hub-bridge.mjs') -WindowStyle Hidden -WorkingDirectory $root
Start-Sleep -Seconds 3
try {
  (Invoke-WebRequest 'http://127.0.0.1:8820/health' -TimeoutSec 8 -UseBasicParsing).Content
} catch {
  'ERR: ' + $_.Exception.Message
}
