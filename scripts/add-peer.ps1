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
    - pool.manifest.json   : role inserted -> appears in the terminal picker. An
                             EXPLICIT layout is kept in sync (new pane spliced beside
                             -After); with no explicit layout the picker auto-derives.
    - _agent_pool_setup-<owner>.md : skeleton from template (boilerplate filled,
                             domain content as <!-- TODO -->).
    - CLAUDE.md (manifest dir): deterministic wiring - owner into the Step-1 mode-detection
                             set (CRITICAL: without it the session falls to Plain mode),
                             role-count bump, and a role-table row after -After. Anchored
                             on the canonical new-pool shape; on a divergent doc it does
                             NOT edit silently - it prints a loud WARN and leaves a snippet.
    - self-verify          : after a real run, reads everything back from disk and asserts
                             ~12 invariants (JSON valid / owner in roles+layout / wrapper
                             AGENT_OWNER+SessionTitle / files present / no-BOM+ASCII /
                             CLAUDE.md mode-set+row), printing ALL PASS or N FAILED.
  Emitted as paste-ready snippets (domain judgement only - the mechanical CLAUDE.md
  wiring above is now done in-place):
    - role section + zones row for 00_docs/pool-roles.md (prose), a fallback CLAUDE.md
      row/tree for non-canonical docs, and a memory row. Written to
      <root>\_add-peer-<owner>.snippets.md.

  Encoding: .bat ASCII no-BOM; .yaml/.md UTF-8 no-BOM; .json UTF-8 no-BOM.

  Usage:
    add-peer.ps1 -Manifest <pool.manifest.json> -Owner backend-enrich-<sub-a> `
      -Title "Backend . Enrich" -Display BackendEnrich-<SUB-A> `
      -Mission "Enrichment layer above adapters." -Zone "02_src/backend/enrichment/" `
      -After backend-search-<sub-a> [-CopyFrom backend-scan-<sub-a>] [-DryRun]
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

# ---- auto-wiring helpers (added). All non-ASCII built from code points so this .ps1 stays pure ASCII (PS 5.1 / no-BOM safe). ----
$script:CyrRoles = -join ([char]0x0440,[char]0x043E,[char]0x043B,[char]0x0435,[char]0x0439)   # "roles" (Cyrillic)
$script:EmDash   = [char]0x2014                                                                # em dash

# Place a pane for $newOwner right after $afterOwner's leaf inside an EXPLICIT manifest layout (text splice, byte-safe).
# Returns @{ ok; text; reason }. ok=$false (text unchanged) when the -After leaf is absent -> caller warns.
function Insert-LayoutPane([string]$text,[string]$afterOwner,[string]$newOwner) {
  $rx = [regex]('"role"\s*:\s*"' + [regex]::Escape($afterOwner) + '"')
  $mo = $rx.Match($text)
  if (-not $mo.Success) { return @{ ok=$false; text=$text; reason='-After owner has no leaf in explicit layout' } }
  $iOpen  = $text.LastIndexOf('{', $mo.Index)
  $iClose = $text.IndexOf('}', $mo.Index)
  if ($iOpen -lt 0 -or $iClose -lt 0 -or $iClose -lt $iOpen) { return @{ ok=$false; text=$text; reason='malformed layout leaf' } }
  $leaf    = $text.Substring($iOpen, $iClose - $iOpen + 1)
  $newLeaf = $leaf.Replace(('"' + $afterOwner + '"'), ('"' + $newOwner + '"'))
  $newText = $text.Substring(0, $iClose + 1) + ', ' + $newLeaf + $text.Substring($iClose + 1)
  return @{ ok=$true; text=$newText; reason='' }
}

# Deterministic CLAUDE.md wiring against the canonical new-pool shape. Never throws; anchor-or-fallback.
# Returns per-part status + warnings; writes the file only if something changed.
function Wire-ClaudeMd([string]$path,[string]$afterOwner,[string]$owner,[string]$display,[string]$title,[string]$mission,[string]$bat,[int]$oldCount,[int]$newCount) {
  $res = [ordered]@{ file=$path; present=$false; modeset='skip'; count=0; row='skip'; warnings=@() }
  if (-not (Test-Path $path)) { $res.warnings += 'CLAUDE.md not at pool root - wire manually (snippet)'; return $res }
  $res.present = $true
  $t = ReadText $path; $orig = $t
  # (a) mode-detection owner set: the Pool-mode row's  AGENT_OWNER ... { <owners> }  (anchored on ASCII AGENT_OWNER, not on the set glyph)
  $rxSet = [regex]'(AGENT_OWNER[^\r\n{]*\{)([^}]*)(\})'
  $ms = $rxSet.Match($t)
  if ($ms.Success) {
    $inside = $ms.Groups[2].Value
    if ($inside -match ('`' + [regex]::Escape($owner) + '`')) { $res.modeset = 'already' }
    else {
      $g = $ms.Groups[2]
      $t = $t.Substring(0,$g.Index) + ($inside.TrimEnd() + ', `' + $owner + '`') + $t.Substring($g.Index + $g.Length)
      $res.modeset = 'added'
    }
  } else { $res.modeset = 'MISS'; $res.warnings += 'mode-detection set not found - CRITICAL: add owner to Pool-mode row manually, else the session falls to Plain mode' }
  # (b) role-count bump: "<old> <Cyr:roles>" -> "<new> ..."
  $rxCount = [regex]('\b' + [regex]::Escape([string]$oldCount) + '\s+' + $script:CyrRoles)
  $cm = $rxCount.Matches($t)
  if ($cm.Count -gt 0) { $t = $rxCount.Replace($t, ([string]$newCount + ' ' + $script:CyrRoles)); $res.count = $cm.Count }
  else { $res.warnings += ('role-count "' + $oldCount + ' <roles>" not found - check counts manually') }
  # (c) role table row (canonical header carries AGENT_OWNER + Display + Wrapper)
  if ([regex]::IsMatch($t, '(?m)^\|[^\r\n]*AGENT_OWNER[^\r\n]*Display[^\r\n]*Wrapper[^\r\n]*\|')) {
    $row = '| `' + $owner + '` | `' + $display + '` | **' + $title + '** ' + $script:EmDash + ' ' + $mission + ' | `' + $bat + '` |'
    $rxAfter = [regex]('(?m)^\|\s*`' + [regex]::Escape($afterOwner) + '`\s*\|[^\r\n]*$')
    $am = $rxAfter.Match($t)
    if ($am.Success) { $end = $am.Index + $am.Length; $t = $t.Substring(0,$end) + "`r`n" + $row + $t.Substring($end); $res.row = 'added' }
    else { $res.row = 'MISS'; $res.warnings += 'role table present but -After row not found - paste row from snippet' }
  } else { $res.row = 'MISS'; $res.warnings += 'canonical role table not found - paste row from snippet' }
  if ($t -ne $orig) { WriteText $path $t }
  return $res
}

function Test-NoBom([string]$p){ if(-not(Test-Path $p)){return $false}; $b=[System.IO.File]::ReadAllBytes($p); -not ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) }
function Test-AllAscii([string]$p){ if(-not(Test-Path $p)){return $false}; foreach($by in [System.IO.File]::ReadAllBytes($p)){ if($by -gt 127){ return $false } }; return $true }

# ---- платформа ------------------------------------------------------------
# Та же идиома, что в pool.ps1: PowerShell 5.1 переменной $IsWindows не имеет вообще.
# На сервере у пула НЕТ обёрток .bat: роль поднимает окно tmux через одну общую scripts/role.sh,
# а всё, что отличает роль от роли, лежит данными в scripts/roles.tsv. Поэтому «клон обёртки
# соседа» там превращается в «клон СТРОКИ соседа», а витрина для рабочей машины собирается в
# <пул>/_windows/ — как это делает new-pool.ps1.
$script:OnWindows = $true
try { $__isWin = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($__isWin) { $script:OnWindows = [bool]$__isWin.Value } } catch { }

# Корень пространства для гарда имён. На сервере его ОБЯЗАТЕЛЬНО передавать явно: дефолт в
# pool-manifest.ps1 windows-овый, и без явного корня гард честно отказывается работать
# («workspace root must be passed explicitly on this platform») — молчаливое «чисто» было бы хуже.
$SpaceRoot = if ($script:OnWindows) { 'C:\workspace-root' } else { Join-Path $HOME 'workspace' }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
# ⚠️ Прямой слэш: на Linux 'templates\add-peer' — это ОДНО имя каталога с обратным слэшем внутри,
# и проверка шаблонов падала бы с «template missing» вместо внятного ответа.
if (-not $TemplatesDir) {
  # ⚠️ Каталог уровнем выше может не существовать (скрипт запущен из /tmp при проверке): Join-Path с
  # пустым первым аргументом не возвращает пустоту, а бросает «Path is empty» — отказ без объяснения.
  $up = Split-Path -Parent $Here
  if (-not $up) { Die ("каталог шаблонов не вывести от расположения скрипта (" + $Here + ") - передай -TemplatesDir") }
  $TemplatesDir = Join-Path $up 'templates/add-peer'
}
foreach ($t in @('workflow.yaml.template','setup.md.template','snippets.md.template')) {
  if (-not (Test-Path (Join-Path $TemplatesDir $t))) { Die ("template missing: " + (Join-Path $TemplatesDir $t)) }
}
if (-not (Test-Path $Manifest)) { Die ("manifest not found: " + $Manifest) }

# ---- parse manifest ----
$rawMf = ReadText $Manifest
try { $m = $rawMf | ConvertFrom-Json } catch { Die ("manifest is not valid JSON: " + $_.Exception.Message) }
$root = $m.root
# Doc artifacts (setup / CLAUDE.md / snippets) live WITH the manifest; wrappers + .warp live in $root.
# Standalone pools: these coincide. Split-layout pools (e.g. div: manifest+docs in the project dir,
# wrappers in a shared scripts\ dir that is manifest.root) differ -> derive docsDir from the manifest path.
$docsDir = Split-Path -Parent (Resolve-Path -LiteralPath $Manifest).Path
$slug = $m.slug
$lead = $m.lead
$ownersNow = @($m.roles | ForEach-Object { $_.owner })
if ($ownersNow -contains $Owner) { Die ("owner already in manifest: " + $Owner) }
# ⚠️ Синтаксис имени — та же проверка, что в new-pool.ps1, и она обязана быть здесь тоже: добавление
# роли в ЖИВОЙ пул идёт этим путём, а не генератором. Имя роли становится именем окна tmux на сервере
# (вторая половина адреса «сессия:окно»), поэтому точка и двоеточие в нём ломают подъём — роль просто
# не встаёт, а причина выглядит как что угодно другое. Сравнение регистрозависимое намеренно:
# `-cnotmatch`, потому что обычный -notmatch регистр игнорирует и пропускал бы 'TechLead'.
if ($Owner -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
    Die ("имя роли '" + $Owner + "' не годится: строчная латиница, цифры, дефис и подчёркивание; первый знак — не разделитель. Задай другое имя в -Owner. Причина запрета: имя роли становится именем окна tmux, а точка и двоеточие в нём ломают адресацию.")
}
# Cross-pool name guard. Sharing a BUS means sharing a mailbox; sharing a working directory means
# sharing the memory store and the session-history namespace. Identical names in NON-overlapping
# pools stay legal and are in use today (qa lives in three pools), so the scope is deliberately
# narrow. Refusal happens HERE, before the first Emit - a half-written role is worse than no role.
. (Join-Path $PSScriptRoot 'pool-manifest.ps1')
$conflicts = @(Get-OwnerConflicts -Owner $Owner -Cwd (Resolve-PoolCwd $m) -Bus (Resolve-PoolBus $m) -ExcludeSlug $slug -WorkspaceRoot $SpaceRoot)
if ($conflicts.Count) {
    $suggest = $slug + '-' + $Owner
    Die ((Get-GuardMessage 'owner') -f $Owner, $conflicts[0].Slug, $conflicts[0].Scope, $suggest)
}
if (-not $After) { $After = $lead }
if ($ownersNow -notcontains $After) { Die ("-After owner not in pool: " + $After) }
if (-not $CopyFrom) { $CopyFrom = $After }
if ($ownersNow -notcontains $CopyFrom) { Die ("-CopyFrom owner not in pool: " + $CopyFrom) }
if (-not $Bat) { $Bat = 'claude-' + $Owner + '.bat' }
$afterRole = $m.roles | Where-Object { $_.owner -eq $After } | Select-Object -First 1
$copyRole  = $m.roles | Where-Object { $_.owner -eq $CopyFrom } | Select-Object -First 1

# Канон параметров запуска для НОВОГО peer'а (одинаков на обеих платформах). Донором обычно
# оказывается лид (-CopyFrom по умолчанию = -After = lead), поэтому его -Effort нельзя наследовать:
# новый peer лидом не становится. Модель пиним всем — иначе сессия при --resume поедет на своей
# старой, а глобальный /model протечёт в пул.
$PeerModel  = 'claude-opus-5[1m]'
$PeerEffort = 'medium'

# ---- серверная ветка: донор — не файл обёртки, а СТРОКА в scripts/roles.tsv ----
$IsServerPool = -not $script:OnWindows
$tsvPath = Join-Path $root (Join-Path 'scripts' 'roles.tsv')
$tsvTextNew = ''; $winBatText = ''; $sibWinBat = ''
if ($IsServerPool) {
  if (-not (Test-Path $tsvPath)) { Die ("на сервере роль описывается строкой в " + $tsvPath + ", а файла нет. Пул создан старой версией new-pool.ps1?") }
  $tsvLines = @([System.IO.File]::ReadAllLines($tsvPath, [System.Text.Encoding]::UTF8))
  $donorIdx = -1
  for ($i = 0; $i -lt $tsvLines.Count; $i++) {
    $ln = $tsvLines[$i]
    if ($ln.TrimStart().StartsWith('#') -or -not $ln.Trim()) { continue }
    if (($ln -split "`t")[0] -eq $CopyFrom) { $donorIdx = $i; break }
    if (($ln -split "`t")[0] -eq $Owner) { Die ("роль уже описана в " + $tsvPath + ": " + $Owner) }
  }
  if ($donorIdx -lt 0) { Die ("донор -CopyFrom '" + $CopyFrom + "' не найден в " + $tsvPath) }
  $donor = $tsvLines[$donorIdx] -split "`t"
  $sibTitleC = if ($donor.Count -ge 2) { $donor[1] } else { '' }
  # Вотчер наследуем у донора: это свойство РОДА роли (серверные/devops не взводят), а не лидерства.
  $watcher = if ($donor.Count -ge 4 -and $donor[3]) { $donor[3] } else { '1' }
  $newTsvLine = '{0}{4}{1}{4}{2}{4}{3}' -f $Owner, $Display, $PeerEffort, $watcher, "`t"
  # ⚠️ Имена $tsvBefore/$tsvAfter, а НЕ $before/$after: PowerShell не различает регистр имён, и
  # локальный $after затирал параметр -After. Симптом уводил далеко: «could not locate -After role
  # block in manifest text» на манифесте, где эта роль есть и регулярка на ней совпадает.
  $tsvBefore = @($tsvLines[0..$donorIdx])
  $tsvAfter  = if ($donorIdx + 1 -lt $tsvLines.Count) { @($tsvLines[($donorIdx + 1)..($tsvLines.Count - 1)]) } else { @() }
  $tsvTextNew = (($tsvBefore + @($newTsvLine) + $tsvAfter) -join "`n").TrimEnd("`n") + "`n"

  # Витрина: обёртку со ssh клонируем у соседа, чтобы адрес сервера, ключ и опции жили в одном месте.
  $sibWinBat = Join-Path $root (Join-Path '_windows' ('claude-' + $CopyFrom + '.bat'))
  if (Test-Path $sibWinBat) {
    $wb = [System.IO.File]::ReadAllText($sibWinBat)
    $wb = [regex]::Replace($wb, '(?im)^(\s*set\s+AGENT_OWNER=).*$', ('${1}' + $Owner))
    $wb = [regex]::Replace($wb, '(?im)^(\s*title\s+)\S+(\s+-\s+.*)$', ('${1}' + $Owner + '${2}'))
    # Последний аргумент ssh — команда входа: "<пул> <роль>". Меняем только роль, пул оставляем.
    $wb = [regex]::Replace($wb, ('enter\.sh\s+(\S+)\s+' + [regex]::Escape($CopyFrom)), ('enter.sh ${1} ' + $Owner))
    $wb = [regex]::Replace($wb, ('(?m)^REM .*' + [regex]::Escape($CopyFrom) + '.*$'), ('REM Обёртка роли ' + $Owner + ' пула ' + $slug + '. Роль живёт НА СЕРВЕРЕ.'))
    $winBatText = $wb
  } else {
    Write-Host ('[add-peer] WARN: витрины соседа нет (' + $sibWinBat + ') - обёртку для рабочей машины не создам; пересоберите витрину скаффолдером') -ForegroundColor Yellow
  }
}

