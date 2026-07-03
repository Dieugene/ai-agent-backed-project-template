#requires -version 5
<#
  add-peer.ps1 - add ONE peer (role) to an existing pool. Sibling of new-pool.ps1
  (which scaffolds a whole pool). Mechanical wiring is automated; role-specific
  domain content is emitted as a skeleton with TODOs.

  Auto-wired (deterministic):
    - claude-<owner>.bat   : cloned from a sibling wrapper, AGENT_OWNER + SessionTitle
                             substituted. Carries env vars / launcher shape (umbrella
                             launch-claude.ps1 vs standalone pool-launch.ps1) /
                             POOL_BUS_ROOT / ProjectKey / -InitialPromptFile (watcher
                             arming) verbatim from the sibling.
    - .warp/workflows/<owner>.yaml : Warp Ctrl-Shift-R launcher.
    - pool.manifest.json   : role inserted -> appears in the terminal picker and its
                             auto-layout of Warp panes (manifest = source of panes).
    - _agent_pool_setup-<owner>.md : skeleton from template (boilerplate filled,
                             domain content as <!-- TODO -->).
  Emitted as paste-ready snippets (need a human glance / domain judgement):
    - role bullet for the subproject CLAUDE.md, structure-tree lines,
      umbrella routing row + onboarding bullet, agent-pool-zones.md section,
      memory row. Written to <root>\_add-peer-<owner>.snippets.md.

  Encoding: .bat ASCII no-BOM; .yaml/.md UTF-8 no-BOM; .json UTF-8 no-BOM.

  Usage:
    add-peer.ps1 -Manifest <pool.manifest.json> -Owner backend-b `
      -Title "Backend B" -Display BackendB `
      -Mission "Enrichment layer above adapters." -Zone "02_src/backend/enrichment/" `
      -After backend-a [-CopyFrom backend-a] [-DryRun]
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Manifest,
  [Parameter(Mandatory=$true)][string]$Owner,
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Display,
  [Parameter(Mandatory=$true)][string]$Mission,
  [string]$Zone = '(TODO)',
  [string]$After = '',
  [string]$CopyFrom = '',
  [string]$Bat = '',
  [switch]$DryRun,
  [string]$TemplatesDir = ''
)

$ErrorActionPreference = 'Stop'
$U8 = New-Object System.Text.UTF8Encoding($false)   # UTF-8, no BOM
function ReadText($p){ [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function WriteText($p,$s){ [System.IO.File]::WriteAllText($p, $s, $U8) }
function WriteBat($p,$s){ [System.IO.File]::WriteAllText($p, $s, (New-Object System.Text.ASCIIEncoding)) }
function Render([string]$tpl,[hashtable]$map){ $s=$tpl; foreach($k in $map.Keys){ $s=$s.Replace('{{'+$k+'}}', [string]$map[$k]) }; return $s }
function Die($msg){ Write-Host ('[add-peer] ERROR: ' + $msg) -ForegroundColor Red; exit 1 }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $TemplatesDir) { $TemplatesDir = Join-Path (Split-Path -Parent $Here) 'templates\add-peer' }
foreach ($t in @('workflow.yaml.template','setup.md.template','snippets.md.template')) {
  if (-not (Test-Path (Join-Path $TemplatesDir $t))) { Die ("template missing: " + (Join-Path $TemplatesDir $t)) }
}
if (-not (Test-Path $Manifest)) { Die ("manifest not found: " + $Manifest) }

# ---- parse manifest ----
$rawMf = ReadText $Manifest
try { $m = $rawMf | ConvertFrom-Json } catch { Die ("manifest is not valid JSON: " + $_.Exception.Message) }
$root = $m.root
$slug = $m.slug
$lead = $m.lead
$ownersNow = @($m.roles | ForEach-Object { $_.owner })
if ($ownersNow -contains $Owner) { Die ("owner already in manifest: " + $Owner) }
if (-not $After) { $After = $lead }
if ($ownersNow -notcontains $After) { Die ("-After owner not in pool: " + $After) }
if (-not $CopyFrom) { $CopyFrom = $After }
if ($ownersNow -notcontains $CopyFrom) { Die ("-CopyFrom owner not in pool: " + $CopyFrom) }
if (-not $Bat) { $Bat = 'claude-' + $Owner + '.bat' }
$afterRole = $m.roles | Where-Object { $_.owner -eq $After } | Select-Object -First 1
$copyRole  = $m.roles | Where-Object { $_.owner -eq $CopyFrom } | Select-Object -First 1
$sibBatPath = Join-Path $root $copyRole.bat
if (-not (Test-Path $sibBatPath)) { Die ("sibling wrapper not found: " + $sibBatPath) }

# ---- build wrapper from sibling (keep only functional ASCII lines; drop sibling REM/echo) ----
$sibLines = Get-Content -LiteralPath $sibBatPath -Encoding ASCII
$cwd=''; $busroot=''; $pool=''
$funcLines = @()
foreach ($ln in $sibLines) {
  if ($ln -match '^\s*@echo') { continue }
  if ($ln -match '^\s*REM')   { continue }
  if ($ln.Trim() -eq '')      { continue }
  $funcLines += $ln
  if ($ln -match '^\s*set\s+POOL_BUS_ROOT=(.+)$')           { $busroot = $matches[1].Trim() }
  if ($ln -match '^\s*set\s+CLAUDE_CODE_TASK_LIST_ID=(.+)$') { $pool    = $matches[1].Trim() }
  if ($ln -match '^\s*cd\s+/d\s+(.+)$')                      { $cwd     = $matches[1].Trim() }
}
$newFunc = @()
foreach ($ln in $funcLines) {
  $x = $ln
  $x = [regex]::Replace($x, '(?i)^(\s*set\s+AGENT_OWNER=).*$', ('${1}' + $Owner))
  $x = [regex]::Replace($x, '-SessionTitle\s+"[^"]*"', ('-SessionTitle "' + $Display + '"'))
  $newFunc += $x
}
$batHeader = @('@echo off', ('REM Pool wrapper for ' + $Owner + ' (pool ' + $slug + '). Generated by add-peer.ps1 from ' + $copyRole.bat + '.'))
$batText = (($batHeader + $newFunc) -join "`r`n") + "`r`n"
if (-not $pool) { $pool = $m.slug + '-assistant-pool' }   # fallback for setup template only

# ---- manifest insert (text, byte-safe, format cloned from -After block) ----
$rxOwner = [regex]('"owner":\s*"' + [regex]::Escape($After) + '"')
$mo = $rxOwner.Match($rawMf)
if (-not $mo.Success) { Die "could not locate -After role block in manifest text" }
$iOwner = $mo.Index
$iOpen  = $rawMf.LastIndexOf('{', $iOwner)
$iClose = $rawMf.IndexOf('}', $iOwner)
$blockText = $rawMf.Substring($iOpen, $iClose - $iOpen + 1)
$lineStart = $rawMf.LastIndexOf("`n", $iOpen) + 1
$indent = $rawMf.Substring($lineStart, $iOpen - $lineStart)
$newBlock = $blockText
$newBlock = $newBlock.Replace('"' + $After + '"', '"' + $Owner + '"')
$newBlock = $newBlock.Replace('"' + $afterRole.title + '"', '"' + $Title + '"')
$newBlock = $newBlock.Replace('"' + $afterRole.bat + '"', '"' + $Bat + '"')
$newBlock = [regex]::Replace($newBlock, ',\s*"lead":\s*true', '')   # never clone leadership
$insertion = ',' + "`r`n" + $indent + $newBlock
$rawMfNew = $rawMf.Substring(0, $iClose + 1) + $insertion + $rawMf.Substring($iClose + 1)
try { $check = $rawMfNew | ConvertFrom-Json } catch { Die ("manifest insert produced invalid JSON: " + $_.Exception.Message) }
if (@($check.roles).Count -ne ($ownersNow.Count + 1)) { Die "manifest role count mismatch after insert" }

