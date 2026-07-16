# run-bridge.ps1 - shared runner for remote-bridge (one copy for all instances). ASCII-only.
#
# Loops `python bridge.py`, auto-restarts on crash, stops on fatal (exit 2). Instance is
# env-driven (REMOTE_BRIDGE_PROJECT_DIR / POOL_BUS_ROOT) or -ProjectDir. A per-instance thin
# .bat sets AGENT_OWNER / POOL_BUS_ROOT (or REMOTE_BRIDGE_PROJECT_DIR) and calls this file.
#
# Exit codes: 0 = clean stop (Ctrl+C); 2 = fatal (409 / live lock / pool without manifest) =>
# no restart; anything else = crash => restart in 10s. Token-not-set does NOT exit - the
# bridge waits quietly, so this runner keeps a single python process up.

param([string]$ProjectDir)

$ErrorActionPreference = 'Continue'
$bridge = Join-Path $PSScriptRoot 'bridge.py'
$argv = @($bridge)
if ($ProjectDir) { $argv += @('--project-dir', $ProjectDir) }

while ($true) {
    & python @argv
    $code = $LASTEXITCODE
    if ($code -eq 2) {
        Write-Host 'FATAL (exit 2): another poller / live lock / pool without manifest. Not restarting.'
        break
    }
    if ($code -eq 0) { break }
    Write-Host "bridge exited with $code, restart in 10s (Ctrl+C to stop)..."
    Start-Sleep -Seconds 10
}
