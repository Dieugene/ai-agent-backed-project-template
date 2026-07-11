# ref.ps1 - injects shared canonical docs into agent context on demand.
# Called from skills: & <workspace-root>\.references\ref.ps1 <topic>
# ASCII-only literals in this file by design (avoids the ps1-BOM/Cyrillic pitfall).
param(
    [Parameter(Position = 0)][string]$Topic,
    [switch]$List
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$map = [ordered]@{
    'windows'           = (Join-Path $root 'base\windows-pitfalls.md')
    'secrets'           = (Join-Path $root 'base\secrets.md')
    'pool-coordination' = '<workspace-root>\.launcher\pool-bus\COORDINATION.md'
    'pool-lifecycle'    = (Join-Path $root 'pool\lifecycle.md')
    'pool-grow-team'    = (Join-Path $root 'pool\grow-team.md')
    'tech-lead'         = (Join-Path $root 'roles\tech-lead.md')
    'qa'                = (Join-Path $root 'roles\qa.md')
}

if ($List -or [string]::IsNullOrEmpty($Topic) -or -not $map.Contains($Topic)) {
    "ref.ps1 topics: " + ($map.Keys -join ', ')
    if ($Topic -and -not $map.Contains($Topic)) { "unknown topic: $Topic"; exit 1 }
    exit 0
}

$file = $map[$Topic]
if (-not (Test-Path $file)) {
    "ref.ps1: source file missing: $file -- report this to the user, do not improvise."
    exit 1
}

"=== INSTRUCTION ($Topic): apply the guidance below to your current task ==="
Get-Content $file -Encoding UTF8 -Raw
"=== END OF INSTRUCTION ($Topic) ==="
