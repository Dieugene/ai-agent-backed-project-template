# memory-audit.ps1 - автоматический аудит памяти роли: зафиксировать историю и проверить структуру.
#
# Зовётся НЕ агентом вручную, а обвязкой в трёх точках:
#   * `pool handoff` - НАЧАЛО свёртки памяти (первая строка канона): сверка прошлой подсадной, сбор
#                      списка, запуск расчёта вердиктов фоном - пока роль пишет якорь, помощник считает;
#                      коммита и структурной проверки здесь нет, их роль делает в конце сама;
#   * `pool ready`  - агент подтвердил готовность к гашению (память дописана, дальше он молчит);
#   * хук PreCompact - контекст вот-вот сожмут, в том числе автоматически, без участия человека.
# 🛑 До 07.09 список и вердикты считались в двух последних точках - то есть ПОСЛЕ свёртки, и роль
# получала их только к следующей: по журналам ~15 закрытий с вердиктом против ~37 без. Слово владельца
# 07.09: запускать работу помощника по команде свёртки, роль тем временем делает то, что вердиктов
# не требует.
#
# Почему не строкой в инструкции: помнить в конце сессии про две команды - самое ненадёжное место
# ровно там, где надёжность и нужна. Агент пишет память, механику выполняет обвязка.
#
#   powershell -File memory-audit.ps1 -Owner <роль> [-Cwd <путь>] [-Reason ready|precompact]
#
# Ничего не чинит и ничего не удаляет. Коммитит - да: незафиксированная запись теряется целиком,
# а замечание проверки - повод посмотреть, а не причина не сохранять.

param(
    [AllowEmptyString()][string]$Owner = $env:AGENT_OWNER,
    [string]$Cwd = (Get-Location).Path,
    [string]$Dir,            # точный адрес хранилища из настроек роли (пишет agent-memory.ps1 вместе с хуком)
    [string]$Reason = 'manual'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}   # без преамбулы (BOM в stdout)

if ([string]::IsNullOrWhiteSpace($Owner)) { return }   # не роль пула - тихо выходим

# Каталог ищем вверх от текущего: агент мог уйти вглубь проекта, и тогда <cwd>\.memory не существует.
# Сверено с копией в memory-inject.ps1 (18.08): -LiteralPath -PathType Container и [IO.Path]::Combine -
# прежде копии разъехались, и файл с именем роли внутри .memory аудит принимал, а впрыск отвергал.
function Find-MemoryDir([string]$start, [string]$owner) {
    $d = $start
    for ($i = 0; $i -lt 6 -and $d; $i++) {
        $cand = [IO.Path]::Combine([IO.Path]::Combine($d, '.memory'), $owner)
        if (Test-Path -LiteralPath $cand -PathType Container) { return $cand }
        $parent = Split-Path $d -Parent
        if ($parent -eq $d) { break }
        $d = $parent
    }
    return $null
}

# Точный адрес приходит из настроек роли (-Dir): подъём по дереву - запасной путь для настроек, записанных
# до 18.08. Подъём брал первого тёзку (.memory/<owner> есть у четырёх lead), а у qa-div расходился с
# настройками: шина и память в разных каталогах. Адрес задан, но каталога нет - выходим МОЛЧА, не гадаем
# подъёмом: угаданный чужой каталог и есть болезнь, ради которой введён -Dir (оппонент 18.08).
# Внутреннее имя НЕ $dir: регистр в именах переменных не различается, и $dir = $null обнулял бы сам
# параметр $Dir (та же ловушка описана в memory-inject.ps1; поймана здесь самотестом - оба теста
# инвертировались).
$memDir = $null
if ($Dir) {
    if (Test-Path -LiteralPath $Dir -PathType Container) { $memDir = $Dir } else { return }
} else {
    $memDir = Find-MemoryDir -start $Cwd -owner $Owner
}
if (-not $memDir) { return }   # память по-старому (переключатель не раскатан) - молчим, это не ошибка

