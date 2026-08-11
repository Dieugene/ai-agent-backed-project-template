#requires -version 5
<#
  fresh-session.ps1 - spin up a FRESH session (new SessionTitle -> clean transcript) for an
  EXISTING pool owner, WITHOUT touching the manifest / CLAUDE.md / identity.

  Use when a live --resume session is stuck (garbled transcript, tool-call format drift) and
  re-resuming just reloads the same bad transcript. This clones a second wrapper (+ its Warp
  workflow) that launches the SAME owner / mailbox / ProjectKey under a NEW SessionTitle, so
  the fresh session sees the same inbox and 'pool mine' recovers its in-flight cur/ + new/ work.

  Sibling of add-peer.ps1 - but add-peer adds a NEW owner (a new identity in the manifest);
  this is for the SAME owner, so it deliberately does NOT edit the manifest or CLAUDE.md.

  Byte-preserving clone (latin1 codec, 1 byte <-> 1 char): Cyrillic REM / name bytes are copied
  verbatim; only the ASCII SessionTitle / .bat-reference / Warp name-prefix change. This .ps1 is
  pure ASCII (no BOM) so PS 5.1 never mangles it.

  Naming convention: a NEW session of the SAME role gets a NUMERIC suffix (2, then 3, ...), NOT 'fresh'.
  -Tag defaults to '2'; pass -Tag 3 (etc.) for a later re-seat of the same role.

  Usage:
    fresh-session.ps1 -Manifest <pool.manifest.json> -Owner metrics-<sub-a> [-Tag 2] [-Force] [-DryRun]
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Manifest,
  [Parameter(Mandatory=$true)][string]$Owner,
  [string]$Bat = '',
  [string]$Tag = '2',
  [switch]$Force,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
function Die($m){ Write-Host ('[fresh-session] ERROR: ' + $m) -ForegroundColor Red; exit 1 }
$L1 = [System.Text.Encoding]::GetEncoding(28591)   # byte-preserving codec (latin1): keeps Cyrillic bytes intact

if (-not (Test-Path $Manifest)) { Die "manifest not found: $Manifest" }
if ($Tag -notmatch '^[A-Za-z0-9]+$') { Die "tag must be ASCII alphanumeric (goes into filenames + SessionTitle): $Tag" }

$m = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
$root = $m.root
if (-not $root) { Die "manifest has no 'root'" }
if (-not ($m.roles | Where-Object { $_.owner -eq $Owner })) {
  Die "owner '$Owner' not in manifest roles - this tool is for EXISTING owners; use add-peer.ps1 for a NEW one"
}

# ---- server pool: identity lives in scripts/roles.tsv, not in a .bat ------------------------
# On the server a pool has NO per-role wrappers: one scripts/role.sh serves them all and the
# session title (the resume handle) is a column in scripts/roles.tsv. A fresh session there means
# exactly one thing: give this owner a NEW title. Mailbox, memory, ProjectKey and the tmux window
# name are untouched - the identity invariant holds by construction, there is nothing to clone.
$tsvPath = Join-Path $root (Join-Path 'scripts' 'roles.tsv')
$IsServerPool = (Test-Path $tsvPath) -and -not (Test-Path (Join-Path $root ("claude-{0}.bat" -f $Owner)))

