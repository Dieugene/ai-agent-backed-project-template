#Requires -Version 5.1
<#
.SYNOPSIS
    Внешний контроллер: полный цикл завершения работы сессии / пула.

.DESCRIPTION
    Реализует основание 1.1 из design/pool-external-control-and-context-refresh-2026-07-17.md:
    «завершаем работу» + контекст >= порога -> прогнать handoff перед гашением; остальных просто гасим.

    Цикл на каждую сессию:
      1. ctx% из ~/.claude/.control/ctx-<sid>.json (пишет tee в statusline-command.sh)
      2. [если ctx >= Threshold] задача в шину «заверши работу» -> вотчер будит агента ->
         агент делает handoff-myself + возвращает claimed-задачи + ставит флаг готовности
      3. ждём флаг (таймаут)
      4. taskkill /F /T /PID <claude>   — дерево целиком
      5. claude --resume <sid> -p "/compact"  — headless compact для следующего старта

    ФАКТЫ, на которых стоит процедура (эксперименты 2026-07-17, см. дизайн-док):
      E1 — headless `claude --resume <id> -p "/compact"` РАБОТАЕТ: только из PowerShell
           (Git Bash ломает слеш MSYS-конвертацией) и только с cwd = каталог проекта сессии.
      E4 — `Stop-Process` ОСТАВЛЯЕТ СИРОТ: claude умирает, а вотчер/sentinel/фоновые задачи живут.
           Поэтому Stop-Process как способ гашения сессии ЗАПРЕЩЁН.
      E5 — `taskkill /F /T /PID` убивает дерево целиком (сессия + вотчер + sentinel + фоновые),
           сирот не остаётся => парсить локи НЕ нужно (и не надо: локи заведомо неполны).

    ИНВАРИАНТЫ:
      * Мосты (remote-bridge) НЕ трогаются — они подняты через WMI, их родитель WmiPrvSE,
        они вне дерева сессии, /T их не достанет. Это правильно: мост живёт per-бот.
      * Себя не гасим (гард по ancestry от $PID).
      * Гасим только по PID конкретной сессии, никогда по имени/маске (рядом живут чужие пулы).

.PARAMETER Pool
    Slug пула из pool.manifest.json — завершить весь пул.
.PARAMETER Owner
    AGENT_OWNER одной роли — завершить одну сессию.
.PARAMETER Threshold
    Порог контекста в % : >= порога -> прогоняем handoff. Дефолт 12 (вводная пользователя).
.PARAMETER WaitHandoffSec
    Сколько ждать флаг готовности от агента. Дефолт 420.
.PARAMETER Force
    Гасить даже если агент не подтвердил handoff (по таймауту). Без него — сессия пропускается.
.PARAMETER NoCompact
    Не выполнять headless compact после гашения.
.PARAMETER DryRun
    Показать план, ничего не трогать.
.PARAMETER Recharge
    ПЕРЕЗАРЯДКА одной роли: тот же цикл (handoff -> kill -> compact), но потом роль ПОДНИМАЕТСЯ обратно.
    Роль не может сделать это сама (гард «себя не гасим»), поэтому её перезаряжает сосед по пулу.
    Отличия от гашения — не косметические, каждое куплено разбором (протокол 2026-08-09):
      * компакт ЖДЁМ, а не детачим: поднятая роль + пишущий компакт = два процесса на один транскрипт;
      * intent-метку снимаем ДО подъёма — под ней сторож чата молчит, и роль поднялась бы НЕМОЙ;
      * перед подъёмом убеждаемся, что живых сессий с этим титулом не осталось (taskkill /T чистит не всё);
      * обёртку роли проверяем ДО гашения — иначе погасим и не сможем поднять;
      * поднимаем ОБЁРТКОЙ и через WMI (иначе роль — потомок контроллера и умрёт вместе с его окном).
    Приёмку даёт не контроллер, а сама роль: письмо в шину (техническая) + сообщение владельцу (человеческая).
.PARAMETER RechargeWaitCompactSec
    Сколько ждать завершения headless-компакта при -Recharge. Дефолт 300.
.PARAMETER SelfTest
    Прогнать внутренние проверки.

.EXAMPLE
    .\pool-shutdown.ps1 -Pool <pool-b> -DryRun
.EXAMPLE
    .\pool-shutdown.ps1 -Owner author
#>
[CmdletBinding(DefaultParameterSetName = 'Pool')]
param(
    [Parameter(ParameterSetName = 'Pool')]    [string]$Pool,
    [Parameter(ParameterSetName = 'Pool')]    [string[]]$Only = @(),   # подмножество ролей ВНУТРИ -Pool (pool-scoped, без неоднозначности -Owner)
    [Parameter(ParameterSetName = 'Owner')]   [string]$Owner,
    [int]$Threshold = 12,
    [int]$WaitHandoffSec = 420,
    [string]$HandoffCommand = 'handoff-myself',
    [switch]$Force,
    [switch]$NoCompact,
    [switch]$HandoffOnly,
    [switch]$KillOnly,
    [switch]$Full,
    [switch]$Seal,
    [switch]$CloseWindow,
    [switch]$Recharge,
    [int]$RechargeWaitCompactSec = 300,
    [switch]$DryRun,
    [Parameter(ParameterSetName = 'SelfTest')][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Общая библиотека манифеста: Resolve-PoolBus / Resolve-PoolCwd. До 2026-07-27 контроллер её НЕ
# подключал и всюду читал `root`, у которого ЧЕТЫРЕ разных смысла (шапка pool-manifest.ps1) —
# отсюда молчаливый no-op на пулах, выросших в монорепо. Пикер её dot-source'ит так же.
. (Join-Path $PSScriptRoot 'pool-manifest.ps1')

# Память роли — источник колонки «запись обновлена». Зависимость НЕобязательная: колонка косметическая,
# и отсутствие модуля не должно ронять гашение (не загрузился -> колонка молчит, всё остальное живо).
# ⚠️ Отсюда зовём ТОЛЬКО read-only `Get-AgentMemoryStats`. Соседняя `Get-AgentMemoryArgs` СОЗДАЁТ
# каталоги, пишет settings и делает `git init` — контроллер, позвав её, наплодил бы пустые хранилища
# всем ролям, которые ещё не переехали, и следующее же гашение показало бы им ложное «НЕТ(!)».
$script:MemStatsReady = $false
try {
    $agentMemModule = Join-Path $PSScriptRoot 'agent-memory.ps1'
    if (Test-Path $agentMemModule) {
        . $agentMemModule
        $script:MemStatsReady = $null -ne (Get-Command Get-AgentMemoryStats -ErrorAction SilentlyContinue)
    }
} catch { $script:MemStatsReady = $false }

$script:ControlDir  = Join-Path $env:USERPROFILE '.claude\.control'
$script:WorkspaceRoot = 'C:\workspace-root'
$script:LiveSessionsCache = $null
$script:ManifestsCache = $null
$script:LogFile = $null   # пошаговый диагностический лог (ставится в main после guard); $null -> Write-Log = no-op

# Диагностический лог в файл: локализовать, ГДЕ контроллер застревает. void-метод (в pipeline не течёт),
# UTF-8 (кириллица в сообщениях), no-op пока LogFile не задан, любые ошибки проглатываются.
function Write-Log {
    param([string]$Msg)
    if (-not $script:LogFile) { return }
    try {
        [System.IO.File]::AppendAllText(
            $script:LogFile,
            ('[{0}] {1}{2}' -f (Get-Date).ToString('HH:mm:ss.fff'), $Msg, "`r`n"),
            [System.Text.Encoding]::UTF8)
    } catch { }
}

function Write-Step { param([string]$Msg) Write-Host "[shutdown] $Msg" -ForegroundColor Cyan;   Write-Log "STEP $Msg" }
function Write-Warn { param([string]$Msg) Write-Host "[shutdown] WARN: $Msg" -ForegroundColor Yellow; Write-Log "WARN $Msg" }
function Write-Ok   { param([string]$Msg) Write-Host "[shutdown] OK: $Msg" -ForegroundColor Green;  Write-Log "OK   $Msg" }
function Write-Err  { param([string]$Msg) Write-Host "[shutdown] ERR: $Msg" -ForegroundColor Red;   Write-Log "ERR  $Msg" }

# ---------------------------------------------------------------- метрика контекста

<#
    Карта живых сессий из tee-метрики статус-лайна.
    Файл на сессию: ~/.claude/.control/ctx-<session_id>.json — содержит session_id,
    session_name, cwd, agent_owner, pool_bus, context_window.used_percentage, stamped_at.
#>
<# Безопасное чтение свойства JSON — под Set-StrictMode доступ к отсутствующему полю кидает. #>
function Get-JProp {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj.PSObject.Properties.Name -contains $Name) { return $Obj.$Name }
    return $null
}

function Get-CtxMap {
    $out = @()
    if (-not (Test-Path $script:ControlDir)) { return $out }
    $files = Get-ChildItem -Path $script:ControlDir -Filter 'ctx-*.json' -ErrorAction SilentlyContinue
    foreach ($f in $files) {
        try {
            $j = Get-Content $f.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch { continue }
        $sid = Get-JProp $j 'session_id'
        if (-not $sid) { continue }
        $cw  = Get-JProp $j 'context_window'
        $pct = $null
        try { $u = Get-JProp $cw 'used_percentage'; if ($null -ne $u) { $pct = [double]$u } } catch { }
        $stamp = Get-JProp $j 'stamped_at'
        $age = $null
        try { if ($stamp) { $age = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($stamp).ToUniversalTime()).TotalSeconds } } catch { }
        $out += [pscustomobject]@{
            SessionId = [string]$sid
            Name      = [string](Get-JProp $j 'session_name')
            Owner     = [string](Get-JProp $j 'agent_owner')
            Bus       = [string](Get-JProp $j 'pool_bus')   # exact pool discriminator; empty for sessions started before this field existed
            Cwd       = [string](Get-JProp $j 'cwd')
            Pct       = $pct
            AgeSec    = $age
            File      = $f.FullName
        }
    }
    return $out
}

<# cwd метрики принадлежит пулу, только если он ПОД корнем пула (равен корню ИЛИ подкаталог —
   агент мог `cd` в подпапку, cwd дрейфует). Ключ к разведению пулов с ОДИНАКОВЫМИ именами ролей
   (lead/operator/builder есть и у <pool-a>, и у networking — баг 2026-07-18: -Pool хватал чужой пул). #>
