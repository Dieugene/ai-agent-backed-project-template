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
.PARAMETER SelfTest
    Прогнать внутренние проверки.

.EXAMPLE
    .\pool-shutdown.ps1 -Pool <pool-name> -DryRun
.EXAMPLE
    .\pool-shutdown.ps1 -Owner <owner>
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
    [switch]$DryRun,
    [Parameter(ParameterSetName = 'SelfTest')][switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$script:ControlDir  = Join-Path $env:USERPROFILE '.claude\.control'
$script:WorkspaceRoot = '<workspace-root>'
$script:LiveSessionsCache = $null

function Write-Step { param([string]$Msg) Write-Host "[shutdown] $Msg" -ForegroundColor Cyan }
function Write-Warn { param([string]$Msg) Write-Host "[shutdown] WARN: $Msg" -ForegroundColor Yellow }
function Write-Ok   { param([string]$Msg) Write-Host "[shutdown] OK: $Msg" -ForegroundColor Green }
function Write-Err  { param([string]$Msg) Write-Host "[shutdown] ERR: $Msg" -ForegroundColor Red }

# ---------------------------------------------------------------- метрика контекста

<#
    Карта живых сессий из tee-метрики статус-лайна.
    Файл на сессию: ~/.claude/.control/ctx-<session_id>.json — содержит session_id,
    session_name, cwd, agent_owner, context_window.used_percentage, stamped_at.
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
   (lead/operator/builder есть и у <pool-name>, и у <other-pool> — баг 2026-07-18: -Pool хватал чужой пул). #>
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

<# SessionTitle роли из её wrapper'а (.bat): строка -SessionTitle "X". #>
function Get-SessionTitleFromBat {
    param([string]$PoolRoot, [string]$BatName)
    if (-not $BatName) { return $null }
    $bat = Join-Path $PoolRoot $BatName
    if (-not (Test-Path $bat)) { return $null }
    try { $txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($bat)) } catch { return $null }
    $m = [regex]::Match($txt, '-SessionTitle\s+"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
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
    (пул-вотчер `pool.ps1 watch` + Telegram `chat_sentinel.py`), claude оставить ЖИВЫМ.
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
        if ($cl -match 'pool\.ps1.*\bwatch\b') { Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue; $stopped += "вотчер($($d.ProcessId))" }
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
    транскриптами резолвится в UUID без живого процесса (баг 2026-07-17: у <pool-name>
    два '<session-title>', свежий транскрипт без процесса). Кэш на прогон.
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
    # -PoolRoot задан -> берём только сессию, чей корень ПОД этим пулом (разводит одинаковые титулы
    # разных пулов). Не задан -> прежнее поведение (первый по титулу) для обратной совместимости.
    param([string]$Title, [string]$PoolRoot)
    if (-not $Title) { return $null }
    $hit = @(Get-LiveSessions | Where-Object { $_.Title -eq $Title -and (-not $PoolRoot -or (Test-CwdUnderRoot $_.Root $PoolRoot)) })
    if ($hit.Count) { return [pscustomobject]@{ Pid = $hit[0].Pid; SessionId = $hit[0].SessionId } }
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
    # Скоуп по корню пула: одинаковый SessionTitle двух ЖИВЫХ пулов иначе дал бы чужой PID -> taskkill не того (баг 2026-07-18).
    $poolRoot = if (($T.PSObject.Properties.Name -contains 'PoolRoot') -and $T.PoolRoot) { $T.PoolRoot } else { $null }
    if ($T.Name) { $r = Resolve-LiveByTitle -Title $T.Name -PoolRoot $poolRoot; if ($r) { return [int]$r.Pid } }
    return (Get-SessionPid -SessionId $T.SessionId -Title $T.Name -PoolRoot $poolRoot)
}

<#
    PID живой сессии. Ищем claude.exe, у которого в CommandLine есть session_id
    (пулы: pool-launch.ps1 резолвит title -> UUID и делает --resume <UUID>)
    либо SessionTitle (роли вроде Launcher, чей wrapper делает --resume <Title>).
#>
function Get-SessionPid {
    param([string]$SessionId, [string]$Title, [string]$PoolRoot)
    $procs = Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if (-not $p.CommandLine) { continue }
        if ($SessionId -and $p.CommandLine -like "*$SessionId*") { return [int]$p.ProcessId }   # uuid глобально уникален — pool-safe
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
    $out = & taskkill.exe '/F' '/T' '/PID' $TargetPid 2>&1
    $killed = @($out | Select-String -Pattern 'SUCCESS' -SimpleMatch).Count
    Start-Sleep -Seconds 3
    $alive = [bool](Get-Process -Id $TargetPid -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Killed = $killed; StillAlive = $alive; Raw = ($out -join ' ') }
}

# ---------------------------------------------------------------- headless compact

<#
    Headless compact над ОСТАНОВЛЕННОЙ сессией [E1].
    Критично: из PowerShell (Git Bash ломает "/compact" в путь) и cwd = каталог проекта.
#>
function Invoke-HeadlessCompact {
    param([string]$SessionTitle, [string]$Cwd)
    if (-not (Test-Path $Cwd)) { return [pscustomobject]@{ Ok = $false; Msg = "cwd не существует: $Cwd" } }
    $claudeExe = Join-Path $env:APPDATA 'npm\node_modules\@anthropic-ai\claude-code\bin\claude.exe'
    if (-not (Test-Path $claudeExe)) { $g = Get-Command claude -ErrorAction SilentlyContinue; if ($g) { $claudeExe = $g.Source } }
    if (-not $claudeExe -or -not (Test-Path $claudeExe)) { return [pscustomobject]@{ Ok = $false; Msg = 'claude.exe не найден' } }
    # Резолв ИМЕНИ -> НОВЕЙШАЯ сессия (=активная), как враппер. headless `--resume <name>` при неоднозначности
    # падает (нет пикера), поэтому резолвим uuid сами. НЕ по метрике (дрейфует), НЕ по launch-uuid.
    $pk = ($Cwd -replace '[:\\]', '-') -replace '_', '-'                       # ProjectKey из cwd
    $projectDir = Join-Path $env:USERPROFILE ".claude\projects\$pk"
    if (-not (Test-Path $projectDir)) { return [pscustomobject]@{ Ok = $false; Msg = "project-каталог не найден: $projectDir" } }
    $uuid = Find-SessionIdByTitle -Title $SessionTitle -Dir $projectDir
    if (-not $uuid) { return [pscustomobject]@{ Ok = $false; Msg = "сессия '$SessionTitle' не найдена в $pk" } }
    # ДЕТАЧ через WMI: compact переживает закрытие терминала (родитель WmiPrvSE, вне job окна) — можно
    # закрыть Warp после фазы kill. .bat + stdin из NUL (иначе headless claude виснет на stdin — баг
    # канарейки 2026-07-18). Fire-and-forget: не ждём завершения.
    $stamp = ($SessionTitle -replace '[^0-9a-zA-Z]', '')
    $batPath = Join-Path $env:TEMP "poolcompact-$stamp.bat"
    $outPath = Join-Path $env:TEMP "poolcompact-$stamp.out"
    # Информативное окно (2b): заголовок + баннер, чтобы задетаченный compact не выглядел «пустым терминалом».
    # Баннер ASCII (файл пишется в ASCII; кириллица в cmd echo хрупкая). Вывод claude уходит в файл.
    $bannerTitle = "[pool-compact] $SessionTitle"
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
        "`"$claudeExe`" --resume $uuid --dangerously-skip-permissions -p `"/compact`" < NUL > `"$outPath`" 2>&1"
    )
    $batContent = ($batLines -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($batPath, $batContent, [System.Text.Encoding]::ASCII)
    try {
        $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "cmd.exe /c `"$batPath`"" }
        if ($res.ReturnValue -eq 0) { return [pscustomobject]@{ Ok = $true; Msg = "detached pid=$($res.ProcessId) resume=$($uuid.Substring(0,8))" } }
        return [pscustomobject]@{ Ok = $false; Msg = "WMI Create rc=$($res.ReturnValue)" }
    } catch {
        return [pscustomobject]@{ Ok = $false; Msg = $_.Exception.Message }
    }
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

function Get-BusRoot {
    param([string]$PoolRoot)
    $bus = Join-Path $PoolRoot '.bus'
    if (Test-Path $bus) { return $bus }
    return $null
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
ЗАВЕРШЕНИЕ РАБОТЫ (команда внешнего контроллера). Это CHECKPOINT-HANDOFF: твоя сессия будет
остановлена (позже, отдельной командой). Подготовь передачу для будущего себя, который возобновит
работу с этого места.

$instrBlock

Дополнительно к инструкции команды:
- Недавние директивы/вводные пользователя сохрани в handoff ДОСЛОВНО (не только пересказом) — они
  критичны и легко теряются при сжатии.
- Верни в шину claimed-задачи, которые не доделал (подхватят после перезапуска).
- Отметь готовность — создай пустой файл-флаг (ПРЯМЫЕ слэши):
   PowerShell:  New-Item -ItemType File -Force -Path '$flagFwd' | Out-Null
   (или bash:   touch '$flagFwd')

После флага не начинай новых дел — сессия будет закрыта.
"@
    try {
        $out = & $poolPs1 send -BusRoot $BusRoot -To $TargetOwner -From 'pool-controller' -Subject 'Завершение работы: handoff + флаг' -Body $body 2>&1
        $outStr = ($out | Out-String).Trim()
        # успех: pool.ps1 send возвращает id вида 1784302131142-f6209d942a
        if ($outStr -match '\d{10,}-[0-9a-fA-F]+') { return [pscustomobject]@{ Ok = $true; Msg = $outStr } }
        return [pscustomobject]@{ Ok = $false; Msg = $outStr }
    } catch {
        return [pscustomobject]@{ Ok = $false; Msg = $_.Exception.Message }
    }
}

<#
    ПУНКТ 2 — свежесть флага готовности. Валиден ТОЛЬКО если ready-флаг новее intent-метки,
    которую пишет Фаза 1 перед отправкой. Ловит: (а) флаг из прошлого цикла/после рестарта
    (нет свежего intent или ready старше него); (б) агент поработал после handoff (item 1 —
    хук UserPromptSubmit — уже стёр ready -> сюда придём с «нет ready-флага»).
#>
function Test-HandoffFlagFresh {
    param([string]$Owner)
    $flag   = Join-Path $script:ControlDir ("shutdown-ready-{0}"  -f $Owner)
    $intent = Join-Path $script:ControlDir ("shutdown-intent-{0}" -f $Owner)
    if (-not (Test-Path $flag))   { return [pscustomobject]@{ Valid = $false; Reason = 'нет ready-флага (агент не подтвердил, либо поработал после handoff -> хук стёр)' } }
    if (-not (Test-Path $intent)) { return [pscustomobject]@{ Valid = $false; Reason = 'нет intent-метки Фазы 1 (флаг не из этого цикла завершения)' } }
    if ((Get-Item $flag).LastWriteTime -lt (Get-Item $intent).LastWriteTime) { return [pscustomobject]@{ Valid = $false; Reason = 'ready СТАРШЕ Фазы 1 (протух)' } }
    return [pscustomobject]@{ Valid = $true; Reason = 'свежий (новее Фазы 1)' }
}

function Wait-ShutdownFlag {
    param([string]$FlagPath, [int]$TimeoutSec)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path $FlagPath) { return $true }
        Start-Sleep -Seconds 5
    }
    return $false
}

<# Handoff-файл роли (для верификации, что handoff реально записался). Best-effort. #>
function Find-HandoffFile {
    param([string]$PoolRoot, [string]$Owner)
    $cand = Get-ChildItem -Path $PoolRoot -Recurse -Filter "_handoff_$Owner.md" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cand) { return [pscustomobject]@{ Path = $cand.FullName; Mtime = $cand.LastWriteTime } }
    return $null
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
        $poolRoot = if ($t.PSObject.Properties.Name -contains 'PoolRoot') { $t.PoolRoot } else { $t.Cwd }
        $bus = Get-BusRoot -PoolRoot $poolRoot
        if (-not $bus) { Write-Warn "$($t.Owner): шины нет ($poolRoot) — пропускаю"; continue }
        $flag = Join-Path $script:ControlDir ("shutdown-ready-{0}" -f $t.Owner)
        if (Test-Path $flag) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
        # ПУНКТ 2: intent-метка = «момент Фазы 1». Ready валиден в -KillOnly только если новее её.
        $intent = Join-Path $script:ControlDir ("shutdown-intent-{0}" -f $t.Owner)
        try { [System.IO.File]::WriteAllText($intent, '') } catch { }
        $hf = Find-HandoffFile -PoolRoot $poolRoot -Owner $t.Owner
        $snd = Send-ShutdownTask -BusRoot $bus -TargetOwner $t.Owner -FlagPath $flag -ProjectRoot $poolRoot -CommandName $CommandName
        if (-not $snd.Ok) { Write-Warn "$($t.Owner): отправка не удалась: $($snd.Msg)"; continue }
        Write-Ok "$($t.Owner): задача отправлена -> $bus"
        $pending += [pscustomobject]@{ Owner = $t.Owner; Flag = $flag; Pid = $tp; HFPath = $(if ($hf) { $hf.Path } else { $null }); HFBefore = $(if ($hf) { $hf.Mtime } else { $null }); Sent = (Get-Date) }
    }
    if (-not $pending.Count) { Write-Warn 'никому не отправлено — целей с живым процессом и шиной нет'; return }

    Write-Step "жду флаги готовности от $($pending.Count) агентов (до $TimeoutSec с, опрос каждые 5 с)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $done = @{}
    while ((Get-Date) -lt $deadline -and $done.Count -lt $pending.Count) {
        foreach ($p in $pending) {
            if ($done.ContainsKey($p.Owner)) { continue }
            if (Test-Path $p.Flag) { $el = [int]((Get-Date) - $p.Sent).TotalSeconds; $done[$p.Owner] = $el; Write-Ok "$($p.Owner): ГОТОВ ($el с)" }
        }
        if ($done.Count -lt $pending.Count) { Start-Sleep -Seconds 5 }
    }

    # ПУНКТ 3 — запечатать ПОДТВЕРДИВШИХ (опционально, -Seal). Стабилизирует «готов» на время гейта.
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
    foreach ($p in $pending) {
        $ok = $done.ContainsKey($p.Owner)
        $hfCh = '?'
        if ($p.HFPath -and (Test-Path $p.HFPath)) { $hfCh = if ((Get-Item $p.HFPath).LastWriteTime -ne $p.HFBefore) { 'да' } else { 'НЕТ(!)' } }
        $rows += [pscustomobject]@{ Owner = $p.Owner; Готов = $(if ($ok) { "да ($($done[$p.Owner])с)" } else { 'ТАЙМАУТ' }); 'handoff-файл обновлён' = $hfCh }
    }
    $rows | Format-Table -AutoSize
    if ($done.Count -eq $pending.Count) {
        Write-Ok "ВСЕ $($pending.Count) агентов завершили handoff. Флаги на месте. По твоей команде: pool-shutdown.ps1 -Pool <slug> -KillOnly"
    } else {
        Write-Warn "подтвердили $($done.Count)/$($pending.Count). НЕ закрывать, пока не разобрались с отставшими."
    }
}

# ---------------------------------------------------------------- цели

function Get-PoolManifest {
    param([string]$Slug)
    $found = Get-ChildItem -Path $script:WorkspaceRoot -Recurse -Filter 'pool.manifest.json' -Depth 3 -ErrorAction SilentlyContinue
    foreach ($f in $found) {
        try { $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ($j.slug -eq $Slug) { return $j }
    }
    return $null
}

<# Манифест + роль по owner'у (для -Owner фолбэка на сессию без метрики). #>
function Find-RoleByOwner {
    param([string]$OwnerName)
    $found = Get-ChildItem -Path $script:WorkspaceRoot -Recurse -Filter 'pool.manifest.json' -Depth 3 -ErrorAction SilentlyContinue
    foreach ($f in $found) {
        try { $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($r in $j.roles) { if ($r.owner -eq $OwnerName) { return [pscustomobject]@{ Manifest = $j; Role = $r } } }
    }
    return $null
}

function Resolve-Targets {
    param([string]$PoolSlug, [string]$OwnerName)
    $ctx = Get-CtxMap
    $targets = @()

    if ($OwnerName) {
        # PoolRoot ВСЕГДА из манифеста (root), не из метрикиного cwd — агент мог `cd` в подкаталог,
        # и cwd дрейфует (баг 2026-07-18: planner cwd=00_docs\plans -> шина/projectDir не находились).
        $rmOwner = Find-RoleByOwner -OwnerName $OwnerName
        $ownerRoot = if ($rmOwner) { $rmOwner.Manifest.root } else { $null }
        # Скоуп по корню пула: owner-имя общее для нескольких пулов (lead/operator/builder), без cwd-фильтра
        # схватило бы чужие сессии (баг 2026-07-18). Нет манифеста -> метрике доверять нельзя -> фолбэк ниже.
        $hit = @($ctx | Where-Object { $_.Owner -eq $OwnerName -and $ownerRoot -and (Test-CwdUnderRoot $_.Cwd $ownerRoot) })
        if ($hit.Count) {
            foreach ($h in $hit) {
                Add-Member -InputObject $h -NotePropertyName PoolRoot -NotePropertyValue $ownerRoot -Force
                $targets += $h
            }
            return $targets
        }
        # Метрики нет — фолбэк как в пуле: найти роль в манифесте -> title -> живой процесс.
        $rm = Find-RoleByOwner -OwnerName $OwnerName
        if ($rm) {
            $title = Get-SessionTitleFromBat -PoolRoot $rm.Manifest.root -BatName $rm.Role.bat
            $live  = if ($title) { Resolve-LiveByTitle -Title $title -PoolRoot $rm.Manifest.root } else { $null }
            if ($live) {
                Write-Warn "owner '$OwnerName': метрики нет, но процесс ЖИВ (pid $($live.Pid)) — включаю с ctx=unknown (по умолчанию handoff)"
                $targets += [pscustomobject]@{
                    SessionId = $live.SessionId; Name = $title; Owner = $OwnerName; Cwd = $rm.Manifest.root
                    Pct = $null; AgeSec = $null; File = $null; PoolRoot = $rm.Manifest.root; KnownPid = $live.Pid; NoMetric = $true
                }
                return $targets
            }
            Write-Warn "owner '$OwnerName': роль найдена в манифесте '$($rm.Manifest.slug)', но живого процесса нет — не запущена"
            return @()
        }
        Write-Warn "owner '$OwnerName': метрики нет и роль не найдена ни в одном манифесте"
        return @()
    }

    $man = Get-PoolManifest -Slug $PoolSlug
    if (-not $man) { throw "манифест пула '$PoolSlug' не найден" }
    Write-Step "манифест: $($man.slug) ($($man.roles.Count) ролей), root=$($man.root)"
    foreach ($r in $man.roles) {
        # cwd-фильтр: без него owner-имя роли, общее у <pool-name> и <other-pool>, схватило бы чужой пул (баг 2026-07-18).
        $hit = @($ctx | Where-Object { $_.Owner -eq $r.owner -and (Test-CwdUnderRoot $_.Cwd $man.root) })
        if ($hit.Count) {
            foreach ($h in $hit) {
                Add-Member -InputObject $h -NotePropertyName PoolRoot -NotePropertyValue $man.root -Force
                $targets += $h
            }
            continue
        }
        # Метрики нет. КРИТИЧНО для инструмента гашения: не пропустить молча живую сессию.
        # Фолбэк — резолв живого процесса по SessionTitle из .bat роли.
        $title = Get-SessionTitleFromBat -PoolRoot $man.root -BatName $r.bat
        $live  = if ($title) { Resolve-LiveByTitle -Title $title -PoolRoot $man.root } else { $null }
        if ($live) {
            Write-Warn "роль '$($r.owner)': метрики нет, но процесс ЖИВ (pid $($live.Pid)) — включаю с ctx=unknown (по умолчанию handoff)"
            $targets += [pscustomobject]@{
                SessionId = $live.SessionId
                Name      = $title
                Owner     = $r.owner
                Cwd       = $man.root
                Pct       = $null           # неизвестно -> консервативно идём через handoff
                AgeSec    = $null
                File      = $null
                PoolRoot  = $man.root
                KnownPid  = $live.Pid
                NoMetric  = $true
            }
        } else {
            Write-Warn "роль '$($r.owner)': метрики нет и живого процесса не найдено — пропускаю (не запущена)"
        }
    }
    return $targets
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
    T 'Get-SessionTitleFromBat читает title из .bat роли' {
        (Get-SessionTitleFromBat -PoolRoot '<workspace-root>\<pool-name>' -BatName 'claude-lead.bat') -eq '<session-title>'
    }
    T 'Get-SessionTitleFromBat: $null на несуществующий .bat' {
        $null -eq (Get-SessionTitleFromBat -PoolRoot '<workspace-root>\<pool-name>' -BatName 'no-such.bat')
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
    T 'Get-PoolManifest находит <pool-name>' { $null -ne (Get-PoolManifest -Slug '<pool-name>') }
    T 'Get-PoolManifest возвращает $null на несуществующий пул' { $null -eq (Get-PoolManifest -Slug 'no-such-pool-xyz') }
    T 'Get-BusRoot находит шину <pool-name>' { $null -ne (Get-BusRoot -PoolRoot '<workspace-root>\<pool-name>') }
    T 'Get-BusRoot возвращает $null без шины' { $null -eq (Get-BusRoot -PoolRoot '<workspace-root>\.launcher') }
    T 'Test-CompactLanded ложь на несуществующем транскрипте' { -not (Test-CompactLanded -TranscriptPath 'Z:\nope.jsonl') }
    # ПУНКТ — разведение пулов с ОДИНАКОВЫМИ именами ролей по cwd (баг 2026-07-18: -Pool хватал <pool-name>)
    T 'CwdUnderRoot: точный корень -> да' { Test-CwdUnderRoot '<workspace-root>\<pool-name>' '<workspace-root>\<pool-name>' }
    T 'CwdUnderRoot: подкаталог (дрейф cwd) -> да' { Test-CwdUnderRoot '<workspace-root>\<pool-name>\00_docs\plans' '<workspace-root>\<pool-name>' }
    T 'CwdUnderRoot: другой пул -> НЕТ (коллизия <pool-name> vs <other-pool>)' { -not (Test-CwdUnderRoot '<workspace-root>\<other-pool>' '<workspace-root>\<pool-name>') }
    T 'CwdUnderRoot: префикс-ловушка (-2) -> НЕТ' { -not (Test-CwdUnderRoot '<workspace-root>\<pool-name>-2' '<workspace-root>\<pool-name>') }
    T 'CwdUnderRoot: слеши/регистр нормализуются -> да' { Test-CwdUnderRoot '<workspace-root>/<pool-name>/x' '<workspace-root>\<pool-name>' }
    T 'CwdUnderRoot: пустой cwd -> НЕТ' { -not (Test-CwdUnderRoot '' '<workspace-root>\<pool-name>') }
    # ПУНКТ — pool-aware резолв PID: корень пула из cmdline + скоуп титула по пулу (баг 2026-07-18, killer)
    T 'PoolRootFromCmdLine: из claude-<owner>.bat' {
        (Get-PoolRootFromCmdLine 'cmd.exe /c "<workspace-root>\<pool-name>\claude-lead.bat"') -eq '<workspace-root>\<pool-name>'
    }
    T 'PoolRootFromCmdLine: из scripts\pool-launch.ps1' {
        (Get-PoolRootFromCmdLine 'powershell -File "<workspace-root>\<other-pool>\scripts\pool-launch.ps1" -SessionTitle "<session-title>"') -eq '<workspace-root>\<other-pool>'
    }
    T 'PoolRootFromCmdLine: нет пула -> пусто' { (Get-PoolRootFromCmdLine 'claude --resume abc-123') -eq '' }
    T 'Resolve-LiveByTitle -PoolRoot разводит ОДИНАКОВЫЙ титул по корню (ядро killer-фикса)' {
        $script:LiveSessionsCache = @(
            [pscustomobject]@{ Pid=111; Token='t1'; SessionId='s1'; Title='Lead-X'; Root='<workspace-root>\pool-a' },
            [pscustomobject]@{ Pid=222; Token='t2'; SessionId='s2'; Title='Lead-X'; Root='<workspace-root>\pool-b' }
        )
        $a = Resolve-LiveByTitle -Title 'Lead-X' -PoolRoot '<workspace-root>\pool-b'
        $b = Resolve-LiveByTitle -Title 'Lead-X' -PoolRoot '<workspace-root>\pool-a'
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
    # ПУНКТ 2 — свежесть флага (4 кейса на throwaway-owner)
    T 'Свежесть: нет флага -> невалидно' {
        $o = 'selftest-fresh-xyz'
        Remove-Item (Join-Path $script:ControlDir "shutdown-ready-$o")  -Force -EA SilentlyContinue
        Remove-Item (Join-Path $script:ControlDir "shutdown-intent-$o") -Force -EA SilentlyContinue
        -not (Test-HandoffFlagFresh -Owner $o).Valid
    }
    T 'Свежесть: intent есть, ready нет -> невалидно' {
        $o = 'selftest-fresh-xyz'
        [IO.File]::WriteAllText((Join-Path $script:ControlDir "shutdown-intent-$o"), '')
        Remove-Item (Join-Path $script:ControlDir "shutdown-ready-$o") -Force -EA SilentlyContinue
        -not (Test-HandoffFlagFresh -Owner $o).Valid
    }
    T 'Свежесть: ready НОВЕЕ intent -> валидно' {
        $o = 'selftest-fresh-xyz'
        [IO.File]::WriteAllText((Join-Path $script:ControlDir "shutdown-intent-$o"), '')
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllText((Join-Path $script:ControlDir "shutdown-ready-$o"), '')
        (Test-HandoffFlagFresh -Owner $o).Valid
    }
    T 'Свежесть: ready СТАРШЕ intent -> невалидно' {
        $o = 'selftest-fresh-xyz'
        [IO.File]::WriteAllText((Join-Path $script:ControlDir "shutdown-ready-$o"), '')
        Start-Sleep -Milliseconds 50
        [IO.File]::WriteAllText((Join-Path $script:ControlDir "shutdown-intent-$o"), '')
        $r = -not (Test-HandoffFlagFresh -Owner $o).Valid
        Remove-Item (Join-Path $script:ControlDir "shutdown-ready-$o")  -Force -EA SilentlyContinue
        Remove-Item (Join-Path $script:ControlDir "shutdown-intent-$o") -Force -EA SilentlyContinue
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
        # объект как метрика-цель: есть Name, НЕТ KnownPid, session_id намеренно битый (как рассинхрон uuid)
        $fake = [pscustomobject]@{ Name = $myTitle; SessionId = 'bad-uuid-mismatch'; }
        (Resolve-TargetPid $fake) -eq $mc
    }
    T 'Resolve-TargetPid: KnownPid имеет приоритет' {
        (Resolve-TargetPid ([pscustomobject]@{ Name='x'; SessionId='y'; KnownPid=424242 })) -eq 424242
    }
    T 'Get-CommandText читает канонический handoff-myself' {
        $t = Get-CommandText -Name 'handoff-myself'
        $t -and $t.Length -gt 200 -and $t -match 'handoff'
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

    Write-Host "`n=== итог: $script:pass ok / $script:fail fail ===" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
    return ($script:fail -eq 0)
}

# ---------------------------------------------------------------- main

if ($SelfTest) { exit ([int](-not (Invoke-SelfTest))) }
if (-not $Pool -and -not $Owner) { throw 'укажи -Pool <slug> или -Owner <owner> (или -SelfTest)' }

$myClaude = Get-MyClaudePid
Write-Step "мой claude.exe = $myClaude (себя не гашу)"

# Глобальная сверка полноты: сколько живых claude.exe против сессий с метрикой.
# Не для таргетинга (он scoped), а чтобы оператор видел «слепые» сессии.
$liveAll = @(Get-CimInstance Win32_Process -Filter "Name='claude.exe'" -ErrorAction SilentlyContinue).Count
$metricN = @(Get-CtxMap).Count
if ($liveAll -gt $metricN) {
    Write-Warn "живых claude.exe=$liveAll, с метрикой=$metricN. Сессии без метрики (idle/до tee) видны только через фолбэк по SessionTitle."
}

$targets = @(Resolve-Targets -PoolSlug $Pool -OwnerName $Owner)
if ($Only -and $Only.Count) {
    $before = $targets.Count
    $targets = @(Select-OnlyOwners -Targets $targets -Only $Only)   # @() — иначе pipeline развернёт массив из 1 в скаляр -> .Count падает под StrictMode
    Write-Step ("-Only: оставлено {0} из {1} целей (роли: {2})" -f $targets.Count, $before, ($Only -join ', '))
}
if (-not $targets.Count) { Write-Warn 'целей нет — выходим'; exit 0 }

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
if ($HandoffOnly) { Invoke-HandoffPhase -Targets $targets -MyPid $myClaude -TimeoutSec $WaitHandoffSec -CommandName $HandoffCommand; exit 0 }

# -Full: ВЕСЬ цикл одним вызовом, БАТЧЕМ (все handoff -> все флаги -> все kill+compact), без человеко-гейта.
# Безопаснее per-target-последовательного: никого не гасим, пока не готовы ВСЕ. Компакты — детач (переживут
# закрытие терминала). Для будущего автономного сервера — этот же кирпич без гейта.
if ($Full) {
    Invoke-HandoffPhase -Targets $targets -MyPid $myClaude -TimeoutSec $WaitHandoffSec -CommandName $HandoffCommand
    Write-Host ""
    Write-Step 'ФАЗА 2 — гашение+compact подтвердивших (после -Full handoff-фазы)...'
    $KillOnly = $true   # дальше main-цикл идёт по свежесть-гейту, как -KillOnly
}

Write-Host ""
$report = @()
foreach ($t in $targets) {
    Write-Host ("--- {0} ---" -f $t.Owner) -ForegroundColor White
    $targetPid = Resolve-TargetPid $t

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

    # ФАЗА 2: handoff уже сделан в фазе 1 -> пропускаем, но проверяем СВЕЖЕСТЬ флага (пункт 2).
    if ($KillOnly) {
        if ($lightClose) {
            Write-Step "ctx=$([math]::Round($t.Pct))% < $Threshold% -> лёгкое закрытие (без handoff/compact); гейт свежести пропускаю, гашу"
        }
        else {
            $fresh = Test-HandoffFlagFresh -Owner $t.Owner
            if ($fresh.Valid) {
                Write-Step "handoff-флаг $($t.Owner): $($fresh.Reason) — фаза 1 подтверждена"
                Remove-Item (Join-Path $script:ControlDir ("shutdown-ready-{0}"  -f $t.Owner)) -Force -ErrorAction SilentlyContinue
                Remove-Item (Join-Path $script:ControlDir ("shutdown-intent-{0}" -f $t.Owner)) -Force -ErrorAction SilentlyContinue
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
        $poolRoot = if ($t.PSObject.Properties.Name -contains 'PoolRoot') { $t.PoolRoot } else { $t.Cwd }
        $bus = Get-BusRoot -PoolRoot $poolRoot
        if (-not $bus) {
            Write-Warn "шины нет ($poolRoot) — handoff через шину невозможен, гашу без него"
        } else {
            $flag = Join-Path $script:ControlDir ("shutdown-ready-{0}" -f $t.Owner)
            if (Test-Path $flag) { Remove-Item $flag -Force -ErrorAction SilentlyContinue }
            Write-Step "ctx=$([math]::Round($t.Pct))% >= $Threshold% -> задача «заверши работу» в шину ($bus)"
            $snd = Send-ShutdownTask -BusRoot $bus -TargetOwner $t.Owner -FlagPath $flag -ProjectRoot $poolRoot -CommandName $HandoffCommand
            if (-not $snd.Ok) {
                Write-Warn "отправка не удалась: $($snd.Msg)"
            } else {
                Write-Step "жду флаг готовности до $WaitHandoffSec с ..."
                if (Wait-ShutdownFlag -FlagPath $flag -TimeoutSec $WaitHandoffSec) {
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
            if ($cmdPid) { $killPid = $cmdPid; $extra = " (cmd-лаунчер $cmdPid — окно закроется; claude $targetPid внутри)" }
            else { Write-Warn "cmd-лаунчер не найден для $($t.Owner) — гашу дерево claude напрямую (окно останется на pause)" }
        }
        Write-Step "гашу: taskkill /F /T /PID $killPid$extra"
        $k = Stop-SessionTree -TargetPid $killPid
        Start-Sleep -Milliseconds 500
        if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) { Write-Err "сессия claude $targetPid ещё жива"; $report += [pscustomobject]@{ Owner = $t.Owner; Result = 'ERR: claude still alive' }; continue }
        Write-Ok "снято процессов: $($k.Killed); claude $targetPid мёртв$(if($CloseWindow -and $cmdPid){' + окно закрыто'})"
    } else {
        # НЕ рапортуем ok: если цель пришла из свежей метрики/манифеста, «нет процесса» = скорее
        # провал резолва, чем «уже выключена». Гасить нечего -> честный skip, не ложный успех.
        Write-Warn "процесс НЕ найден для $($t.Owner) — гасить нечего. Если сессия жива, это ошибка резолва (сообщи)."
        $report += [pscustomobject]@{ Owner = $t.Owner; Result = 'skip: процесс не найден (НЕ гашено)' }
        continue
    }

    if (-not $NoCompact -and -not $lightClose) {
        # compact = resume по ИМЕНИ (новейшая сессия) -> /compact. Root — из МАНИФЕСТА (PoolRoot), не из
        # дрейфующего cwd агента (projectDir/resume завязаны на launch-cwd = корень пула).
        $compactRoot = if (($t.PSObject.Properties.Name -contains 'PoolRoot') -and $t.PoolRoot) { $t.PoolRoot } else { $t.Cwd }
        Write-Step "headless compact (resume-by-name '$($t.Name)', root=$compactRoot)"
        $c = Invoke-HeadlessCompact -SessionTitle $t.Name -Cwd $compactRoot
        if ($c.Ok) { Write-Ok "compact ЗАПУЩЕН ($($c.Msg)) — детач, допишется даже если закрыть терминал" } else { Write-Warn "compact не запущен: $($c.Msg)" }
    }

    $resLabel = 'ok: ' + $(if ($didHandoff) { 'handoff+' } else { '' }) + 'kill' + $(if ($NoCompact) { '' } else { '+compact' })
    $report += [pscustomobject]@{ Owner = $t.Owner; Result = $resLabel }
}

Write-Host "`n=== ИТОГ ===" -ForegroundColor Cyan
$report | Format-Table -AutoSize
