# remote_sentinel_gate.ps1 - Stop-hook gate for remote-bridge (generalized). ASCII-only.
#
# Fires (exit 2 + re-arm instruction) ONLY when ALL hold:
#   AGENT_OWNER == the bridge's CURRENT TARGET (state/current-target.txt)
#   AND the bridge is alive (bridge.lock pid runs)
#   AND chat_sentinel is dead (no live chat-sentinel.lock pid)
# Otherwise exit 0 - other roles/sessions are never touched, and a down bridge is a
# different alarm (stay silent). Wire ONLY to the Stop hook in a session's settings.local.json.
#
# The message below dictates the background-task DESCRIPTION as well as the command, on
# purpose: the harness stops the sentinel at arbitrary times (measured 2026-07-28: 2.8 /
# 9.3 / 73 / 117 / 337 min, no timeout), a killed task loses its buffered stdout, and the
# description is the only text that survives into the wake-up summary.
#
# State dir: env REMOTE_BRIDGE_STATE_DIR (explicit; set it for solo where data_dir moves) >
#            <REMOTE_BRIDGE_PROJECT_DIR>\03_data\state > <POOL_BUS_ROOT parent>\03_data\state.
# Liveness = pid-in-lock is a live process (locks store pid at start; ts is not a heartbeat).

if (-not $env:AGENT_OWNER) { exit 0 }

$state = $env:REMOTE_BRIDGE_STATE_DIR
if (-not $state) {
    $proj = $env:REMOTE_BRIDGE_PROJECT_DIR
    if (-not $proj -and $env:POOL_BUS_ROOT) { $proj = Split-Path $env:POOL_BUS_ROOT -Parent }
    if ($proj) { $state = Join-Path $proj '03_data\state' }
}
if (-not $state) { exit 0 }   # cannot locate instance -> never block

$ctFile = Join-Path $state 'current-target.txt'
if (-not (Test-Path $ctFile)) { exit 0 }
$target = ''
try { $target = (Get-Content $ctFile -Raw -Encoding utf8).Trim() } catch { exit 0 }
if ($env:AGENT_OWNER -ne $target) { exit 0 }   # not the current target -> not our alarm

function PidAlive([string]$lockFile) {
    if (-not (Test-Path $lockFile)) { return $false }
    try {
        $p = (Get-Content $lockFile -Raw -Encoding utf8 | ConvertFrom-Json).pid
    } catch {
        return $false
    }
    if (-not $p) { return $false }
    return [bool](Get-Process -Id $p -ErrorAction SilentlyContinue)
}

# Bridge down => different alarm, stay silent.
if (-not (PidAlive (Join-Path $state 'bridge.lock'))) { exit 0 }
if (PidAlive (Join-Path $state 'chat-sentinel.lock')) { exit 0 }

[Console]::Error.WriteLine('chat_sentinel is NOT running. Before idling, arm it as a background Bash task (run_in_background), BOTH fields:')
[Console]::Error.WriteLine('  command:     python C:\workspace-root\.launcher\pool-bus\remote-bridge\tools\chat_sentinel.py')
[Console]::Error.WriteLine('  description: chat sentinel idle-wait: EMPTY output = harness stopped it, nothing arrived, just re-arm; any printed line says what to do')
[Console]::Error.WriteLine('The description is not decoration: it is echoed verbatim in the wake-up summary, and when the harness kills the task its stdout is lost, so that line is the ONLY text that reaches you.')
exit 2