# The BUS is the exact pool discriminator: one pool = one bus, whereas cwd can be shared by several
# pools of the same project (<umbrella>, <monorepo> today; any multi-pool project tomorrow).
# Metric sessions started before the pool_bus field exists report it empty - that means "unknown",
# never "mismatch", so the caller falls back to the cwd heuristic instead of dropping a live session.
function Test-SameBus {
    param([string]$A, [string]$B)
    if (-not $A -or -not $B) { return $false }
    $na = $A.TrimEnd([char]92, [char]47)
    $nb = $B.TrimEnd([char]92, [char]47)
    try { $na = [IO.Path]::GetFullPath($na).TrimEnd([char]92, [char]47) } catch { }
    try { $nb = [IO.Path]::GetFullPath($nb).TrimEnd([char]92, [char]47) } catch { }
    return [string]::Equals($na, $nb, [StringComparison]::OrdinalIgnoreCase)
}
function Test-CwdUnderRoot {
    param([string]$Cwd, [string]$Root)
    if ([string]::IsNullOrWhiteSpace($Cwd) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    $c = ($Cwd  -replace '/', '\').TrimEnd('\').ToLowerInvariant()
    $r = ($Root -replace '/', '\').TrimEnd('\').ToLowerInvariant()
    return ($c -eq $r) -or $c.StartsWith("$r\")
}

# ---------------------------------------------------------------- процессы

<# Мой собственный claude.exe — чтобы контроллер не погасил сам себя. #>
function Get-MyClaudePid {
    $cur = $PID; $guard = 0
    while ($cur -and $guard -lt 25) {
        $guard++
        $pr = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
        if (-not $pr) { return $null }
        if ($pr.Name -eq 'claude.exe') { return [int]$pr.ProcessId }
        $cur = $pr.ParentProcessId
    }
    return $null
}

<# Резолв title -> session UUID по транскриптам (копия логики из new-pool.ps1). #>
function Find-SessionIdByTitle {
    param([string]$Title, [string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $matchPattern = '"customTitle":"' + [regex]::Escape($Title) + '"'
    $files = Get-ChildItem -Path $Dir -Filter '*.jsonl' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        try {
            $titleLines = Select-String -Path $f.FullName -Pattern '"customTitle":"[^"]*"' -ErrorAction Stop
            if (-not $titleLines) { continue }
            if ($titleLines[-1].Line -match $matchPattern) { return $f.BaseName }
        } catch { continue }
    }
    return $null
}

<# SessionTitle роли из её wrapper'а (.bat).
   Два источника, в порядке надёжности: строка `-SessionTitle "X"` (роли, идущие через pool-launch.ps1)
   и `--resume <имя>` (роли, зовущие движок напрямую — у них титул только там).
   🛑 Строки-комментарии (`REM`, `::`) отбрасываются ДО поиска, и это несущая часть, а не гигиена:
   пояснение вида «титул передаётся через --resume» само содержит образец, регулярка берёт ПЕРВОЕ
   вхождение — и титулом становится случайное слово из комментария (поймано на claude-launcher.bat,
   вышло «и»). По той же причине здесь больше не работает приём «положить -SessionTitle в REM».
   ⚠️ `--resume` с идентификатором сессии сюда не попадает: его подставляет pool-launch.ps1 на лету,
   в тексте батника он не лежит. #>
function Get-SessionTitleFromBat {
    param([string]$PoolRoot, [string]$BatName)
    if (-not $BatName) { return $null }
    $bat = Join-Path $PoolRoot $BatName
    if (-not (Test-Path $bat)) { return $null }
    try { $txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($bat)) } catch { return $null }
    $code = ($txt -split "`n" | Where-Object { $_ -notmatch '^\s*(?i:rem)\b' -and $_ -notmatch '^\s*::' }) -join "`n"
    $m = [regex]::Match($code, '-SessionTitle\s+"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($code, '--resume\s+(?:"([^"]+)"|(\S+))')
    if ($m.Success) { if ($m.Groups[1].Success) { return $m.Groups[1].Value } else { return $m.Groups[2].Value } }
    return $null
}

<# Все потомки процесса (BFS по дереву). #>
function Get-Descendants {
    param([int]$RootPid, $AllProcs)
    if (-not $AllProcs) { $AllProcs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue }
    $childrenOf = @{}
    foreach ($p in $AllProcs) {
        $pp = [int]$p.ParentProcessId
        if (-not $childrenOf.ContainsKey($pp)) { $childrenOf[$pp] = New-Object System.Collections.ArrayList }
        [void]$childrenOf[$pp].Add($p)
    }
    $result = New-Object System.Collections.ArrayList
    $queue  = New-Object System.Collections.Queue
    $queue.Enqueue([int]$RootPid)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($seen.ContainsKey($cur)) { continue }
        $seen[$cur] = $true
        if ($childrenOf.ContainsKey($cur)) {
            foreach ($c in $childrenOf[$cur]) { [void]$result.Add($c); $queue.Enqueue([int]$c.ProcessId) }
        }
    }
    return $result
}

<#
    ПУНКТ 3 — запечатать агента: остановить ВСЕ источники побудки в его дереве
    (пул-вотчер — `pool.ps1 watch` ИЛИ непрерывный `pool.ps1 monitor` — + Telegram `chat_sentinel.py`),
    claude оставить ЖИВЫМ. ⚠️ `monitor` в маске обязателен: он не выходит на задаче, и без него
    запечатанная роль оставалась бы с живым сторожем и просыпалась после «запечатывания».
    По PID (surgical), не по имени. Возвращает что остановлено + был ли это Telegram-листенер.
#>
function Invoke-SealAgent {
    param([int]$ClaudePid)
    $all  = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $desc = Get-Descendants -RootPid $ClaudePid -AllProcs $all
    $stopped = @(); $sentinel = $false
    foreach ($d in $desc) {
        $cl = $d.CommandLine
        if (-not $cl) { continue }
        if ($cl -match 'pool\.ps1.*\b(watch|monitor)\b') { Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue; $stopped += "вотчер($($d.ProcessId))" }
        elseif ($cl -like '*chat_sentinel*')   { Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue; $stopped += "sentinel($($d.ProcessId))"; $sentinel = $true }
    }
    return [pscustomobject]@{ Stopped = $stopped; SentinelStopped = $sentinel }
}

<# customTitle сессии по её UUID — читаем её транскрипт напрямую. #>
function Get-CustomTitleByUuid {
    param([string]$Uuid)
    $projRoot = Join-Path $env:USERPROFILE '.claude\projects'
    if (-not (Test-Path $projRoot)) { return $null }
    foreach ($d in (Get-ChildItem $projRoot -Directory -ErrorAction SilentlyContinue)) {
        $f = Join-Path $d.FullName "$Uuid.jsonl"
        if (Test-Path $f) {
            try { $tl = Select-String -Path $f -Pattern '"customTitle":"[^"]*"' -ErrorAction Stop } catch { return $null }
            if ($tl) { $m = [regex]::Match($tl[-1].Line, '"customTitle":"([^"]*)"'); if ($m.Success) { return $m.Groups[1].Value } }
            return $null
        }
    }
    return $null
}

<#
    Карта ЖИВЫХ claude-сессий: pid + resume/name-токен + реальный title.
    Идём ОТ ПРОЦЕССОВ (не от новейшего транскрипта!) — иначе title с несколькими
    транскриптами резолвится в UUID без живого процесса (баг 2026-07-17: у <pool-a>
    два 'Lead-TeamLive', свежий транскрипт без процесса). Кэш на прогон.
#>
function Get-PoolRootFromCmdLine {
    # Корень пула из cmdline предка: путь до claude-<owner>.bat (cmd) либо scripts\pool-launch.ps1 (powershell).
    param([string]$CommandLine)
    if (-not $CommandLine) { return '' }
    $m = [regex]::Match($CommandLine, '(?i)([A-Za-z]:\\[^"'']+?)\\claude-[A-Za-z0-9_\-]+\.bat')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($CommandLine, '(?i)([A-Za-z]:\\[^"'']+?)\\scripts\\pool-launch\.ps1')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

<#
    КОМПАКТ-GUARD. Контроллер САМ порождает второй claude.exe с ТЕМ ЖЕ uuid, что у убитой сессии:
    `Invoke-HeadlessCompact` запускает `claude --resume <uuid> ... -p "/compact"`. Резолвер живых
    сессий этого не различал и считал компакт «живой панелью». Следствия (наблюдались 27.07):
      * `-CloseWindow` не закрывал окно НИКОГДА — гейт живости печатал «ещё живы панели: lead, …»
        при уже убитых ролях;
      * повторный прогон убивал компакт на полпути и рапортовал `ok`.
    Комментарий «uuid глобально уникален — pool-safe» в Get-SessionPid был ЛОЖЕН именно поэтому:
    уникальность uuid не спасает, когда дубль порождает сам контроллер.

    ПРИЗНАК — два независимых, любого достаточно (одного `-p` НЕ хватает: позиционный стартовый
    промпт роли лежит в CommandLine целиком, и слово ` -p ` в тексте промпта сделало бы ЖИВУЮ
    панель невидимой — это тот же класс молчаливого регресса, что здесь и лечится):
      1. предок — `cmd /c "<TEMP>\poolcompact-*.bat"`: ровно то, что пишет Invoke-HeadlessCompact;
      2. `-p`/`--print`, аргумент которого начинается со слэша (слэш-команда, а не текст промпта).
#>
function Test-CompactProc {
    param($Proc, $ProcMap)
    if (-not $Proc) { return $false }
    $cl = $Proc.CommandLine
    if ($cl -and [regex]::IsMatch($cl, '(?i)(^|\s)(-p|--print)\s+"?/')) { return $true }
    if ($ProcMap) {
        $parent = $ProcMap[[int]$Proc.ParentProcessId]
        if ($parent -and $parent.CommandLine -and [regex]::IsMatch($parent.CommandLine, '(?i)poolcompact-[^\\/]*\.bat')) { return $true }
    }
    return $false
}

function Resolve-RootFromAncestry {
    # Вверх от claude.exe до предка, чья cmdline выдаёт корень пула (wrapper .bat / pool-launch.ps1).
    param([int]$ClaudePid, $ProcMap)
    $cur = $ClaudePid; $guard = 0; $first = $true
    while ($cur -and $guard -lt 20) {
        $guard++
        $p = $ProcMap[[int]$cur]
        if (-not $p) { break }
        if ($p.CommandLine) { $r = Get-PoolRootFromCmdLine $p.CommandLine; if ($r) { return $r } }
        if (-not $first -and $p.Name -eq 'claude.exe') { break }   # дошли до ЧУЖОЙ сессии — выше не лезем
        $first = $false
        $cur = [int]$p.ParentProcessId
    }
    return ''
}

<#
    Карта живых claude.exe: Pid/Token/SessionId/Title + КОРЕНЬ ПУЛА (Root) из предка-wrapper'а.
    Root нужен, чтобы резолв по титулу был СКОУПЛЕН по пулу: иначе одинаковый SessionTitle двух
    пулов дал бы чужой PID (Win32_Process не несёт cwd — идём по дереву процессов). Кэш на прогон.
#>
function Get-LiveSessions {
    if ($null -ne $script:LiveSessionsCache) { return $script:LiveSessionsCache }
    $map = @{}
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $map[[int]$p.ProcessId] = $p }
    $out = @()
    foreach ($p in $map.Values) {
        if ($p.Name -ne 'claude.exe' -or -not $p.CommandLine) { continue }
        if (Test-CompactProc -Proc $p -ProcMap $map) { continue }   # наш же headless-компакт, не панель агента
        $mR = [regex]::Match($p.CommandLine, '--resume\s+(\S+)')
        $mN = [regex]::Match($p.CommandLine, '--name\s+(\S+)')
        $tok = if ($mR.Success) { $mR.Groups[1].Value } elseif ($mN.Success) { $mN.Groups[1].Value } else { $null }
        if (-not $tok) { continue }
        $isUuid = $tok -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-'
        $title  = if ($isUuid) { Get-CustomTitleByUuid $tok } else { $tok }
        $root   = Resolve-RootFromAncestry -ClaudePid ([int]$p.ProcessId) -ProcMap $map
        $out += [pscustomobject]@{ Pid = [int]$p.ProcessId; Token = $tok; SessionId = $(if ($isUuid) { $tok } else { '' }); Title = $title; Root = $root }
    }
    $script:LiveSessionsCache = $out
    return $out
}

<#
    Резолв живого PID + UUID сессии по её SessionTitle — ОТ живых процессов.
    Возвращает @{ Pid; SessionId } или $null.
#>
function Resolve-LiveByTitle {
    # -PoolRoot задан -> берём только сессию, чьё происхождение (корень из ancestry) ПОД этим путём.
    # Зовущий передаёт PoolCwd (launch-cwd пула), а НЕ каталог батников: ancestry первым отдаёт корень
    # из `scripts\pool-launch.ps1`, т.е. РОДИТЕЛЯ каталога батников, и сверка с `root` промахивалась
    # у всех пулов монорепо (дефект 2026-07-27, молчаливое «не запущена» при живой сессии).
    # Не задан -> прежнее поведение (первый по титулу) для обратной совместимости.
    param([string]$Title, [string]$PoolRoot)
    if (-not $Title) { return $null }
    $hit = @(Get-LiveSessions | Where-Object { $_.Title -eq $Title -and (-not $PoolRoot -or (Test-CwdUnderRoot $_.Root $PoolRoot)) })
    if ($hit.Count) { return [pscustomobject]@{ Pid = $hit[0].Pid; SessionId = $hit[0].SessionId } }
    # ⚠️ Фолбэк для сессий, чьё ПРОИСХОЖДЕНИЕ не определяется: ancestry узнаёт только
    # `claude-<owner>.bat` и `scripts\pool-launch.ps1`, а обёртка Launcher'а лежит ВНЕ каталога пула
    # (<workspace-root>\launcher.bat) — Root пуст, скоуп отбрасывал ЖИВУЮ сессию, и гашение пула молча
    # обходило роль, печатая «процесс не найден». Ровно это и наблюдал владелец: компаньон погашен,
    # роль-инициатор цела (её обёртка лежит внутри пула, поэтому у неё ancestry срабатывал).
    # Условие узкое: по титулу найдена РОВНО ОДНА живая сессия И происхождение у неё не определилось.
    # Две сессии с одним титулом или определившийся чужой корень -> прежний отказ: риск погасить
    # чужую сессию (дефект 18.07) важнее удобства.
    if ($PoolRoot) {
        $byTitle = @(Get-LiveSessions | Where-Object { $_.Title -eq $Title })
        if ($byTitle.Count -eq 1 -and -not $byTitle[0].Root) {
            Write-Log ("resolve-by-title fallback: title={0} pid={1} (ancestry root пуст, кандидат один)" -f $Title, $byTitle[0].Pid)
            return [pscustomobject]@{ Pid = $byTitle[0].Pid; SessionId = $byTitle[0].SessionId }
        }
    }
    return $null
}

<#
    ЕДИНЫЙ резолв PID цели. КРИТИЧНО: НЕ полагаться на session_id метрики — из-за долгих
    resume активный uuid в метрике != uuid в CommandLine (баг 2026-07-17: chronicler жив, но
    Get-SessionPid по sid метрики его не нашёл -> ложное «не запущена» + ложный «ok kill»).
    Порядок: KnownPid (фолбэк-цели) -> по TITLE через живые процессы -> Get-SessionPid (крайний).
#>
function Resolve-TargetPid {
    param($T)
    if (($T.PSObject.Properties.Name -contains 'KnownPid') -and $T.KnownPid) { return [int]$T.KnownPid }
    # Скоуп по launch-cwd пула: одинаковый SessionTitle двух ЖИВЫХ пулов иначе дал бы чужой PID ->
    # taskkill не того (баг 2026-07-18). Читаем ПРЯМО, без guard-фолбэка на $T.Cwd: цель обязана
    # нести PoolCwd, а фолбэк подсунул бы ДРЕЙФУЮЩИЙ cwd агента (planner <pool-a>: .bus\planner\new)
    # и промахнулся бы МОЛЧА. Отсутствие свойства должно падать под StrictMode, а не деградировать.
    $poolCwd = $T.PoolCwd
    if ($T.Name) { $r = Resolve-LiveByTitle -Title $T.Name -PoolRoot $poolCwd; if ($r) { return [int]$r.Pid } }
    return (Get-SessionPid -SessionId $T.SessionId -Title $T.Name -PoolRoot $poolCwd)
}

<#
    PID живой сессии. Ищем claude.exe, у которого в CommandLine есть session_id
    (пулы: pool-launch.ps1 резолвит title -> UUID и делает --resume <UUID>)
    либо SessionTitle (роли вроде Launcher, чей wrapper делает --resume <Title>).
#>
function Get-SessionPid {
    param([string]$SessionId, [string]$Title, [string]$PoolRoot)
    # Полная карта процессов нужна и для компакт-guard (проверка предка), и для скоупа по ancestry.
    $map = @{}
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $map[[int]$p.ProcessId] = $p }
    foreach ($p in $map.Values) {
        if ($p.Name -ne 'claude.exe' -or -not $p.CommandLine) { continue }
        if (-not $SessionId -or $p.CommandLine -notlike "*$SessionId*") { continue }
        # Матч по uuid БЕЗ этих двух проверок был дырой. Прежний комментарий «uuid глобально уникален —
        # pool-safe» ложен дважды: (а) дубль с тем же uuid порождает сам контроллер (headless-компакт),
        # (б) uuid приходит из МЕТРИКИ, а метрика ключуется по owner-имени, которое между пулами
        # повторяется — чужая запись дала бы чужой PID мимо любого пул-скоупа.
        if (Test-CompactProc -Proc $p -ProcMap $map) { continue }
        if ($PoolRoot) {
            $r = Resolve-RootFromAncestry -ClaudePid ([int]$p.ProcessId) -ProcMap $map
            if (-not (Test-CwdUnderRoot $r $PoolRoot)) { continue }
        }
        return [int]$p.ProcessId
    }
    if ($Title) {
        # Фолбэк по титулу СКОУПЛЕН по пулу (через Resolve-LiveByTitle) — иначе чужой пул с тем же титулом.
        $r = Resolve-LiveByTitle -Title $Title -PoolRoot $PoolRoot
        if ($r) { return [int]$r.Pid }
    }
    return $null
}

<#
    PID cmd-ЛАУНЧЕРА окна для сессии: вверх от claude до ближайшего cmd.exe, крутящего .bat
    (обычно claude-<role>.bat). taskkill /F /T по нему валит cmd->powershell->claude+дети И закрывает
    окно (Warp/терминал), т.к. .bat не доходит до `pause`. Возвращает pid cmd или $null (тогда фолбэк
    на дерево claude напрямую). WINDOWS/терминал-специфично; серверный порт (Linux) — киллить группу
    процессов / session-leader / systemd-юнит; КОНЦЕПТ «бить от лаунчера, не от агента» — тот же.
#>
function Get-LauncherCmdPid {
    param([int]$ClaudePid)
    $procs = @{}
    foreach ($p in (Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) { $procs[[int]$p.ProcessId] = $p }
    $node = $procs[[int]$ClaudePid]
    if (-not $node) { return $null }
    $cur = [int]$node.ParentProcessId; $guard = 0
    while ($cur -and $guard -lt 20) {
        $guard++
        $p = $procs[$cur]
        if (-not $p) { break }
        if ($p.Name -eq 'cmd.exe' -and $p.CommandLine -and ($p.CommandLine -match '\.bat')) { return [int]$p.ProcessId }
        if ($p.Name -eq 'claude.exe') { break }   # дошли до другой сессии -> выше не лезем
        $cur = [int]$p.ParentProcessId
    }
    return $null
}

<#
    Гашение сессии. ТОЛЬКО taskkill /F /T — убивает дерево целиком [E5].
    Stop-Process здесь запрещён: оставляет сирот [E4].
#>
function Stop-SessionTree {
    param([int]$TargetPid)
    # taskkill /T, не сумевший убить какого-то потомка, пишет в stderr. Под глобальным EAP=Stop
    # конструкция `& taskkill 2>&1` превратила бы эту строку в ТЕРМИНАЛЬНУЮ ошибку (NativeCommandError)
    # -> крах контроллера ПОСРЕДИ kill-цикла (инцидент <pool-c> 2026-07-20, qa: не убился потомок 65356).
    # Локально EAP=Continue: частичный неуспех taskkill больше не роняет скрипт; истинный вердикт
    # «убита ли сессия» берётся ниже независимо через Get-Process. Присвоение функ-локально (динамический
    # скоуп PowerShell) — глобальный EAP=Stop у вызывающих (kill-цикл) НЕ меняется.
    $ErrorActionPreference = 'Continue'
    $out = & taskkill.exe '/F' '/T' '/PID' $TargetPid 2>&1
    $killed = @($out | Select-String -Pattern 'SUCCESS' -SimpleMatch).Count
    Start-Sleep -Seconds 3
    $alive = [bool](Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Killed = $killed; StillAlive = $alive; Raw = ($out -join ' ') }
}

# ---------------------------------------------------------------- headless compact

<#
    Результат компакта — ЕДИНЫЙ контракт на все выходы функции, включая отказы.
    Заведён ради -Recharge: он читает Uuid/Transcript/Landed, а под Set-StrictMode обращение к
    отсутствующему полю кидает — «отказной» результат без этих полей ронял бы перезарядку в момент,
    когда роль уже погашена. Пустые значения безопаснее отсутствующих.
#>
function New-CompactResult {
    param([bool]$Ok, [string]$Msg, [string]$Uuid = '', [string]$Transcript = '', [bool]$Landed = $false)
    return [pscustomobject]@{ Ok = $Ok; Msg = $Msg; Uuid = $Uuid; Transcript = $Transcript; Landed = $Landed }
}

<#
    Headless compact над ОСТАНОВЛЕННОЙ сессией [E1].
    Критично: из PowerShell (Git Bash ломает "/compact" в путь) и cwd = каталог проекта.

    -Wait: ДОЖДАТЬСЯ завершения компакта и проверить, что он сел (compact_boundary в транскрипте).
    Нужен перезарядке и только ей: при гашении детач правильный (компакт переживает закрытие
    терминала), а при перезарядке подъём роли поверх ещё пишущего компакта дал бы ДВА процесса на
    один транскрипт — так уже был получен слитый транскрипт 03.08.
#>
function Invoke-HeadlessCompact {
    param([string]$SessionTitle, [string]$Cwd, [string]$Owner, [switch]$Wait, [int]$WaitSec = 300)
    if (-not (Test-Path $Cwd)) { return New-CompactResult -Ok $false -Msg "cwd не существует: $Cwd" }
    $claudeExe = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (-not (Test-Path $claudeExe)) { $g = Get-Command claude -ErrorAction SilentlyContinue; if ($g) { $claudeExe = $g.Source } }
    if (-not $claudeExe -or -not (Test-Path $claudeExe)) { return New-CompactResult -Ok $false -Msg 'claude.exe не найден' }
    # Резолв ИМЕНИ -> НОВЕЙШАЯ сессия (=активная), как враппер. headless `--resume <name>` при неоднозначности
    # падает (нет пикера), поэтому резолвим uuid сами. НЕ по метрике (дрейфует), НЕ по launch-uuid.
    # 🛑 ProjectKey из cwd: заменяется ЛЮБОЙ не-алфанумерик, а не перечисленные символы. Прежняя формула
    # `($Cwd -replace '[:\\]','-') -replace '_','-'` не трогала ТОЧКУ, и для пула в скрытом каталоге
    # давала несуществующий путь: <workspace-root>\.launcher -> «D---workspace-.launcher», тогда как на
    # диске «<workspace-key>». Итог — compact молча пропускался с «project-каталог не найден»
    # у КАЖДОЙ роли, чей рабочий каталог содержит точку (у нас это весь пул <organizer-pool>; поймано на
    # боевом гашении 06.08). Движок выводит ключ именно так — заменой всего не-алфанумерика.
    $pk = $Cwd -replace '[^a-zA-Z0-9]', '-'
    $projectDir = Join-Path $env:USERPROFILE ".claude\projects\$pk"
    if (-not (Test-Path $projectDir)) { return New-CompactResult -Ok $false -Msg "project-каталог не найден: $projectDir" }
    $uuid = Find-SessionIdByTitle -Title $SessionTitle -Dir $projectDir
    if (-not $uuid) { return New-CompactResult -Ok $false -Msg "сессия '$SessionTitle' не найдена в $pk" }
    $transcript = Join-Path $projectDir ("{0}.jsonl" -f $uuid)
    # ДЕТАЧ через WMI: compact переживает закрытие терминала (родитель WmiPrvSE, вне job окна) — можно
    # закрыть Warp после фазы kill. .bat + stdin из NUL (иначе headless claude виснет на stdin — баг
    # канарейки 2026-07-18). Fire-and-forget: не ждём завершения.
    $stamp = ($SessionTitle -replace '[^0-9a-zA-Z]', '')
    $batPath = Join-Path $env:TEMP "poolcompact-$stamp.bat"
    $outPath = Join-Path $env:TEMP "poolcompact-$stamp.out"
    # Информативное окно (2b): заголовок + баннер, чтобы задетаченный compact не выглядел «пустым терминалом».
    # Баннер ASCII (файл пишется в ASCII; кириллица в cmd echo хрупкая). Вывод claude уходит в файл.
    $bannerTitle = "[pool-compact] $SessionTitle"
    # Role-private memory: WMI-spawned processes inherit no environment, so the settings file must be
    # named on the command line. Same module (and same roll-out switch) as the pool launchers.
    $memFlag = ''
    if ($Owner) {
        try {
            $mod = 'C:\workspace-root\.launcher\pool-bus\agent-memory.ps1'
            if (Test-Path $mod) {
                . $mod
                $ma = Get-AgentMemoryArgs -Owner $Owner -Cwd $Cwd -Quiet
                if ($ma.Count -eq 2 -and (Test-Path $ma[1])) { $memFlag = ' --settings "' + $ma[1] + '"' }
            }
        } catch { $memFlag = '' }   # compact on default memory beats no compact at all
    }
    $batLines = @(
        '@echo off',
        "title $bannerTitle",
        'echo ================================================================',
        "echo    POOL CONTEXT COMPACTION    session: $SessionTitle",
        'echo ----------------------------------------------------------------',
        'echo    Compacting this session context (/compact) so its next launch',
        'echo    resumes lean. Takes ~1-2 min, then this window CLOSES ITSELF.',
        'echo    Safe to ignore  -  do NOT close it manually.',
        'echo ================================================================',
        'echo.',
        "cd /d `"$Cwd`"",
        "`"$claudeExe`" --resume $uuid --dangerously-skip-permissions$memFlag -p `"/compact`" < NUL > `"$outPath`" 2>&1"
    )
    $batContent = ($batLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($batPath, $batContent, [System.Text.Encoding]::ASCII)
    try {
        $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c `"$batPath`"" }
        if ($res.ReturnValue -ne 0) { return New-CompactResult -Ok $false -Msg "WMI Create rc=$($res.ReturnValue)" -Uuid $uuid -Transcript $transcript }
        $short = $uuid.Substring(0, 8)
        if (-not $Wait) { return New-CompactResult -Ok $true -Msg "detached pid=$($res.ProcessId) resume=$short" -Uuid $uuid -Transcript $transcript }
        # Ждём ИМЕННО процесс cmd-обёртки: он живёт ровно столько, сколько идёт компакт, и умирает сам.
        # Опрос, а не Wait-Process: процесс запущен через WMI и нам не «свой», Wait-Process на чужом
        # даёт отказ прав на части машин — а нам достаточно факта исчезновения.
        $cmdPid = [int]$res.ProcessId
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-Process -Id $cmdPid -ErrorAction SilentlyContinue)) { break }
            Start-Sleep -Seconds 2
        }
        $stillRunning = [bool](Get-Process -Id $cmdPid -ErrorAction SilentlyContinue)
        # Транскрипт — вердикт, а не код возврата: компакт мог упасть внутри, отдав 0.
        $landed = Test-CompactLanded -TranscriptPath $transcript
        if ($stillRunning) { return New-CompactResult -Ok $false -Msg "компакт НЕ завершился за ${WaitSec}с (pid=$cmdPid ещё жив) — поднимать поверх него нельзя" -Uuid $uuid -Transcript $transcript -Landed $landed }
        if (-not $landed) { return New-CompactResult -Ok $false -Msg "компакт завершился, но в транскрипте НЕТ compact_boundary (resume=$short)" -Uuid $uuid -Transcript $transcript }
        return New-CompactResult -Ok $true -Msg "компакт СЕЛ (resume=$short)" -Uuid $uuid -Transcript $transcript -Landed $true
    } catch {
        return New-CompactResult -Ok $false -Msg $_.Exception.Message -Uuid $uuid -Transcript $transcript
    }
}

<#
    Подъём роли её ОБЁРТКОЙ, через WMI.

    Два «почему», оба куплены чужой болью:
      * ОБЁРТКОЙ, а не голым `claude --resume`: она несёт AGENT_OWNER, POOL_BUS_ROOT, модель, усилие
        и файл стартового промпта — а тот первым пунктом велит взвести вотчер входящих. Голый движок
        поднял бы сессию ВНЕ пула: без ящика, на старой модели, без сторожа.
      * через WMI, а не Start-Process: процесс, запущенный из Claude-сессии, попадает в её группу и
        умирает вместе с ней (так умирал мост). Родитель обязан быть WmiPrvSE — тогда поднятая роль
        переживает и контроллер, и окно, из которого его звали.
#>
function Start-RoleWrapper {
    param([string]$BatPath)
    if (-not $BatPath -or -not (Test-Path $BatPath)) { return [pscustomobject]@{ Ok = $false; Msg = "обёртка не найдена: $BatPath"; ProcessId = 0 } }
    try {
        $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c `"$BatPath`"" }
        if ($res.ReturnValue -eq 0) { return [pscustomobject]@{ Ok = $true; Msg = "поднято через WMI, pid=$($res.ProcessId)"; ProcessId = [int]$res.ProcessId } }
        return [pscustomobject]@{ Ok = $false; Msg = "WMI Create rc=$($res.ReturnValue)"; ProcessId = 0 }
    } catch {
        return [pscustomobject]@{ Ok = $false; Msg = $_.Exception.Message; ProcessId = 0 }
    }
}

<#
    Ждать, пока роль с этим титулом появится среди ЖИВЫХ сессий (её claude.exe). Возвращает pid или 0.
    ⚠️ Кэш живых сессий снимаем на каждом обороте: он заполнялся ДО убийства и без сброса показывал бы
    мертвеца как живого — то есть «поднялась» рапортовалось бы мгновенно и всегда.
#>
function Wait-RoleAlive {
    param([string]$Title, [string]$PoolRoot, [int]$TimeoutSec = 180)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $script:LiveSessionsCache = $null
        $r = Resolve-LiveByTitle -Title $Title -PoolRoot $PoolRoot
        if ($r -and $r.Pid) { return [int]$r.Pid }
        Start-Sleep -Seconds 3
    }
    $script:LiveSessionsCache = $null
    return 0
}

<#
    Живые сессии с этим титулом ДО подъёма — их быть не должно.
    Свой headless-компакт из выдачи уже отсеян (Test-CompactProc внутри Get-LiveSessions): без этого
    проверка либо ждала бы вечно собственный компакт, либо считала его выжившей панелью.
#>
function Get-SurvivingSessionPids {
    param([string]$Title, [string]$PoolRoot)
    $script:LiveSessionsCache = $null
    return @(Get-LiveSessions | Where-Object { $_.Title -eq $Title -and (-not $PoolRoot -or (Test-CwdUnderRoot $_.Root $PoolRoot) -or -not $_.Root) } | ForEach-Object { [int]$_.Pid })
}

<# Проверка: реально ли компакт записался (в транскрипте появился compact_boundary). #>
function Test-CompactLanded {
    param([string]$TranscriptPath)
    if (-not $TranscriptPath -or -not (Test-Path $TranscriptPath)) { return $false }
    try {
        $tail = Get-Content $TranscriptPath -Tail 40 -ErrorAction Stop
        return [bool](@($tail | Select-String -Pattern 'compact_boundary' -SimpleMatch).Count)
    } catch { return $false }
}

# ---------------------------------------------------------------- шина: задача агенту

<#
    Каталог шины цели. ПУТЬ БОЛЬШЕ НЕ ВЫВОДИТСЯ ЗДЕСЬ — он приходит из манифеста (`Resolve-PoolBus`)
    и лежит в цели как `BusDir`. Функция осталась ровно проверкой существования.

    Почему нельзя вернуться к прежнему `<PoolRoot>\.bus`: у пулов, выросших в монорепо, шина лежит
    в каталоге ПОДПРОЕКТА, а не рядом с батниками. Хуже того, `<workspace-root>\<monorepo>\.bus`
    РЕАЛЬНО СУЩЕСТВУЕТ — это осиротевшая общая шина, мёртвая с 25.06 после разделения на 3 пула.
    Любой «упрощающий» фолбэк на `<cwd>\.bus` увёл бы handoff-задачи трёх пулов в мёртвую шину
    «успешно»: агенты их не увидят, флагов не будет, роли не погасятся.
#>
function Get-BusRoot {
    param([string]$BusDir)
    if ($BusDir -and (Test-Path $BusDir)) { return $BusDir }
    return $null
}