# ---- build wrapper from sibling (keep only functional ASCII lines; drop sibling REM/echo) ----
$sibLines = @()
if (-not $IsServerPool) {
  $sibBatPath = Join-Path $root $copyRole.bat
  if (-not (Test-Path $sibBatPath)) { Die ("sibling wrapper not found: " + $sibBatPath) }
  $sibLines = Get-Content -LiteralPath $sibBatPath -Encoding ASCII
}

# ---- (C) suffix-consistency warn: new peer's SessionTitle suffix vs sibling's (catches a -Display typo) ----
# Roles of one pool must share the suffix (e.g. all "-Networking"); a mismatch usually means a wrong -Display.
# На сервере заголовок донора уже взят из roles.tsv — не обнуляем, иначе проверка суффикса,
# ловящая опечатку в -Display, там просто не сработает.
if (-not $IsServerPool) { $sibTitleC = '' }
foreach ($lnC in $sibLines) {
  $mtC = [regex]::Match($lnC, '-SessionTitle\s+"([^"]*)"')
  if ($mtC.Success) { $sibTitleC = $mtC.Groups[1].Value; break }
}
if ($sibTitleC) {
  $sibSufC = if ($sibTitleC -match '^[^-]+-(.+)$') { $matches[1] } else { '' }
  $newSufC = if ($Display    -match '^[^-]+-(.+)$') { $matches[1] } else { '' }
  if ($sibSufC -and $newSufC -and ($sibSufC -ne $newSufC)) {
    Write-Host ("[add-peer] WARN: new SessionTitle suffix '" + $newSufC + "' (from -Display '" + $Display + "') != sibling suffix '" + $sibSufC + "' (sibling '" + $sibTitleC + "'). Roles in one pool should share the suffix - check -Display. (Warning only, continuing.)") -ForegroundColor Yellow
  }
}
$cwd=''; $busroot=''; $pool=''
if ($IsServerPool) {
  # На сервере эти три значения не вычитываются из обёртки — их там нет. Рабочий каталог роли и есть
  # корень пула, шина лежит рядом, список задач записан в scripts/pool.env (его читает role.sh).
  $cwd = $root
  $busroot = Join-Path $root '.bus'
  $envPath = Join-Path $root (Join-Path 'scripts' 'pool.env')
  if (Test-Path $envPath) {
    $pm = [regex]::Match([System.IO.File]::ReadAllText($envPath), '(?m)^\s*POOL_TASK_LIST_ID\s*=\s*(.+?)\s*$')
    if ($pm.Success) { $pool = $pm.Groups[1].Value }
  }
}
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
  # Якорь ТОЛЬКО на строку запуска сессии: у лида в wrapper'е есть ещё строка board-window.ps1,
  # ей флаги модели ни к чему (проверено на throwaway-скаффолде — широкий якорь цеплял и её).
  if ($x -match '^\s*powershell\b.*-File\b.*(pool-launch|launch-claude)\.ps1') {
    $x = [regex]::Replace($x, '\s+(?<!-)-Model\s+(?:"[^"]*"|\S+)',  '')
    $x = [regex]::Replace($x, '\s+(?<!-)-Effort\s+(?:"[^"]*"|\S+)', '')
    $x = $x.TrimEnd() + ' -Model "' + $PeerModel + '" -Effort ' + $PeerEffort
  }
  $newFunc += $x
}
$batText = ''
if (-not $IsServerPool) {
  $batHeader = @('@echo off', ('REM Pool wrapper for ' + $Owner + ' (pool ' + $slug + '). Generated by add-peer.ps1 from ' + $copyRole.bat + '.'))
  $batText = (($batHeader + $newFunc) -join "`r`n") + "`r`n"
}
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