# ---- render templates ----
$tplWf    = ReadText (Join-Path $TemplatesDir 'workflow.yaml.template')
$tplSetup = ReadText (Join-Path $TemplatesDir 'setup.md.template')
$tplSnip  = ReadText (Join-Path $TemplatesDir 'snippets.md.template')
$map = @{
  OWNER=$Owner; TITLE=$Title; DISPLAY=$Display; MISSION=$Mission; ZONE=$Zone;
  POOL=$pool; SLUG=$slug; ROOT=$root; BAT=$Bat; CWD=$cwd; BUSROOT=$busroot;
  DATE=(Get-Date).ToString('yyyy-MM-dd')
}
$wfText    = Render $tplWf $map
$setupText = Render $tplSetup $map
$snipText  = Render $tplSnip $map

# ---- target paths ----
$wfDir   = Join-Path $root '.warp\workflows'
$pWf     = Join-Path $wfDir ($Owner + '.yaml')
$pBat    = Join-Path $root $Bat
$pSetup  = Join-Path $root ('_agent_pool_setup-' + $Owner + '.md')
$pSnip   = Join-Path $root ('_add-peer-' + $Owner + '.snippets.md')

$plan = @(
  @{ path=$pBat;      kind='bat';  text=$batText },
  @{ path=$Manifest;  kind='json'; text=$rawMfNew },
  @{ path=$pWf;       kind='utf8'; text=$wfText },
  @{ path=$pSetup;    kind='utf8'; text=$setupText },
  @{ path=$pSnip;     kind='utf8'; text=$snipText }
)