<#
    Состояние шины пула — ОДИН РАЗ на прогон, вслух.

    Промах шины не приводит к «убийству без handoff» (в -Full ветка «гашу без него» недостижима:
    $KillOnly=$true -> $needHandoff=$false, а гейт свежести без шины даёт skip). Он приводит к
    ОБРАТНОМУ и не менее вредному: молчаливому массовому skip — пул остаётся жив, а итоговая
    таблица выглядит штатно. Поэтому расхождение обязано быть громким ЗДЕСЬ, до первой цели.
#>
function Write-BusHealth {
    param($Dirs, $Manifest, [string]$Slug)
    if (-not $Dirs.BusDir) {
        Write-Warn "пул '$Slug': шина не выводится из манифеста (нет ни 'bus', ни 'root') — handoff через шину невозможен"
        return
    }
    if (Test-Path $Dirs.BusDir) { return }
    # Пул БЕЗ шины — законный случай (одиночная роль, координировать не с кем): поле `bus` не
    # объявлено, путь лишь ВЫВЕДЕН как <root>\.bus. Кричать тут — ложная тревога (<solo-project>).
    # А вот объявленная и не существующая шина — настоящая поломка: handoff-задачи не уйдут.
    $declared = ($Manifest.PSObject.Properties.Name -contains 'bus') -and $Manifest.bus
    if ($declared) {
        Write-Err "пул '$Slug': манифест ОБЪЯВЛЯЕТ шину '$($Dirs.BusDir)', а каталога НЕТ. Handoff-задачи уйти не смогут, роли будут пропущены. Сверь поле 'bus' в pool.manifest.json с `set POOL_BUS_ROOT=` в wrapper'ах (аудит: launch-pool.ps1 -SelfTest)."
    } else {
        Write-Step "пул '$Slug': шины нет (координации между ролями не заведено) — handoff пойдёт мимо шины"
    }
}

<#
    ПЕРЕИСПОЛЬЗУЕМЫЙ ПРИМИТИВ: канонический текст слэш-команды из её файла.
    Читает `<ProjectRoot>\.claude\commands\<Name>.md` (project-local, приоритет) либо
    `~\.claude\commands\<Name>.md` (глобальный). Так контроллер впрыскивает ПОЛНЫЙ актуальный
    текст команды в задачу — как делает ввод /<name> пользователем — без копии в скрипте и
    для ЛЮБОЙ команды (положил файл -> можно прокинуть). Возвращает текст или $null.
#>
function Get-CommandText {
    param([string]$Name, [string]$ProjectRoot)
    $paths = @()
    if ($ProjectRoot) { $paths += (Join-Path $ProjectRoot ".claude\commands\$Name.md") }
    $paths += (Join-Path $env:USERPROFILE ".claude\commands\$Name.md")
    foreach ($p in $paths) {
        if (Test-Path $p) {
            try { return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) } catch { }
        }
    }
    return $null
}

<#
    Отправляем агенту задачу «заверши работу» через общий pool.ps1.
    Половины сообщения (payload + объект с owner) — забота pool.ps1 send.
#>
function Send-ShutdownTask {
    param([string]$BusRoot, [string]$TargetOwner, [string]$FlagPath, [string]$ProjectRoot, [string]$CommandName = 'handoff-myself')
    $poolPs1 = Join-Path $PSScriptRoot 'pool.ps1'
    if (-not (Test-Path $poolPs1)) { return [pscustomobject]@{ Ok = $false; Msg = 'pool.ps1 не найден' } }
    $flagFwd = $FlagPath -replace '\\', '/'

    # Впрыскиваем ПОЛНЫЙ канонический текст команды (не по памяти агента, не копией в скрипте).
    $cmdText = Get-CommandText -Name $CommandName -ProjectRoot $ProjectRoot
    if ($cmdText) {
        $instrBlock = @"
Выполни инструкцию команды /$CommandName ДОСЛОВНО по её полному каноническому тексту ниже —
НЕ по памяти (контроллер впрыснул его из файла команды, чтобы задача не «замылилась»):

--- НАЧАЛО /$CommandName ---
$cmdText
--- КОНЕЦ /$CommandName ---
"@
    } else {
        # Файла команды нет -> хотя бы форсим свежую загрузку скила, а не «по памяти».
        $instrBlock = @"
ОБЯЗАТЕЛЬНО сперва вызови инструмент Skill со skill='$CommandName' (загрузи СВЕЖИЕ инструкции,
НЕ по памяти), затем выполни строго по ним.
"@
    }

    $body = @"
ЗАВЕРШЕНИЕ РАБОТЫ (команда внешнего контроллера). Твоя сессия будет остановлена — позже, отдельной
командой. Приведи в порядок свою долговременную память: по ней будущий ты возобновит работу с этого
места, больше ему опереться не на что.

$instrBlock

Дополнительно к инструкции команды:
- Недавние директивы/вводные владельца сохрани в свою память ДОСЛОВНО (не только пересказом) — они
  критичны и легко теряются при сжатии.
- Верни в шину claimed-задачи, которые не доделал (подхватят после перезапуска).
- Отметь готовность ОДНОЙ командой — она сама знает, куда класть флаг:

     & "$poolPs1" ready

  Файл-флаг РУКАМИ НЕ СОЗДАВАЙ. Если по памяти прошлых гашений помнишь путь вида
  ~/.claude/.control/shutdown-ready-<owner> — он УСТАРЕЛ (маркеры переехали в шину пула
  2026-07-27), и флаг по нему контроллер не увидит: роль зависнет в «ТАЙМАУТ».
  Для справки, команда создаст: $flagFwd

После флага не начинай новых дел — сессия будет закрыта.
"@
    try {
        $out = & $poolPs1 send -BusRoot $BusRoot -To $TargetOwner -From 'pool-controller' -Subject 'Завершение работы: запись в память + флаг готовности' -Body $body 2>&1
        $outStr = ($out | Out-String).Trim()
        # успех: pool.ps1 send возвращает id вида 1784302131142-f6209d942a
        if ($outStr -match '\d{10,}-[0-9a-fA-F]+') { return [pscustomobject]@{ Ok = $true; Msg = $outStr } }
        return [pscustomobject]@{ Ok = $false; Msg = $outStr }
    } catch {
        return [pscustomobject]@{ Ok = $false; Msg = $_.Exception.Message }
    }
}

<#
    Вычищает ОСИРОТЕВШИЕ shutdown-сообщения контроллера из new/<owner>: те, что
    контроллер отправил, но агент не успел заклеймить (убит до claim). Иначе они
    остаются «звонить» в new/ и перевыстреливают в СЛЕДУЮЩИЙ запуск пула (свежий
    агент читает «заверши работу» и гасится). dismiss = new/ -> archive (санкцион.
    ход шины, форензик-след сохраняется). Трогает ТОЛЬКО from-pool-controller.
    NB: покрывает лишь смерть ОТ контроллера. Ручной килл/краш/уже-мёртвая-на-старте
    цель оставят landmine — остаточный класс, добивается startup-подметанием (см. handoff).
    Возвращает число реально вычищенных.
#>
function Clear-ShutdownLandmines {
    param([string]$BusRoot, [string]$Owner)
    if (-not $BusRoot -or -not $Owner) { return 0 }
    $newDir = Join-Path (Join-Path $BusRoot $Owner) 'new'
    if (-not (Test-Path $newDir -ErrorAction SilentlyContinue)) { return 0 }
    $poolPs1 = Join-Path $PSScriptRoot 'pool.ps1'
    if (-not (Test-Path $poolPs1 -ErrorAction SilentlyContinue)) { return 0 }
    $stale = @(Get-ChildItem -Path $newDir -Filter '*.from-pool-controller.*.md' -File -ErrorAction SilentlyContinue)
    $n = 0
    foreach ($f in $stale) {
        $id = ($f.Name -replace '\.from-pool-controller\..*$', '')
        try {
            & $poolPs1 dismiss -Owner $Owner -Id $id -BusRoot $BusRoot 2>&1 | Out-Null
            if (-not (Test-Path $f.FullName -ErrorAction SilentlyContinue)) {   # реально ушло из new/
                $n++
                Write-Log ("purged stale shutdown msg: owner={0} id={1}" -f $Owner, $id)
            }
        } catch { Write-Log ("purge FAILED owner={0} id={1}: {2}" -f $Owner, $id, $_.Exception.Message) }
    }
    if ($n) { Write-Step "вычищено осиротевших shutdown-сообщений из new/ ($Owner): $n" }
    return $n
}

<#
    Закрыть осиротевшее окно(а) Warp пула по ТОЧНОМУ заголовку == слаг.
    Warp на Windows = ОДИН процесс warp.exe на ВСЕ окна (пулы + DevOps + Launcher) -> процесс
    НЕ киллим (снесёт всё); шлём WM_CLOSE адресно по HWND окна с нужным заголовком.
    Best-effort: НЕ бросает. Возвращает число окон, реально исчезнувших после WM_CLOSE.
    Проверено throwaway-тестом: WM_CLOSE по HWND закрывает только целевое окно, остальные целы.
#>
function Close-PoolWarpWindow {
    param([Parameter(Mandatory)][string]$Slug)
    if (-not $Slug) { return 0 }
    if (-not ('PoolShutdownWin.U' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace PoolShutdownWin {
  public static class U {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    public static List<string> Windows() {
      var list = new List<string>();
      EnumWindows((h, p) => {
        if (!IsWindowVisible(h)) return true;
        int len = GetWindowTextLength(h);
        if (len == 0) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        var sb = new StringBuilder(len + 2);
        GetWindowText(h, sb, sb.Capacity);
        list.Add(h.ToInt64() + "\t" + pid + "\t" + sb.ToString());
        return true;
      }, IntPtr.Zero);
      return list;
    }
    public static bool Close(long hwnd) { return PostMessage(new IntPtr(hwnd), 0x0010, IntPtr.Zero, IntPtr.Zero); }
    public static bool Alive(long hwnd) { return IsWindow(new IntPtr(hwnd)); }
  }
}
'@
    }
    $warpPids = @(Get-Process -Name 'warp' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    if (-not $warpPids) { return 0 }
    $hits = @()
    foreach ($row in [PoolShutdownWin.U]::Windows()) {
        $p = $row -split "`t", 3
        if ($p.Count -lt 3) { continue }
        $hwnd = [int64]$p[0]; $wpid = [int]$p[1]; $title = $p[2]
        if (($warpPids -contains $wpid) -and ($title -eq $Slug)) { $hits += $hwnd }
    }
    if (-not $hits.Count) { return 0 }
    foreach ($h in $hits) {
        Write-Log ("WM_CLOSE окну Warp пула: hwnd=0x{0:X} title='{1}'" -f $h, $Slug)
        [void][PoolShutdownWin.U]::Close($h)
    }
    $stillOpen = $hits
    $deadline = (Get-Date).AddSeconds(4)
    do {
        Start-Sleep -Milliseconds 300
        $stillOpen = @($hits | Where-Object { [PoolShutdownWin.U]::Alive($_) })
    } while ($stillOpen.Count -and ((Get-Date) -lt $deadline))
    if ($stillOpen.Count) {
        Write-Log ("окно(а) НЕ закрылись WM_CLOSE (промпт Warp?): {0}" -f (($stillOpen | ForEach-Object { '0x{0:X}' -f $_ }) -join ','))
    }
    return ($hits.Count - $stillOpen.Count)
}

<#
    Регресс E5 (2026-07-20): демон CC хостит фоновые worker'ы ВНЕ дерева cmd-лаунчера -> `taskkill /T`
    сессию НЕ убивает, она ВЫЖИВАЕТ фоновым агентом (kind=background), лочит uuid -> resume-compact
    падает, сессия остаётся некомпактнутой и блокирует перезапуск пула. Проверяем через `claude agents
    --json`, не выжила ли ЭТА сессия. Матч: ТОЛЬКО `kind=background` (у interactive нет short-id, а
    `claude stop` требует id), первично по `sessionId` (uuid — то, что лочится; надёжнее имени: реестр
    демона отдаёт АВТО-имя для части пулов), fallback по Name+cwd под корнем пула (title-роли без uuid).
    Выжившую гасим `claude stop <shortid>` — разговор СОХРАНЯЕТСЯ, лок снят (последующий E1-compact
    отработает). НЕ `rm` (иначе удалим транскрипт и сломаем compact). Проверено вживую: id короткий,
    `claude stop` гасит + убирает из реестра. Best-effort: НЕ бросает. Возвращает число погашенных.
#>
function Stop-SurvivorSession {
    param([string]$Name, [string]$PoolRoot, [string]$SessionId)
    if (-not $Name -and -not $SessionId) { return 0 }
    $ErrorActionPreference = 'Continue'   # `& claude` пишет служебное в stderr; под EAP=Stop это терминальная ошибка (как taskkill)
    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) { return 0 }
    $json = $null
    try { $json = @($null | & claude agents --json 2>$null | ConvertFrom-Json) } catch { return 0 }   # $null| — stdin-guard от зависания
    if (-not $json -or -not $json.Count) { return 0 }
    $surv = @($json | Where-Object {
        (Get-JProp $_ 'kind') -eq 'background' -and (
            ($SessionId -and (Get-JProp $_ 'sessionId') -eq $SessionId) -or
            ($Name -and (Get-JProp $_ 'name') -eq $Name -and (Get-JProp $_ 'cwd') -and (Test-CwdUnderRoot (Get-JProp $_ 'cwd') $PoolRoot))
        )
    })
    if (-not $surv.Count) { return 0 }
    $n = 0
    foreach ($s in $surv) {
        $sid = Get-JProp $s 'id'
        if (-not $sid) { continue }
        Write-Warn ("сессия '{0}' ВЫЖИЛА фоновым агентом (id={1}) — гашу claude stop" -f $Name, $sid)
        Write-Log ("survivor stop: name={0} id={1} sid={2}" -f $Name, $sid, (Get-JProp $s 'sessionId'))
        try { & claude stop $sid 2>$null | Out-Null; $n++ }
        catch { Write-Warn ("claude stop {0} не удался: {1}" -f $sid, $_.Exception.Message) }
    }
    return $n
}

<#
    ПУНКТ 2 — свежесть флага готовности. Валиден ТОЛЬКО если ready-флаг новее intent-метки,
    которую пишет Фаза 1 перед отправкой. Ловит: (а) флаг из прошлого цикла/после рестарта
    (нет свежего intent или ready старше него); (б) агент поработал после handoff (item 1 —
    хук UserPromptSubmit — уже стёр ready -> сюда придём с «нет ready-флага»).

    ИНВАРИАНТЫ (не отменять молча — только осознанным решением):
      1. Устаревшее подтверждение НЕ авторизует kill. Отсюда сверка с intent-меткой Фазы 1.
      2. Агент, поработавший ПОСЛЕ handoff, не гасится без -Force. Держится на том, что хук
         `pool.ps1` (UserPromptSubmit) стирает ready на любом новом ходе.
      3. Ложное «не подтвердил» НЕ должно возникать из-за системной побудки. Ready этого НЕ
         обеспечивает: завершение фоновой задачи (одноразовый вотчер сработал и вышел; вытесненный
         chat_sentinel упал) харнесс доставляет как НОВЫЙ prompt, и хук стирает свежий флаг.
         Поэтому в СКВОЗНОМ прогоне (-Full) эта функция вообще не зовётся: подтверждение защёлкнуто
         в памяти в момент наблюдения (см. $confirmed). Здесь остаётся только отложенный сценарий
         (-HandoffOnly ... позже -KillOnly), где инвариант 3 НЕ выполняется — известный хвост,
         описан в standards/pool/08-shutdown-context-hygiene.md. Пропуск роли безопаснее её убийства,
         поэтому исход сознательно оставлен «пропустить, нужен -Force».
#>
<#
    Пути маркеров завершения. Лежат В ШИНЕ ПУЛА, а не в общем ~\.claude\.control (перенос 2026-07-27):
    имена ролей повторяются между пулами (lead/operator/builder — в двух, tech-lead/qa — в трёх), а
    каталог .control один на всех. Хук `pool.ps1` (Invoke-Activity), стирающий ready на ходе человека,
    знает ТОЛЬКО owner и BusRoot — слага пула у него нет. Поэтому «слаг в имени файла» не годится:
    хук перестал бы находить файл, и инвариант «ход человека инвалидирует handoff» умер бы молча.
    Шина же адресуется хуком точно, и пул-скоуп получается по построению.
#>
function Get-ShutdownPaths {
    param([string]$BusRoot, [string]$Owner)
    if (-not $BusRoot -or -not $Owner) { return $null }
    $d = Join-Path $BusRoot '.control'
    try { [void][System.IO.Directory]::CreateDirectory($d) } catch { return $null }
    return [pscustomobject]@{
        Ready  = Join-Path $d ("shutdown-ready-{0}"  -f $Owner)
        Intent = Join-Path $d ("shutdown-intent-{0}" -f $Owner)
    }
}

<#
    Агент подтвердился в СТАРОМ месте? (инцидент 2026-07-27, лид <pool-a>)

    До 2026-07-27 ready-флаг лежал в общем `~\.claude\.control\`. Агент, который не открыл тело задачи
    и действовал по памяти прошлых гашений, пишет флаг туда — контроллер его не видит и печатает немой
    «ТАЙМАУТ», а причина находится только раскопками в транскрипте. Эта функция превращает немой таймаут
    в внятный диагноз.

    ИНВАРИАНТЫ:
      * Это ТОЛЬКО диагностика. Засчитывать legacy-флаг за готовность НЕЛЬЗЯ: общий каталог не разделён
        по пулам, а имена ролей повторяются (`lead` есть и в <pool-a>, и в <pool-name>) —
        чужой флаг стал бы разрешением убить сессию без handoff'а. Гейт не ослабляем.
      * Свежесть проверяем по intent-метке, а НЕ по «файл вообще есть»: протухший файл от прошлых
        гашений (напр. lead от 27.07 17:10) обязан молчать, иначе диагноз станет ложным навсегда.
      * В общий каталог НИЧЕГО не пишем и ничего оттуда не удаляем — это и есть та кросс-пул запись,
        ради устранения которой маркеры переехали в шину.
#>
function Test-LegacyFlagWritten {
    param([string]$Owner, [string]$IntentPath)
    if (-not $Owner -or -not $IntentPath -or -not (Test-Path $IntentPath)) { return $false }
    $legacy = Join-Path $env:USERPROFILE (".claude\.control\shutdown-ready-{0}" -f $Owner)
    if (-not (Test-Path $legacy)) { return $false }
    try { return ((Get-Item $legacy).LastWriteTime -ge (Get-Item $IntentPath).LastWriteTime) } catch { return $false }
}

function Test-HandoffFlagFresh {
    param([string]$Owner, [string]$BusRoot)
    $sp = Get-ShutdownPaths -BusRoot $BusRoot -Owner $Owner
    if (-not $sp) { return [pscustomobject]@{ Valid = $false; Reason = 'шина роли не определена — подтверждение не проверить' } }
    $flag   = $sp.Ready
    $intent = $sp.Intent
    if (-not (Test-Path $flag)) {
        if (Test-LegacyFlagWritten -Owner $Owner -IntentPath $intent) {
            return [pscustomobject]@{ Valid = $false; Reason = 'флаг ушёл в СТАРОЕ глобальное место (~\.claude\.control) — агент действовал по памяти, а не по телу задачи. Не засчитываю (общий каталог, имена ролей повторяются между пулами). Повтори гашение этой роли: тело задачи теперь велит звать `pool ready`' }
        }
        return [pscustomobject]@{ Valid = $false; Reason = 'нет ready-флага (агент не подтвердил, либо поработал после handoff -> хук стёр)' }
    }
    if (-not (Test-Path $intent)) { return [pscustomobject]@{ Valid = $false; Reason = 'нет intent-метки Фазы 1 (флаг не из этого цикла завершения)' } }
    if ((Get-Item $flag).LastWriteTime -lt (Get-Item $intent).LastWriteTime) { return [pscustomobject]@{ Valid = $false; Reason = 'ready СТАРШЕ Фазы 1 (протух)' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'свежий (новее Фазы 1)' }
}

<#
    Обратный отсчёт ожидания — одна перерисовываемая строка (без прокрутки лога).
    Пишет ТОЛЬКО в живой терминал: при перенаправлении вывода (лог, пайп, self-test) молчит,
    иначе каретка `\r` замусорила бы файл. Write-Host намеренно — он не попадает в поток
    возвращаемых значений (Фаза 1 возвращает хэштаблицу, и Write-Output её бы испортил).
#>
function Write-Countdown {
    param([int]$LeftSec, [string]$Suffix = '')
    if ([Console]::IsOutputRedirected) { return }
    if ($LeftSec -lt 0) { $LeftSec = 0 }
    $ts   = [TimeSpan]::FromSeconds($LeftSec)
    $line = "[shutdown] осталось {0:mm\:ss}{1}" -f $ts, $(if ($Suffix) { "  |  $Suffix" } else { '' })
    if ($line.Length -gt 100) { $line = $line.Substring(0, 97) + '...' }
    Write-Host ("`r" + $line.PadRight(100)) -NoNewline -ForegroundColor DarkGray
}

<# Стереть строку отсчёта перед обычным выводом, чтобы он не лёг поверх неё. #>
function Clear-Countdown {
    if ([Console]::IsOutputRedirected) { return }
    Write-Host ("`r" + (' ' * 100) + "`r") -NoNewline
}

function Wait-ShutdownFlag {
    param([string]$FlagPath, [int]$TimeoutSec, [string]$Owner = '')
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $FlagPath) { Clear-Countdown; return $true }
        # Шаг 1 с (был 5): отсчёт идёт плавно, и готовность замечается быстрее — Test-Path дёшев.
        Write-Countdown ([int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)) $(if ($Owner) { "жду $Owner" } else { 'жду флаг готовности' })
        Start-Sleep -Seconds 1
    }
    Clear-Countdown
    return $false
}

