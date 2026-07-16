# autostart.ps1 - start remote-bridge instances at logon. ASCII-only.
#
# WHY WMI: a bridge started with Start-Process from inside a Claude session joins that session's
# job object and is killed when the session exits (observed 2026-07-15: both bridges died on
# session teardown). Win32_Process.Create spawns outside the caller's job (parent = WmiPrvSE),
# so the bridge survives session exit, sleep/wake and logoff of the launching shell.
# WHY NOT Task Scheduler: schtasks/Register-ScheduledTask return "Access is denied" for this
# non-elevated user, so the per-user Startup folder is the available autostart hook.
#
# Instance list is DATA (autostart.json = array of project dirs) - the engine stays generic.
# Duplicate spawn is harmless: the bridge lock makes a second live instance exit (fatal, no retry).

param([string]$ListPath)

$ErrorActionPreference = 'Stop'
if (-not $ListPath) { $ListPath = Join-Path $PSScriptRoot 'autostart.json' }
if (-not (Test-Path $ListPath)) { exit 0 }

$engine = Join-Path $PSScriptRoot 'run-bridge.ps1'
$dirs = Get-Content $ListPath -Raw -Encoding UTF8 | ConvertFrom-Json

foreach ($d in $dirs) {
    if (-not (Test-Path $d)) { continue }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ProjectDir "{1}"' -f $engine, $d
    try {
        Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmd } | Out-Null
    } catch {
        # Never fail logon over a bridge; the instance simply stays down until started by hand.
    }
}
