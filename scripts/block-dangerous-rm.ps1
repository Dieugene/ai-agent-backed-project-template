# block-dangerous-rm.ps1  --  PreToolUse safety guard (global).
# Reads the hook JSON from stdin, inspects tool_input.command for Bash/PowerShell,
# and BLOCKS a recursive delete aimed at a catastrophic target:
#   $VAR/  ${VAR}/  "$VAR"/  $VAR\   (variable-before-slash: empty var -> wipes wrong tree)
#   /  /*  bare filesystem root       C:\  C:\*  bare drive root
#   ~  ~/  $HOME  $USERPROFILE        home directory
# SURGICAL: plain recursive deletes of a named/relative path are allowed.
# ASCII-only by design (avoids the .ps1 BOM/Cyrillic corruption trap on PS 5.1).
#
# Run  `powershell -File block-dangerous-rm.ps1 -SelfTest`  to verify the matcher.
# Test cases live as DATA inside this file, so no dangerous string ever reaches a
# shell command line -- the self-test command itself is clean.
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'

function Test-DangerousRm {
    param([string]$cmd)
    if (-not $cmd) { return $null }
    $delVerb   = '(?i)(^|[\s;&|(])(rm|rmdir|rd|del|erase|ri|remove-item)(\s|$)'
    $recursive = '(?i)\s-{1,2}[a-z]*r'
    if (-not (($cmd -match $delVerb) -and ($cmd -match $recursive))) { return $null }
    $danger = @(
        '\$\{?\w+\}?["'']?[\\/]',          # $VAR/  ${VAR}/  "$VAR"/  $VAR\  -- the incident pattern
        '\$env:\w+["'']?[\\/]',            # $env:X/  (PowerShell)
        '(\s|=)[\\/](\s|$|\*)',            # bare root  /  or  /*  (or backslash)
        '(\s|^|=)~[\\/]?(\s|$)',           # ~ or ~/ as a target
        '\$HOME\b', '\$\{HOME\}', '\$USERPROFILE\b', '\$env:USERPROFILE\b',
        '(\s|=)[A-Za-z]:[\\/](\s|$|\*)'    # bare drive root  C:\  or  C:\*
    )
    foreach ($p in $danger) { if ($cmd -match $p) { return $p } }
    return $null
}

if ($SelfTest) {
    # DATA ONLY -- these strings are regex-matched, never executed.
    $cases = @(
        @{ expect = 'DENY';  c = 'rm -rf "$SP"/*' }
        @{ expect = 'DENY';  c = 'rm -rf /' }
        @{ expect = 'DENY';  c = 'rm -rf $HOME/.cache' }
        @{ expect = 'DENY';  c = 'cd /x && rm -rf ${DIR}/*' }
        @{ expect = 'DENY';  c = 'Remove-Item -Recurse -Force $x\*' }
        @{ expect = 'DENY';  c = 'sudo rm -rf /*' }
        @{ expect = 'DENY';  c = 'rm -Rf ~/' }
        @{ expect = 'DENY';  c = 'rm -rf C:\*' }
        @{ expect = 'ALLOW'; c = 'rm -rf node_modules' }
        @{ expect = 'ALLOW'; c = 'rm -rf ./build/dist' }
        @{ expect = 'ALLOW'; c = 'rm -rf "${TMP:?unset}/x"' }
        @{ expect = 'ALLOW'; c = 'rm -f somefile.txt' }
        @{ expect = 'ALLOW'; c = 'ls -la /etc' }
        @{ expect = 'ALLOW'; c = 'git rm -r --cached foo' }
    )
    $pass = 0; $fail = 0
    foreach ($t in $cases) {
        $hit = Test-DangerousRm $t.c
        $got = if ($hit) { 'DENY' } else { 'ALLOW' }
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

$hit = Test-DangerousRm $cmd
if (-not $hit) { exit 0 }

$reasonBase = @'
BLOCKED by global safety guard: a recursive delete is aimed at a catastrophic target (a variable right before a slash, the filesystem/drive root, or the home directory). If that variable is empty or unset, this deletes the wrong tree - potentially the whole disk. Rewrite it safely: guard the variable with "${VAR:?not set}" so the shell aborts when it is empty/unset, and delete a specific literal subpath - never a bare variable-glob. Matched pattern:
'@
$out = [ordered]@{
    hookSpecificOutput = [ordered]@{
        hookEventName            = 'PreToolUse'
        permissionDecision       = 'deny'
        permissionDecisionReason = $reasonBase + $hit
    }
}
$out | ConvertTo-Json -Depth 5 -Compress
exit 0