if ($IsServerPool) {
  $lines = @([System.IO.File]::ReadAllLines($tsvPath, [System.Text.Encoding]::UTF8))
  $idx = -1
  for ($i = 0; $i -lt $lines.Count; $i++) {
    $ln = $lines[$i]
    if ($ln.TrimStart().StartsWith('#') -or -not $ln.Trim()) { continue }
    if (($ln -split "`t")[0] -eq $Owner) { $idx = $i; break }
  }
  if ($idx -lt 0) { Die ("owner '" + $Owner + "' not in " + $tsvPath) }
  $cols = $lines[$idx] -split "`t"
  if ($cols.Count -lt 2 -or -not $cols[1]) { Die ("no session title for '" + $Owner + "' in " + $tsvPath) }
  $origTitle = $cols[1]
  $newTitle  = "{0}-{1}" -f $origTitle, $Tag
  if ($origTitle -match ("-" + [regex]::Escape($Tag) + '$') -and -not $Force) {
    Die ("title is already '" + $origTitle + "' - pass a higher -Tag (3, 4...) or -Force")
  }
  $cols[1] = $newTitle
  # ASCII only: this file is declared pure ASCII without BOM, and PS 5.1 would read Cyrillic here
  # as cp1251 and mangle the source itself (the damage is invisible on the machine that wrote it).
  $note = '# fresh-session: ' + $Owner + ' - previous session title was ' + $origTitle
  $out = @()
  for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($i -eq $idx) { $out += $note; $out += ($cols -join "`t") } else { $out += $lines[$i] }
  }
  $tsvNew = ($out -join "`n").TrimEnd("`n") + "`n"

  if ($DryRun) {
    Write-Host "[fresh-session] DRY RUN - nothing written"
    Write-Host ("  owner (UNCHANGED): {0}   pool root: {1}" -f $Owner, $root)
    Write-Host ("  [edit]   {0}" -f $tsvPath)
    Write-Host ("           SessionTitle '{0}' -> '{1}'" -f $origTitle, $newTitle)
    Write-Host  "  (server pool: no wrappers and no Warp workflow are touched - the role runs in a tmux window)"
    exit 0
  }

  [System.IO.File]::WriteAllText($tsvPath, $tsvNew, (New-Object System.Text.UTF8Encoding($false)))

  # self-verify: read the row back from disk
  $back = [System.IO.File]::ReadAllText($tsvPath, [System.Text.Encoding]::UTF8)
  $row  = @($back -split "`r?`n" | Where-Object { ($_ -split "`t")[0] -eq $Owner }) | Select-Object -First 1
  $rc   = if ($row) { $row -split "`t" } else { @() }
  $fails = 0
  function ChkS($cond, $label) { if ($cond) { Write-Host ("  PASS  " + $label) -ForegroundColor Green } else { Write-Host ("  FAIL  " + $label) -ForegroundColor Red; $script:sfail++ } }
  $script:sfail = 0
  ChkS ([bool]$row)                              ("role still present: " + $Owner)
  ChkS ($rc.Count -ge 2 -and $rc[1] -eq $newTitle) ("new session title: " + $newTitle)
  ChkS ($rc.Count -ge 3 -and $rc[2] -eq $cols[2]) "effort unchanged"
  ChkS ($back.Contains($origTitle))              "previous title kept in a comment"
  Write-Host ''
  if ($script:sfail -ne 0) { Write-Host ("[fresh-session] {0} FAILED" -f $script:sfail) -ForegroundColor Red; exit 1 }
  Write-Host "[fresh-session] ALL PASS" -ForegroundColor Green
  Write-Host ''
  Write-Host 'Next steps are MANUAL - they touch a live session:'
  Write-Host ("  1) close the role window:  tmux -L agents kill-window -t {0}:{1}" -f $m.slug, $Owner)
  Write-Host ("  2) bring it back up:       ~/workspace/.launcher/scripts/pool-up.sh {0} {1}" -f $root, $Owner)
  Write-Host 'Mailbox, memory and ProjectKey are the same - `pool mine` recovers the in-flight work.'
  Write-Host 'No need to rebuild the Windows showcase: its wrapper targets the window by ROLE name, unchanged.'
  exit 0
}

$srcBatName = if ($Bat) { $Bat } else { "claude-{0}.bat" -f $Owner }
$srcBat = Join-Path $root $srcBatName
if (-not (Test-Path $srcBat)) { Die "source wrapper not found: $srcBat (if this pool names wrappers claude-<tag>-<role>.bat rather than claude-<owner>.bat, pass -Bat <name>)" }
$dstBatName = $srcBatName -replace '\.bat$', ("-{0}.bat" -f $Tag)
$dstBat = Join-Path $root $dstBatName

# ---- clone wrapper: change ONLY the SessionTitle, keep AGENT_OWNER + everything else ----
$b = $L1.GetString([System.IO.File]::ReadAllBytes($srcBat))
# Warp discovers .warp\workflows from the agent's cwd (its cd /d target), NOT manifest.root.
$cwd = ''
$mtc = [regex]::Match($b, '(?im)^\s*cd\s+/d\s+(.+?)\s*$')
if ($mtc.Success) { $cwd = $mtc.Groups[1].Value.Trim() }
$warpBase = if ($cwd) { $cwd } else { $root }
$mt = [regex]::Match($b, '-SessionTitle\s+"([^"]+)"')
if (-not $mt.Success) { Die "no -SessionTitle in $srcBat (cannot derive a fresh title)" }
$origTitle = $mt.Groups[1].Value
$newTitle  = "{0}-{1}" -f $origTitle, $Tag
$note = ('REM FRESH SESSION for the SAME owner {0} (SessionTitle {1}). Resets a stuck transcript; same mailbox/context/ProjectKey. Do NOT run alongside the old {2} window.' -f $Owner, $newTitle, $origTitle)
$b2 = $b.Replace('@echo off', '@echo off' + "`r`n" + $note)
$b2 = $b2.Replace(('-SessionTitle "{0}"' -f $origTitle), ('-SessionTitle "{0}"' -f $newTitle))