Write-Host ''
Write-Host ('[add-peer] pool="' + $slug + '"  owner="' + $Owner + '"  after=' + $After + '  clone-wrapper-from=' + $CopyFrom) -ForegroundColor Cyan
if ($DryRun) { Write-Host '[add-peer] DRY RUN - nothing will be written' -ForegroundColor Yellow }
Write-Host ''

foreach ($a in $plan) {
  $exists = Test-Path $a.path
  $tag = if ($exists) { 'OVERWRITE' } else { 'create' }
  if ($a.kind -eq 'json') { $tag = 'edit' }
  Write-Host ('  [' + $tag + '] ' + $a.path)
  if ($DryRun) {
    $first = ($a.text -split "`r?`n" | Select-Object -First 1)
    Write-Host ('            first: ' + $first) -ForegroundColor DarkGray
  } else {
    if ($a.path -eq $pWf -and -not (Test-Path $wfDir)) { New-Item -ItemType Directory -Force -Path $wfDir | Out-Null }
    if ($exists -and $a.kind -ne 'json') { Write-Host ('            WARN: file exists, skipping to avoid clobber') -ForegroundColor Yellow; continue }
    if ($a.kind -eq 'bat') { WriteBat $a.path $a.text } else { WriteText $a.path $a.text }
  }
}

Write-Host ''
Write-Host '[add-peer] Auto-wired: wrapper, manifest (picker + Warp auto-layout), Warp workflow, setup skeleton.' -ForegroundColor Green
Write-Host ('[add-peer] Paste-ready snippets written to: ' + $pSnip) -ForegroundColor Green
Write-Host '[add-peer] NEXT (human / lead):' -ForegroundColor Green
Write-Host '   1) Paste BULLET + TREE into the subproject CLAUDE.md (role list + structure tree).'
Write-Host '   2) Paste ROUTING into the umbrella CLAUDE.md (routing row + onboarding bullet); bump owner count.'
Write-Host '   3) Paste ZONES into 00_docs/architecture/agent-pool-zones.md and fill the TODOs.'
Write-Host '   4) Paste MEMORY row into project_<pool>.md; bump count in its description + MEMORY.md.'
Write-Host ('   5) Fill the <!-- TODO --> domain blocks in ' + $pSetup + ' (mission detail, zone boundaries, seam).')
Write-Host ''
if (-not $DryRun) { Write-Host '[add-peer] Done.' -ForegroundColor Green }
