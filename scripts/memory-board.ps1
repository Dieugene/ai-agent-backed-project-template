# memory-board.ps1 - борд долговременной памяти пула: по строке на роль.
#
#   powershell -File memory-board.ps1 -Pool <slug>     один пул
#   powershell -File memory-board.ps1 -All             все пулы воркспейса
#
# Показывает то, чего не видно изнутри роли: у кого память не завелась вовсе, у кого индекс подошёл
# к потолку (движок обрежет), у кого туда поехала хроника, кто не писал давно.
#
# Все числа - МАРКЕРЫ, а не приговор: повод разобраться, что пошло не так, а не резать записи.
# Отсюда и отсутствие «нормы»: колонка «замечания» ведёт к memory-check.ps1 по конкретной роли.

param(
    [string]$Pool,
    [switch]$All,
    [string]$WorkspaceRoot = 'C:\workspace-root'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$checker = Join-Path $PSScriptRoot 'memory-check.ps1'

# Метрики считает модуль, а не этот файл: те же цифры показывает подвал борда задач (pool.ps1).
# Две копии формулы разъехались бы, и владелец получил бы два разных процента на одну роль.
. (Join-Path $PSScriptRoot 'agent-memory.ps1')

$manifests = @(Get-ChildItem $WorkspaceRoot -Recurse -File -Filter 'pool.manifest.json' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(notes\\backup|node_modules)\\' })
if ($Pool) { $manifests = @($manifests | Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).slug -eq $Pool }) }
elseif (-not $All) {
    "Укажи -Pool <slug> или -All. Доступные пулы:"
    foreach ($m in $manifests) { '  ' + ((Get-Content $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).slug) }
    exit 0
}
if (-not $manifests.Count) { "манифестов не найдено"; exit 1 }

foreach ($m in $manifests) {
    $j = Get-Content $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $cwd = if ($j.PSObject.Properties.Name -contains 'cwd' -and $j.cwd) { $j.cwd } else { $j.root }
    $memRoot = Join-Path $cwd '.memory'

    $enabled = (Test-Path (Join-Path $memRoot '.enabled')) -or (Test-Path (Join-Path $PSScriptRoot 'agent-memory.enabled'))
    $state = if ($enabled) { 'раскатано' } else { 'ВЫКЛ (память по-старому, общая)' }
    Write-Host ''
    Write-Host ("=== {0} — память ролей [{1}] ===" -f $j.slug, $state) -ForegroundColor Cyan
    Write-Host ("    каталог: {0}" -f $memRoot) -ForegroundColor DarkGray

    $rows = foreach ($r in $j.roles) {
        $dir = Join-Path $memRoot $r.owner
        $st = Get-AgentMemoryStats -RoleDir $dir
        if (-not $st.Exists) {
            [PSCustomObject]@{ Роль=$r.owner; Записей='-'; Индекс='-'; 'Потолок%'='-'; 'Писал'='—'; Замечаний='нет каталога' }
            continue
        }
        $ago = if ($st.LastWrite) { '{0:d} дн назад' -f [int]((Get-Date) - $st.LastWrite).TotalDays } else { '—' }
        # Каталог без MEMORY.md - самое опасное состояние, и процентом оно не выражается: записи есть,
        # а в контекст роли не попадает ни одна. Поэтому отдельным словом, а не нулём.
        $idxTxt = if ($st.HasIndex) { "$($st.IndexLines) стр" } else { 'НЕТ ИНДЕКСА' }
        $pctTxt = if ($st.HasIndex) { "$($st.Pct) ($($st.Bound))" } else { '-' }

        $notes = '?'
        if (Test-Path $checker) {
            $out = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $checker -Dir $dir -Quiet 2>&1)
            $notes = @($out | Where-Object { $_ -match '^\s+- ' }).Count
        }
        [PSCustomObject]@{ Роль=$r.owner; Записей=$st.Entries; Индекс=$idxTxt; 'Потолок%'=$pctTxt; 'Писал'=$ago; Замечаний=$notes }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 140 | Write-Host
}

Write-Host "подробности по роли: memory-check.ps1 -Dir <каталог роли>" -ForegroundColor DarkGray
