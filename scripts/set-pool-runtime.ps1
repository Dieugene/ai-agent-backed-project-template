<#
    set-pool-runtime.ps1 — задать параметры запуска модели (model + effort) участникам пулов.

    Зачем: без явных флагов сессия при `--resume` восстанавливается на СВОЕЙ старой модели, а
    глобальные `/model` и `/effort` протекают во все пулы разом. Флаги в wrapper'е это развязывают.

    Канон (по умолчанию):
        ведущий пула (manifest "lead": true) -> -Model claude-opus-5[1m] -Effort xhigh
        рядовой участник                     -> -Model claude-opus-5[1m] -Effort medium

    Примеры:
        # общая раскатка канона по всем пулам
        .\set-pool-runtime.ps1 -All -DryRun
        .\set-pool-runtime.ps1 -All

        # точечно: одна роль на повышенный уровень
        .\set-pool-runtime.ps1 -Pool sub-c -Owner extractor-auditors -Effort xhigh

        # весь пул на другую модель
        .\set-pool-runtime.ps1 -Pool pool-b -Model claude-opus-5

        # снять пин (вернуть наследование от клиента)
        .\set-pool-runtime.ps1 -Pool covenants -Model none -Effort none

    Что правит: единственную строку запуска в `claude-<роль>.bat` — ту, что начинается с
    `powershell ... -File ...\pool-launch.ps1` (или `launch-claude.ps1`). Строки-обманки в
    REM-комментариях не трогает. Файл пишется побайтно: кодировка (UTF-8 без BOM) и смешанные
    переводы строк сохраняются, потому что правится только содержимое одной строки.

    Чего НЕ трогает: `launcher.bat` и `devops-orchestrator-2.bat` (личные роли владельца — они
    зовут `claude` напрямую и под якорь не подпадают), копии в `.claude\worktrees\`, папку
    `ai-umbrella\` (резерв после миграции).
#>
[CmdletBinding()]
param(
    [string]$Pool = '',        # slug пула (см. pool.manifest.json)
    [string]$Owner = '',       # AGENT_OWNER роли
    [string]$Model = '',       # id модели; 'none' = убрать флаг; пусто = канон
    [string]$Effort = '',      # low|medium|high|xhigh|max; 'none' = убрать флаг; пусто = канон
    [switch]$All,              # обязателен для сплошной раскатки (без -Pool/-Owner)
    [switch]$DryRun,
    [switch]$NoBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- канон ------------------------------------------------------------------
$CANON_MODEL       = 'claude-opus-5[1m]'
$CANON_LEAD_EFFORT = 'xhigh'
$CANON_EFFORT      = 'medium'

# Wrapper'ы, которых нет ни в одном манифесте (устаревшие экземпляры ролей и fresh-session-клоны).
# lead=$true там, где wrapper поднимает ведущего своего пула.
$ORPHANS = @(
    @{ Path = 'C:\workspace-root\umbrella\sub-a\claude-frontend-sub-a.bat';                 Lead = $false; Note = 'sub-a: старый frontend (в манифесте frontend2)' },
    @{ Path = 'C:\workspace-root\umbrella\sub-a\claude-metrics2-sub-a.bat';                 Lead = $false; Note = 'sub-a: fresh-session клон metrics' },
    @{ Path = 'C:\workspace-root\demo-site-replication\claude-dev.bat';                   Lead = $true;  Note = 'demo-site-replication: единственная роль' },
    @{ Path = 'C:\workspace-root\monorepo\scripts\claude-auditors-dev.bat';        Lead = $false; Note = 'auditors: 1-й экземпляр dev' },
    @{ Path = 'C:\workspace-root\monorepo\scripts\claude-auditors-tl.bat';         Lead = $true;  Note = 'auditors: 1-й экземпляр лида' },
    @{ Path = 'C:\workspace-root\umbrella\launch-devops.bat';                           Lead = $true;  Note = 'devops-umbrella (из control.json)' }
)

# NB: завершать якорь на '$' нельзя — в .NET он в multiline совпадает только ПЕРЕД '\n',
# поэтому строки с CRLF (а такие среди .bat есть) молча не находились. Отсюда lookahead.
$ANCHOR = '(?m)^([ \t]*powershell\b[^\r\n]*-File[^\r\n]*(?:pool-launch|launch-claude)\.ps1[^\r\n]*)(?=\r|\n|$)'

function Write-Ok   { param([string]$m) Write-Host "  [ok] $m"   -ForegroundColor Green }
function Write-Skip { param([string]$m) Write-Host "  [--] $m"   -ForegroundColor DarkGray }
function Write-Bad  { param([string]$m) Write-Host "  [!!] $m"   -ForegroundColor Red }

# --- сбор целей -------------------------------------------------------------
function Get-Targets {
    $targets = @()

    $mans = Get-ChildItem 'C:\workspace-root' -Recurse -Filter 'pool.manifest.json' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notlike '*\worktrees\*' -and $_.FullName -notlike '*\ai-umbrella\*' }

    foreach ($m in $mans) {
        try { $j = Get-Content $m.FullName -Raw -Encoding utf8 | ConvertFrom-Json } catch { continue }
        foreach ($r in $j.roles) {
            $isLead = ($r.PSObject.Properties.Name -contains 'lead') -and $r.lead
            $targets += [pscustomobject]@{
                Pool  = $j.slug
                Owner = $r.owner
                Lead  = [bool]$isLead
                Path  = (Join-Path $j.root $r.bat)
                # Персональное усилие роли: ключ "effort" в её записи манифеста побеждает канон.
                # Заведено под <peer-supervisor> — он рядовой по манифесту (ведущий там launcher),
                # но работает как второй супервайзор, и владелец распорядился держать ему xhigh.
                # Без этого поля выравнивание молча понижало бы его до medium при каждом прогоне.
                Effort = $(if ($r.PSObject.Properties.Name -contains 'effort') { [string]$r.effort } else { '' })
                Note  = ''
            }
        }
    }

    foreach ($o in $ORPHANS) {
        $targets += [pscustomobject]@{
            Pool  = '(вне манифеста)'
            Owner = [IO.Path]::GetFileNameWithoutExtension($o.Path)
            Lead  = [bool]$o.Lead
            Path  = $o.Path
            Effort = ''
            Note  = $o.Note
        }
    }
    return $targets
}

# --- правка одной строки запуска -------------------------------------------
function Set-LaunchLine {
    param([string]$Line, [string]$WantModel, [string]$WantEffort)

    # снять существующие флаги (одинарный дефис; '--effort' в прямых вызовах claude не заденет)
    $out = [regex]::Replace($Line, '\s+(?<!-)-Model\s+(?:"[^"]*"|\S+)',  '')
    $out = [regex]::Replace($out,  '\s+(?<!-)-Effort\s+(?:"[^"]*"|\S+)', '')
    $out = $out.TrimEnd()

    if ($WantModel)  { $out += ' -Model "'  + $WantModel  + '"' }
    if ($WantEffort) { $out += ' -Effort ' + $WantEffort }
    return $out
}

# --- main -------------------------------------------------------------------
if (-not $All -and -not $Pool -and -not $Owner) {
    Write-Bad 'Укажи -All (сплошная раскатка) либо -Pool/-Owner (точечно). Ничего не сделано.'
    exit 2
}

# ВНИМАНИЕ: имена переменных в PS регистро-независимы — локальную нельзя звать $all,
# иначе она затрёт параметр-переключатель $All (ошибка приведения типа при старте).
$allTargets = @(Get-Targets)
$sel = $allTargets
if ($Pool)  { $sel = @($sel | Where-Object { $_.Pool  -eq $Pool  }) }
if ($Owner) { $sel = @($sel | Where-Object { $_.Owner -eq $Owner }) }

if (-not $sel.Count) {
    Write-Bad "Под фильтр (Pool='$Pool' Owner='$Owner') не попало ни одной роли. Всего ролей: $($allTargets.Count)."
    exit 2
}

$bkDir = ''
if (-not $DryRun -and -not $NoBackup) {
    $bkDir = Join-Path $env:TEMP ('pool-runtime-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $bkDir | Out-Null
}

Write-Host ''
Write-Host ("Целей: {0}{1}" -f $sel.Count, $(if ($DryRun) { '   (DRY-RUN, ничего не пишется)' } else { '' })) -ForegroundColor Cyan
if ($bkDir) { Write-Host "Бэкап: $bkDir" -ForegroundColor Cyan }
Write-Host ''

$nChanged = 0; $nSame = 0; $nFail = 0

foreach ($t in ($sel | Sort-Object Pool, Owner)) {
    $tag = "$($t.Pool)/$($t.Owner)"

    if (-not (Test-Path -LiteralPath $t.Path)) { Write-Bad "$tag — файла нет: $($t.Path)"; $nFail++; continue }

    $wantModel = if ($Model)  { $(if ($Model -eq 'none')  { '' } else { $Model  }) } else { $CANON_MODEL }
    $wantEff   = if ($Effort) { $(if ($Effort -eq 'none') { '' } else { $Effort }) }
                 else { $(if ($t.Effort) { $t.Effort } elseif ($t.Lead) { $CANON_LEAD_EFFORT } else { $CANON_EFFORT }) }

    $bytes = [IO.File]::ReadAllBytes($t.Path)
    $text  = [Text.Encoding]::UTF8.GetString($bytes)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Bad "$tag — у .bat обнаружен BOM, пропускаю (нештатный файл)"; $nFail++; continue
    }

    $hits = [regex]::Matches($text, $ANCHOR)
    if ($hits.Count -ne 1) { Write-Bad "$tag — строк запуска найдено $($hits.Count) (нужна ровно 1), пропускаю"; $nFail++; continue }

    $oldLine = $hits[0].Groups[1].Value
    $newLine = Set-LaunchLine -Line $oldLine -WantModel $wantModel -WantEffort $wantEff

    if ($newLine -eq $oldLine) { Write-Skip "$tag — уже как надо"; $nSame++; continue }

    if ($DryRun) {
        Write-Ok "$tag$(if ($t.Note) { '  (' + $t.Note + ')' })"
        Write-Host "        было:  $($oldLine.Trim())" -ForegroundColor DarkGray
        Write-Host "        стало: $($newLine.Trim())" -ForegroundColor Gray
        $nChanged++
        continue
    }

    if ($bkDir) {
        $flat = ($t.Path -replace '^[A-Za-z]:\\', '') -replace '[\\/]', '__'
        Copy-Item -LiteralPath $t.Path -Destination (Join-Path $bkDir $flat) -Force
    }

    $newText = $text.Remove($hits[0].Groups[1].Index, $oldLine.Length).Insert($hits[0].Groups[1].Index, $newLine)
    [IO.File]::WriteAllBytes($t.Path, [Text.Encoding]::UTF8.GetBytes($newText))

    # самопроверка записанного
    $check = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($t.Path))
    $okModel = (-not $wantModel) -or $check.Contains('-Model "' + $wantModel + '"')
    $okEff   = (-not $wantEff)   -or $check.Contains('-Effort ' + $wantEff)
    if ($okModel -and $okEff) { Write-Ok "$tag -> model=$(if($wantModel){$wantModel}else{'(снят)'}) effort=$(if($wantEff){$wantEff}else{'(снят)'})"; $nChanged++ }
    else { Write-Bad "$tag — запись не подтвердилась самопроверкой!"; $nFail++ }
}

Write-Host ''
Write-Host ("ИТОГ: изменено {0}, уже верно {1}, ошибок {2}" -f $nChanged, $nSame, $nFail) -ForegroundColor Cyan
if ($nFail) { exit 1 }
