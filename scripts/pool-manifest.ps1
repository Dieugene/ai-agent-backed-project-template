<#
    ОБЩАЯ БИБЛИОТЕКА ПО pool.manifest.json (dot-source: . "<...>\pool-bus\pool-manifest.ps1").
    Потребители: pool-launcher\launch-pool.ps1 (борд, самопроверка), pool-bus\pool-shutdown.ps1.

    ЗАЧЕМ ОНА ЕСТЬ (баг 2026-07-27, борд «DIV Extraction» открывался пустым):
    поле `root` в манифесте исторически несёт ЧЕТЫРЕ разных смысла:
        (1) каталог wrapper-батников     — launch-pool.ps1 (панели Warp), set-pool-runtime.ps1, fresh-session.ps1
        (2) каталог шины (`root\.bus`)   — борд, Get-BusRoot в контроллере гашения
        (3) launch-cwd сессии            — Test-CwdUnderRoot (скоуп сессий), ProjectKey для headless compact
        (4) корень поиска документов     — Find-HandoffFile (ИСТОРИЯ: строка врала — функция всегда
            получала РОДИТЕЛЯ ШИНЫ, а не `root`; с 2026-08-02 её вытеснила память роли, которая
            берётся от `cwd`, смысл (3), потому что у 5 пулов родитель шины и cwd — разные каталоги)
    У пулов, выросших внутри монорепо (<monorepo>, <pool-c>, <sub-a>), это ТРИ РАЗНЫХ каталога,
    и один `root` их не описывает. Отсюда молчаливые промахи: борд смотрел в `<root>\.bus`, которого нет.

    РЕШЕНИЕ: смыслы (2) и (3) выносятся в отдельные НЕОБЯЗАТЕЛЬНЫЕ поля `bus` и `cwd`, с фолбэком на `root`.
    Фолбэк сохраняет поведение пулов, у которых все каталоги совпадают (их большинство), — поле только
    УТОЧНЯЕТ, никогда не расширяет. Регрессировать тут нечему by construction.

    ИНВАРИАНТЫ (нарушишь — вернёшь баг 2026-07-27):
      * Resolve-PoolBus НЕ проверяет существование каталога: «куда смотреть» и «существует ли» — разные
        вопросы. Вызывающий обязан проверить сам и сказать вслух, если каталога нет (молчание = этот баг).
      * Источник ИСТИНЫ о шине — `set POOL_BUS_ROOT=` в wrapper'е: именно с ним стартует живая сессия.
        Манифест — лишь его отражение. Расхождение ловит Test-PoolManifest (гоняется в -SelfTest пикера).
      * Пул без POOL_BUS_ROOT во ВСЕХ wrapper'ах — законный случай (одиночная роль без координации),
        а не поломка. Аудит помечает такой пул Busless и не краснеет.
#>

<# Каталог шины пула: явное поле `bus`, иначе legacy-фолбэк `<root>\.bus`. Существование НЕ проверяется. #>
function Resolve-PoolBus {
    param($Manifest)
    if (-not $Manifest) { return $null }
    $props = $Manifest.PSObject.Properties.Name
    if (($props -contains 'bus') -and $Manifest.bus) { return [string]$Manifest.bus }
    if (($props -contains 'root') -and $Manifest.root) { return (Join-Path ([string]$Manifest.root) '.bus') }
    return $null
}

<# Launch-cwd сессий пула: явное поле `cwd`, иначе фолбэк `root`. Нужен для скоупа сессий и ProjectKey. #>
function Resolve-PoolCwd {
    param($Manifest)
    if (-not $Manifest) { return $null }
    $props = $Manifest.PSObject.Properties.Name
    if (($props -contains 'cwd') -and $Manifest.cwd) { return [string]$Manifest.cwd }
    if (($props -contains 'root') -and $Manifest.root) { return [string]$Manifest.root }
    return $null
}

<# `set POOL_BUS_ROOT=<путь>` из wrapper-батника. $null — если файла нет или переменная не выставлена. #>
function Get-BatBusRoot {
    param([string]$BatPath)
    if (-not $BatPath -or -not (Test-Path $BatPath)) { return $null }
    try { $txt = [System.IO.File]::ReadAllText($BatPath) } catch { return $null }
    $m = [regex]::Match($txt, '(?im)^\s*set\s+POOL_BUS_ROOT=(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"') }
    return $null
}

<# `cd /d <путь>` из wrapper-батника — реальный launch-cwd сессии. #>
function Get-BatCwd {
    param([string]$BatPath)
    if (-not $BatPath -or -not (Test-Path $BatPath)) { return $null }
    try { $txt = [System.IO.File]::ReadAllText($BatPath) } catch { return $null }
    $m = [regex]::Match($txt, '(?im)^\s*cd\s+/d\s+(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"') }
    return $null
}