# ---- keep an EXPLICIT layout in sync: place the new pane beside -After (no explicit layout -> picker auto-derives, nothing to do) ----
$hasExplicitLayout = ($m.PSObject.Properties.Name -contains 'layout') -and $m.layout
$layoutStatus = 'auto'
if ($hasExplicitLayout) {
  $lr = Insert-LayoutPane $rawMfNew $After $Owner
  if ($lr.ok) { $rawMfNew = $lr.text; $layoutStatus = 'added' }
  else { $layoutStatus = 'WARN'; Write-Host ('[add-peer] WARN: explicit layout present but pane not inserted (' + $lr.reason + ') - add {"role":"' + $Owner + '"} to layout manually') -ForegroundColor Yellow }
}

try { $check = $rawMfNew | ConvertFrom-Json } catch { Die ("manifest insert produced invalid JSON: " + $_.Exception.Message) }
if (@($check.roles).Count -ne ($ownersNow.Count + 1)) { Die "manifest role count mismatch after insert" }

# ---- render templates ----
$tplWf    = ReadText (Join-Path $TemplatesDir 'workflow.yaml.template')
$tplSetup = ReadText (Join-Path $TemplatesDir 'setup.md.template')
$tplSnip  = ReadText (Join-Path $TemplatesDir 'snippets.md.template')
$map = @{
  OWNER=$Owner; TITLE=$Title; DISPLAY=$Display; MISSION=$Mission; ZONE=$Zone;
  POOL=$pool; SLUG=$slug; ROOT=$root; DOCSDIR=$docsDir; BAT=$Bat; CWD=$cwd; BUSROOT=$busroot;
  DATE=(Get-Date).ToString('yyyy-MM-dd')
}
$wfText    = Render $tplWf $map
$setupText = Render $tplSetup $map
$snipText  = Render $tplSnip $map