Write-Output ("[memory-audit] {0} ({1})" -f $Owner, $Reason)

# --- 1. зафиксировать историю -------------------------------------------------
# В начале свёртки (handoff) не коммитим: роль ещё ничего не правила, а коммит "до" читался бы ею
# как "мои правки уже в истории". История фиксируется на PreCompact и ready, как и была.
if ($Reason -eq 'handoff') {
    Write-Output '  история: в начале свёртки не фиксируется (будет на сжатии или ready)'
} elseif (Test-Path (Join-Path $memDir '.git')) {
    $st = @(& git -C $memDir status --porcelain 2>$null)
    if ($st.Count -gt 0) {
        $null = & git -C $memDir add -A 2>&1
        $msg = "memory: $Reason ($($st.Count) файлов)"
        $out = & git -C $memDir -c user.name=$Owner -c user.email="$Owner@local" commit -q -m $msg 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Output ("  зафиксировано изменений: {0}" -f $st.Count) }
        else { Write-Output ("  коммит не прошёл: {0}" -f ($out -join ' ')) }
    } else {
        Write-Output '  изменений нет'
    }
} else {
    Write-Output '  истории нет (репозиторий не инициализирован) - записи сохранены, версий не будет'
}

# --- 1.5. список актуализации ---------------------------------------------------
# Собираем ДО структурной проверки: она печатает лишь указатель на готовый файл, и без сбора
# роль видела бы вечное «список не собран» - а вечно красная строка приучает не читать вывод.
# Молчим, если питона или модуля нет: механика вводится по ролям, а не сразу всем.
$revMod = $null
foreach ($cand in @((Join-Path $PSScriptRoot 'memory-revision\memory-revision.py'),
                    (Join-Path $PSScriptRoot '..\shop\memory-revision.py'),
                    (Join-Path $PSScriptRoot '..\server\memory-revision\memory-revision.py'))) {
    if (Test-Path -LiteralPath $cand) { $revMod = (Resolve-Path -LiteralPath $cand).Path; break }
}
if ($revMod) {
    # 🛑 Имени в PATH НЕДОСТАТОЧНО: на Windows `python3` почти всегда есть как заглушка из
    # WindowsApps, которая ничего не исполняет и открывает магазин. Кандидат принимается только
    # если реально отвечает на --version (поймано здесь же: сбор молча не давал признака).
    $py = $null
    foreach ($c in @('python3','python')) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        if ($cmd.Source -like '*WindowsApps*') { continue }
        $ver = & $cmd.Source '--version' 2>&1
        if ($LASTEXITCODE -eq 0 -and "$ver" -match 'Python') { $py = $cmd.Source; break }
    }
    if ($py) {
        $poolRoot = Split-Path -Parent (Split-Path -Parent $memDir)
        $revOut   = Join-Path (Join-Path $poolRoot '.revision') ($Owner + '.md')
        $mailBox  = Join-Path (Join-Path $poolRoot '.bus') $Owner
        $revArgs  = @($revMod, '--dir', $memDir, '--out', $revOut)
        if (Test-Path -LiteralPath $mailBox) { $revArgs += @('--mail', $mailBox) }
        # Сообщения ЛЮДЕЙ - такой же вход сверки, как письма ролей: слово владельца 04.09, канал не
        # важен, важно содержание. Мост складывает их в <пул>\03_data\inbox; путь можно задать явно
        # файлом .revision\inbox-path (у пулов, где мост живёт в стороне, - например в ~/.config).
        # Нет ни того, ни другого - источник просто не подключается, поведение как раньше.
        $inbox = Join-Path $poolRoot '03_data\inbox'
        $inboxCfg = Join-Path (Join-Path $poolRoot '.revision') 'inbox-path'
        if (Test-Path -LiteralPath $inboxCfg) {
            $fromCfg = (Get-Content -LiteralPath $inboxCfg -Raw -ErrorAction SilentlyContinue).Trim()
            if ($fromCfg) { $inbox = $fromCfg }
        }
        if (Test-Path -LiteralPath $inbox) {
            $revArgs += @('--inbox', $inbox)
            # Общий мост обслуживает несколько пулов: у записи стоит адрес вида «pool-B-3/lead».
            # Собираем свой адрес из пути пула относительно рабочего пространства - «pool-B-3»
            # превращается в «pool-B-3». У пул-локального моста адреса в записях нет, и фильтр
            # ничего не отсекает.
            $wsRoot = Split-Path -Parent (Split-Path -Parent $poolRoot)
            $rel = $poolRoot
            if ($poolRoot.StartsWith($wsRoot)) { $rel = $poolRoot.Substring($wsRoot.Length).Trim('\','/') }
            # Скобки вокруг суммы обязательны: запятая литерала массива связывает сильнее «+», и без них
            # к массиву приклеивались ТРИ элемента («pool-B-2», «/», «lead») - сборщик падал на
            # разборе аргументов, список не собирался вовсе у любого пула с подключённым мостом.
            # Нашёл lead pool-B-2 04.09 (обязательство revision-inbox-target-argv).
            $revArgs += @('--inbox-target', (($rel -replace '[\\/]', '-') + '/' + $Owner))
        }
        # Подсадная позиция: механика проверки самого хода (shop/plant.py). Ставится ПОСЛЕ сборки
        # и проверяется на следующем проходе - до 04.09 вызывалась руками, то есть проверка против
        # штамповки зависела от того, вспомнит ли о ней роль.
        $plantMod = $null
        foreach ($cand in @((Join-Path $PSScriptRoot 'memory-revision\plant.py'),
                            (Join-Path $PSScriptRoot '..\shop\plant.py'),
                            (Join-Path $PSScriptRoot '..\server\memory-revision\plant.py'))) {
            if (Test-Path -LiteralPath $cand) { $plantMod = (Resolve-Path -LiteralPath $cand).Path; break }
        }

        # 🛑 Список собирается ТОЛЬКО в начале свёртки. Сбор на сжатии и ready давал список, который
        # роль увидит через сутки, и на каждой свёртке - ложную тревогу «прошлый список без исходов».
        if ($Reason -eq 'handoff') {
            # 🛑 Сверка прошлой подсадной - ДО пересборки. Сборка переносит только почтовые пункты, а
            # подсадная ключуется по записи (age:...), то есть её блок с исходом стирался раньше, чем
            # сверка его читала: прогон 07.09 - подсажено=6, поймано=0, без_исхода=6. Ряд «доля
            # поимок» читался нулём по построению.
            if ($plantMod -and (Test-Path -LiteralPath $revOut)) {
                try {
                    $chk = & $py $plantMod '--dir' $memDir '--list' $revOut '--check' 2>&1
                    # Образец по машинной строке PLANTED: прежний ('подсадн') не совпадал со словом
                    # «подсажено», и строка сверки не печаталась никогда.
                    $chkLine = $chk | Select-String 'PLANTED|подсадн' | Select-Object -First 1
                    if ($chkLine) { Write-Output ("  " + $chkLine.ToString().Trim()) }
                } catch { }
            }
            # Признак положительный: строка REVISION приходит только от состоявшегося сбора. Нет её -
            # говорим об этом прямо, иначе несобранный список неотличим от собранного и пустого.
            try {
                $revOutText = & $py @revArgs 2>&1
                $revLine = $revOutText | Select-String '^REVISION: ' | Select-Object -First 1
                if ($revLine) { Write-Output ("  " + $revLine.ToString().Trim()); $collected = $true }
                else { Write-Output "  актуализация: сбор НЕ дал признака REVISION - список не обновлён" }
            } catch {
                Write-Output ("  актуализация: сбор упал - " + $_.Exception.Message)
            }
            # 🛑 Саму подсадную ставит РАСЧЁТ вердиктов, а не обвязка: расчёт идёт фоном следом и
            # переписывает файл вердиктов - подложный вердикт затирался настоящим (сверка 04.09).
        }
    }
}

# --- 1.6. вердикты помощника: считаем ФОНОМ в НАЧАЛЕ свёртки ---------------
# Роль пишет якорь несколько минут, расчёт занимает 30-120 с (замер 07.09) - к шагу «вердикт открывать
# вторым» он готов; роль зовёт `memory-verdicts.py --wait`, которая отвечает по штампу.
# Штамп `.verdicts-stamp-<роль>.json` пишется ЗДЕСЬ до запуска (status=running, pid=0): упадёт питон
# на импорте - штамп останется с мёртвым pid, и читатели прочтут его как failed, а не как «считается».
# Ролевой замок держит один проход на роль; протухший распознаётся по штампу (процесса нет), а не
# по возрасту каталога.
if ($Reason -eq 'handoff' -and $revMod -and $py) {
    $vMod = Join-Path (Split-Path -Parent $revMod) 'memory-verdicts.py'
    $revDir = Split-Path -Parent $revOut
    $closeMod = Join-Path (Split-Path -Parent $revMod) 'memory-close.py'
    if (Test-Path -LiteralPath $vMod) {
        $lockDir = Join-Path $revDir ('.verdicts-lock-' + $Owner)
        $stampPath = Join-Path $revDir ('.verdicts-stamp-' + $Owner + '.json')
        $stale = $false
        if (Test-Path -LiteralPath $lockDir) {
            $busy = $false
            $st = $null
            try { $st = Get-Content -LiteralPath $stampPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json } catch { }
            if ($st -and "$($st.status)" -eq 'running') {
                $pidNum = 0; [void][int]::TryParse("$($st.pid)", [ref]$pidNum)
                if ($pidNum -gt 0 -and (Get-Process -Id $pidNum -ErrorAction SilentlyContinue)) { $busy = $true }
            } elseif (-not $st) {
                # Штампа нет - замок от кода до 07.09: судим по возрасту, как раньше.
                $age = (Get-Date) - (Get-Item -LiteralPath $lockDir).CreationTime
                if ($age.TotalMinutes -le 60) { $busy = $true }
            }
            if (-not $busy) { Remove-Item -LiteralPath $lockDir -Force -Recurse -ErrorAction SilentlyContinue; $stale = $true }
        }
        if (-not (Test-Path -LiteralPath $lockDir)) {
            try {
                New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
                $stampObj = [ordered]@{ role = $Owner; list = $revOut; status = 'running'; pid = 0
                                        phase = 'запуск обвязкой'; reason = ''
                                        started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); launched_by = 'memory-audit' }
                [System.IO.File]::WriteAllText($stampPath, ($stampObj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
                $vArgs = @($vMod, '--list', $revOut, '--dir', $memDir, '--jobs', '3', '--lock', $lockDir)
                # ⚠️ Рабочий каталог намеренно ПУСТОЙ (временный): любой CLAUDE.md выше по дереву
                # притащит помощнику весь каскад и съест выигрыш от выноса наружу.
                $wd = if ($env:TEMP) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
                # -WindowStyle есть только на Windows; на Linux параметр валит запуск.
                if ($IsWindows -eq $false) {
                    $proc = Start-Process -FilePath $py -ArgumentList $vArgs -WorkingDirectory $wd -PassThru -ErrorAction Stop
                } else {
                    $proc = Start-Process -FilePath $py -ArgumentList $vArgs -WorkingDirectory $wd `
                                  -WindowStyle Hidden -PassThru -ErrorAction Stop
                }
                Write-Output ("  вердикты: расчёт запущен фоном (pid {0}){1}" -f $proc.Id, $(if ($stale) { " (снят остаток прошлого)" } else { "" }))
            } catch {
                Remove-Item -LiteralPath $lockDir -Force -Recurse -ErrorAction SilentlyContinue
                $stampObj = [ordered]@{ role = $Owner; list = $revOut; status = 'failed'; pid = 0
                                        reason = ('запуск не удался: ' + $_.Exception.Message)
                                        started = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); finished = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') }
                [System.IO.File]::WriteAllText($stampPath, ($stampObj | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
                Write-Output ("  вердикты: запустить не удалось - " + $_.Exception.Message)
            }
        } else {
            Write-Output "  вердикты: прошлый расчёт этой роли ещё идёт (процесс жив), новый не запускаю"
        }
        # Роли - всё, что ей нужно дальше, одним блоком: путь списка, команда ожидания, закрыватель.
        # Пути здесь, а не в каноне: канон один на обе машины, а модуль лежит на них по-разному.
        $total = ''
        try {
            $m = [regex]::Match((Get-Content -LiteralPath $revOut -Raw -Encoding UTF8), '(?m)^ВСЕГО ПУНКТОВ:\s*(\d+)')
            if ($m.Success) { $total = $m.Groups[1].Value }
        } catch { }
        Write-Output ("  СПИСОК: {0}{1}" -f $revOut, $(if ($total -ne '') { " (пунктов: $total)" } else { '' }))
        Write-Output ("  ВЕРДИКТЫ ЖДАТЬ (на шаге «открыть вторым»; таймаут инструмента 10 мин): {0} {1} --wait --dir `"{2}`"" -f $py, $vMod, $memDir)
        if (Test-Path -LiteralPath $closeMod) {
            Write-Output ("  ЗАКРЫВАТЕЛЬ: {0} {1} --list `"{2}`" --outcomes <файл исходов> --dir `"{3}`"" -f $py, $closeMod, $revOut, $memDir)
        }
    }
}

# --- 2. структурная проверка --------------------------------------------------
# В начале свёртки не гоняем: роль по канону прогоняет её сама ПОСЛЕ своих правок, а вторая
# проверка «до» лишь путала бы, какой из двух списков замечаний исправлять.
$checker = Join-Path $PSScriptRoot 'memory-check.ps1'
if ($Reason -ne 'handoff' -and (Test-Path $checker)) {
    # Интерпретатор РЕЗОЛВИМ, а не зовём по имени: на сервере исполняемого `powershell` нет вовсе, и
    # вызов по имени падал CommandNotFoundException - причём ДО запуска процесса, поэтому в $lines не
    # приходило ни строки даже при 2>&1, а $LASTEXITCODE оставался от предыдущей команды. Идиома та
    # же, что в agent-memory.ps1: путь ТЕКУЩЕГО процесса, без догадок про PATH.
    $onWin = $true
    try { $v = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($v) { $onWin = [bool]$v.Value } } catch { }
    # Кандидаты по очереди, а не один: ProcessPath есть только в .NET 6+ (под 5.1 его НЕТ вовсе, и
    # обращение молча уводило в 'pwsh', которого на Windows нет), а MainModule при запуске вида
    # `dotnet pwsh.dll` вернул бы путь к dotnet. Последний рубеж - имя, пусть ищет в PATH.
    $psExe = 'powershell'
    if (-not $onWin) {
        $psExe = $null
        try { $psExe = [System.Environment]::ProcessPath } catch { }
        if (-not $psExe) { try { $psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { } }
        if (-not $psExe) { $psExe = 'pwsh' }
    }
    # 🛑 @() ОБЯЗАТЕЛЬНО снаружи if, а не внутри веток: результат ветки с ОДНИМ элементом PowerShell
    # разворачивает в строку, и splatting строки идёт ПОСИМВОЛЬНО - на Linux уходило «- N o P r o f
    # i l e», pwsh ругался на несуществующий аргумент 'N'. Буквы N нет ни в одном исходнике, поэтому
    # по тексту ошибки корень не ищется. Замер компаньона на сервере, /bin/echo вместо pwsh.
    $psArgs = @(if ($onWin) { '-NoProfile','-ExecutionPolicy','Bypass' } else { '-NoProfile' })

    # 🛑 Успех подтверждается ПОЛОЖИТЕЛЬНЫМ признаком, а не отсутствием ругани: проверка печатает под
    # -Quiet машинную строку RESULT: findings=N. Нет её - проверка не состоялась, и это должно быть
    # видно: раньше упавший вызов и чистая память давали одинаковое «замечаний нет».
    # $LASTEXITCODE в снимок, а не в $global: pool.ps1 зовёт этот файл В СВОЁМ процессе, и глобальное
    # присваивание затирало бы его код возврата.
    $found = $null; $why = $null; $lines = @()
    try {
        $lines = @(& $psExe @psArgs -File $checker -Dir $memDir -Quiet 2>&1)
        $code = $LASTEXITCODE
        foreach ($l in $lines) { if ("$l" -match 'RESULT:\s*findings=(\d+)') { $found = [int]$Matches[1] } }
        if ($null -eq $found) { $why = if ($code) { "код возврата $code" } else { 'нет ответа' } }
    } catch { $why = $_.Exception.Message }

    if ($null -eq $found) {
        # Причину печатаем ОБРЕЗАННОЙ и одной строкой: текст CommandNotFoundException длиннее всего
        # остального отчёта, а отчёт этот - последние строки перед сжатием или гашением. Первая строка
        # вывода добавляется потому, что штатный отказ здесь - гонка за MEMORY.md на PreCompact
        # (движок переписывает индекс, проверка читает), и без неё «НЕ ВЫПОЛНЕНА» ничего не объясняет.
        # Берём НЕСКОЛЬКО первых строк, а не одну: сообщение об ошибке дочернего процесса приходит
        # разорванным по ширине его консоли, и по одной строке в отчёте оставалось «Exception calling
        # "Rea». Префикс «<полный путь к .ps1> : » PowerShell приклеивает сам - он тоже съедал длину.
        $head = @($lines | Select-Object -First 4)
        if ($head.Count) {
            # Склейка БЕЗ разделителя: разрыв идёт по ширине буфера, а не по словам, и пробел-склейка
            # рвала слово пополам («Exception calling "Rea dAllText"»).
            $msg = (($head | ForEach-Object { "$_" }) -join '') -replace '^\S+\.ps1\s*:\s*', ''
            $why = ("{0}; {1}" -f $why, $msg)
        }
        $why = ($why -replace '\s+', ' ').Trim()
        if ($why.Length -gt 160) { $why = $why.Substring(0, 157) + '...' }
        Write-Output ("  структура: ПРОВЕРКА НЕ ВЫПОЛНЕНА - {0}" -f $why)
    }
    elseif ($found -eq 0) { Write-Output '  структура: замечаний нет' }
    else {
        # Печатаем НЕСКОЛЬКО, а не всё: это последние строки перед сжатием или гашением, и простыня
        # из тридцати однотипных пунктов там не помогает никому. Полный список - у самой проверки.
        # Счёт берём из RESULT, а тексты - по образцу: если оформление вдруг разъедется, число всё
        # равно верное, а за текстами вызывающий пойдёт к проверке сам.
        Write-Output ("  структура: замечаний {0}" -f $found)
        $notes = @($lines | Where-Object { "$_" -match '^\s+- ' })
        foreach ($n in ($notes | Select-Object -First 5)) { Write-Output ("  {0}" -f "$n".TrimEnd()) }
        if ($notes.Count -gt 5) { Write-Output ("    показаны 5 из {0}" -f $notes.Count) }
    }
    # Команду полного прогона печатаем ВСЕГДА - и при нуле замечаний, и при невыполненной проверке:
    # команда сверки памяти велит роли прогнать проверку повторно после своих правок «командой из её
    # вывода» (адрес в тексте команды не выписан намеренно - устареет), а новые дефекты появляются
    # именно от правок, то есть чаще всего у роли, у которой ДО правок было чисто.
    Write-Output ("    Полный прогон: {0} -Dir `"{1}`"" -f $checker, $memDir)
}
