# stop-bridge.ps1 - stop the Anthropic <-> Hub translation layer
$conn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
  Where-Object LocalPort -eq 8820 | Select-Object -First 1
if ($conn) {
  Stop-Process -Id $conn.OwningProcess -Force
  Write-Output ("stopped PID " + $conn.OwningProcess)
} else {
  Write-Output "bridge not running"
}
