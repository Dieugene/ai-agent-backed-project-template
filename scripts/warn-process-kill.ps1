# warn-process-kill.ps1  --  PreToolUse advisory (global, NON-BLOCKING).
# Reads the hook JSON from stdin, inspects tool_input.command for Bash/PowerShell.
# When the command kills processes BY ATTRIBUTE/QUERY (name, CommandLine filter,
# Get-CimInstance|Stop-Process pipe, .Terminate(), taskkill /IM) -- a form that
# sweeps EVERY matching process machine-wide -- it ALLOWS the command but injects
# an advisory into the model's context (additionalContext), nudging the agent to
# reconsider. It NEVER blocks. By-PID kills (Stop-Process -Id <n>, taskkill /PID <n>)
# are the safe form and are deliberately NOT flagged.
#
# Stateless: no marker files, no per-session bookkeeping. Because it only advises
# (never denies), false positives are harmless, so the matcher stays deliberately
# crude. ASCII-only (avoids the .ps1 BOM/Cyrillic corruption trap on PS 5.1).
#
# Run  `powershell -File warn-process-kill.ps1 -SelfTest`  to verify the matcher.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

function Test-BroadKill {
    param([string]$cmd)
    if (-not $cmd) { return $null }
    # Broad = kill by name/query/method (sweeps ALL matching processes machine-wide).
    # By-PID forms are NOT matched -- they are the safe way to kill your own process.
    $patterns = @(
        '(?i)(get-ciminstance|get-wmiobject|gwmi|gcim|get-process|gps)\b[^\r\n]*\|[^\r\n]*(stop-process|\bkill\b|terminate)',
        '(?i)\|[^\r\n|]*stop-process\b',
        '(?i)stop-process\b[^\r\n;|]*-name\b',
        '(?i)\btaskkill\b[^\r\n]*/(im|fi|t)\b',
        '(?i)\.terminate\s*\(',
        '(?i)invoke-cimmethod\b[^\r\n]*terminate'
    )
    foreach ($p in $patterns) { if ($cmd -match $p) { return $p } }
    return $null
}

if ($SelfTest) {
    # DATA ONLY -- these strings are regex-matched, never executed.
    $cases = @(
        @{ expect = 'WARN'; c = 'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like "*pool*" } | Stop-Process' }
        @{ expect = 'WARN'; c = 'Get-CimInstance Win32_Process | ? { $_.Name -eq "powershell.exe" } | % { $_.Terminate() }' }
        @{ expect = 'WARN'; c = 'Get-Process -Name powershell | Stop-Process -Force' }
        @{ expect = 'WARN'; c = 'Stop-Process -Name node' }
        @{ expect = 'WARN'; c = 'taskkill /F /IM powershell.exe' }
        @{ expect = 'WARN'; c = '$w | Stop-Process' }
        @{ expect = 'PASS'; c = 'Stop-Process -Id 12345' }
        @{ expect = 'PASS'; c = 'taskkill /PID 12345 /F' }
        @{ expect = 'PASS'; c = 'Get-Process -Name node' }
        @{ expect = 'PASS'; c = 'ls -la' }
        @{ expect = 'PASS'; c = 'powershell -File warn-process-kill.ps1 -SelfTest' }
        @{ expect = 'PASS'; c = 'pool.ps1 watch' }
    )
    $pass = 0; $fail = 0
    foreach ($t in $cases) {
        $hit = Test-BroadKill $t.c
        $got = if ($hit) { 'WARN' } else { 'PASS' }
        $ok  = if ($got -eq $t.expect) { $pass++; 'ok  ' } else { $fail++; 'FAIL' }
        "{0}  {1,-5} (expect {2,-5})  {3}" -f $ok, $got, $t.expect, $t.c
    }
    ""
    "self-test: {0} passed, {1} failed" -f $pass, $fail
    if ($fail -gt 0) { exit 1 } else { exit 0 }
}

# ---- live hook mode (stdin JSON) ----
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$raw = [Console]::In.ReadToEnd()
if (-not $raw) { exit 0 }

$cmd = ''
try {
    $j = $raw | ConvertFrom-Json
    if ($j.tool_input -and $j.tool_input.command) { $cmd = [string]$j.tool_input.command }
} catch {
    $cmd = $raw   # unparseable payload: scan raw text rather than trust it
}

$hit = Test-BroadKill $cmd
if (-not $hit) { exit 0 }

$advice = @'
POOL SAFETY (advisory): killing by name/query hits EVERY matching process on the machine -- you can kill OTHER pool agents' watchers or whole Claude sessions, not just yours. For one clean watcher, don't kill anything -- just re-arm "pool.ps1 watch" (supersedes only your own by PID). If you must kill, target a specific PID (Stop-Process -Id), not -Name/CommandLine. (Vanished processes are usually a sibling's kill, not the antivirus.)
'@
$out = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName      = 'PreToolUse'
        permissionDecision = 'allow'
        additionalContext  = $advice
    }
}
$out | ConvertTo-Json -Depth 5 -Compress
exit 0