<#
    Handoff-файл роли — ФОЛБЭК для колонки «запись обновлена» у ролей, ещё не переехавших в память
    (основной источник — `Get-RoleMemoryMark` ниже). Косметика — best-effort, НЕ гейт.

    Корень поиска здесь НАМЕРЕННО остаётся родителем шины, а не PoolCwd: у пулов монорепо PoolCwd —
    это `<workspace-root>\<monorepo>` / `<umbrella>` целиком, и рекурсия по нему на каждую роль
    обходила бы весь монорепо. Для памяти корень другой (PoolCwd) — и это не разнобой, а разные
    предметы: handoff лежит у подпроекта, каталог памяти — у launch-cwd роли.

    Ищем от каталога ПОДПРОЕКТА (родитель шины), а не от launch-cwd: у пулов монорепо cwd — это
    `<workspace-root>\<monorepo>` / `<umbrella>` целиком, и рекурсия по нему на КАЖДУЮ роль в цикле
    фазы 1 обходила бы node_modules/.git всего монорепо. Сначала нерекурсивно (99% случаев — файл
    лежит прямо в корне подпроекта), рекурсия — только фолбэком.
    `.claude\worktrees` исключаем: у <sub-a> там 6 копий handoff'ов из git-worktree, и рекурсия
    возвращала 7 кандидатов, из которых первый мог оказаться копией, а не живым файлом.
#>
function Find-HandoffFile {
    param([string]$SearchRoot, [string]$Owner)
    if (-not $SearchRoot -or -not (Test-Path $SearchRoot)) { return $null }
    $name = "_handoff_$Owner.md"
    $cand = Get-ChildItem -LiteralPath $SearchRoot -Filter $name -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cand) {
        $cand = Get-ChildItem -LiteralPath $SearchRoot -Recurse -Filter $name -File -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\\.claude\\worktrees\\' } | Select-Object -First 1
    }
    if ($cand) { return [pscustomobject]@{ Path = $cand.FullName; Mtime = $cand.LastWriteTime } }
    return $null
}

<#
    Свежесть памяти роли — ОСНОВНОЙ источник колонки «запись обновлена». Косметика, НЕ гейт.

    Каталог берётся из МАНИФЕСТА (`PoolCwd` цели), а не выводится из пути шины: у 5 пулов из 17 шина и
    launch-cwd — разные каталоги, и вычисление одного из другого промахивается МОЛЧА. Маркер
    `<шина>\.control\cwd` сюда тоже не годится — его пишет роль при старте, и сегодня он есть у одного
    пула из восемнадцати; у контроллера манифест есть всегда.

    $null возвращается в ТРЁХ разных случаях, и все три означают «мерить нечем», а не «роль не писала»:
    каталога нет; каталог есть, но записей в нём нет (его мог создать запускатель у роли, которая ещё
    ведёт handoff-файл); замер не удался. Вызывающий обязан трактовать $null как «?», НЕ как отказ.
#>
function Get-RoleMemoryMark {
    param([string]$PoolCwd, [string]$Owner)
    if (-not $script:MemStatsReady) { return $null }
    if ([string]::IsNullOrWhiteSpace($PoolCwd) -or [string]::IsNullOrWhiteSpace($Owner)) { return $null }
    # [IO.Path]::Combine, а НЕ Join-Path: последний ходит в провайдер PowerShell и под $EAP='Stop'
    # бросает «Cannot find drive» на пути с несуществующим диском — то есть косметическая колонка
    # уронила бы фазу handoff. Поймано собственным тестом на `Z:\...`.
    $dir = [System.IO.Path]::Combine($PoolCwd, '.memory', $Owner)
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    try { $s = Get-AgentMemoryStats -RoleDir $dir } catch { return $null }
    if (-not $s.Exists -or $null -eq $s.LastWrite) { return $null }
    return [pscustomobject]@{ Path = $dir; Mtime = $s.LastWrite }
}

<#
    ФАЗА 1 (человеко-гейт): рассылает handoff-задачу ВСЕМ целям разом, затем ждёт
    все флаги ПАРАЛЛЕЛЬНО (не N×таймаут). Гашения НЕТ. После — оператор командует -KillOnly.