<# Сравнение путей: регистронезависимо, без хвостового слэша, без требования существования. #>
function Test-SamePath {
    param([string]$A, [string]$B)
    if (-not $A -and -not $B) { return $true }
    if (-not $A -or -not $B) { return $false }
    $na = $A.Trim().TrimEnd('\'); $nb = $B.Trim().TrimEnd('\')
    return ($na -ieq $nb)
}

<# `set AGENT_OWNER=<роль>` из wrapper-батника — КЛЮЧ роли. Именно он, а не имя файла: fresh-session.ps1
   клонирует обёртку под новым именем (`claude-<owner>-2.bat`), сохраняя владельца, и в одном каталоге
   уживаются `claude-div-dev.bat` и `claude-div-dev-internal.bat` — сравнение имён путает такие пары. #>
function Get-BatOwner {
    param([string]$BatPath)
    if (-not $BatPath -or -not (Test-Path $BatPath)) { return $null }
    try { $txt = [System.IO.File]::ReadAllText($BatPath) } catch { return $null }
    $m = [regex]::Match($txt, '(?im)^\s*set\s+AGENT_OWNER=(.+?)\s*$')
    if ($m.Success) { return $m.Groups[1].Value.Trim().Trim('"') }
    return $null
}

<# Схлопнуть `..` в пути. Чистая строковая операция: диска не касается, существования не требует.
   Нужна потому, что манифест пула supervisors несёт `..\..\launcher.bat`, а Warp-workflow той же роли
   зовёт `<workspace-root>\launcher.bat` — без нормализации это два разных «файла». #>
function Get-NormalPath {
    param([string]$Path)
    if (-not $Path) { return '' }
    try { return ([System.IO.Path]::GetFullPath($Path)).TrimEnd('\') } catch { return ([string]$Path).Trim().TrimEnd('\') }
}

<# Пути .bat из командной строки. Класс без кавычек не даёт матчу перепрыгнуть из `"...\cmd.exe"`
   в следующий аргумент, поэтому путь самого cmd.exe сюда не попадает. #>
function Get-BatPathsFromCmdLine {
    param([string]$CommandLine)
    if (-not $CommandLine) { return @() }
    $out = @()
    foreach ($m in [regex]::Matches($CommandLine, '(?i)[A-Za-z]:\\[^"''<>|\r\n]*?\.bat')) {
        $n = Get-NormalPath $m.Value
        if ($n -and ($out -notcontains $n)) { $out += $n }
    }
    # Запятая обязательна: без неё единственный элемент вернётся СТРОКОЙ, и `[0]` у неё — первая буква.
    # Но `,@()` — это массив ИЗ пустого массива, длиной 1, поэтому пустой случай возвращается отдельно.
    if ($out.Count -eq 0) { return @() }
    return ,@($out)
}

<#
    КТО СЕЙЧАС ПОДНЯТ. Возвращает { Ok; Panes[] } — Ok=$false означает «проверить не удалось»,
    и это НЕ то же самое, что пустой список: инструмент не вправе утверждать отрицание, которого
    не проверил. Вызывающий обязан развести эти два случая.

    Якорь — процесс-обёртка cmd.exe, а не claude.exe. Три причины: (1) обёртка живёт с первой секунды,
    а claude.exe появляется лишь через несколько секунд (pool-launch.ps1 сперва резолвит SessionTitle
    в uuid перебором транскриптов) — на claude.exe проверка была бы слепа ровно в те секунды, когда
    человек и жмёт второй раз; (2) не нужен подъём по дереву процессов; (3) headless-компакт
    контроллера гашения крутится под `poolcompact-*.bat`, в котором нет AGENT_OWNER, и отсеивается сам.
    Плата: панель, где сессия упала и cmd висит на `if errorlevel 1 pause`, считается занятой. Для
    вопроса «поднимать ли сюда вторую» это верный ответ.
#>
function Get-LiveAgentPanes {
    $procs = $null
    try { $procs = @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -OperationTimeoutSec 20 -ErrorAction Stop) }
    catch { return [pscustomobject]@{ Ok = $false; Panes = @() } }
    $panes = @()
    foreach ($p in $procs) {
        $cl = $null
        if ($p.PSObject.Properties.Name -contains 'CommandLine') { $cl = $p.CommandLine }
        if (-not $cl) { continue }
        foreach ($bat in (Get-BatPathsFromCmdLine $cl)) {
            $owner = Get-BatOwner $bat
            if (-not $owner) { continue }                      # не обёртка агента
            $panes += [pscustomobject]@{ Owner = $owner; Bat = $bat; Bus = (Get-BatBusRoot $bat); ProcId = [int]$p.ProcessId }
        }
    }
    return [pscustomobject]@{ Ok = $true; Panes = @($panes) }
}

<#
    Поднята ли роль пула. Ключ — владелец; пулы с одноимёнными ролями (`lead` есть и у <pool-a>,
    и у networking-assistant) разводятся по шине из обёртки, а где шины нет — по пути обёртки.
    Чистая функция: $Panes приходит снаружи, чтобы её можно было гонять в -SelfTest на фикстурах.
#>
function Test-PoolRoleLive {
    param($Manifest, $Role, $Panes)
    if (-not $Manifest -or -not $Role -or -not $Panes) { return $false }
    $rprops = $Role.PSObject.Properties.Name
    $owner  = if ($rprops -contains 'owner') { [string]$Role.owner } else { '' }
    if (-not $owner) { return $false }
    $mprops = $Manifest.PSObject.Properties.Name
    $bus = ''
    try { $bus = Get-NormalPath (Resolve-PoolBus $Manifest) } catch { $bus = '' }
    $roleBat = ''
    if (($rprops -contains 'bat') -and $Role.bat -and ($mprops -contains 'root') -and $Manifest.root) {
        try { $roleBat = Get-NormalPath ([System.IO.Path]::Combine([string]$Manifest.root, [string]$Role.bat)) } catch { $roleBat = '' }
    }
    foreach ($p in $Panes) {
        if ([string]$p.Owner -ine $owner) { continue }
        $pbus = Get-NormalPath ([string]$p.Bus)
        if ($bus -and $pbus) { if (Test-SamePath $bus $pbus) { return $true }; continue }   # разные шины = чужой пул
        if ($roleBat -and (Test-SamePath $roleBat ([string]$p.Bat))) { return $true }
        if (-not $bus -and -not $pbus) { return $true }
    }
    return $false
}

<#
    АУДИТ ОДНОГО МАНИФЕСТА. Возвращает объект с Slug/Busless/Issues[].
    Проверяет ровно то, что молча ломалось: (1) батник роли существует; (2) POOL_BUS_ROOT совпадает
    с выводимой шиной; (3) POOL_BUS_ROOT одинаков у ВСЕХ ролей пула; (4) каталог шины существует;
    (5) `cd /d` из батника совпадает с выводимым cwd (расхождение = промах скоупа сессий и ProjectKey).
#>
function Test-PoolManifest {
    param($Manifest)
    $issues = @()
    $slug   = if ($Manifest.PSObject.Properties.Name -contains 'slug') { [string]$Manifest.slug } else { '<без slug>' }
    $bus    = Resolve-PoolBus $Manifest
    $cwd    = Resolve-PoolCwd $Manifest
    $root   = if ($Manifest.PSObject.Properties.Name -contains 'root') { [string]$Manifest.root } else { $null }

    $seenBus = @{}
    $anyBus  = $false
    foreach ($r in @($Manifest.roles)) {
        $bat = if ($root -and $r.bat) { Join-Path $root ([string]$r.bat) } else { $null }
        if (-not $bat -or -not (Test-Path $bat)) { $issues += ("роль '{0}': батник не найден: {1}" -f $r.owner, $bat); continue }

        $rb = Get-BatBusRoot $bat
        if ($rb) {
            $anyBus = $true
            $seenBus[$rb.TrimEnd('\').ToLowerInvariant()] = $true
            if (-not (Test-SamePath $rb $bus)) {
                $issues += ("роль '{0}': POOL_BUS_ROOT={1} != выводимая шина {2}" -f $r.owner, $rb, $bus)
            }
        }

        $bc = Get-BatCwd $bat
        if ($bc -and -not (Test-SamePath $bc $cwd)) {
            $issues += ("роль '{0}': cd /d {1} != выводимый cwd {2}" -f $r.owner, $bc, $cwd)
        }
    }

    if ($seenBus.Keys.Count -gt 1) {
        $issues += ("роли пула смотрят в РАЗНЫЕ шины: {0}" -f (($seenBus.Keys | Sort-Object) -join ' | '))
    }
    if ($anyBus -and $bus -and -not (Test-Path $bus)) {
        $issues += ("каталог шины не существует: {0}" -f $bus)
    }

    return [pscustomobject]@{
        Slug    = $slug
        Bus     = $bus
        Busless = (-not $anyBus)
        Issues  = $issues
    }
}

<# Аудит списка манифестов -> печать отчёта. Возвращает число пулов с проблемами. #>
function Invoke-PoolManifestAudit {
    param($Manifests)
    $bad = 0
    foreach ($m in @($Manifests)) {
        $r = Test-PoolManifest $m
        if ($r.Issues.Count) {
            $bad++
            Write-Host ("  [FAIL] {0}" -f $r.Slug) -ForegroundColor Red
            foreach ($i in $r.Issues) { Write-Host ("         - {0}" -f $i) -ForegroundColor Red }
        }
        elseif ($r.Busless) { Write-Host ("  [ok]   {0}  (пул без шины — координации нет)" -f $r.Slug) -ForegroundColor DarkGray }
        else { Write-Host ("  [ok]   {0}  -> {1}" -f $r.Slug, $r.Bus) -ForegroundColor DarkGreen }
    }
    return $bad
}