# ---- clone Warp workflow if the owner has one ----
$srcYaml  = Join-Path $warpBase (".warp\workflows\{0}.yaml" -f $Owner)
$dstYaml  = Join-Path $warpBase (".warp\workflows\{0}-{1}.yaml" -f $Owner, $Tag)
$haveYaml = Test-Path $srcYaml
$y2 = $null
if ($haveYaml) {
  $y = $L1.GetString([System.IO.File]::ReadAllBytes($srcYaml))
  $y2 = $y.Replace($srcBatName, $dstBatName)
  if ($y2 -match 'name: "> ') { $y2 = $y2.Replace('name: "> ', ('name: "> [{0}] ' -f $Tag)) }
}

# ---- collisions ----
if ((Test-Path $dstBat) -and -not $Force) { Die "target exists: $dstBat (use -Force to overwrite)" }
if ($haveYaml -and (Test-Path $dstYaml) -and -not $Force) { Die "target exists: $dstYaml (use -Force)" }

if ($DryRun) {
  Write-Host "[fresh-session] DRY RUN - nothing written"
  Write-Host ("  owner (UNCHANGED): {0}   pool root: {1}" -f $Owner, $root)
  if ($srcBatName -ne ("claude-{0}.bat" -f $Owner) -or $warpBase -ne $root) { Write-Host ("  split/naming: wrapper {0} -> {1}   |  .warp base: {2}" -f $srcBatName, $dstBatName, $warpBase) }
  Write-Host ("  [create] {0}" -f $dstBat)
  Write-Host ("           SessionTitle '{0}' -> '{1}'" -f $origTitle, $newTitle)
  if ($haveYaml) { Write-Host ("  [create] {0}" -f $dstYaml) } else { Write-Host "  (owner has no Warp workflow - skipping yaml)" }
  exit 0
}

[System.IO.File]::WriteAllBytes($dstBat, $L1.GetBytes($b2))
if ($haveYaml) { [System.IO.File]::WriteAllBytes($dstYaml, $L1.GetBytes($y2)) }

# ---- self-verify (read back from disk) ----
$script:fail = 0
function Chk($cond,$label){ if ($cond) { Write-Host ("  PASS  " + $label) -ForegroundColor Green } else { Write-Host ("  FAIL  " + $label) -ForegroundColor Red; $script:fail++ } }
$batBytes = [System.IO.File]::ReadAllBytes($dstBat)
$bv       = $L1.GetString($batBytes)
$batUtf   = [System.IO.File]::ReadAllText($dstBat, [System.Text.Encoding]::UTF8)
Chk (-not ($batBytes.Length -ge 3 -and $batBytes[0] -eq 0xEF -and $batBytes[1] -eq 0xBB -and $batBytes[2] -eq 0xBF)) "wrapper: no BOM"
Chk ($bv -match ('set AGENT_OWNER={0}(\s|$)' -f [regex]::Escape($Owner))) ("wrapper: AGENT_OWNER unchanged (" + $Owner + ")")
Chk ($bv.Contains('-SessionTitle "' + $newTitle + '"')) ("wrapper: SessionTitle = " + $newTitle)
Chk ([regex]::IsMatch($batUtf,'\p{IsCyrillic}') -and -not [regex]::IsMatch($batUtf,'[\u00C0-\u00FF]{2,}')) "wrapper: Cyrillic intact (no mojibake)"
if ($haveYaml) {
  $yBytes = [System.IO.File]::ReadAllBytes($dstYaml)
  $yv     = $L1.GetString($yBytes)
  Chk (-not ($yBytes.Length -ge 3 -and $yBytes[0] -eq 0xEF -and $yBytes[1] -eq 0xBB -and $yBytes[2] -eq 0xBF)) "yaml: no BOM"
  Chk ($yv.Contains($dstBatName)) "yaml: command -> fresh .bat"
}
Write-Host ""
if ($script:fail -eq 0) { Write-Host "[fresh-session] ALL PASS" -ForegroundColor Green } else { Write-Host ("[fresh-session] {0} FAILED" -f $script:fail) -ForegroundColor Red; exit 1 }
Write-Host ""
Write-Host ("Next: close the old '{0}' window, then launch the fresh one (SAME owner):" -f $origTitle)
Write-Host ("  - double-click {0}" -f $dstBat)
if ($haveYaml) { Write-Host ("  - or Warp: workflow '[{0}] ...' (reopen Warp so it picks up the new yaml)" -f $Tag) }
Write-Host "The fresh session runs the SAME owner -> 'pool mine' recovers its in-flight cur/ + new/ work."