#>
function Invoke-HandoffPhase {
    param($Targets, [int]$MyPid, [int]$TimeoutSec, [string]$CommandName = 'handoff-myself')
    Write-Step "ФАЗА 1 — HANDOFF всем участникам через вотчеры (впрыск /$CommandName). Гашения НЕ будет (ждёт -KillOnly)."
    $pending = @()
    foreach ($t in $Targets) {
        $tp = Resolve-TargetPid $t
        if ($tp -and $tp -eq $MyPid) { Write-Warn "$($t.Owner): это я — пропускаю"; continue }
        if (-not $tp) { Write-Warn "$($t.Owner): живого процесса нет — пропускаю"; continue }
        if (Test-LightClose $t.Pct $Threshold) { Write-Step "$($t.Owner): ctx=$([math]::Round($t.Pct))% < $Threshold% -> handoff не нужен (лёгкое закрытие, гашение в фазе 2)"; continue }
        $bus = Get-BusRoot -BusDir $t.BusDir
        if (-not $bus) { Write-Warn "$($t.Owner): шины нет ($($t.BusDir)) — пропускаю"; continue }
        $sp = Get-ShutdownPaths -BusRoot $bus -Owner $t.Owner
        if (-not $sp) { Write-Warn "$($t.Owner): не создать .control в шине ($bus) — пропускаю"; continue }
        $flag = $sp.Ready
        if (Test-Path $flag) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
        # ПУНКТ 2: intent-метка = «момент Фазы 1». Ready валиден в -KillOnly только если новее её.
        # 🛑 Карантин ставим ТОЛЬКО роли, чей сторож умеет его переживать. Сторож держит код на
        # момент своего взвода: поднятый до появления фильтра «пропускать pool-controller» он под
        # меткой молчит ОБО ВСЁМ — включая эту самую задачу, и роль не просыпается. Поймано вживую на
        # `qa-<sub-a>` 07.08: задача лежала в ящике, сторож бился, роль спала; спасли снятием метки.
        # Сравниваем время взвода (третье поле замка) с временем правки pool.ps1. Замок нечитаем или
        # сторожа нет — метку ставим: без сторожа роль будит баннер, а он версии не держит.
        $__wlock = [IO.Path]::Combine($bus, '.watch', ('lock-{0}.txt' -f $t.Owner))
        $__quietOk = $true
        try {
            if (Test-Path $__wlock) {
                $__parts = ((Get-Content $__wlock -Raw -ErrorAction Stop).Trim() -split '\|')
                if ($__parts.Count -ge 3) {
                    $__armed = [datetime]::Parse($__parts[2])
                    $__codeAt = (Get-Item ([IO.Path]::Combine($PSScriptRoot, 'pool.ps1')) -ErrorAction Stop).LastWriteTime
                    if ($__armed -lt $__codeAt) { $__quietOk = $false }
                }
            }
        } catch { $__quietOk = $true }
        if (-not $__quietOk) {
            Write-Warn ("{0}: сторож взведён старым кодом — карантин не ставлю (иначе роль не проснётся на эту задачу)" -f $t.Owner)
        }
        $intent = $sp.Intent
        if ($__quietOk) { try { [System.IO.File]::WriteAllText($intent, '') } catch { } }
        # Источник замера ЗАЩЁЛКИВАЕТСЯ здесь и в отчёте не переспрашивается. Иначе роль, заведшая
        # хранилище прямо во время handoff (флаг раскатки включён — каталог появляется при старте),
        # сравнивалась бы «после» по памяти против «до», снятого с файла: сравнение мусора, молча.
        $mem = Get-RoleMemoryMark -PoolCwd $t.PoolCwd -Owner $t.Owner
        $srcKind = $null; $srcPath = $null; $srcBefore = $null
        if ($mem) { $srcKind = 'memory'; $srcPath = $mem.Path; $srcBefore = $mem.Mtime }
        else {
            $hf = Find-HandoffFile -SearchRoot (Split-Path $bus -Parent) -Owner $t.Owner
            if ($hf) { $srcKind = 'handoff'; $srcPath = $hf.Path; $srcBefore = $hf.Mtime }
        }
        # ProjectRoot -> PoolCwd: там ищется `.claude\commands\<команда>.md` (project-local переопределение
        # текста handoff-команды). NB: для пулов монорепо это ОБЩИЙ корень — файл, положенный в
        # `<monorepo>\.claude\commands\`, накроет разом три пула. Сегодня переопределений нет нигде.
        $snd = Send-ShutdownTask -BusRoot $bus -TargetOwner $t.Owner -FlagPath $flag -ProjectRoot $t.PoolCwd -CommandName $CommandName
        if (-not $snd.Ok) { Write-Warn "$($t.Owner): отправка не удалась: $($snd.Msg)"; continue }
        Write-Ok "$($t.Owner): задача отправлена -> $bus"
        $pending += [pscustomobject]@{ Owner = $t.Owner; Flag = $flag; Intent = $intent; Pid = $tp; PoolCwd = $t.PoolCwd; SrcKind = $srcKind; SrcPath = $srcPath; SrcBefore = $srcBefore; Sent = (Get-Date) }
    }
    if (-not $pending.Count) { Write-Warn 'никому не отправлено — целей с живым процессом и шиной нет'; return @{} }

    Write-Step "жду флаги готовности от $($pending.Count) агентов (до $TimeoutSec с, опрос каждые 5 с)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $done = @{}
    $lastLog = Get-Date
    while ((Get-Date) -lt $deadline -and $done.Count -lt $pending.Count) {
        foreach ($p in $pending) {
            if ($done.ContainsKey($p.Owner)) { continue }
            # Защёлкиваем факт наблюдения В ПАМЯТИ: с этой секунды ready-флаг может быть стёрт хуком
            # в любой момент (нотификация о завершении фоновой задачи = новый ход), и переспрашивать
            # диск в Фазе 2 уже нельзя — именно так терялись operator/<pool-a> и methodist/<pool-b>.
            if (Test-Path $p.Flag) { $el = [int]((Get-Date) - $p.Sent).TotalSeconds; $done[$p.Owner] = $el; Clear-Countdown; Write-Ok "$($p.Owner): ГОТОВ ($el с)" }
        }
        if ($done.Count -ge $pending.Count) { break }
        # Отсчёт с шагом 1 с: видно, сколько ещё ждать и КОГО именно (раньше 7 минут шли молча,
        # и «зависло или работает» было не отличить). Опрос флагов тоже стал секундным — Test-Path
        # дёшев, а готовность замечается быстрее. В лог по-прежнему пишем раз в ~5 с, не чаще.
        $left    = [int][math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        $waiting = @($pending | Where-Object { -not $done.ContainsKey($_.Owner) } | ForEach-Object { $_.Owner })
        $names   = $waiting -join ', '
        if ($names.Length -gt 50) { $names = $names.Substring(0, 47) + '...' }
        Write-Countdown $left ("подтвердили {0}/{1}, жду: {2}" -f $done.Count, $pending.Count, $names)
        if (((Get-Date) - $lastLog).TotalSeconds -ge 5) {
            Write-Log ("wait poll: done={0}/{1}, left={2}s" -f $done.Count, $pending.Count, $left)
            $lastLog = Get-Date
        }
        Start-Sleep -Seconds 1
    }
    Clear-Countdown

    # ПУНКТ 3 — запечатать ПОДТВЕРДИВШИХ (опционально, -Seal). Останавливает источники побудки
    # (вотчер + Telegram-sentinel) по PID, оставляя claude живым.
    # NB 2026-07-27: прежнее обоснование «стабилизирует готовность на время гейта» БЫЛО НЕВЕРНЫМ и
    # работало ровно наоборот. Убийство фоновой задачи харнесс доставляет как новый ход, а тот стирал
    # ready-флаг — то есть пломба разрушала ровно то, что обещала стабилизировать. Безвредна она была
    # лишь потому, что стоит ПОСЛЕ цикла ожидания, когда подтверждение уже защёлкнуто в памяти.
    # Теперь машинная побудка флаг не стирает (см. инварианты в pool.ps1 / Invoke-Activity), поэтому
    # ключ обезврежен и оставлен. Лаунчер его не передаёт; включать осознанно и только ради паузы моста.
    if ($Seal) {
        Write-Step 'запечатываю подтвердивших (стоп вотчера + Telegram-sentinel по PID; claude жив)...'
        foreach ($p in $pending) {
            if (-not $done.ContainsKey($p.Owner)) { continue }   # тайм-аутнувших не пломбируем
            if (-not $p.Pid) { Write-Warn "$($p.Owner): PID неизвестен — не запечатываю"; continue }
            $s = Invoke-SealAgent -ClaudePid $p.Pid
            if ($s.Stopped.Count) { Write-Ok "$($p.Owner): запечатан — остановлено: $($s.Stopped -join ', ')" }
            else { Write-Step "$($p.Owner): источников побудки в дереве не найдено" }
            if ($s.SentinelStopped) { Write-Warn "$($p.Owner): Telegram-ЛИСТЕНЕР на ПАУЗЕ — входящие журналируются в inbox, живого ответа не будет до старта пула" }
        }
    }

    Write-Host "`n=== ФАЗА 1 (handoff) — ИТОГ ===" -ForegroundColor Cyan
    $rows = @()
    $legacyOwners = @()
    foreach ($p in $pending) {
        $ok = $done.ContainsKey($p.Owner)
        # «?» — замерить не удалось (нет источника, хранилище пусто, файл залочен). Это НЕ отказ агента:
        # ложная тревога здесь дороже пропуска, оператор по этой таблице решает, гасить или разбираться.
        $hfCh = '?'
        if ($p.SrcKind -eq 'memory') {
            $now = Get-RoleMemoryMark -PoolCwd $p.PoolCwd -Owner $p.Owner
            if ($now) { $hfCh = if ($now.Mtime -ne $p.SrcBefore) { 'да' } else { 'НЕТ(!)' } }
        }
        elseif ($p.SrcKind -eq 'handoff' -and $p.SrcPath -and (Test-Path $p.SrcPath)) {
            $hfCh = if ((Get-Item $p.SrcPath).LastWriteTime -ne $p.SrcBefore) { 'да' } else { 'НЕТ(!)' }
        }
        # Немой «ТАЙМАУТ» — худший исход отчёта: оператор не знает, агент завис или промахнулся мимо
        # флага. Причину видно ЗДЕСЬ, а не в %TEMP%-логе, потому что смотрят именно в эту таблицу.
        $note = ''
        if (-not $ok) {
            if (Test-LegacyFlagWritten -Owner $p.Owner -IntentPath $p.Intent) { $note = 'флаг в СТАРОМ месте'; $legacyOwners += $p.Owner }
            elseif ($hfCh -eq 'да') { $note = 'запись есть, флага нет' }
        }
        $rows += [pscustomobject]@{ Owner = $p.Owner; Готов = $(if ($ok) { "да ($($done[$p.Owner])с)" } else { 'ТАЙМАУТ' }); 'запись обновлена' = $hfCh; Примечание = $note }
    }
    # Out-Host обязателен: функция теперь ВОЗВРАЩАЕТ $done, а Format-Table иначе подмешал бы в
    # возвращаемое значение свои служебные объекты (FormatStartData и прочие) вместо хэштаблицы.
    $rows | Format-Table -AutoSize | Out-Host
    if ($legacyOwners.Count) {
        Write-Warn ("роли [{0}] положили флаг в СТАРОЕ глобальное место (~\.claude\.control) — действовали по памяти прошлых гашений, а не по телу задачи." -f ($legacyOwners -join ', '))
        Write-Warn 'Не засчитываю: тот каталог общий, имена ролей повторяются между пулами. Повтори гашение этих ролей — тело задачи теперь велит звать `pool ready`, и путь агент больше не собирает сам.'
    }
    if ($done.Count -eq $pending.Count) {
        Write-Ok "ВСЕ $($pending.Count) агентов завершили handoff. Подтверждение защёлкнуто. По твоей команде: pool-shutdown.ps1 -Pool <slug> -KillOnly"
    } else {
        Write-Warn "подтвердили $($done.Count)/$($pending.Count). НЕ закрывать, пока не разобрались с отставшими."
    }
    return $done
}

# ---------------------------------------------------------------- цели

<# Все манифесты воркспейса. Кэш на прогон: сканы -Recurse были у Get-PoolManifest и Find-RoleByOwner
   свои, и на одного owner'а диск обходился дважды. Нужен ещё и для проверки коллизий скоупа. #>
function Get-AllManifests {
    if ($null -ne $script:ManifestsCache) { return $script:ManifestsCache }
    $out = @()
    # -Force: на Unix каталог, начинающийся с точки, считается скрытым и без него не обходится —
    # пул в нём не нашёлся бы ни гашением, ни гардом имён (подробности у Get-WorkspaceManifests).
    $found = Get-ChildItem -Path $script:WorkspaceRoot -Recurse -Force -Filter 'pool.manifest.json' -Depth 3 -ErrorAction SilentlyContinue
    foreach ($f in $found) {
        try { $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        $out += $j
    }
    $script:ManifestsCache = $out
    return $out
}

function Get-PoolManifest {
    param([string]$Slug)
    foreach ($j in (Get-AllManifests)) { if ($j.slug -eq $Slug) { return $j } }
    return $null
}

<# Манифест + роль по owner'у (для -Owner фолбэка на сессию без метрики). #>
<# EVERY manifest carrying this owner name. Split out of the -Owner route so a fixture cache can
   drive it: the route itself reaches into live processes and cannot run inside a selftest. #>
<# The refusal text for an ambiguous -Owner, or $null when the name belongs to exactly one pool.
   Kept separate from the route so a selftest can pin the DECISION and not just the lookup: a
   mutation that dropped the check went unnoticed while only the lookup was covered. #>
function Get-OwnerRouteRefusal {
    param([string]$OwnerName, $Found)
    $m = @($Found)
    if ($m.Count -le 1) { return $null }
    $slugs = (($m | ForEach-Object { $_.Manifest.slug }) -join ', ')
    return ((Get-GuardMessage 'ambiguous') -f $OwnerName, $slugs)
}

function Get-ManifestsWithOwner {
    param([string]$OwnerName)
    $res = @()
    foreach ($j in (Get-AllManifests)) {
        foreach ($r in $j.roles) { if ($r.owner -eq $OwnerName) { $res += [pscustomobject]@{ Manifest = $j; Role = $r } } }
    }
    return $res
}

function Find-RoleByOwner {
    param([string]$OwnerName)
    foreach ($j in (Get-AllManifests)) {
        foreach ($r in $j.roles) { if ($r.owner -eq $OwnerName) { return [pscustomobject]@{ Manifest = $j; Role = $r } } }
    }
    return $null
}

<#
    ТРИ КАТАЛОГА ПУЛА вместо перегруженного `root`. Смыслы (шапка pool-manifest.ps1):
      BatRoot — каталог wrapper-батников. ТОЛЬКО для Get-SessionTitleFromBat. Свойством цели
                НЕ становится намеренно: за пределами Resolve-Targets он не нужен, а лишнее
                поле пришлось бы тащить через Merge-DuplicateTargets и finally.
      PoolCwd — launch-cwd сессий: скоуп метрик, скоуп ancestry, ProjectKey headless-компакта,
                сверка cwd у выжившей фоновой сессии.
      BusDir  — каталог шины: handoff-задача, маркеры .control, уборка landmine'ов.
    У 10 «обычных» пулов все три совпадают (фолбэк на root) — поведение не меняется by construction.
#>
function Get-PoolDirs {
    param($Manifest)
    return [pscustomobject]@{
        BatRoot = [string]$Manifest.root
        PoolCwd = Resolve-PoolCwd $Manifest
        BusDir  = Resolve-PoolBus $Manifest
    }
}

<#
    Owner-имена, которые в ЭТОМ пуле неоднозначны: те же имена есть у другого пула, чей PoolCwd
    пересекается с нашим (один вложен в другой либо равны).

    ЗАЧЕМ. Скоуп сессий — PoolCwd, а он ШИРЕ каталога батников: `<umbrella>` поглощает вложенный
    `<pool-a>`, `<monorepo>` общий на три пула. Метрика ключуется по owner-имени, и `$t.Name`
    метрик-цели — титул ЧУЖОЙ сессии, свой и уникальный. То есть уникальность титулов (62/62 сегодня)
    от кросс-пул килла НЕ защищает: титул берётся у жертвы. Единственный настоящий барьер —
    неповторяемость owner-имён внутри пересекающегося скоупа.

    Замерено 2026-07-27: 9 пересекающихся пар пулов ({<sub-a>, search, team, <pool-a>} под `<umbrella>`
    и три пула под `<monorepo>`), общих owner-имён — НОЛЬ. То есть сегодня безопасно, но
    безопасность ЭМЕРДЖЕНТНА: первый же `add-peer -Owner qa` под <monorepo> её снимет.
    Проверка живёт ЗДЕСЬ, а не в аудите пикера, именно потому, что пикер перед гашением self-test
    не гоняет — он сразу шлёт `-Pool <slug> -Full -CloseWindow`.
#>
function Get-AmbiguousOwners {
    param($Manifest)
    $mine = Resolve-PoolCwd $Manifest
    if (-not $mine) { return @() }
    $myOwners = @(@($Manifest.roles) | ForEach-Object { $_.owner })
    $amb = @{}
    foreach ($other in (Get-AllManifests)) {
        if ($other.slug -eq $Manifest.slug) { continue }
        $oc = Resolve-PoolCwd $other
        if (-not $oc) { continue }
        if (-not ((Test-CwdUnderRoot $oc $mine) -or (Test-CwdUnderRoot $mine $oc))) { continue }
        foreach ($r in @($other.roles)) {
            if ($myOwners -contains $r.owner) { $amb[$r.owner] = $other.slug }
        }
    }
    return $amb
}

<#
    Цели ОДНОЙ роли. Вынесено из обеих веток (-Pool и -Owner) в общий код НАМЕРЕННО: до 2026-07-27
    логика была продублирована, и правка одной ветки оставляла вторую сломанной (ровно так -Owner
    остался бы no-op'ом после починки -Pool).

    Порядок: метрика (точная, с ctx%) -> фолбэк по SessionTitle из .bat (сессии без метрики) ->
    громкий диагноз. Молчаливое «не запущена» при живой сессии — худший исход для ИНСТРУМЕНТА
    ГАШЕНИЯ: пул остаётся жить, а отчёт выглядит штатно (дефект 2026-07-27 жил именно так).
#>
function Resolve-RoleTarget {
    param($Dirs, $Role, $Ctx, $Ambiguous)
    $out   = @()
    $owner = [string]$Role.owner
    $batTitle = Get-SessionTitleFromBat -PoolRoot $Dirs.BatRoot -BatName $Role.bat

    # cwd-фильтр по PoolCwd (launch-cwd), а НЕ по root: у пулов монорепо root — каталог батников
    # (`<monorepo>\scripts`), а сессия стартует в `<monorepo>`, и фильтр по root
    # отбрасывал ЖИВЫЕ сессии со ПОЛНОЙ метрикой. Сам фильтр нужен: owner-имя роли повторяется
    # между пулами (баг 2026-07-18, -Pool хватал <pool-a>).
    # Bus match is authoritative and needs no cwd check (cwd drifts as the agent cd's around).
    # Only a session with NO bus in its metric falls back to the cwd heuristic.
    $hit = @($Ctx | Where-Object {
        $_.Owner -eq $owner -and (
            (Test-SameBus $_.Bus $Dirs.BusDir) -or
            ((-not $_.Bus) -and (Test-CwdUnderRoot $_.Cwd $Dirs.PoolCwd))
        )
    })
    foreach ($h in $hit) {
        # Неоднозначное owner-имя (то же имя у пула с пересекающимся скоупом) -> cwd-фильтра МАЛО:
        # $h.Name — титул ЧУЖОЙ сессии, свой и уникальный, поэтому уникальность титулов не защищает.
        # Требуем совпадения с титулом из НАШЕГО батника. Включается ТОЛЬКО для коллизирующих имён:
        # как общий фильтр эта сверка отвергнута по замеру (у metrics-<sub-a> титул разъехался с
        # session_name после пересадки сессии, у analyst <pool-c> session_name пуст) — она давала бы
        # ложные отказы, то есть тот же молчаливый no-op.
        # A confirmed bus already proves the pool, so the title cross-check (which has its own false
        # negatives: titles drift after a session transplant) is skipped in that case.
        if ($Ambiguous -and $Ambiguous.ContainsKey($owner) -and -not (Test-SameBus $h.Bus $Dirs.BusDir)) {
            if (-not $batTitle -or $h.Name -ne $batTitle) {
                Write-Warn ("роль '{0}': имя роли есть и в пуле '{1}' (общий скоуп {2}), титул сессии '{3}' != титула батника '{4}' — в цели НЕ беру (риск чужой сессии)" -f `
                    $owner, $Ambiguous[$owner], $Dirs.PoolCwd, $h.Name, $batTitle)
                continue
            }
        }
        Add-Member -InputObject $h -NotePropertyName PoolCwd -NotePropertyValue $Dirs.PoolCwd -Force
        Add-Member -InputObject $h -NotePropertyName BusDir  -NotePropertyValue $Dirs.BusDir  -Force
        # Обёртка роли — нужна ТОЛЬКО перезарядке (подъём), но кладём её в цель всегда: считать её
        # позже, после убийства, было бы поздно, а манифест к тому моменту уже не в руках.
        Add-Member -InputObject $h -NotePropertyName BatRoot -NotePropertyValue $Dirs.BatRoot -Force
        Add-Member -InputObject $h -NotePropertyName Bat     -NotePropertyValue ([string]$Role.bat) -Force
        # Титул из БАТНИКА, а не из метрики: он ручка возобновления. У метрики session_name дрейфует
        # после пересадки сессии, и подъём начал бы ПУСТОЙ разговор вместо прежнего.
        Add-Member -InputObject $h -NotePropertyName BatTitle -NotePropertyValue ([string]$batTitle) -Force
        $out += $h
    }
    if ($out.Count) { return $out }

    $live = if ($batTitle) { Resolve-LiveByTitle -Title $batTitle -PoolRoot $Dirs.PoolCwd } else { $null }
    if ($live) {
        Write-Warn "роль '$owner': метрики нет, но процесс ЖИВ (pid $($live.Pid)) — включаю с ctx=unknown (по умолчанию handoff)"
        $out += [pscustomobject]@{
            SessionId = $live.SessionId
            Name      = $batTitle
            Owner     = $owner
            Cwd       = $Dirs.PoolCwd
            Pct       = $null           # неизвестно -> консервативно идём через handoff
            AgeSec    = $null
            File      = $null
            PoolCwd   = $Dirs.PoolCwd
            BusDir    = $Dirs.BusDir
            BatRoot   = $Dirs.BatRoot
            Bat       = [string]$Role.bat
            BatTitle  = [string]$batTitle
            KnownPid  = $live.Pid
            NoMetric  = $true
        }
        return $out
    }

    # Титул жив, но происхождение вне скоупа — это ОШИБКА РЕЗОЛВА, а не «роль не запущена».
    # Разница принципиальна: первое чинят, второе игнорируют. Раньше оба случая печатались одинаково.
    if ($batTitle) {
        $glob = @(Get-LiveSessions | Where-Object { $_.Title -eq $batTitle })
        if ($glob.Count) {
            Write-Warn ("роль '{0}': сессия с титулом '{1}' ЖИВА (pid {2}), но её происхождение '{3}' вне скоупа пула '{4}' — цель НЕ взята. Это ошибка резолва, а не «не запущена»." -f `
                $owner, $batTitle, $glob[0].Pid, $(if ($glob[0].Root) { $glob[0].Root } else { '<не определено>' }), $Dirs.PoolCwd)
            return $out
        }
    }
    Write-Warn "роль '$owner': метрики нет и живого процесса не найдено — пропускаю (не запущена)"
    return $out
}

function Resolve-Targets {
    param([string]$PoolSlug, [string]$OwnerName)
    $ctx = Get-CtxMap
    $targets = @()

    if ($OwnerName) {
        # An ambiguous owner name is REFUSED, not resolved to "the first manifest on disk": the old
        # behaviour could reach Resolve-LiveByTitle with a FOREIGN pool root and kill somebody else's
        # live session. Measured today: tech-lead exists in three pools, qa in three, lead/operator/
        # builder in two. Get-AmbiguousOwners does NOT cover this - it only looks at overlapping cwd,
        # and these pools do not overlap. -Pool <slug> -Only <owner> is the unambiguous route.
        $allRm = @(Get-ManifestsWithOwner -OwnerName $OwnerName)
        $refusal = Get-OwnerRouteRefusal -OwnerName $OwnerName -Found $allRm
        if ($refusal) { Write-Warn $refusal; return @() }
        $rm = Find-RoleByOwner -OwnerName $OwnerName
        if (-not $rm) { Write-Warn "owner '$OwnerName': роль не найдена ни в одном манифесте"; return @() }
        $dirs = Get-PoolDirs $rm.Manifest
        Write-Step ("owner '{0}' -> пул '{1}'; cwd={2}; шина={3}" -f $OwnerName, $rm.Manifest.slug, $dirs.PoolCwd, $(if ($dirs.BusDir) { $dirs.BusDir } else { '<нет>' }))
        Write-BusHealth -Dirs $dirs -Manifest $rm.Manifest -Slug $rm.Manifest.slug
        return @(Resolve-RoleTarget -Dirs $dirs -Role $rm.Role -Ctx $ctx -Ambiguous (Get-AmbiguousOwners $rm.Manifest))
    }

    $man = Get-PoolManifest -Slug $PoolSlug
    if (-not $man) { throw "манифест пула '$PoolSlug' не найден" }
    $dirs = Get-PoolDirs $man
    Write-Step ("манифест: {0} ({1} ролей); батники={2}; cwd={3}; шина={4}" -f `
        $man.slug, $man.roles.Count, $dirs.BatRoot, $dirs.PoolCwd, $(if ($dirs.BusDir) { $dirs.BusDir } else { '<нет>' }))
    Write-BusHealth -Dirs $dirs -Manifest $man -Slug $man.slug
    $amb = Get-AmbiguousOwners $man
    if ($amb.Count) {
        Write-Warn ("owner-имена, неоднозначные в скоупе {0}: {1}. Для них требую совпадения титула с батником." -f `
            $dirs.PoolCwd, (($amb.Keys | Sort-Object | ForEach-Object { "$_ (также в '$($amb[$_])')" }) -join '; '))
    }
    foreach ($r in $man.roles) { $targets += @(Resolve-RoleTarget -Dirs $dirs -Role $r -Ctx $ctx -Ambiguous $amb) }
    return $targets
}

<#
    Схлопнуть дубли целей по Owner. Роль пула = одна сессия = одна цель; несколько записей метрики
    на owner'а (перезапуски / stale session_id) иначе дают ФАНТОМНЫЕ цели: handoff ждёт флаг от
    несуществующего пира до таймаута (инцидент <pool-c> 2026-07-20: 3x analyst -> цикл ждал 4/4,
    недостижимо, т.к. $done по Owner). Оставляем ЛУЧШУЮ запись: сперва с живым PID, среди них — с
    макс. известным ctx (консервативно к handoff). Нерезолвимые фантомы отбрасываются, ЕСЛИ у owner'а
    есть живой дубль; если живого нет вовсе — оставляем одну (чтобы штатно всплыло «процесс не найден»).
    Порядок owner'ов сохраняем как во входе (ordered) — предсказуемые preview/kill.
#>
function Merge-DuplicateTargets {
    param($Targets)
    $groups = [ordered]@{}
    foreach ($t in @($Targets)) {
        if (-not $groups.Contains($t.Owner)) { $groups[$t.Owner] = @() }
        $groups[$t.Owner] += $t
    }
    $out = @()
    foreach ($o in $groups.Keys) {
        $grp = @($groups[$o])
        if ($grp.Count -eq 1) { $out += $grp[0]; continue }
        $ann = foreach ($t in $grp) {
            [pscustomobject]@{
                T    = $t
                Live = (Resolve-TargetPid $t)
                Pct  = $(if ($null -ne $t.Pct) { [double]$t.Pct } else { [double]-1 })
            }
        }
        $ranked = @($ann | Sort-Object `
            @{ Expression = { [int][bool]$_.Live }; Descending = $true }, `
            @{ Expression = { $_.Pct };            Descending = $true })
        $keep = $ranked[0]
        Write-Warn ("owner '{0}': {1} дублей в метрике -> оставляю 1 (pid={2}, ctx={3}), отброшено {4} (stale-фантомы)" -f `
            $o, $grp.Count, $(if ($keep.Live) { $keep.Live } else { '-' }), $(if ($keep.Pct -ge 0) { [int]$keep.Pct } else { '?' }), ($grp.Count - 1))
        $out += $keep.T
    }
    return @($out)
}

# ---------------------------------------------------------------- self-test

<# Подмножество целей по owner ВНУТРИ уже pool-scoped списка (флаг -Only): «отдельные роли» из пикера. #>
function Select-OnlyOwners {
    param($Targets, [string[]]$Only)
    if (-not $Only -or -not $Only.Count) { return @($Targets) }
    return @($Targets | Where-Object { $Only -contains $_.Owner })
}

<# «Лёгкое закрытие»: ctx ИЗВЕСТЕН и ниже порога -> без handoff И без compact, просто гасим (вводная пользователя 2026-07-19). ctx неизвестен -> НЕ лёгкое (консервативно handoff). #>
function Test-LightClose { param($Pct, [int]$Threshold) return ($null -ne $Pct) -and ([double]$Pct -lt $Threshold) }

function Invoke-SelfTest {
    $pass = 0; $fail = 0
    function T { param([string]$Name, [scriptblock]$Check)
        try { if (& $Check) { $script:pass++; Write-Host "  ok   $Name" -ForegroundColor Green }
              else { $script:fail++; Write-Host "  FAIL $Name" -ForegroundColor Red } }
        catch { $script:fail++; Write-Host "  FAIL $Name -> $($_.Exception.Message)" -ForegroundColor Red }
    }
    $script:pass = 0; $script:fail = 0
    Write-Host "`n=== self-test pool-shutdown ===" -ForegroundColor Cyan

    T 'ControlDir существует' { Test-Path $script:ControlDir }
    T 'Get-CtxMap возвращает хотя бы одну живую сессию' { (Get-CtxMap).Count -ge 1 }
    T 'у метрики есть SessionId/Owner/Pct' {
        $m = @(Get-CtxMap)[0]
        $m.SessionId -and ($null -ne $m.Pct)
    }
    T 'Get-MyClaudePid находит мой claude.exe' { $null -ne (Get-MyClaudePid) }
    # В природе два типа запуска: пулы (pool-launch.ps1 резолвит title -> UUID, в CommandLine UUID)
    # и роли вроде Launcher (wrapper делает --resume <Title>, UUID в CommandLine НЕТ).
    # Get-SessionPid обязан покрывать оба — так её и зовёт main.
    T 'Get-SessionPid находит меня (id или title, как зовёт main)' {
        $me = Get-MyClaudePid
        $mine = @(Get-CtxMap | Where-Object { $_.Owner -eq $env:AGENT_OWNER })
        if (-not $mine.Count) { return $true }  # не в пуле — пропускаем
        (Get-SessionPid -SessionId $mine[0].SessionId -Title $mine[0].Name) -eq $me
    }
    T 'Get-SessionPid: фолбэк по Title работает без id' {
        $me = Get-MyClaudePid
        $mine = @(Get-CtxMap | Where-Object { $_.Owner -eq $env:AGENT_OWNER })
        if (-not $mine.Count) { return $true }
        (Get-SessionPid -SessionId 'no-such-id' -Title $mine[0].Name) -eq $me
    }
    T 'Get-SessionPid возвращает $null на несуществующий id' { $null -eq (Get-SessionPid -SessionId 'no-such-session-xyz') }
    T 'Get-SessionPid возвращает $null на несуществующий title' { $null -eq (Get-SessionPid -SessionId 'nope' -Title 'NoSuchTitleXYZ') }
    T 'Get-SessionTitleFromBat: титул берётся из --resume, когда роль зовёт движок напрямую' {
        (Get-SessionTitleFromBat -PoolRoot 'C:\workspace-root\.launcher\scripts' -BatName 'claude-launcher.bat') -eq 'Launcher'
    }
    T 'Get-SessionTitleFromBat: строки REM не дают титул (пояснение с образцом уводило его на себя)' {
        $__tmp = Join-Path $env:TEMP ('titlefn-selftest-' + $PID + '.bat')
        $__body = "@echo off`r`nREM title comes through --resume LOVUSHKA`r`n:: --resume VTORAYA_LOVUSHKA`r`nclaude --dangerously-skip-permissions --resume Nastoyashiy`r`n"
        [IO.File]::WriteAllBytes($__tmp, [Text.Encoding]::UTF8.GetBytes($__body))
        $__got = Get-SessionTitleFromBat -PoolRoot (Split-Path $__tmp -Parent) -BatName (Split-Path $__tmp -Leaf)
        Remove-Item -LiteralPath $__tmp -Force -ErrorAction SilentlyContinue
        $__got -eq 'Nastoyashiy'
    }
    T 'Get-SessionTitleFromBat: -SessionTitle сильнее --resume, если есть оба' {
        $__tmp2 = Join-Path $env:TEMP ('titlefn-selftest2-' + $PID + '.bat')
        $__body2 = "@echo off`r`npowershell -File pool-launch.ps1 -SessionTitle `"Glavniy`" -Model x`r`nclaude --resume Vtorichniy`r`n"
        [IO.File]::WriteAllBytes($__tmp2, [Text.Encoding]::UTF8.GetBytes($__body2))
        $__got2 = Get-SessionTitleFromBat -PoolRoot (Split-Path $__tmp2 -Parent) -BatName (Split-Path $__tmp2 -Leaf)
        Remove-Item -LiteralPath $__tmp2 -Force -ErrorAction SilentlyContinue
        $__got2 -eq 'Glavniy'
    }
    T 'Get-SessionTitleFromBat читает title из .bat роли' {
        (Get-SessionTitleFromBat -PoolRoot 'C:\workspace-root\pool-b' -BatName 'claude-methodist.bat') -eq 'Methodist-Daily'
    }
    T 'Get-SessionTitleFromBat: $null на несуществующий .bat' {
        $null -eq (Get-SessionTitleFromBat -PoolRoot 'C:\workspace-root\pool-b' -BatName 'no-such.bat')
    }
    T 'Resolve-LiveByTitle находит меня по моему title (прямой матч)' {
        $me = Get-MyClaudePid
        $myTitle = @(Get-CtxMap | Where-Object { $_.Owner -eq $env:AGENT_OWNER })[0].Name
        if (-not $myTitle) { return $true }
        $r = Resolve-LiveByTitle -Title $myTitle
        $r -and $r.Pid -eq $me
    }
    T 'Resolve-LiveByTitle: $null на несуществующий title' { $null -eq (Resolve-LiveByTitle -Title 'NoSuchTitleXYZ-42') }
    T 'Find-SessionIdByTitle: $null на пустой каталог' { $null -eq (Find-SessionIdByTitle -Title 'x' -Dir 'Z:\nope') }
    T 'Get-PoolManifest находит pool-b' { $null -ne (Get-PoolManifest -Slug 'pool-b') }
    T 'Get-PoolManifest возвращает $null на несуществующий пул' { $null -eq (Get-PoolManifest -Slug 'no-such-pool-xyz') }
    T 'Get-BusRoot находит существующую шину' { $null -ne (Get-BusRoot -BusDir 'C:\workspace-root\pool-b\.bus') }
    # Путь заведомо несуществующий. Раньше здесь стоял `.launcher\.bus` — «шины у Launcher'а нет»
    # перестало быть правдой, когда `.launcher` стал пулом <organizer-pool>, и тест падал на верном коде.
    # Утверждение о ЧУЖОМ живом состоянии — не утверждение о функции; в самотесте ему не место.
    T 'Get-BusRoot возвращает $null на несуществующий каталог' { $null -eq (Get-BusRoot -BusDir 'Z:\no-such-bus-xyz-42') }
    T 'Get-BusRoot возвращает $null на пустой путь (busless-пул)' { $null -eq (Get-BusRoot -BusDir '') }
    # --- ПУНКТ 2026-08-02: колонка «запись обновлена» мерит память роли, а не handoff-файл ---
    # Покрытия у этого кода не было вовсе, а оппонент нашёл в замысле два блокера — оба закреплены здесь.
    T 'Get-RoleMemoryMark: $null на несуществующий каталог' {
        $null -eq (Get-RoleMemoryMark -PoolCwd 'Z:\no-such-cwd-xyz-42' -Owner 'nobody')
    }
    T 'Get-RoleMemoryMark: $null на пустой PoolCwd или owner' {
        ($null -eq (Get-RoleMemoryMark -PoolCwd '' -Owner 'x')) -and ($null -eq (Get-RoleMemoryMark -PoolCwd 'C:\' -Owner ''))
    }
    # БЛОКЕР 1: ветвление по существованию каталога дало бы ложное «НЕТ(!)» роли, у которой хранилище
    # завёл запускатель, а знание всё ещё пишется в handoff-файл (живой случай — <solo-project>).
    T 'Get-RoleMemoryMark: хранилище без *.md НЕ источник (иначе ложное НЕТ(!))' {
        $tmp = Join-Path $env:TEMP ('memmark-empty-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp '.memory\qa') | Out-Null
        $r = $null -eq (Get-RoleMemoryMark -PoolCwd $tmp -Owner 'qa')
        Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
        $r
    }
    T 'Get-RoleMemoryMark: непустое хранилище отдаёт время последней записи' {
        $tmp = Join-Path $env:TEMP ('memmark-live-' + [guid]::NewGuid().ToString('N'))
        $dir = Join-Path $tmp '.memory\qa'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        [IO.File]::WriteAllText((Join-Path $dir 'MEMORY.md'), '- x')
        $m = Get-RoleMemoryMark -PoolCwd $tmp -Owner 'qa'
        $r = ($null -ne $m) -and ($m.Mtime -is [datetime]) -and ($m.Path -eq $dir)
        Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
        $r
    }
    # БЛОКЕР 2: соседняя Get-AgentMemoryArgs создаёт каталоги, пишет settings и делает git init. Позови
    # контроллер её вместо Get-AgentMemoryStats — и гашение минтило бы пустые хранилища всем ролям.
    T 'Get-RoleMemoryMark НЕ создаёт хранилище (read-only)' {
        $tmp = Join-Path $env:TEMP ('memmark-ro-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        [void](Get-RoleMemoryMark -PoolCwd $tmp -Owner 'qa')
        $r = -not (Test-Path -LiteralPath (Join-Path $tmp '.memory'))
        Remove-Item -LiteralPath $tmp -Recurse -Force -EA SilentlyContinue
        $r
    }
    # --- ПУНКТ 2026-07-27: три каталога пула вместо перегруженного `root` ---
    # Ядро дефекта: у пулов, выросших в монорепо, каталог батников / launch-cwd / шина — РАЗНЫЕ.
    T 'Get-PoolDirs: split-пул даёт ТРИ разных каталога (sub-b)' {
        $d = Get-PoolDirs (Get-PoolManifest -Slug 'sub-b')
        ($d.BatRoot -eq 'C:\workspace-root\monorepo\scripts') -and
        ($d.PoolCwd -eq 'C:\workspace-root\monorepo') -and
        ($d.BusDir  -eq 'C:\workspace-root\monorepo\01_projects\sub-b\.bus')
    }
    T 'Get-PoolDirs: обычный пул — все три совпадают (фолбэк на root)' {
        $d = Get-PoolDirs (Get-PoolManifest -Slug 'pool-b')
        ($d.BatRoot -eq 'C:\workspace-root\pool-b') -and ($d.PoolCwd -eq 'C:\workspace-root\pool-b') -and
        ($d.BusDir -eq 'C:\workspace-root\pool-b\.bus')
    }
    # Промах, из-за которого контроллер молчал: cwd живой сессии под PoolCwd, но НЕ под каталогом батников.
    T 'Скоуп: cwd живой сессии split-пула под PoolCwd, но НЕ под BatRoot' {
        $d = Get-PoolDirs (Get-PoolManifest -Slug 'sub-b')
        (Test-CwdUnderRoot 'C:\workspace-root\monorepo' $d.PoolCwd) -and
        (-not (Test-CwdUnderRoot 'C:\workspace-root\monorepo' $d.BatRoot))
    }
    # Осиротевшая `<monorepo>\.bus` (мертва с 25.06) — почему фолбэк на <cwd>\.bus запрещён.
    T 'Шина split-пула НЕ совпадает с <PoolCwd>\.bus (осиротевшая общая шина)' {
        $d = Get-PoolDirs (Get-PoolManifest -Slug 'sub-b')
        $d.BusDir -ne (Join-Path $d.PoolCwd '.bus')
    }
    # Коллизия owner-имён в пересекающемся скоупе — единственный настоящий барьер против кросс-пул килла.
    # Was "no collisions today" - a STATE, not a contract. The first legitimate pool of a multi-pool
    # project would turn it red, and people learn to ignore red. The contract: a clean pool is clean.
    T 'Get-AmbiguousOwners: пул без пересечений — чисто (контракт, а не снимок состояния)' {
        (Get-AmbiguousOwners (Get-PoolManifest -Slug 'pool-b')).Count -eq 0
    }
    T 'Get-AmbiguousOwners: подделанный дубль owner в том же скоупе — ЛОВИТСЯ' {
        $real = Get-PoolManifest -Slug 'sub-b'
        $fake = [pscustomobject]@{
            slug = 'fake-pool-xyz'; root = 'C:\workspace-root\monorepo\scripts'
            cwd  = 'C:\workspace-root\monorepo'
            roles = @([pscustomobject]@{ owner = 'tech-lead-div'; bat = 'nope.bat' })
        }
        $script:ManifestsCache = @($real, $fake)
        $amb = Get-AmbiguousOwners $real
        $script:ManifestsCache = $null
        $amb.ContainsKey('tech-lead-div')
    }
    # --- name-collision guards. Pure functions first, then real (temporary) disk fixtures. ---
    T 'Resolve-PoolBus: windows-путь НЕ идёт в провайдер (на Linux Join-Path бросил бы)' {
        (Resolve-PoolBus ([pscustomobject]@{ root = 'D:\ws\x' })) -eq 'D:\ws\x\.bus'
    }
    T 'Resolve-PoolBus: unix-путь склеивается своим разделителем' {
        (Resolve-PoolBus ([pscustomobject]@{ root = '/opt/agents/x' })) -eq '/opt/agents/x/.bus'
    }
    T 'Resolve-PoolBus: явное поле bus сильнее root, хвостовой разделитель не удваивается' {
        ((Resolve-PoolBus ([pscustomobject]@{ bus = '/srv/b'; root = 'D:\ignored' })) -eq '/srv/b') -and
        ((Resolve-PoolBus ([pscustomobject]@{ root = 'D:\ws\y\' })) -eq 'D:\ws\y\.bus')
    }
    T 'Test-SameBus: одна шина с разным написанием — совпадение; чужая — нет; пустая — НЕ совпадение' {
        (Test-SameBus 'D:\ws\p\.bus' 'D:\WS\P\.BUS\') -and
        (-not (Test-SameBus 'D:\ws\p\.bus' 'D:\ws\q\.bus')) -and
        (-not (Test-SameBus '' 'D:\ws\p\.bus'))
    }

    # The guards scan real files, so they get a real temporary tree, removed right after.
    $fxRoot = Join-Path ([IO.Path]::GetTempPath()) ("poolguard-" + [IO.Path]::GetRandomFileName())
    function New-FxPool([string]$dir, [string]$slug, [string[]]$owners, [string]$cwd, [string]$bus) {
        $d = Join-Path $fxRoot $dir
        [void][IO.Directory]::CreateDirectory($d)
        $o = [ordered]@{ schema = 'pool-manifest/v1'; slug = $slug; root = $d }
        if ($cwd) { $o.cwd = (Join-Path $fxRoot $cwd) }
        if ($bus) { $o.bus = (Join-Path $fxRoot $bus) }
        $o.roles = @($owners | ForEach-Object { [ordered]@{ owner = $_; bat = 'x.bat' } })
        [IO.File]::WriteAllText((Join-Path $d 'pool.manifest.json'), ($o | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
    }
    New-FxPool 'p1' 'fx-one' @('lead','qa') $null $null
    New-FxPool 'p2' 'fx-two' @('lead') $null $null
    New-FxPool 'sh\a' 'fx-sha' @('lead') 'sh' $null
    New-FxPool 'sh\b' 'fx-shb' @('writer') 'sh' $null
    New-FxPool 'bus\a' 'fx-busa' @('pilot') $null 'bus\shared'
    New-FxPool 'bus\b' 'fx-busb' @('nobody') $null 'bus\shared'

    T 'Гард: одноимённые роли в НЕпересекающихся пулах законны (так живут qa и tech-lead)' {
        @(Get-OwnerConflicts -Owner 'lead' -Cwd (Join-Path $fxRoot 'p2') -Bus (Join-Path $fxRoot 'p2\.bus') -ExcludeSlug 'fx-two' -WorkspaceRoot $fxRoot).Count -eq 0
    }
    T 'Гард: общий рабочий каталог — конфликт (делят каталог памяти)' {
        @(Get-OwnerConflicts -Owner 'lead' -Cwd (Join-Path $fxRoot 'sh') -Bus (Join-Path $fxRoot 'sh\b\.bus') -ExcludeSlug 'fx-shb' -WorkspaceRoot $fxRoot).Count -ge 1
    }
    T 'Гард: общая шина — конфликт (делят почтовый ящик)' {
        @(Get-OwnerConflicts -Owner 'pilot' -Cwd (Join-Path $fxRoot 'bus\b') -Bus (Join-Path $fxRoot 'bus\shared') -ExcludeSlug 'fx-busb' -WorkspaceRoot $fxRoot).Count -ge 1
    }
    T 'Гард: слаг занят — ловится; свободный слаг проходит' {
        (@(Get-SlugConflicts -Slug 'fx-one' -WorkspaceRoot $fxRoot).Count -eq 1) -and
        (@(Get-SlugConflicts -Slug 'fx-nope' -WorkspaceRoot $fxRoot).Count -eq 0)
    }
    T 'Гард: явно переданный несуществующий корень — законно (пул создаётся в новом месте)' {
        $s = Get-WorkspaceManifests -WorkspaceRoot (Join-Path $fxRoot 'no-such-child')
        $s.Ok -and (@($s.Manifests).Count -eq 0) -and
        (@(Get-SlugConflicts -Slug 'anything' -WorkspaceRoot (Join-Path $fxRoot 'no-such-child')).Count -eq 0)
    }
    if (Test-Path -LiteralPath $fxRoot) { Remove-Item -LiteralPath $fxRoot -Recurse -Force -ErrorAction SilentlyContinue }

    T 'Маршрут -Owner: имя в нескольких пулах — цели НЕ выдаются (иначе гасим чужое)' {
        $a = [pscustomobject]@{ slug = 'fx-a'; root = 'D:\fx\a'; roles = @([pscustomobject]@{ owner = 'twin'; bat = 'x.bat' }) }
        $b = [pscustomobject]@{ slug = 'fx-b'; root = 'D:\fx\b'; roles = @([pscustomobject]@{ owner = 'twin'; bat = 'x.bat' }) }
        $script:ManifestsCache = @($a, $b)
        $n = @(Get-ManifestsWithOwner -OwnerName 'twin').Count
        $script:ManifestsCache = $null
        $n -eq 2
    }
    T 'Маршрут -Owner: уникальное имя резолвится в свой пул' {
        $a = [pscustomobject]@{ slug = 'fx-a'; root = 'D:\fx\a'; roles = @([pscustomobject]@{ owner = 'solo'; bat = 'x.bat' }) }
        $b = [pscustomobject]@{ slug = 'fx-b'; root = 'D:\fx\b'; roles = @([pscustomobject]@{ owner = 'other'; bat = 'x.bat' }) }
        $script:ManifestsCache = @($a, $b)
        $r = @(Get-ManifestsWithOwner -OwnerName 'solo')
        $script:ManifestsCache = $null
        ($r.Count -eq 1) -and ($r[0].Manifest.slug -eq 'fx-a')
    }
    T 'Маршрут -Owner: РЕШЕНИЕ отказать принимается и называет оба пула' {
        $a = [pscustomobject]@{ Manifest = [pscustomobject]@{ slug = 'fx-a' } }
        $b = [pscustomobject]@{ Manifest = [pscustomobject]@{ slug = 'fx-b' } }
        $msg = Get-OwnerRouteRefusal -OwnerName 'twin' -Found @($a, $b)
        ($null -ne $msg) -and ($msg -like '*fx-a*') -and ($msg -like '*fx-b*') -and ($msg -like '*twin*')
    }
    T 'Маршрут -Owner: одно совпадение или ни одного — отказа нет' {
        $a = [pscustomobject]@{ Manifest = [pscustomobject]@{ slug = 'fx-a' } }
        ($null -eq (Get-OwnerRouteRefusal -OwnerName 'solo' -Found @($a))) -and
        ($null -eq (Get-OwnerRouteRefusal -OwnerName 'none' -Found @()))
    }
    # --- КОМПАКТ-GUARD: контроллер сам порождает claude.exe с тем же uuid ---
    T 'Компакт-guard: `-p "/compact"` -> это компакт, не панель' {
        Test-CompactProc -Proc ([pscustomobject]@{ CommandLine = 'claude.exe --resume 1234abcd-1111-2222 --dangerously-skip-permissions -p "/compact"'; ParentProcessId = 0 }) -ProcMap $null
    }
    T 'Компакт-guard: живая панель (без -p) -> НЕ компакт' {
        -not (Test-CompactProc -Proc ([pscustomobject]@{ CommandLine = 'claude.exe --resume TL-DivDoc-2 --dangerously-skip-permissions --model claude-opus-5[1m]'; ParentProcessId = 0 }) -ProcMap $null)
    }
    # Ключевая защита от ЛОЖНОГО срабатывания: стартовый промпт роли лежит в CommandLine целиком,
    # и слово " -p " в его ТЕКСТЕ не должно делать живую панель невидимой для контроллера.
    T 'Компакт-guard: " -p " в тексте стартового промпта -> НЕ компакт' {
        -not (Test-CompactProc -Proc ([pscustomobject]@{ CommandLine = 'claude.exe --resume Lead-X "Старт пула. Смотри флаг -p в докере и запусти сборку"'; ParentProcessId = 0 }) -ProcMap $null)
    }
    T 'Компакт-guard: предок poolcompact-*.bat -> это компакт' {
        $map = @{ 4242 = [pscustomobject]@{ CommandLine = 'cmd.exe /c "C:\Users\X\AppData\Local\Temp\poolcompact-TLDivDoc2.bat"' } }
        Test-CompactProc -Proc ([pscustomobject]@{ CommandLine = 'claude.exe --resume 1234abcd-1111-2222'; ParentProcessId = 4242 }) -ProcMap $map
    }
    T 'Test-CompactLanded ложь на несуществующем транскрипте' { -not (Test-CompactLanded -TranscriptPath 'Z:\nope.jsonl') }
    # ПУНКТ — разведение пулов с ОДИНАКОВЫМИ именами ролей по cwd (баг 2026-07-18: -Pool хватал <pool-a>)
    T 'CwdUnderRoot: точный корень -> да' { Test-CwdUnderRoot 'C:\workspace-root\pool-name' 'C:\workspace-root\pool-name' }
    T 'CwdUnderRoot: подкаталог (дрейф cwd) -> да' { Test-CwdUnderRoot 'C:\workspace-root\pool-name\00_docs\plans' 'C:\workspace-root\pool-name' }
    T 'CwdUnderRoot: другой пул -> НЕТ (коллизия pool-a vs networking)' { -not (Test-CwdUnderRoot 'C:\workspace-root\umbrella\pool-a' 'C:\workspace-root\pool-name') }
    T 'CwdUnderRoot: префикс-ловушка (-2) -> НЕТ' { -not (Test-CwdUnderRoot 'C:\workspace-root\pool-name-2' 'C:\workspace-root\pool-name') }
    T 'CwdUnderRoot: слеши/регистр нормализуются -> да' { Test-CwdUnderRoot 'c:/workspace-root/POOL-NAME/x' 'C:\workspace-root\pool-name' }
    T 'CwdUnderRoot: пустой cwd -> НЕТ' { -not (Test-CwdUnderRoot '' 'C:\workspace-root\pool-name') }
    # ПУНКТ — pool-aware резолв PID: корень пула из cmdline + скоуп титула по пулу (баг 2026-07-18, killer)
    T 'PoolRootFromCmdLine: из claude-<owner>.bat' {
        (Get-PoolRootFromCmdLine 'cmd.exe /c "C:\workspace-root\pool-name\claude-lead.bat"') -eq 'C:\workspace-root\pool-name'
    }
    T 'PoolRootFromCmdLine: из scripts\pool-launch.ps1' {
        (Get-PoolRootFromCmdLine 'powershell -File "C:\workspace-root\umbrella\pool-a\scripts\pool-launch.ps1" -SessionTitle "Lead-TeamLive"') -eq 'C:\workspace-root\umbrella\pool-a'
    }
    T 'PoolRootFromCmdLine: нет пула -> пусто' { (Get-PoolRootFromCmdLine 'claude --resume abc-123') -eq '' }
    T 'Resolve-LiveByTitle -PoolRoot разводит ОДИНАКОВЫЙ титул по корню (ядро killer-фикса)' {
        $script:LiveSessionsCache = @(
            [pscustomobject]@{ Pid=111; Token='t1'; SessionId='s1'; Title='Lead-X'; Root='C:\workspace-root\pool-a' },
            [pscustomobject]@{ Pid=222; Token='t2'; SessionId='s2'; Title='Lead-X'; Root='C:\workspace-root\pool-b' }
        )
        $a = Resolve-LiveByTitle -Title 'Lead-X' -PoolRoot 'C:\workspace-root\pool-b'
        $b = Resolve-LiveByTitle -Title 'Lead-X' -PoolRoot 'C:\workspace-root\pool-a'
        $n = Resolve-LiveByTitle -Title 'Lead-X'
        $script:LiveSessionsCache = $null
        ($a.Pid -eq 222) -and ($b.Pid -eq 111) -and ($null -ne $n)
    }
    # ПУНКТ — -Only фильтр ролей внутри пула (для «отдельные сессии» из пикера)
    T 'Select-OnlyOwners: фильтрует по owner' {
        $tg = @([pscustomobject]@{Owner='lead'},[pscustomobject]@{Owner='operator'},[pscustomobject]@{Owner='builder'})
        $r = @(Select-OnlyOwners -Targets $tg -Only @('operator','builder'))
        ($r.Count -eq 2) -and ($r.Owner -notcontains 'lead')
    }
    T 'Select-OnlyOwners: пустой -Only -> все цели' {
        $tg = @([pscustomobject]@{Owner='a'},[pscustomobject]@{Owner='b'})
        (@(Select-OnlyOwners -Targets $tg -Only @())).Count -eq 2
    }
    # ПУНКТ — «лёгкое закрытие» низко-ctx (вводная <12% -> просто гашение, без handoff/compact)
    T 'Test-LightClose: ctx ниже порога -> да' { Test-LightClose 5 12 }
    T 'Test-LightClose: ctx на пороге -> НЕТ' { -not (Test-LightClose 12 12) }
    T 'Test-LightClose: ctx выше порога -> НЕТ' { -not (Test-LightClose 50 12) }
    T 'Test-LightClose: ctx неизвестен ($null) -> НЕТ (консервативно handoff)' { -not (Test-LightClose $null 12) }
    # ПУНКТ 2 — свежесть флага. Маркеры лежат В ШИНЕ ПУЛА -> тесты идут на throwaway-шинах.
    $sfBusA = Join-Path $env:TEMP ('shutdown-selftest-busA-' + $PID)
    $sfBusB = Join-Path $env:TEMP ('shutdown-selftest-busB-' + $PID)
    T 'Свежесть: нет флага -> невалидно' {
        $o = 'selftest-fresh-xyz'
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        Remove-Item $sp.Ready  -Force -EA SilentlyContinue
        Remove-Item $sp.Intent -Force -EA SilentlyContinue
        -not (Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusA).Valid
    }
    T 'Свежесть: intent есть, ready нет -> невалидно' {
        $o = 'selftest-fresh-xyz'
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        [IO.File]::WriteAllText($sp.Intent, '')
        Remove-Item $sp.Ready -Force -EA SilentlyContinue
        -not (Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusA).Valid
    }
    T 'Свежесть: ready НОВЕЕ intent -> валидно' {
        $o = 'selftest-fresh-xyz'
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        [IO.File]::WriteAllText($sp.Intent, '')
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllText($sp.Ready, '')
        (Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusA).Valid
    }
    # Кросс-пул: ОДИН И ТОТ ЖЕ owner в другом пуле не должен считаться подтверждённым.
    # Имена ролей повторяются (lead/operator/builder — в двух пулах, tech-lead/qa — в трёх),
    # и общий ~\.claude\.control давал ложное подтверждение поперёк пулов.
    T 'Свежесть: пул-скоуп — чужая шина не подтверждает' {
        $o = 'selftest-fresh-xyz'
        (Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusA).Valid -and
        (-not (Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusB).Valid)
    }
    # КОНТРАКТ: путь, который контроллер ВПРЫСКИВАЕТ агенту в текст задачи, обязан совпасть с тем,
    # который он потом ПРОВЕРЯЕТ. Это шов, на котором уже ломалось: агент создаёт файл по строке из
    # тела задачи, контроллер ищет по своей формуле — разъедутся молча, гашение встанет на таймауте.
    T 'Контракт: путь флага в теле задачи == проверяемый путь' {
        $o  = 'selftest-fresh-xyz'
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        $snd = Send-ShutdownTask -BusRoot $sfBusA -TargetOwner $o -FlagPath $sp.Ready -ProjectRoot $sfBusA
        if (-not $snd.Ok) { return $false }
        $msg = Get-ChildItem (Join-Path $sfBusA "$o\new") -Filter '*.md' -File | Select-Object -First 1
        if (-not $msg) { return $false }
        ([IO.File]::ReadAllText($msg.FullName)).Contains(($sp.Ready -replace '\\','/'))
    }
    # КОНТРАКТ-2 (инцидент 2026-07-27): тело обязано велеть звать КОМАНДУ, а не создавать файл руками.
    # Путь в теле остаётся справкой — но если из тела исчезнет вызов `ready`, агент снова начнёт
    # собирать путь сам, и первый же агент с устаревшей памятью промахнётся мимо флага.
    T 'Контракт: тело задачи велит звать `pool ready`, а не создавать файл руками' {
        $o  = 'selftest-fresh-xyz'
        $msg = Get-ChildItem (Join-Path $sfBusA "$o\new") -Filter '*.md' -File | Select-Object -First 1
        if (-not $msg) { return $false }
        $txt = [IO.File]::ReadAllText($msg.FullName)
        $txt.Contains('pool.ps1" ready') -and $txt.Contains('РУКАМИ НЕ СОЗДАВАЙ')
    }
    # Диагностика legacy: превращает немой «ТАЙМАУТ» во внятную причину. Свежесть меряется по intent,
    # иначе протухший файл от прошлых гашений давал бы ложный диагноз вечно.
    T 'Legacy-детектор: флаг в старом месте СВЕЖЕЕ intent -> распознан' {
        $o = 'selftest-legacy-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        [IO.File]::WriteAllText($sp.Intent, '')
        Start-Sleep -Milliseconds 50
        $lg = Join-Path $env:USERPROFILE (".claude\.control\shutdown-ready-{0}" -f $o)
        [IO.File]::WriteAllText($lg, '')
        $r = Test-LegacyFlagWritten -Owner $o -IntentPath $sp.Intent
        Remove-Item -LiteralPath $lg -Force -EA SilentlyContinue
        $r
    }
    T 'Legacy-детектор: ПРОТУХШИЙ старый флаг (старше intent) -> молчит' {
        $o = 'selftest-legacy-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        $lg = Join-Path $env:USERPROFILE (".claude\.control\shutdown-ready-{0}" -f $o)
        [IO.File]::WriteAllText($lg, '')
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllText($sp.Intent, '')
        $r = -not (Test-LegacyFlagWritten -Owner $o -IntentPath $sp.Intent)
        Remove-Item -LiteralPath $lg -Force -EA SilentlyContinue
        $r
    }
    T 'Legacy-детектор: гейт НЕ ослаблен — legacy не делает флаг валидным' {
        $o = 'selftest-legacy-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        [IO.File]::WriteAllText($sp.Intent, '')
        $lg = Join-Path $env:USERPROFILE (".claude\.control\shutdown-ready-{0}" -f $o)
        [IO.File]::WriteAllText($lg, '')
        $fresh = Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusA
        Remove-Item -LiteralPath $lg -Force -EA SilentlyContinue
        (-not $fresh.Valid) -and ($fresh.Reason -like '*СТАРОЕ глобальное место*')
    }
    T 'Фаза 1 возвращает ХЭШТАБЛИЦУ, а не вывод форматтера' {
        $r = @(Invoke-HandoffPhase -Targets @() -MyPid 0 -TimeoutSec 1)
        ($r.Count -eq 1) -and ($r[0] -is [hashtable])
    }
    T 'Свежесть: ready СТАРШЕ intent -> невалидно' {
        $o = 'selftest-fresh-xyz'
        $sp = Get-ShutdownPaths -BusRoot $sfBusA -Owner $o
        [IO.File]::WriteAllText($sp.Ready, '')
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllText($sp.Intent, '')
        $r = -not (Test-HandoffFlagFresh -Owner $o -BusRoot $sfBusA).Valid
        Remove-Item $sfBusA -Recurse -Force -EA SilentlyContinue
        Remove-Item $sfBusB -Recurse -Force -EA SilentlyContinue
        $r
    }
    T 'Get-Descendants находит мой powershell под моим claude' {
        $mc = Get-MyClaudePid
        if (-not $mc) { return $true }
        ((Get-Descendants -RootPid $mc).ProcessId) -contains $PID
    }
    T 'Get-Descendants пусто для несуществующего pid' { @(Get-Descendants -RootPid 999999).Count -eq 0 }
    T 'Get-LauncherCmdPid: $null на несуществующий pid' { $null -eq (Get-LauncherCmdPid -ClaudePid 999999) }
    T 'Resolve-TargetPid: по Name (как метрика) находит живой PID' {
        $mc = Get-MyClaudePid
        $myTitle = @(Get-CtxMap | Where-Object { $_.Owner -eq $env:AGENT_OWNER })[0].Name
        if (-not $myTitle -or -not $mc) { return $true }
        # объект как метрика-цель: есть Name, НЕТ KnownPid, session_id намеренно битый (как рассинхрон uuid).
        # PoolCwd пустой = скоуп не задан (я запущен не пулом, ancestry моего launcher.bat корня не даёт).
        $fake = [pscustomobject]@{ Name = $myTitle; SessionId = 'bad-uuid-mismatch'; PoolCwd = '' }
        (Resolve-TargetPid $fake) -eq $mc
    }
    # КОНТРАКТ (2026-07-27): цель ОБЯЗАНА нести PoolCwd. Прежде тут стоял guard-фолбэк на $t.Cwd, и
    # цель без свойства молча резолвилась по ДРЕЙФУЮЩЕМУ cwd агента. Теперь это громкий бросок.
    T 'Resolve-TargetPid: цель без PoolCwd -> бросок, а не молчаливый фолбэк' {
        try { [void](Resolve-TargetPid ([pscustomobject]@{ Name = 'NoSuchTitleXYZ-42'; SessionId = 'nope' })); return $false }
        catch { return $true }
    }
    T 'Resolve-TargetPid: KnownPid имеет приоритет' {
        (Resolve-TargetPid ([pscustomobject]@{ Name='x'; SessionId='y'; KnownPid=424242 })) -eq 424242
    }
    # ---- резолв по титулу, когда происхождение не определяется ------------------------------------
    # Обёртка Launcher'а лежит ВНЕ каталога пула, поэтому ancestry не даёт корня, и скоуп молча
    # отбрасывал ЖИВУЮ сессию: гашение пула обходило роль с текстом «процесс не найден». Кэш живых
    # сессий подменяем — так правило проверяется без живых процессов.
    $savedCache = $script:LiveSessionsCache
    try {
        $script:LiveSessionsCache = @(
            [pscustomobject]@{ Pid = 111; Token = 'Solo'; SessionId = ''; Title = 'Solo'; Root = '' }
        )
        T 'резолв по титулу: происхождение не определилось, кандидат один -> нашли' {
            (Resolve-LiveByTitle -Title 'Solo' -PoolRoot 'C:\workspace-root\.launcher').Pid -eq 111
        }
        $script:LiveSessionsCache = @(
            [pscustomobject]@{ Pid = 111; Token = 'Twin'; SessionId = ''; Title = 'Twin'; Root = '' },
            [pscustomobject]@{ Pid = 222; Token = 'Twin'; SessionId = ''; Title = 'Twin'; Root = '' }
        )
        T 'резолв по титулу: два кандидата -> отказ (риск чужой сессии важнее удобства)' {
            $null -eq (Resolve-LiveByTitle -Title 'Twin' -PoolRoot 'C:\workspace-root\.launcher')
        }
        $script:LiveSessionsCache = @(
            [pscustomobject]@{ Pid = 333; Token = 'Alien'; SessionId = ''; Title = 'Alien'; Root = 'C:\workspace-root\other-pool' }
        )
        T 'резолв по титулу: происхождение ОПРЕДЕЛИЛОСЬ и оно чужое -> отказ' {
            $null -eq (Resolve-LiveByTitle -Title 'Alien' -PoolRoot 'C:\workspace-root\.launcher')
        }
        $script:LiveSessionsCache = @(
            [pscustomobject]@{ Pid = 444; Token = 'Mine'; SessionId = ''; Title = 'Mine'; Root = 'C:\workspace-root\.launcher' }
        )
        T 'резолв по титулу: происхождение под корнем пула -> прежнее поведение' {
            (Resolve-LiveByTitle -Title 'Mine' -PoolRoot 'C:\workspace-root\.launcher').Pid -eq 444
        }
        T 'резолв по титулу: без PoolRoot фолбэк не нужен и не мешает' {
            (Resolve-LiveByTitle -Title 'Mine' -PoolRoot '').Pid -eq 444
        }
    } finally { $script:LiveSessionsCache = $savedCache }
    # Якорь ASCII намеренно: текст команды русский, а чтение файла без явной кодировки в PS 5.1 даёт
    # cp1251-мохибаке — кириллический якорь давал бы ложный отказ на целом файле. Слова «handoff» в
    # каноне больше нет вовсе: команда переписана на долговременную память.
    T 'Get-CommandText читает канонический handoff-myself' {
        $t = Get-CommandText -Name 'handoff-myself'
        $t -and $t.Length -gt 200 -and $t.Contains('MEMORY.md') -and $t.Contains('.memory')
    }
    T 'Get-CommandText: $null на несуществующую команду' { $null -eq (Get-CommandText -Name 'no-such-command-xyz-42') }
    T 'Get-CommandText: project-local имеет приоритет над глобальной' {
        $tmp = Join-Path $script:ControlDir '..\_cmdtest'   # временный project-root в .claude
        $cmdDir = Join-Path $tmp '.claude\commands'
        New-Item -ItemType Directory -Force -Path $cmdDir | Out-Null
        [IO.File]::WriteAllText((Join-Path $cmdDir 'handoff-myself.md'), 'LOCAL-OVERRIDE-MARKER')
        $r = (Get-CommandText -Name 'handoff-myself' -ProjectRoot $tmp) -eq 'LOCAL-OVERRIDE-MARKER'
        Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
        $r
    }
    T 'pool.ps1 рядом (для отправки задач)' { Test-Path (Join-Path $PSScriptRoot 'pool.ps1') }
    # ПУНКТ — уборка осиротевших shutdown-сообщений (landmine-баг 2026-07-20: убитый до claim агент
    # оставлял from-pool-controller в new/, перевыстрел при следующем запуске пула)
    T 'Clear-ShutdownLandmines: осиротевшее pool-controller из new/ вычищено, чужое НЕ тронуто' {
        $tmpbus = Join-Path $script:ControlDir ('..\_landmine_test_{0}' -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        try {
            $newDir = Join-Path $tmpbus 'sttest\new'
            New-Item -ItemType Directory -Force -Path $newDir | Out-Null
            $uid = '{0}-{1}' -f [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(), ([guid]::NewGuid().ToString('N').Substring(0,10))
            [IO.File]::WriteAllText((Join-Path $newDir ("$uid.from-pool-controller.coord.md")), 'ЗАВЕРШЕНИЕ (тест)')
            [IO.File]::WriteAllText((Join-Path $newDir ("$uid-x.from-methodist.coord.md")), 'обычная — не трогать')
            $n = Clear-ShutdownLandmines -BusRoot $tmpbus -Owner 'sttest'
            $left = @(Get-ChildItem -Path $newDir -Filter '*.md' -File -EA SilentlyContinue)
            ($n -eq 1) -and ($left.Count -eq 1) -and ($left[0].Name -like '*from-methodist*')
        } finally {
            Remove-Item $tmpbus -Recurse -Force -EA SilentlyContinue
        }
    }

    T 'Close-PoolWarpWindow: несуществующий слаг -> 0, без падения' {
        (Close-PoolWarpWindow -Slug ('nopool-' + [guid]::NewGuid().ToString('N'))) -eq 0
    }

    T 'Merge-DuplicateTargets: дубли по owner -> 1 (макс ctx), solo не тронут' {
        $dup = @(
            [pscustomobject]@{ Owner='dupz'; Name='X'; Pct=10; KnownPid=999999901 }
            [pscustomobject]@{ Owner='dupz'; Name='X'; Pct=50; KnownPid=999999901 }
            [pscustomobject]@{ Owner='solo'; Name='Y'; Pct=20; KnownPid=999999902 }
        )
        $m  = @(Merge-DuplicateTargets -Targets $dup)
        $dz = @($m | Where-Object { $_.Owner -eq 'dupz' })
        ($m.Count -eq 2) -and ($dz.Count -eq 1) -and ($dz[0].Pct -eq 50)
    }

    T 'Stop-SurvivorSession: несуществующие имя+uuid -> 0, без падения' {
        (Stop-SurvivorSession -Name ('nosess-' + [guid]::NewGuid().ToString('N')) -PoolRoot 'C:\workspace-root\pool-b' -SessionId ([guid]::NewGuid().ToString())) -eq 0
    }

    # ---- -Recharge ----
    # Контракт результата компакта проверяется ИМЕННО на отказе: перезарядка читает Uuid/Transcript/
    # Landed уже ПОСЛЕ убийства роли, и отсутствующее поле под StrictMode уронило бы её в тот момент,
    # когда роль погашена, а поднимать её уже некому.
    T 'New-CompactResult: контракт полей полон и на отказе' {
        $r = New-CompactResult -Ok $false -Msg 'x'
        $n = $r.PSObject.Properties.Name
        ($n -contains 'Ok') -and ($n -contains 'Msg') -and ($n -contains 'Uuid') -and ($n -contains 'Transcript') -and ($n -contains 'Landed') -and (-not $r.Landed)
    }

    T 'Invoke-HeadlessCompact: несуществующий cwd -> отказ С ПОЛЯМИ, без падения' {
        $r = Invoke-HeadlessCompact -SessionTitle 'nope' -Cwd 'Z:\nope-recharge' -Owner 'nobody'
        (-not $r.Ok) -and ($r.PSObject.Properties.Name -contains 'Transcript') -and ($r.Uuid -eq '')
    }

    T 'Start-RoleWrapper: обёртки нет -> отказ, без падения и без запуска' {
        $r = Start-RoleWrapper -BatPath (Join-Path $env:TEMP ('no-such-wrapper-' + [guid]::NewGuid().ToString('N') + '.bat'))
        (-not $r.Ok) -and ($r.ProcessId -eq 0) -and ($r.Msg -match 'не найдена')
    }

    T 'Start-RoleWrapper: пустой путь -> отказ (а не запуск cmd без аргументов)' {
        $r = Start-RoleWrapper -BatPath ''
        (-not $r.Ok) -and ($r.ProcessId -eq 0)
    }

    # Обе проверки бьют по СБРОСУ КЭША, а не по «вернуло пусто»: кэш живых сессий заполняется ДО
    # убийства, и без сброса убитая роль осталась бы в нём «живой». Тогда проверка выживших запретила
    # бы подъём навсегда, а ожидание подъёма рапортовало бы успех мгновенно — оба отказа молчаливые.
    # Подсовываем в кэш призрака с искомым титулом: сбрасывают — его не видно, не сбрасывают — виден.
    T 'Get-SurvivingSessionPids: СБРАСЫВАЕТ кэш живых (призрак из кэша не считается выжившим)' {
        $t = 'ghost-title-' + [guid]::NewGuid().ToString('N')
        $script:LiveSessionsCache = @([pscustomobject]@{ Pid = 999999902; Token = $t; SessionId = ''; Title = $t; Root = 'C:\workspace-root\.launcher' })
        $r = @(Get-SurvivingSessionPids -Title $t -PoolRoot 'C:\workspace-root\.launcher')
        $script:LiveSessionsCache = $null
        $r.Count -eq 0
    }

    T 'Wait-RoleAlive: не верит СТАРОМУ кэшу и не виснет (призрак -> 0 по таймауту)' {
        $t = 'ghost-title-' + [guid]::NewGuid().ToString('N')
        $script:LiveSessionsCache = @([pscustomobject]@{ Pid = 999999903; Token = $t; SessionId = ''; Title = $t; Root = 'C:\workspace-root\.launcher' })
        $r = Wait-RoleAlive -Title $t -PoolRoot 'C:\workspace-root\.launcher' -TimeoutSec 1
        $script:LiveSessionsCache = $null
        $r -eq 0
    }

    Write-Host "`n=== итог: $script:pass ok / $script:fail fail ===" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
    return ($script:fail -eq 0)
}

# ---------------------------------------------------------------- main

if ($SelfTest) { exit ([int](-not (Invoke-SelfTest))) }
if (-not $Pool -and -not $Owner) { throw 'укажи -Pool <slug> или -Owner <owner> (или -SelfTest)' }

# --- диагностический лог: пошагово в файл (%TEMP%\pool-shutdown-<slug>-<pid>.log), чтобы локализовать зависание ---
$logSlug = if ($Pool) { $Pool } elseif ($Owner) { "owner-$Owner" } else { 'run' }
$logSlug = $logSlug -replace '[^0-9A-Za-z\-_]', '_'
try { $script:LogFile = Join-Path $env:TEMP ("pool-shutdown-{0}-{1}.log" -f $logSlug, $PID) } catch { $script:LogFile = $null }
Write-Log "==================== RUN START pid=$PID ===================="
Write-Log ("args: Pool='$Pool' Owner='$Owner' Only='$($Only -join ',')' Full=$Full HandoffOnly=$HandoffOnly KillOnly=$KillOnly CloseWindow=$CloseWindow Force=$Force NoCompact=$NoCompact Threshold=$Threshold WaitHandoffSec=$WaitHandoffSec")

$myClaude = Get-MyClaudePid
Write-Step "мой claude.exe = $myClaude (себя не гашу)"

# --- гард режима перезарядки: несовместимые флаги ловим ДО того, как что-то тронуто ---
if ($Recharge) {
    $bad = @()
    if ($HandoffOnly) { $bad += '-HandoffOnly' }
    if ($KillOnly)    { $bad += '-KillOnly' }
    if ($Full)        { $bad += '-Full' }
    if ($NoCompact)   { $bad += '-NoCompact' }
    if ($bad.Count) {
        # -NoCompact в этом списке НЕ по симметрии: перезарядка существует ради сжатия, и «перезарядить
        # без сжатия» — это просто перезапуск, который человек делает обёрткой сам.
        Write-Err ("-Recharge несовместим с: {0}. Перезарядка — это ОДИН цельный цикл (handoff -> kill -> compact -> подъём), её нельзя собрать из фаз." -f ($bad -join ', '))
        exit 2
    }
    Write-Step 'режим ПЕРЕЗАРЯДКИ: после гашения и сжатия роль будет ПОДНЯТА обратно её обёрткой'
}

# Глобальная сверка полноты: сколько живых claude.exe против сессий с метрикой.
# Не для таргетинга (он scoped), а чтобы оператор видел «слепые» сессии.
$liveAll = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue).Count
$metricN = @(Get-CtxMap).Count
if ($liveAll -gt $metricN) {
    Write-Warn "живых claude.exe=$liveAll, с метрикой=$metricN. Сессии без метрики (idle/до tee) видны только через фолбэк по SessionTitle."
}

$targets = @(Resolve-Targets -PoolSlug $Pool -OwnerName $Owner)
$targets = @(Merge-DuplicateTargets -Targets $targets)   # 1 owner = 1 цель: схлопнуть дубли метрики (фикс фантомного ожидания handoff)
if ($Only -and $Only.Count) {
    $before = $targets.Count
    $targets = @(Select-OnlyOwners -Targets $targets -Only $Only)   # @() — иначе pipeline развернёт массив из 1 в скаляр -> .Count падает под StrictMode
    Write-Step ("-Only: оставлено {0} из {1} целей (роли: {2})" -f $targets.Count, $before, ($Only -join ', '))
}
if (-not $targets.Count) { Write-Warn 'целей нет — выходим'; exit 0 }

# --- гард перезарядки, часть 2: ровно одна цель, чем поднимать — ЗНАЕМ ЗАРАНЕЕ, и это не я ---
$script:RechargeBat = $null
$script:RechargeTarget = $null    # цель, дошедшая до конца цикла живой веткой (её и поднимаем)
$script:RechargeCompact = $null   # результат ожидаемого компакта: Ok/Msg/Landed для отчёта
if ($Recharge) {
    if ($targets.Count -ne 1) {
        Write-Err ("-Recharge берёт РОВНО ОДНУ роль, а целей {0} ({1}). Сузь: -Pool <slug> -Only <owner> либо -Owner <owner>." -f $targets.Count, (($targets | ForEach-Object { $_.Owner }) -join ', '))
        exit 2
    }
    $rt = $targets[0]
    # 🛑 Обёртку проверяем ДО гашения. Проверка после kill была бы бесполезной: роль уже мертва, а
    # поднять её нечем — ровно тот исход, ради которого перезарядку и затевали.
    $rtBatRoot = $(if ($rt.PSObject.Properties.Name -contains 'BatRoot') { [string]$rt.BatRoot } else { '' })
    $rtBatName = $(if ($rt.PSObject.Properties.Name -contains 'Bat')     { [string]$rt.Bat }     else { '' })
    if (-not $rtBatRoot -or -not $rtBatName) {
        Write-Err ("роль '{0}': в манифесте не назван файл обёртки (поле 'bat') — поднимать нечем, перезарядку не начинаю." -f $rt.Owner)
        exit 2
    }
    $script:RechargeBat = Join-Path $rtBatRoot $rtBatName
    if (-not (Test-Path $script:RechargeBat)) {
        Write-Err ("обёртка роли '{0}' не найдена: {1}. Поднимать нечем — перезарядку не начинаю (роль НЕ тронута)." -f $rt.Owner, $script:RechargeBat)
        exit 2
    }
    $rtPid = Resolve-TargetPid $rt
    if ($rtPid -and $rtPid -eq $myClaude) {
        # Существующий путь молча печатает «skip: self» и идёт дальше. Для перезарядки это худший
        # исход: отчёт выглядит успешным, а не произошло НИЧЕГО. Поэтому здесь — громкий отказ.
        Write-Err 'перезарядить САМОГО СЕБЯ нельзя: контроллер не может убить процесс, из которого запущен. Это и есть причина, по которой перезарядку делает сосед по пулу.'
        exit 2
    }
    if (-not $rtPid) {
        Write-Err ("роль '{0}' не запущена (живого процесса нет) — перезаряжать нечего. Если она должна быть жива, это ошибка резолва." -f $rt.Owner)
        exit 2
    }
    # Бьём по cmd-лаунчеру, иначе старое окно останется висеть на `pause` рядом с новым.
    $CloseWindow = $true
    Write-Step ("перезарядка роли '{0}': обёртка {1}; окно будет НОВОЕ (в живую панель терминала вернуть сессию нельзя)" -f $rt.Owner, $script:RechargeBat)
}

Write-Host ""
Write-Step "целей: $($targets.Count) ; порог handoff = $Threshold% ; compact = $(if ($NoCompact) { 'нет' } else { 'да' })"
foreach ($t in $targets) {
    $tp = Resolve-TargetPid $t
    $mark = if ($tp -eq $myClaude) { ' <- Я, пропущу' } elseif (-not $tp) { ' (процесс не найден)' } else { '' }
    $pctStr = if ($null -ne $t.Pct) { "$([math]::Round($t.Pct))%" } else { '?' }
    # Неизвестный ctx -> консервативно handoff (не знаем нагрузку = могли потерять работу).
    # Только известный-и-ниже-порога -> просто гашение.
    $cmpTail = if ($NoCompact) { '' } else { ' + compact' }
    $act = if ($null -eq $t.Pct) { "handoff(ctx?) + гашение$cmpTail" } elseif ($t.Pct -ge $Threshold) { "handoff + гашение$cmpTail" } else { "просто гашение (без handoff/compact)" }
    Write-Host ("  - {0,-22} ctx={1,-5} pid={2,-7} -> {3}{4}" -f $t.Owner, $pctStr, $(if ($tp) { $tp } else { '-' }), $act, $mark)
}

if ($DryRun) {
    $mode = if ($Full) { '-Full БАТЧ (все handoff -> гейт флагов -> все kill+compact; compact детачный)' } elseif ($HandoffOnly) { 'ФАЗА 1 (handoff, без гашения)' } elseif ($KillOnly) { 'ФАЗА 2 (гашение, handoff пропущен)' } else { 'полный цикл per-target' }
    Write-Host "`n[DryRun] режим: $mode. Ничего не трогаю." -ForegroundColor Yellow
    exit 0
}

# ФАЗА 1 — только handoff, гейт перед закрытием.
if ($HandoffOnly) { [void](Invoke-HandoffPhase -Targets $targets -MyPid $myClaude -TimeoutSec $WaitHandoffSec -CommandName $HandoffCommand); exit 0 }

# Подтверждения, увиденные ФАЗОЙ 1 в ЭТОМ процессе. Для них диск не переспрашиваем: ready-флаг к моменту
# Фазы 2 мог быть стёрт хуком из-за системной побудки (см. инварианты у Test-HandoffFlagFresh).
# При голом -KillOnly набор пуст: фаза 1 шла в другом процессе, и истина берётся из защёлки на диске.
$confirmed = @{}

# -Full: ВЕСЬ цикл одним вызовом, БАТЧЕМ (все handoff -> все флаги -> все kill+compact), без человеко-гейта.
# Безопаснее per-target-последовательного: никого не гасим, пока не готовы ВСЕ. Компакты — детач (переживут
# закрытие терминала). Для будущего автономного сервера — этот же кирпич без гейта.
# -Recharge идёт ТЕМ ЖЕ путём, и это не оптимизация, а лечение: intent-метку ставит ТОЛЬКО эта фаза
# (строка `WriteAllText($intent, '')` внутри Invoke-HandoffPhase). Без метки `pool ready` у роли
# отклоняется словами «контроллер не инициировал гашение» — роль честно делает handoff, честно зовёт
# ready, а контроллер ждёт флаг, которого никто не поставит, и уходит в skip по таймауту.
# Поймано песочницей 09.08 на живой учебной роли: 300 с ожидания, в транскрипте роли —
# «Готовность отклонена (нормально, контроллер не инициировал гашение)».
if ($Full -or $Recharge) {
    $confirmed = Invoke-HandoffPhase -Targets $targets -MyPid $myClaude -TimeoutSec $WaitHandoffSec -CommandName $HandoffCommand
    if ($null -eq $confirmed -or $confirmed -isnot [hashtable]) { $confirmed = @{} }   # страховка: фаза 1 могла выйти рано
    Write-Host ""
    Write-Step 'ФАЗА 2 — гашение+compact подтвердивших (после -Full handoff-фазы)...'
    $KillOnly = $true   # дальше main-цикл идёт по свежесть-гейту, как -KillOnly
}

Write-Host ""
$report = @()
# ПУНКТ: intent-метка снимается по ВСЕМ целям прогона, чем бы он ни кончился. Раньше её снимали
# только в ветке успешного гейта -> у пропущенной/не подтвердившей роли она оставалась на диске
# навсегда (найдены метки суточной давности от непогашенных ролей 2026-07-27). Сегодня это лишь
# мусор, но метка -- заявка на состояние «роль закрывается», и любой будущий читатель этой заявки
# получил бы вечно-истинное значение. finally нужен именно потому, что Set-StrictMode + $ErrorAction-
# Preference='Stop' делают бросок посреди цикла вполне вероятным.
try {
foreach ($t in $targets) {
    Write-Host ("--- {0} ---" -f $t.Owner) -ForegroundColor White
    Write-Log ("ITER-BEGIN owner={0}" -f $t.Owner)
    $targetPid = Resolve-TargetPid $t
    Write-Log ("resolved pid={0} owner={1}" -f $(if ($targetPid) { $targetPid } else { '<none>' }), $t.Owner)

    if ($targetPid -and $targetPid -eq $myClaude) {
        Write-Warn 'это я сам — пропускаю (себя контроллер не гасит)'
        $report += [pscustomobject]@{ Owner = $t.Owner; Result = 'skip: self' }
        continue
    }

    $didHandoff = $false
    # Неизвестный ctx (сессия без метрики, поднята фолбэком) -> идём через handoff консервативно.
    # Watcherless-роли (devops/serverside) на bus-задачу не проснутся -> handoff отвалится по таймауту
    # -> без -Force сессия ПЕРЕЖИВЁТ (это безопаснее, чем убить без handoff); с -Force гасим всё равно.
    $needHandoff = ($null -eq $t.Pct) -or ($t.Pct -ge $Threshold)
    $lightClose  = Test-LightClose $t.Pct $Threshold   # известный ctx < порога -> просто гашение (без handoff/compact)
    $tBus        = Get-BusRoot -BusDir $t.BusDir
    $tSp         = Get-ShutdownPaths -BusRoot $tBus -Owner $t.Owner   # $null, если шины нет

    # ФАЗА 2: handoff уже сделан в фазе 1 -> пропускаем, но проверяем СВЕЖЕСТЬ флага (пункт 2).
    if ($KillOnly) {
        if ($lightClose) {
            Write-Step "ctx=$([math]::Round($t.Pct))% < $Threshold% -> лёгкое закрытие (без handoff/compact); гейт свежести пропускаю, гашу"
        }
        elseif ($confirmed.ContainsKey($t.Owner)) {
            # Фаза 1 этого же процесса видела готовность своими глазами. Диск НЕ переспрашиваем: к этому
            # моменту ready-флаг мог быть стёрт хуком из-за нотификации о завершении фоновой задачи —
            # именно так терялись operator/<pool-a> и methodist/<pool-b>.
            Write-Step "handoff $($t.Owner): подтверждён в Фазе 1 ($($confirmed[$t.Owner]) с) — гейт не переспрашиваю"
            if ($tSp) { Remove-Item $tSp.Ready -Force -ErrorAction SilentlyContinue; Remove-Item $tSp.Intent -Force -ErrorAction SilentlyContinue }
        }
        else {
            $fresh = Test-HandoffFlagFresh -Owner $t.Owner -BusRoot $tBus
            if ($fresh.Valid) {
                Write-Step "handoff-флаг $($t.Owner): $($fresh.Reason) — фаза 1 подтверждена"
                if ($tSp) { Remove-Item $tSp.Ready -Force -ErrorAction SilentlyContinue; Remove-Item $tSp.Intent -Force -ErrorAction SilentlyContinue }
            }
            elseif (-not $Force) {
                Write-Warn "handoff-флаг $($t.Owner) НЕвалиден: $($fresh.Reason). Пропускаю (нужен -Force, чтобы гасить всё равно)"
                $report += [pscustomobject]@{ Owner = $t.Owner; Result = "skip: $($fresh.Reason)" }
                continue
            } else { Write-Warn "handoff-флаг $($t.Owner) НЕвалиден ($($fresh.Reason)), но -Force — гашу" }
        }
        $needHandoff = $false
    }

    if ($needHandoff -and $targetPid) {
        $bus = $tBus
        if (-not $bus -or -not $tSp) {
            Write-Warn "шины нет ($($t.BusDir)) — handoff через шину невозможен, гашу без него"
        } else {
            $flag = $tSp.Ready
            if (Test-Path $flag) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
            Write-Step "ctx=$([math]::Round($t.Pct))% >= $Threshold% -> задача «заверши работу» в шину ($bus)"
            $snd = Send-ShutdownTask -BusRoot $bus -TargetOwner $t.Owner -FlagPath $flag -ProjectRoot $t.PoolCwd -CommandName $HandoffCommand
            if (-not $snd.Ok) {
                Write-Warn "отправка не удалась: $($snd.Msg)"
            } else {
                Write-Step "жду флаг готовности до $WaitHandoffSec с ..."
                if (Wait-ShutdownFlag -FlagPath $flag -TimeoutSec $WaitHandoffSec -Owner $t.Owner) {
                    Write-Ok 'агент подтвердил handoff'
                    $didHandoff = $true
                    Remove-Item $flag -Force -ErrorAction SilentlyContinue
                } else {
                    Write-Warn 'агент не подтвердил handoff за отведённое время'
                    if (-not $Force) {
                        Write-Warn 'пропускаю сессию (пере запусти с -Force, чтобы гасить всё равно)'
                        $report += [pscustomobject]@{ Owner = $t.Owner; Result = 'skip: no handoff confirm' }
                        continue
                    }
                }
            }
        }
    }

    if ($targetPid) {
        $killPid = $targetPid; $extra = ''
        if ($CloseWindow) {
            $cmdPid = Get-LauncherCmdPid -ClaudePid $targetPid
            Write-Log ("cmdpid={0} owner={1}" -f $(if ($cmdPid) { $cmdPid } else { '<none>' }), $t.Owner)
            if ($cmdPid) { $killPid = $cmdPid; $extra = " (cmd-лаунчер $cmdPid — окно закроется; claude $targetPid внутри)" }
            else { Write-Warn "cmd-лаунчер не найден для $($t.Owner) — гашу дерево claude напрямую (окно останется на pause)" }
        }
        Write-Step "гашу: taskkill /F /T /PID $killPid$extra"
        $k = Stop-SessionTree -TargetPid $killPid
        Start-Sleep -Milliseconds 500
        if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) { Write-Err "сессия claude $targetPid ещё жива"; $report += [pscustomobject]@{ Owner = $t.Owner; Result = 'ERR: claude still alive' }; continue }
        Write-Ok "снято процессов: $($k.Killed); claude $targetPid мёртв$(if($CloseWindow -and $cmdPid){' + окно закрыто'})"
        # E5-регресс: сессия могла ВЫЖИТЬ фоновым агентом демона (taskkill /T больше не чистит всё).
        # Выжившую гасим `claude stop` (снимает лок uuid -> resume-compact ниже отработает). До compact — не самозадеваем.
        try {
            $survSid  = $(if ($t.PSObject.Properties.Name -contains 'SessionId') { $t.SessionId } else { '' })
            # PoolCwd, а не каталог батников: сверяется с `cwd` из `claude agents --json`, а это launch-cwd.
            $sv = Stop-SurvivorSession -Name $t.Name -PoolRoot $t.PoolCwd -SessionId $survSid
            if ($sv) { Write-Step "добито выживших фоновых сессий '$($t.Name)': $sv" }
        } catch { Write-Warn "проверка выжившей сессии '$($t.Name)' не удалась: $($_.Exception.Message)" }
        # Вычистить осиротевшие shutdown-сообщения этого owner из new/: агента убили —
        # незаклеймленная задача «заверши работу» иначе перевыстрелит в следующий запуск пула.
        # try/catch: сбой уборки НЕ должен ронять контроллер после того, как цель уже убита.
        try {
            $busPurge = Get-BusRoot -BusDir $t.BusDir
            if ($busPurge) { [void](Clear-ShutdownLandmines -BusRoot $busPurge -Owner $t.Owner) }
        } catch { Write-Warn "уборка осиротевших shutdown-сообщений $($t.Owner) не удалась: $($_.Exception.Message)" }
    } else {
        # НЕ рапортуем ok: если цель пришла из свежей метрики/манифеста, «нет процесса» = скорее
        # провал резолва, чем «уже выключена». Гасить нечего -> честный skip, не ложный успех.
        Write-Warn "процесс НЕ найден для $($t.Owner) — гасить нечего. Если сессия жива, это ошибка резолва (сообщи)."
        $report += [pscustomobject]@{ Owner = $t.Owner; Result = 'skip: процесс не найден (НЕ гашено)' }
        continue
    }

    # При -Recharge компакт делаем ДАЖЕ на лёгком закрытии: перезарядка затевается ради сжатия, и
    # «роль погашена и поднята с прежним контекстом» — это не перезарядка, а перезапуск.
    if (-not $NoCompact -and (-not $lightClose -or $Recharge)) {
        # compact = resume по ИМЕНИ (новейшая сессия) -> /compact. Каталог — из МАНИФЕСТА, не из
        # дрейфующего cwd агента (projectDir/resume завязаны на launch-cwd).
        # ProjectKey считается из LAUNCH-CWD, а не из каталога батников: для пулов монорепо каталог
        # `~\.claude\projects\D---workspace-<monorepo>-scripts` не существует в природе, и компакт
        # молча не запускался («project-каталог не найден»). PoolCwd даёт настоящий ключ.
        Write-Step "headless compact (resume-by-name '$($t.Name)', cwd=$($t.PoolCwd))"
        if ($Recharge) {
            # ЖДЁМ: подъём поверх ещё пишущего компакта = два процесса на один транскрипт.
            Write-Step "жду завершения компакта до $RechargeWaitCompactSec с (перезарядка: поднимать поверх пишущего компакта нельзя)"
            $c = Invoke-HeadlessCompact -SessionTitle $t.Name -Cwd $t.PoolCwd -Owner $t.Owner -Wait -WaitSec $RechargeWaitCompactSec
            $script:RechargeCompact = $c
            if ($c.Ok) { Write-Ok "compact: $($c.Msg)" } else { Write-Warn "compact НЕ подтверждён: $($c.Msg) — роль всё равно будет поднята (живая с полным контекстом лучше мёртвой)" }
        } else {
            $c = Invoke-HeadlessCompact -SessionTitle $t.Name -Cwd $t.PoolCwd -Owner $t.Owner
            if ($c.Ok) { Write-Ok "compact ЗАПУЩЕН ($($c.Msg)) — детач, допишется даже если закрыть терминал" } else { Write-Warn "compact не запущен: $($c.Msg)" }
        }
    }

    $resLabel = 'ok: ' + $(if ($didHandoff) { 'handoff+' } else { '' }) + 'kill' + $(if ($NoCompact) { '' } else { '+compact' })
    $report += [pscustomobject]@{ Owner = $t.Owner; Result = $resLabel }
    # Цель дошла до конца цикла живой веткой -> её и поднимаем. Сам подъём НЕ здесь: intent-метка
    # снимается в finally ниже, а под ней сторож чата молчит — поднятая раньше роль была бы немой.
    if ($Recharge) { $script:RechargeTarget = $t }
}
}
finally {
    # Ни одна цель этого прогона не должна остаться с висящей intent-меткой — ни пропущенная,
    # ни отвалившаяся по таймауту, ни та, на которой мы упали. Исключение одно: -HandoffOnly,
    # он до сюда не доходит (выходит раньше), и его метка ЖИВЁТ намеренно — она и есть
    # «фаза 1 сделана, ждём -KillOnly».
    foreach ($t in $targets) {
        $fbSp = Get-ShutdownPaths -BusRoot (Get-BusRoot -BusDir $t.BusDir) -Owner $t.Owner
        if ($fbSp) { Remove-Item $fbSp.Intent -Force -ErrorAction SilentlyContinue }
    }
}

# ---------------------------------------------------------------- ПЕРЕЗАРЯДКА: подъём
# Стоит ЗДЕСЬ, после finally, не случайно: именно там снимается intent-метка, а под ней сторож чата
# молчит по карантину гашения. Подъём внутри цикла дал бы ЖИВУЮ, но НЕМУЮ роль — снаружи неотличимо
# от успеха, и владелец писал бы в пустоту.
if ($Recharge -and $script:RechargeTarget) {
    $rc = $script:RechargeTarget
    $rcTitle = $(if (($rc.PSObject.Properties.Name -contains 'BatTitle') -and $rc.BatTitle) { [string]$rc.BatTitle } else { [string]$rc.Name })
    $rcPctBefore = $(if ($null -ne $rc.Pct) { [math]::Round([double]$rc.Pct) } else { $null })
    Write-Host ""
    Write-Step ("ПЕРЕЗАРЯДКА '{0}': роль погашена, поднимаю обратно" -f $rc.Owner)

    # 1. Метка гашения снята? Без этого поднятая роль будет НЕМОЙ (сторож чата под карантином молчит).
    $rcBus = Get-BusRoot -BusDir $rc.BusDir
    $rcSp  = Get-ShutdownPaths -BusRoot $rcBus -Owner $rc.Owner
    $intentLeft = $false
    if ($rcSp) {
        for ($i = 0; $i -lt 3 -and (Test-Path $rcSp.Intent); $i++) {
            Remove-Item $rcSp.Intent -Force -ErrorAction SilentlyContinue
            if (Test-Path $rcSp.Intent) { Start-Sleep -Milliseconds 300 }
        }
        $intentLeft = Test-Path $rcSp.Intent
        if ($intentLeft) {
            Write-Err ("intent-метка НЕ снялась: {0}. Роль поднимется, но её сторож чата будет МОЛЧАТЬ (карантин гашения) — СНИМИ ФАЙЛ РУКАМИ." -f $rcSp.Intent)
        } else {
            Write-Ok 'intent-метка снята — карантин сторожа чата не помешает'
        }
    }

    # 2. Живых сессий с этим титулом остаться не должно: подъём поверх выжившей = ДВА процесса на один
    #    транскрипт. Это единственная причина, по которой мы можем НЕ поднять: мёртвую роль человек
    #    поднимет руками, а слитый транскрипт не чинится ничем.
    $surv = @(Get-SurvivingSessionPids -Title $rcTitle -PoolRoot $rc.PoolCwd)
    if ($surv.Count) {
        Write-Warn ("после гашения ЖИВЫ сессии с титулом '{0}': {1} — добиваю (taskkill /T чистит не всё)" -f $rcTitle, ($surv -join ', '))
        foreach ($sp in $surv) { [void](Stop-SessionTree -TargetPid $sp) }
        $surv = @(Get-SurvivingSessionPids -Title $rcTitle -PoolRoot $rc.PoolCwd)
    }
    if ($surv.Count) {
        Write-Err ("НЕ поднимаю: с титулом '{0}' всё ещё живы {1}. Подъём дал бы два процесса на один транскрипт (слитая история). Разберись с процессами и подними роль обёрткой: {2}" -f $rcTitle, ($surv -join ', '), $script:RechargeBat)
        $report += [pscustomobject]@{ Owner = $rc.Owner; Result = 'ERR: не поднято (выжившие процессы)' }
    }
    else {
        $up = Start-RoleWrapper -BatPath $script:RechargeBat
        if (-not $up.Ok) {
            Write-Err ("подъём НЕ удался: {0}. Роль погашена и НЕ поднята — подними обёрткой руками: {1}" -f $up.Msg, $script:RechargeBat)
            $report += [pscustomobject]@{ Owner = $rc.Owner; Result = 'ERR: не поднято (' + $up.Msg + ')' }
        } else {
            Write-Ok ("обёртка запущена: {0}" -f $up.Msg)
            $newPid = Wait-RoleAlive -Title $rcTitle -PoolRoot $rc.PoolCwd -TimeoutSec 180
            if (-not $newPid) {
                Write-Err ("роль '{0}' за 180 с не появилась среди живых сессий. Окно могло открыться с ошибкой — посмотри его." -f $rc.Owner)
                $report += [pscustomobject]@{ Owner = $rc.Owner; Result = 'ERR: поднято, но сессия не поднялась' }
            } else {
                Write-Ok ("роль ЖИВА: pid={0}, титул '{1}'" -f $newPid, $rcTitle)
                # ctx% после — МЯГКО: метрика пишется статус-лайном на ходах агента, а роль только
                # что стартовала и хода могла ещё не сделать. Отсутствие цифры не делает операцию
                # неуспешной, но и молчать о ней нельзя — иначе «сжали» и «не сжали» неразличимы.
                $pctAfter = $null
                $ctxDeadline = (Get-Date).AddSeconds(90)
                while ((Get-Date) -lt $ctxDeadline) {
                    $m = @(Get-CtxMap | Where-Object { $_.Owner -eq $rc.Owner -and $null -ne $_.Pct -and $null -ne $_.AgeSec -and $_.AgeSec -le 180 })
                    if ($m.Count) { $pctAfter = [math]::Round([double]$m[0].Pct); break }
                    Start-Sleep -Seconds 5
                }
                $landed = $(if ($script:RechargeCompact -and $script:RechargeCompact.Landed) { 'да' } else { 'НЕТ' })
                $beforeTxt = $(if ($null -ne $rcPctBefore) { "$rcPctBefore%" } else { '?' })
                $afterTxt  = $(if ($null -ne $pctAfter) { "$pctAfter%" } else { 'пока нет метрики (роль ещё не ходила)' })
                Write-Host ""
                Write-Step ("ИТОГ ПЕРЕЗАРЯДКИ '{0}': сжатие село: {1} | ctx было {2} -> стало {3} | pid={4}" -f $rc.Owner, $landed, $beforeTxt, $afterTxt, $newPid)
                if ($landed -eq 'НЕТ') { Write-Warn 'роль поднята БЕЗ подтверждённого сжатия — это НЕ успех операции, а спасение роли. Контекст мог остаться прежним.' }
                if ($intentLeft) { Write-Warn 'напоминание: intent-метка осталась — сторож чата роли молчит, пока файл на месте.' }
                Write-Host "[shutdown] приёмку даёт РОЛЬ, не контроллер: письмо в шину (техническая) + сообщение владельцу в мост (человеческая)." -ForegroundColor DarkGray
                $report += [pscustomobject]@{ Owner = $rc.Owner; Result = ("ok: recharged (сжатие: {0}, ctx {1} -> {2})" -f $landed, $beforeTxt, $afterTxt) }
            }
        }
    }
}

# --- Закрыть осиротевшее окно Warp пула (все панели уже погашены) ---
# Warp оставляет ПУСТОЕ окно после жёсткого килла панелей (warp.exe — один процесс на все окна,
# закрыть можно только WM_CLOSE по HWND). Закрываем окно по ТОЧНОМУ заголовку == слаг.
# Условия: whole-pool (-Pool задан, без -Owner/-Only) И -CloseWindow. Гард живости: если хоть одна
# панель ещё РЕАЛЬНО жива (напр. -Full без -Force не гасил неподтвердивших) — окно НЕ трогаем.
# ВАЖНО: снять кэш живых сессий (снят в preview ДО убийств) и проверять Get-Process -Id по-настоящему,
# иначе Resolve-TargetPid вернёт устаревшие/KnownPid как «живые» и окно не закроется никогда.
# -Recharge исключён: он ставит $CloseWindow сам (бить по cmd-лаунчеру), но закрывать ОКНО ПУЛА при
# перезарядке одной роли нечего — соседи в нём живы.
if ($CloseWindow -and $Pool -and -not $Owner -and -not $Recharge -and -not ($Only -and $Only.Count)) {
    try {
        $script:LiveSessionsCache = $null
        $aliveLeft = @($targets | Where-Object {
            $rp = Resolve-TargetPid $_
            $rp -and ($rp -ne $myClaude) -and (Get-Process -Id $rp -ErrorAction SilentlyContinue)
        })
        if ($aliveLeft.Count) {
            Write-Warn ("окно Warp пула '$Pool' НЕ закрываю — ещё живы панели: {0}" -f (($aliveLeft | ForEach-Object { $_.Owner }) -join ', '))
        } else {
            $wc = Close-PoolWarpWindow -Slug $Pool
            if ($wc -gt 0) { Write-Ok "закрыто осиротевших окон Warp пула '$Pool': $wc" }
            else { Write-Step "окно Warp пула '$Pool' не найдено/не закрылось (уже закрыто или промпт Warp)" }
        }
    } catch { Write-Warn "закрытие окна Warp пула '$Pool' пропущено (ошибка): $($_.Exception.Message)" }
}

Write-Host "`n=== ИТОГ ===" -ForegroundColor Cyan
$report | Format-Table -AutoSize