# ---- target paths ----
$warpBase = if ($cwd) { $cwd } else { $root }   # Warp discovers .warp/workflows from the agent's cwd (its cd /d target), NOT manifest.root
# ⚠️ Прямой слэш: на Linux '.warp\workflows' — одно имя каталога с обратным слэшем внутри.
# И сама витрина на сервере живёт в <пул>/_windows/: рабочей машине нужны обёртка и воркфлоу,
# но лежать они обязаны там, откуда их забирает pull-server-pool.ps1.
$wfDir   = if ($IsServerPool) { Join-Path $root (Join-Path '_windows' (Join-Path '.warp' 'workflows')) }
           else                { Join-Path $warpBase (Join-Path '.warp' 'workflows') }
$pWf     = Join-Path $wfDir ($Owner + '.yaml')
$pBat    = Join-Path $root $Bat
$pWinBat = Join-Path $root (Join-Path '_windows' $Bat)
$pSetup  = Join-Path $docsDir ('_agent_pool_setup-' + $Owner + '.md')
$pSnip   = Join-Path $docsDir ('_add-peer-' + $Owner + '.snippets.md')

# На сервере вместо обёртки роли пишется СТРОКА в roles.tsv (её читает общая role.sh), плюс
# витринная обёртка для рабочей машины. Файл roles.tsv правится, а не создаётся, поэтому идёт
# как 'edit' — иначе защита «файл существует, пропускаю» не дала бы дописать роль.
$plan = if ($IsServerPool) {
  $p = @(
    @{ path=$tsvPath;   kind='edit'; text=$tsvTextNew },
    @{ path=$Manifest;  kind='json'; text=$rawMfNew },
    @{ path=$pSetup;    kind='utf8'; text=$setupText },
    @{ path=$pSnip;     kind='utf8'; text=$snipText }
  )
  # utf8, а не 'bat': витринная обёртка несёт кириллицу в пояснении, а ASCII-запись её покорёжит.
  if ($winBatText) { $p += @{ path=$pWinBat; kind='utf8'; text=$winBatText }; $p += @{ path=$pWf; kind='utf8'; text=$wfText } }
  $p
} else {
  @(
    @{ path=$pBat;      kind='bat';  text=$batText },
    @{ path=$Manifest;  kind='json'; text=$rawMfNew },
    @{ path=$pWf;       kind='utf8'; text=$wfText },
    @{ path=$pSetup;    kind='utf8'; text=$setupText },
    @{ path=$pSnip;     kind='utf8'; text=$snipText }
  )
}

