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
    # ⚠️ Дефолта в сигнатуре НЕТ намеренно: windows-путь по умолчанию на сервере выглядел бы как
    # «корень задан явно», обход честно находил там ноль манифестов, и борд говорил «манифестов не
    # найдено» — то есть отказ окружения печатался как факт о пулах. Резолв ниже, по платформе.
    [string]$WorkspaceRoot
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}

$checker = Join-Path $PSScriptRoot 'memory-check.ps1'

# Интерпретатор РЕЗОЛВИМ, а не зовём по имени: на сервере исполняемого `powershell` нет вовсе, а
# вызов по имени падает CommandNotFoundException - здесь, под EAP=Stop, он валил бы ВЕСЬ борд.
# Идиома та же, что в agent-memory.ps1 и memory-audit.ps1: путь текущего процесса, без догадок про PATH.
$onWin = $true
try { $v = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($v) { $onWin = [bool]$v.Value } } catch { }
# Кандидаты по очереди: ProcessPath есть только в .NET 6+, MainModule врёт при запуске `dotnet pwsh.dll`.
$psExe = 'powershell'
if (-not $onWin) {
    $psExe = $null
    try { $psExe = [System.Environment]::ProcessPath } catch { }
    if (-not $psExe) { try { $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { } }
    if (-not $psExe) { $psExe = 'pwsh' }
}
# 🛑 @() снаружи if: ветка с ОДНИМ элементом разворачивается в строку, и splatting идёт посимвольно
# («- N o P r o f i l e»). Дефект живёт только в Linux-ветке, на Windows не воспроизводится вовсе.
$psArgs = @(if ($onWin) { '-NoProfile','-ExecutionPolicy','Bypass' } else { '-NoProfile' })

# Корень пространства: на Windows дефолт законен, на сервере его надо задать - и молчать об этом
# нельзя, иначе «манифестов не найдено» читается как факт о пулах, а не как отказ окружения.
if (-not $WorkspaceRoot) {
    if ($env:POOL_WORKSPACE_ROOT) { $WorkspaceRoot = $env:POOL_WORKSPACE_ROOT }
    else {
        Write-Host 'корень пространства надо задать явно: -WorkspaceRoot <путь>' -ForegroundColor Red
        exit 2
    }
}

# Метрики считает модуль, а не этот файл: те же цифры показывает подвал борда задач (pool.ps1).
# Две копии формулы разъехались бы, и владелец получил бы два разных процента на одну роль.
. (Join-Path $PSScriptRoot 'agent-memory.ps1')

# 🛑 Манифесты ищет ОБЩАЯ функция, а не этот файл. Свой обход здесь был третьей копией правила в
# пространстве и самой слабой: без `-Force` (на Unix каталог с точки считается СКРЫТЫМ и пропускается
# молча), без `-Depth`, с исключениями через `'\\'` (на Linux обратного слэша в путях нет, и они не
# исключают НИЧЕГО) и без витрин `_windows`. Из-за последнего борд считал витрину серверного пула
# отдельным пулом и падал на её windows-корне. В самой функции стоит предупреждение «чтобы следующий
# не починил обратно» — вот, не чиню: зову её.
. (Join-Path $PSScriptRoot 'pool-manifest.ps1')
$scan = Get-WorkspaceManifests -WorkspaceRoot $WorkspaceRoot
if (-not $scan.Ok -and $scan.Error) { Write-Host ("обход не удался: {0}" -f $scan.Error) -ForegroundColor Red; exit 1 }
if ($scan.Broken.Count) {
    # Битые называем ПОИМЁННО и идём дальше: молчаливый пропуск неотличим от «такого пула нет».
    Write-Host ("манифестов не разобралось: {0}" -f $scan.Broken.Count) -ForegroundColor Red
    foreach ($b in $scan.Broken) { Write-Host ("  - {0}" -f $b) -ForegroundColor Red }
}
$pools = @($scan.Manifests)
if ($Pool) { $pools = @($pools | Where-Object { $_.Slug -eq $Pool }) }
elseif (-not $All) {
    # Пустой список с кодом 0 неотличим от полной картины - это тот же класс, что и «замечаний нет»
    # при упавшей проверке. Поэтому ноль пулов здесь - отказ, а не ответ.
    if (-not $pools.Count) { Write-Host ("ни одного пула не найдено под {0}" -f $WorkspaceRoot) -ForegroundColor Red; exit 1 }
    "Укажи -Pool <slug> или -All. Доступные пулы:"
    foreach ($p in $pools) { '  ' + $p.Slug }
    exit 0
}
if (-not $pools.Count) { "манифестов не найдено"; exit 1 }

$skipped = @()
foreach ($p in $pools) {
  try {
    # Корня может не быть вовсе (поле потеряли при переезде) или он может вести на чужой диск.
    # ⚠️ Здесь именно Join-Path, а НЕ [IO.Path]::Combine: последний на пустом корне даёт
    # ОТНОСИТЕЛЬНЫЙ путь `.memory`, борд читает чужую память от своего рабочего каталога и печатает
    # её как чужую - тихо и убедительно. Join-Path в этом месте падает, и падение ловится ниже.
    if ([string]::IsNullOrWhiteSpace($p.Cwd)) { throw 'в манифесте нет корня (root/cwd)' }
    $memRoot = Join-Path $p.Cwd '.memory'

    $enabled = (Test-Path (Join-Path $memRoot '.enabled')) -or (Test-Path (Join-Path $PSScriptRoot 'agent-memory.enabled'))
    $state = if ($enabled) { 'раскатано' } else { 'ВЫКЛ (память по-старому, общая)' }
    # Шапка печатается ПОСЛЕ резолва корня: иначе пул сначала объявлялся, а следом отменялся.
    Write-Host ''
    Write-Host ("=== {0} — память ролей [{1}] ===" -f $p.Slug, $state) -ForegroundColor Cyan
    Write-Host ("    каталог: {0}" -f $memRoot) -ForegroundColor DarkGray

    $rows = foreach ($owner in $p.Owners) {
        $dir = Join-Path $memRoot $owner
        $st = Get-AgentMemoryStats -RoleDir $dir
        if (-not $st.Exists) {
            [PSCustomObject]@{ Роль=$owner; Записей='-'; Индекс='-'; 'Потолок%'='-'; 'Писал'='—'; Замечаний='нет каталога' }
            continue
        }
        $ago = if ($st.LastWrite) { '{0:d} дн назад' -f [int]((Get-Date) - $st.LastWrite).TotalDays } else { '—' }
        # Каталог без MEMORY.md - самое опасное состояние, и процентом оно не выражается: записи есть,
        # а в контекст роли не попадает ни одна. Поэтому отдельным словом, а не нулём.
        # ⚠️ Отказ ЧТЕНИЯ индекса - это не измеренный ноль. Get-AgentMemoryStats ставит Unknown, когда
        # MEMORY.md не дался (движок переписывает его ровно тогда, когда идёт PreCompact-аудит), а поля
        # при этом остаются нулевыми - и роль показывалась как «0 стр, 0% потолка», то есть отказ
        # измерения выдавался за измеренный ноль. Ровно тот класс, ради которого правился и счёт
        # замечаний ниже.
        $idxTxt = if ($st.Unknown) { 'НЕ ПРОЧИТАН' } elseif ($st.HasIndex) { "$($st.IndexLines) стр" } else { 'НЕТ ИНДЕКСА' }
        $pctTxt = if ($st.Unknown -or -not $st.HasIndex) { '-' } else { "$($st.Pct) ($($st.Bound))" }

        $notes = '?'
        if (Test-Path $checker) {
            # Успех - ПОЛОЖИТЕЛЬНЫЙ признак (машинная строка RESULT от проверки), а не «ругани не было»:
            # прежний счёт по образцу `^\s+- ` превращал любой отказ в честный ноль.
            # 🛑 EAP локально в Continue: под Stop перенаправление 2>&1 бросает NativeCommandError на
            # ЛЮБУЮ строку дочернего процесса в stderr и теряет весь уже полученный stdout - роль
            # получила бы ОТКАЗ там, где проверка отработала.
            $found = $null
            $eapSaved = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $out = @(& $psExe @psArgs -File $checker -Dir $dir -Quiet 2>&1)
                foreach ($l in $out) { if ("$l" -match 'RESULT:\s*findings=(\d+)') { $found = [int]$Matches[1] } }
            } catch { }
            finally { $ErrorActionPreference = $eapSaved }
            $notes = if ($null -eq $found) { 'ОТКАЗ' } else { $found }
        }
        [PSCustomObject]@{ Роль=$owner; Записей=$st.Entries; Индекс=$idxTxt; 'Потолок%'=$pctTxt; 'Писал'=$ago; Замечаний=$notes }
    }
    $rows | Format-Table -AutoSize | Out-String -Width 140 | Write-Host
  } catch {
    # Обход НЕ обрывается на одном негодном пуле: раньше борд печатал часть таблиц, падал на первом
    # непригодном корне и оставлял человеку картину, неотличимую от полной.
    $skipped += $p.Slug
    Write-Host ''
    Write-Host ("=== {0} — ПУЛ ПРОПУЩЕН: {1} ===" -f $p.Slug, $_.Exception.Message) -ForegroundColor Red
    Write-Host ("    корень: {0}" -f $p.Cwd) -ForegroundColor DarkGray
  }
}

if ($skipped.Count) {
    Write-Host ''
    Write-Host ("пулов пропущено: {0} ({1}) - картина НЕПОЛНАЯ" -f $skipped.Count, ($skipped -join ', ')) -ForegroundColor Red
}
Write-Host "подробности по роли: memory-check.ps1 -Dir <каталог роли>" -ForegroundColor DarkGray