Write-Host ''
Write-Host ('[add-peer] pool="' + $slug + '"  owner="' + $Owner + '"  after=' + $After + '  clone-wrapper-from=' + $CopyFrom) -ForegroundColor Cyan
if ($docsDir -ne $root -or $warpBase -ne $root) { Write-Host ('[add-peer] split layout: docs -> ' + $docsDir + '  |  wrapper -> ' + $root + '  |  .warp (Warp cwd) -> ' + $warpBase) -ForegroundColor DarkCyan }
if ($DryRun) { Write-Host '[add-peer] DRY RUN - nothing will be written' -ForegroundColor Yellow }
Write-Host ''

foreach ($a in $plan) {
  $exists = Test-Path $a.path
  $tag = if ($exists) { 'OVERWRITE' } else { 'create' }
  if ($a.kind -eq 'json' -or $a.kind -eq 'edit') { $tag = 'edit' }
  Write-Host ('  [' + $tag + '] ' + $a.path)
  if ($DryRun) {
    $first = ($a.text -split "`r?`n" | Select-Object -First 1)
    Write-Host ('            first: ' + $first) -ForegroundColor DarkGray
  } else {
    # Каталог назначения может не существовать вовсе (_windows/ у пула, собранного до витрины).
    $parent = Split-Path -Parent $a.path
    if ($parent -and -not (Test-Path $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    # 'edit' — правка существующего файла (манифест, roles.tsv): защита от затирания к ней не применима.
    if ($exists -and $a.kind -ne 'json' -and $a.kind -ne 'edit') { Write-Host ('            WARN: file exists, skipping to avoid clobber') -ForegroundColor Yellow; continue }
    if ($a.kind -eq 'bat') { WriteBat $a.path $a.text } else { WriteText $a.path $a.text }
  }
}

Write-Host ''
$pClaude   = Join-Path $docsDir 'CLAUDE.md'
$claudeRes = $null
if (-not $DryRun) { $claudeRes = Wire-ClaudeMd $pClaude $After $Owner $Display $Title $Mission $Bat $ownersNow.Count ($ownersNow.Count + 1) }

$layoutNote = switch ($layoutStatus) { 'added' { 'layout pane (beside ' + $After + ')' } 'auto' { 'layout (auto from roles)' } default { 'layout (WARN - see above)' } }
Write-Host ('[add-peer] Auto-wired: wrapper, manifest roles + ' + $layoutNote + ', Warp workflow, setup skeleton.') -ForegroundColor Green
if ($DryRun) {
  Write-Host '[add-peer] (dry run) CLAUDE.md auto-wiring + self-verify run only on real apply.' -ForegroundColor Yellow
} elseif ($claudeRes -and $claudeRes.present) {
  Write-Host ('[add-peer] CLAUDE.md auto-wired: mode-set=' + $claudeRes.modeset + '  count-bumped=' + $claudeRes.count + '  role-row=' + $claudeRes.row) -ForegroundColor Green
  foreach ($w in $claudeRes.warnings) { Write-Host ('   WARN(CLAUDE.md): ' + $w) -ForegroundColor Yellow }
} elseif ($claudeRes) {
  foreach ($w in $claudeRes.warnings) { Write-Host ('   WARN(CLAUDE.md): ' + $w) -ForegroundColor Yellow }
}
Write-Host ('[add-peer] Paste-ready snippets written to: ' + $pSnip) -ForegroundColor Green

# ---- self-verify (real apply only): read back from disk and assert the wiring landed ----
if (-not $DryRun) {
  $checks = New-Object System.Collections.ArrayList
  $mfDisk = $null; $jsonOk = $false
  try { $mfDisk = (ReadText $Manifest) | ConvertFrom-Json; $jsonOk = $true } catch {}
  $rolesDisk = if ($mfDisk) { @($mfDisk.roles | ForEach-Object { $_.owner }) } else { @() }
  [void]$checks.Add(@{ k='manifest JSON valid';    ok=$jsonOk;                                   n='' })
  [void]$checks.Add(@{ k='owner in roles';         ok=($rolesDisk -contains $Owner);            n='' })
  [void]$checks.Add(@{ k='role count';             ok=($rolesDisk.Count -eq ($ownersNow.Count+1)); n=('= ' + $rolesDisk.Count) })
  if ($hasExplicitLayout) {
    $lj = if ($mfDisk) { $mfDisk.layout | ConvertTo-Json -Depth 20 } else { '' }
    [void]$checks.Add(@{ k='owner in layout';      ok=($lj -match ('"' + [regex]::Escape($Owner) + '"')); n='' })
  } else { [void]$checks.Add(@{ k='layout';         ok=$true;                                    n='auto from roles' }) }
  if ($IsServerPool) {
    # На сервере обёртки роли нет: её место занимает строка в roles.tsv, которую читает общая role.sh.
    # Проверяем ровно то, от чего зависит подъём: роль описана, заголовок сессии тот, что заказан.
    $tsvDisk = if (Test-Path $tsvPath) { [System.IO.File]::ReadAllText($tsvPath, [System.Text.Encoding]::UTF8) } else { '' }
    $tsvRow  = @($tsvDisk -split "`r?`n" | Where-Object { ($_ -split "`t")[0] -eq $Owner }) | Select-Object -First 1
    $tsvCols = if ($tsvRow) { $tsvRow -split "`t" } else { @() }
    [void]$checks.Add(@{ k='роль в roles.tsv';       ok=[bool]$tsvRow;                             n='' })
    [void]$checks.Add(@{ k='заголовок сессии';       ok=($tsvCols.Count -ge 2 -and $tsvCols[1] -eq $Display); n=$(if ($tsvCols.Count -ge 2) { $tsvCols[1] } else { '' }) })
    [void]$checks.Add(@{ k='усилие рядового';        ok=($tsvCols.Count -ge 3 -and $tsvCols[2] -eq $PeerEffort); n='' })
    [void]$checks.Add(@{ k='витрина: обёртка';       ok=($(if ($winBatText) { Test-Path $pWinBat } else { $true })); n=$(if ($winBatText) { '' } else { 'пропущена: витрины соседа нет' }) })
    [void]$checks.Add(@{ k='витрина: workflow';      ok=($(if ($winBatText) { Test-Path $pWf }    else { $true })); n='' })
    [void]$checks.Add(@{ k='setup skeleton file';    ok=(Test-Path $pSetup);                       n='' })
    [void]$checks.Add(@{ k='no-BOM (json/setup)';    ok=((Test-NoBom $Manifest) -and (Test-NoBom $pSetup)); n='' })
  } else {
    $batTxt = if (Test-Path $pBat) { Get-Content -LiteralPath $pBat -Raw -Encoding ASCII } else { '' }
    [void]$checks.Add(@{ k='wrapper AGENT_OWNER';    ok=($batTxt -match ('(?im)^\s*set\s+AGENT_OWNER=' + [regex]::Escape($Owner) + '\s*$')); n='' })
    [void]$checks.Add(@{ k='wrapper SessionTitle';   ok=($batTxt -match ('-SessionTitle\s+"' + [regex]::Escape($Display) + '"')); n='' })
    [void]$checks.Add(@{ k='warp workflow file';     ok=(Test-Path $pWf);                          n='' })
    [void]$checks.Add(@{ k='setup skeleton file';    ok=(Test-Path $pSetup);                       n='' })
    [void]$checks.Add(@{ k='no-BOM (json/setup/wf)'; ok=((Test-NoBom $Manifest) -and (Test-NoBom $pSetup) -and (Test-NoBom $pWf)); n='' })
    [void]$checks.Add(@{ k='wrapper is ASCII';       ok=(Test-AllAscii $pBat);                     n='' })
  }
  if ($claudeRes -and $claudeRes.present) {
    [void]$checks.Add(@{ k='CLAUDE.md mode-set';   ok=($claudeRes.modeset -eq 'added' -or $claudeRes.modeset -eq 'already'); n=$claudeRes.modeset })
    [void]$checks.Add(@{ k='CLAUDE.md role row';   ok=($claudeRes.row -eq 'added');              n=$claudeRes.row })
  }
  Write-Host ''
  Write-Host '[add-peer] self-verify:' -ForegroundColor Cyan
  $fail = 0
  foreach ($c in $checks) {
    if (-not $c.ok) { $fail++ }
    $mark = if ($c.ok) { ' OK ' } else { 'FAIL' }
    $col  = if ($c.ok) { 'Green' } else { 'Red' }
    $suffix = if ($c.n) { ' (' + $c.n + ')' } else { '' }
    Write-Host ('   [' + $mark + '] ' + $c.k + $suffix) -ForegroundColor $col
  }
  if ($fail -eq 0) { Write-Host '[add-peer] self-verify: ALL PASS' -ForegroundColor Green }
  else { Write-Host ('[add-peer] self-verify: ' + $fail + ' FAILED - inspect above') -ForegroundColor Red }
}

Write-Host ''
if ($IsServerPool -and -not $DryRun) {
  Write-Host ''
  Write-Host '[add-peer] Роль описана, но ещё НЕ поднята. Дальше по порядку:' -ForegroundColor Cyan
  Write-Host ("   поднять окно роли:  ~/workspace/.launcher/scripts/pool-up.sh " + $root + " " + $Owner)
  Write-Host ("   обновить витрину НА РАБОЧЕЙ МАШИНЕ (иначе роли не будет в пикере):")
  Write-Host ("   powershell -File C:\workspace-root\.launcher\pool-launcher\pull-server-pool.ps1 -Pool " + $slug)
}

Write-Host ''
Write-Host '[add-peer] Remaining (domain judgement - not automated):' -ForegroundColor Green
Write-Host ('   1) 00_docs/pool-roles.md: add the role section + zones row (prose; ZONES snippet in ' + $pSnip + ').')
Write-Host ('   2) Fill the <!-- TODO --> domain blocks in ' + $pSetup + ' (mission detail, seam) - or point them at the role memory .memory\' + $Owner + '\ if a brief already exists.')
Write-Host '   3) MEMORY row into project_<pool>.md; bump count in its description + MEMORY.md.'
Write-Host ''
if (-not $DryRun) { Write-Host '[add-peer] Done.' -ForegroundColor Green }
