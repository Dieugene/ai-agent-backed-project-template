# memory-check.selftest.ps1 - самопроверка структурной проверки памяти (memory-check.ps1).
#   powershell -File memory-check.selftest.ps1
# Гоняется на одноразовых каталогах в TEMP: ни одна живая память не читается и не трогается.
#
# Зачем нужен: у memory-check не было ни одного теста, а он ходит по памяти ВСЕХ ролей — правку в нём
# проверяли глазами. Главный предмет здесь — признак «задача закрыта»: он решает, промолчать или нет,
# и ошибка в сторону молчания прячет ровно тот случай, ради которого проверка существует.
$ErrorActionPreference = 'Continue'

# РЯДОМ С СОБОЙ, не абсолютом: копия обязана проверять КОПИЮ (иначе прогон из песочницы молча
# проверяет живой файл, и зелёное относится не к тому объекту).
$Checker = Join-Path $PSScriptRoot 'memory-check.ps1'

$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
  if ($cond) { $script:pass++; "  OK   $name" }
  else       { $script:fail++; "  FAIL $name $detail" }
}

# Временный каталог: ДВЕ честные ветки, без «общего» решения.
# 🛑 `[IO.Path]::GetTempPath()` здесь НЕЛЬЗЯ: на Windows при пустом окружении он тихо возвращает
# `C:\Windows\`, а этот самотест в конце делает по своему каталогу `Remove-Item -Recurse -Force` —
# то есть громкий отказ сменился бы тихой рекурсивной уборкой в системном каталоге.
# 🛑 А `$env:TEMP` на Linux ПУСТ, и `Join-Path` с пустым первым аргументом бросает: `$root` остаётся
# null, падают ВСЕ проверки разом (замер на сервере: PASS=3 FAIL=12), и симптом читается как
# «сломана вся логика», хотя сломан временный каталог. `[IO.Path]::Combine` вместо `Join-Path`:
# последний ходит в провайдер PowerShell и на чужом пути бросает.
# ⚠️ Ветки ПЛАТФОРМЕННЫЕ, а не каскад «TEMP, иначе TMPDIR, иначе /tmp»: каскад на Windows при пустом
# окружении уходит в `/tmp`, что здесь значит `C:\tmp` — и уходит МОЛЧА (проверено подстановкой:
# самотест отработал там и напечатал PASS, будто всё в порядке).
$OnWinTmp = $true
try { $vw = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($vw) { $OnWinTmp = [bool]$vw.Value } } catch { }
$TmpBase = if ($OnWinTmp) { $env:TEMP } elseif ($env:TMPDIR) { $env:TMPDIR } else { '/tmp' }
if ([string]::IsNullOrWhiteSpace($TmpBase) -or -not (Test-Path -LiteralPath $TmpBase)) {
  Write-Host "НЕТ ВРЕМЕННОГО КАТАЛОГА: '$TmpBase' - прогон невозможен"; exit 2
}
$root = [IO.Path]::Combine($TmpBase, ('memory-check-test-' + (Get-Random)))
$null = New-Item -ItemType Directory -Path $root -Force

function New-Case([string]$name, [string]$index, [hashtable]$files) {
  $d = Join-Path $root $name
  $null = New-Item -ItemType Directory -Path $d -Force
  [IO.File]::WriteAllText((Join-Path $d 'MEMORY.md'), $index, (New-Object Text.UTF8Encoding($false)))
  foreach ($k in $files.Keys) {
    [IO.File]::WriteAllText((Join-Path $d $k), $files[$k], (New-Object Text.UTF8Encoding($false)))
  }
  return $d
}
function Body([string]$desc, [string]$text) {
  return "---`nname: x`ndescription: `"$desc`"`nmetadata:`n  node_type: memory`n  type: task`n---`n`n$text`n"
}
# Интерпретатор РЕЗОЛВИМ, а не зовём по имени: на сервере исполняемого `powershell` нет вовсе, и
# самотест там не запускался НИ РАЗУ - «зелено на платформе, где не исполняется».
$OnWin = $true
try { $v = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($v) { $OnWin = [bool]$v.Value } } catch { }
# Кандидаты по очереди: ProcessPath есть только в .NET 6+, MainModule врёт при запуске `dotnet pwsh.dll`.
$PsExe = 'powershell'
if (-not $OnWin) {
  $PsExe = $null
  try { $PsExe = [System.Environment]::ProcessPath } catch { }
  if (-not $PsExe) { try { $PsExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { } }
  if (-not $PsExe) { $PsExe = 'pwsh' }
}
# 🛑 @() снаружи if: одноэлементная ветка разворачивается в строку, splatting идёт посимвольно.
$PsArgs = @(if ($OnWin) { '-NoProfile','-ExecutionPolicy','Bypass' } else { '-NoProfile' })

# Кодировку консоли объявляем сами: под родителем с OEM-консолью (CP866, Git Bash) вывод дочернего
# powershell приходил мохибаке, Contains('...') по кириллице не совпадал - и НЕГАТИВНЫЕ проверки
# («-> молчит») зеленели на нечитаемом выводе, а позитивные краснели (нашёл оппонент 17.08).
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
function Run([string]$dir) {
  $out = & $PsExe @PsArgs -File $Checker -Dir $dir 2>&1 | Out-String
  # Канарейка: строка «записей:» печатается всегда; нет её - вывод нечитаем, и все Contains ниже врут.
  if (-not $out.Contains('записей:')) { throw "вывод проверки нечитаем (кодировка?): $out" }
  return $out
}
function RunQuiet([string]$dir) {
  $out = & $PsExe @PsArgs -File $Checker -Dir $dir -Quiet 2>&1 | Out-String
  return $out
}
function Flags([string]$out) { return $out.Contains('НЕ В ИНДЕКСЕ') }

'--- 1. закрытая задача вне индекса: проверка молчит'
$d = New-Case 'closed-desc' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки, достаточно длинное чтобы не спорить о мелочах')
  'task_done.md'   = (Body 'ЗАКРЫТО: дело сделано, файл оставлен отчётом' 'Итог работы и куда лёг результат.')
}
Check 'метка в описании -> молчит' (-not (Flags (Run $d)))

$d = New-Case 'closed-body' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки')
  'task_done.md'   = (Body 'итог по задаче' '**ЗАКРЫТО.** Результат лёг туда-то, дальше действий нет.')
}
Check 'метка первой строкой тела -> молчит' (-not (Flags (Run $d)))

'--- 2. открытая задача вне индекса: проверка говорит'
$d = New-Case 'open-orphan' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки')
  'task_live.md'   = (Body 'Открытая задача: доделать раздел 3.4' 'Остановился на разборе, дальше нужен ответ владельца.')
}
Check 'открытая сирота -> замечание' (Flags (Run $d))

'--- 3. контр-признак: закрытый ПОДПУНКТ внутри открытой работы не делает запись закрытой'
# Живой класс: «Регламентный срок ЗАКРЫТ», «Шаги 1 и 2 ЗАКРЫТЫ» — при широком окне такие записи
# замолкали целиком, включая якорь «где я остановился» серверной роли.
$d = New-Case 'open-with-closed-item' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md'  = (Body 'справка' 'тело справки')
  'task_partial.md' = (Body 'ОТКРЫТО: у согласования нет верхней границы' '## Регламентный срок ЗАКРЫТ — но сам вопрос открыт.')
}
Check 'описание ОТКРЫТО перекрывает метку в теле' (Flags (Run $d))

$d = New-Case 'not-verified' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки')
  'task_nv.md'     = (Body 'НЕ ПРОВЕРЕНО: вывода не делать' '**ЗАКРЫТО** по первому подпункту, остальное висит.')
}
Check 'описание НЕ ... перекрывает метку в теле' (Flags (Run $d))

'--- 4. метка засчитывается только в НАЧАЛЕ, а не где угодно'
$deep = "Первая строка тела.`n`nВторая.`n`nТретья.`n`nЧетвёртая.`n`n**ЗАКРЫТО.** А метка вот здесь, глубоко."
$d = New-Case 'deep-mark' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md'   = (Body 'справка' 'тело справки')
  'task_deep.md'     = (Body 'итог' $deep)
}
Check 'метка глубоко в теле НЕ считается' (Flags (Run $d))

$d = New-Case 'lowercase-mark' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md'  = (Body 'справка' 'тело справки')
  'task_lower.md'   = (Body 'задача закрыта вроде бы' 'задача закрыта, но строчными — это обычный текст, а не пометка.')
}
Check 'строчное «закрыта» НЕ считается' (Flags (Run $d))

'--- 5. послабление только для task_: прочие сироты остаются сиротами'
$d = New-Case 'non-task' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md'    = (Body 'справка' 'тело справки')
  'project_zzz.md'    = (Body 'ЗАКРЫТО: устройство того-то' 'Даже с меткой это не задача, а предмет — он обязан быть в индексе.')
}
Check 'project_ с меткой -> всё равно замечание' (Flags (Run $d))

'--- 6. соседняя проверка не сломана'
$d = New-Case 'broken-link' "- [Есть](reference_x.md) — следствие`n- [Нет](reference_missing.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки')
  'task_done.md'   = (Body 'ЗАКРЫТО: сделано' 'итог')
}
$out = Run $d
Check 'ССЫЛКА В НИКУДА по-прежнему ловится' ($out.Contains('ССЫЛКА В НИКУДА'))
Check 'закрытая задача при этом молчит' (-not (Flags $out))

'--- 7. текст замечания даёт ОБЕ ветки, а не только «как замолчать»'
# Прежняя редакция советовала только пометить закрытие — то есть настоящей пропаже предлагала
# способ исчезнуть из отчёта вместо способа починиться.
$d = New-Case 'hint-text' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки')
  'task_live.md'   = (Body 'Открытая задача: доделать' 'дальше нужен ответ')
}
$out = Run $d
Check 'подсказка предлагает вернуть строку' ($out.Contains('верни строку'))
Check 'подсказка предлагает пометить закрытие' ($out.Contains('ЗАКРЫТО'))

'--- 8. машинный хвост RESULT: контракт с вызывающими'
# 🛑 Этот блок существует потому, что на нём и погорели: memory-audit и memory-board выводили счёт
# замечаний ИЗ ОФОРМЛЕНИЯ печати, и упавшая проверка была неотличима от чистой памяти. Теперь у них
# есть положительный признак успеха - и он обязан быть закреплён здесь, иначе первая же уборка
# «под -Quiet не шуметь» вернёт беду молча.
# Чистая память ОБЯЗАНА иметь якорь: без него теперь стоит замечание «ЯКОРЯ НЕТ» (см. раздел 9).
$d = New-Case 'quiet-clean' "- [Якорь](task_session_state.md) — состояние`n- [Что-то](reference_x.md) — следствие`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' 'Остановился здесь. Следующий шаг такой-то, условие такое-то.')
  'reference_x.md' = (Body 'справка' 'тело справки, достаточно длинное чтобы не спорить о мелочах')
}
$out = RunQuiet $d
Check 'чистая память под -Quiet печатает RESULT: findings=0' ($out -match 'RESULT:\s*findings=0')

$d = New-Case 'quiet-dirty' "- [Есть](reference_x.md) — следствие`n- [Нет](reference_missing.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки')
  'task_live.md'   = (Body 'Открытая задача: доделать' 'дальше нужен ответ')
}
$out = RunQuiet $d
$m = [regex]::Match($out, 'RESULT:\s*findings=(\d+)')
Check 'память с замечаниями печатает RESULT с ненулевым счётом' ($m.Success -and [int]$m.Groups[1].Value -gt 0) $out
# Счёт в хвосте обязан совпадать с числом напечатанных замечаний, иначе вызывающий покажет одно, а
# человек по ссылке увидит другое.
$notes = @(($out -split "`r?`n") | Where-Object { $_ -match '^\s+- ' }).Count
Check 'счёт в RESULT совпадает с числом строк замечаний' ($m.Success -and [int]$m.Groups[1].Value -eq $notes) ("RESULT=$($m.Groups[1].Value) строк=$notes")

'--- 9. якорь против впрыска: замер идёт скриптом впрыска, а не своим счётом'
# 🛑 Повод: 17.08.2026 якорь ведущего вырос до 39 000 знаков при пределе 4000, роль после каждого сжатия
# получала 10 % (начало и старый хвост), поднималась на состоянии пятидневной давности - и проверка про
# это молчала, потому что предел жил только в memory-inject.ps1. Здесь закреплено: (а) переполненный
# якорь - замечание, и оно ПЕРВОЕ; (б) якорь под пределом - молчание; (в) `.noinject` - молчание, а
# ОТСУТСТВИЕ якоря и якорь не по имени - замечания; (г) нет измерителя рядом - замечание, а не тишина
# (измеритель, которого нет, неотличим от «в норме»); (д) боевой вход `-Owner/-Cwd` (поиск каталога вверх
# от cwd) - тот же ответ, что и `-Dir`. Предел берётся ИЗ ОТВЕТА впрыска, а не дублируется тут: второй
# экземпляр числа - второй источник правды.
$Injector = Join-Path $PSScriptRoot 'memory-inject.ps1'
$probe = @(& $PsExe @PsArgs -File $Injector -Dir $root -Measure 2>&1)  # $root - без MEMORY.md ⇒ none
$lim = 0
foreach ($l in @(& $PsExe @PsArgs -File $Injector -Dir (New-Case 'lim-probe' "- [Якорь](task_session_state.md) — состояние`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' 'коротко')
}) -Measure 2>&1)) { if ("$l" -match 'limit=(\d+)') { $lim = [int]$Matches[1] } }
Check 'впрыск отвечает на -Measure и называет предел' ($lim -gt 0) ("probe: $($probe -join '|')")

$big = ('слово ' * [int]($lim / 3))          # ~2×предел: заведомо не помещается
# Вторая строка индекса ведёт в никуда НАРОЧНО: без второго замечания проверка «стоит первым» была бы
# пустой - единственное замечание первое всегда.
$d = New-Case 'anchor-fat' "- [Якорь](task_session_state.md) — состояние`n- [Нет](reference_missing.md) — следствие`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' $big)
}
$out = Run $d
Check 'раздутый якорь -> ЯКОРЬ НЕ ДОЕЗЖАЕТ' ($out.Contains('ЯКОРЬ НЕ ДОЕЗЖАЕТ')) $out
$notesAll = @(($out -split "`r?`n") | Where-Object { $_ -match '^\s+- ' })
Check 'и это замечание стоит ПЕРВЫМ (при втором замечании рядом)' ($notesAll.Count -ge 2 -and $notesAll[0].Contains('ЯКОРЬ НЕ ДОЕЗЖАЕТ')) ($notesAll -join ' || ')
Check 'в тексте есть предел и доля' ($out -match "не больше $lim" -and $out -match '\d+ %')
# Доля проверяется ЧИСЛОМ: мутация «delivered всегда 100» иначе оставалась зелёной (нашёл оппонент).
# Тело ~2×предела ⇒ доедет 45–55 %.
$mm = [regex]::Match($out, 'доедет (\d+) %')
Check 'доля посчитана, а не напечатана константой (45-55 % при 2x)' ($mm.Success -and [int]$mm.Groups[1].Value -ge 45 -and [int]$mm.Groups[1].Value -le 55) ("доля=" + $mm.Groups[1].Value)
# Предел из ответа `-Measure` обязан быть НАСТОЯЩИМ пределом впрыска, а не числом, которое замер
# печатает сам по себе: гоняем впрыск в боевом режиме на том же раздутом якоре и меряем, сколько
# знаков записи он реально напечатал (голова + хвост = предел; служебные строки не считаем).
$inj = @(& $PsExe @PsArgs -File $Injector -Dir $d 2>&1 | ForEach-Object { "$_" })
$printed = (($inj | Where-Object { $_ -notmatch '^===' -and $_ -notmatch 'СЕРЕДИНА ВЫРЕЗАНА' }) -join "`n").Trim()
Check 'боевой впрыск режет раздутый якорь до объявленного предела' ($inj -match 'СЕРЕДИНА ВЫРЕЗАНА' -and [Math]::Abs($printed.Length - $lim) -le 8) ("напечатано $($printed.Length), предел $lim")

$d = New-Case 'anchor-fit' "- [Якорь](task_session_state.md) — состояние`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' 'Остановился здесь. Следующий шаг такой-то, условие такое-то.')
}
# Проверяем СТЕБЕЛЬ «ЯКОР»: замечания два - «ЯКОРЬ НЕ ДОЕЗЖАЕТ» и «ЗАМЕР ЯКОРЯ НЕ ВЫПОЛНЕН», - и поиск
# полного слова пропускал второе (мутация «замер молчит про .noinject» оставалась зелёной).
Check 'якорь под пределом -> молчит' (-not (Run $d).Contains('ЯКОР'))

# Впритык: тело чуть короче предела, а с шапкой - длиннее. Считаться обязано ТЕЛО (шапку впрыск
# срезает), иначе якорь в норме получит замечание, а роль - повод резать то, что и так доезжает.
$tight = ('слово ' * [int](($lim - 60) / 6))
$d = New-Case 'anchor-tight' "- [Якорь](task_session_state.md) — состояние`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' $tight)
}
Check 'якорь впритык под пределом (шапка не в счёт) -> молчит' (-not (Run $d).Contains('ЯКОР')) ("тело $($tight.Length) знаков, предел $lim")

$d = New-Case 'anchor-noinject' "- [Якорь](task_session_state.md) — состояние`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' $big)
  '.noinject' = ''
}
# Выключатель не замечание, но и не тишина (18.08): в счёт замечаний не входит, а строка о нём есть -
# иначе роль без точки входа пряталась бы за зелёной проверкой. Обе стороны проверяем явно: прежний
# тест «-> молчит про ЯКОР» зеленел бы и на выводе, где замечание есть (нашёл оппонент).
$out = Run $d
Check '.noinject при раздутом якоре -> молчит про ЯКОР (выключено нарочно)' (-not $out.Contains('ЯКОР'))
Check '.noinject -> отдельная строка «впрыск выключен», не замечание' ($out.Contains('впрыск выключен') -and (RunQuiet $d).Contains('findings=0')) $out
# И сам впрыск на боевом пути обязан сказать о выключателе одной строкой в контекст - раньше молчал,
# и роль не знала, что осталась без точки входа нарочно.
$inj = @(& $PsExe @PsArgs -File $Injector -Dir $d 2>&1 | ForEach-Object { "$_" }) -join "`n"
Check '.noinject: боевой впрыск печатает «ВЫКЛЮЧЕН», а не молчит' ($inj.Contains('ВЫКЛЮЧЕН') -and $inj.Contains('.noinject')) $inj

# Обратный слэш в ссылке оглавления: на Linux это обычный символ имени, и файл считался разом «ссылкой
# в никуда» и «сиротой» - две ложные тревоги (приёмка 17.08). На Windows тест слаб по построению
# (Split-Path понимает оба слэша) - мутацию «убрать нормализацию» красным покажет только прогон на
# Linux, он за серверной стороной.
$d = New-Case 'backslash-link' "- [Якорь](task_session_state.md) — состояние`n- [X](notes\reference_x.md) — следствие`n" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' 'Остановился здесь. Следующий шаг такой-то.')
  'reference_x.md' = (Body 'справка' 'тело справки, достаточно длинное чтобы не спорить о мелочах')
}
$out = Run $d
Check 'ссылка с обратным слэшем -> ни СИРОТЫ, ни ССЫЛКИ В НИКУДА' (-not $out.Contains('НЕ В ИНДЕКСЕ') -and -not $out.Contains('ССЫЛКА В НИКУДА')) $out

# ЗАПАСНОЙ проход впрыска со слэшем: якоря по имени НЕТ - только так этот путь вообще исполняется
# (прежний тест бил мимо: стенд с task_session_state.md в запасной проход не заходит - нашёл компаньон
# мутацией на Linux). Форма ссылки `](task_*\*.md)` - единственная, которую образец прохода вообще
# берёт с '\' внутри (`](sub\task_x.md)` образец отбрасывает: `task_` обязан идти сразу после скобки).
# GetFileName на Unix понимает только '/' - на Linux мутация «снять нормализацию» даёт ANCHOR: none;
# на Windows она зелёная по построению, красное покажет прогон компаньона.
$d = New-Case 'backslash-fallback' "- [Где я](task_sub\task_resume_point.md) — точка входа`n" @{
  'task_resume_point.md' = (Body 'Где остановился' 'Остановился здесь. Следующий шаг такой-то.')
}
$m = @(& $PsExe @PsArgs -File $Injector -Dir $d -Measure 2>&1 | ForEach-Object { "$_" }) -join ''
Check 'запасной проход: ссылка task_*\*.md с обратным слэшем находит файл (by=index)' ($m.Contains('by=index') -and $m.Contains('task_resume_point.md')) $m

# Якоря нет вовсе - замечание, а не тишина: без якоря впрыск после сжатия отдаёт список задач, и роль
# «восстанавливает контекст» из пересказа, который выглядит полным.
$d = New-Case 'anchor-absent' "- [Что-то](reference_x.md) — следствие`n" @{
  'reference_x.md' = (Body 'справка' 'тело справки, достаточно длинное чтобы не спорить о мелочах')
}
$out = Run $d
Check 'якоря нет -> ЯКОРЯ НЕТ' ($out.Contains('ЯКОРЯ НЕТ')) $out
Check '  ...и без ЗАМЕР/НЕ ДОЕЗЖАЕТ' (-not $out.Contains('ЗАМЕР') -and -not $out.Contains('НЕ ДОЕЗЖАЕТ'))

# Якорь под другим именем ловится запасным проходом впрыска (первая task_-ссылка), и это надо СКАЗАТЬ:
# 09.08 у 17 ролей из 44 подставлялось не то, заголовок был одинаковый.
$d = New-Case 'anchor-othername' "- [Где я](task_resume_point.md) — точка входа`n" @{
  'task_resume_point.md' = (Body 'Где остановился' 'Остановился здесь. Следующий шаг такой-то.')
}
$out = Run $d
Check 'якорь под другим именем -> ЯКОРЬ НЕ ПО ИМЕНИ, с именем файла' ($out.Contains('ЯКОРЬ НЕ ПО ИМЕНИ') -and $out.Contains('task_resume_point.md')) $out

# Толстый файл в запасном проходе: ОДНО замечание (НЕ ПО ИМЕНИ, с размером внутри), а не «НЕ ДОЕЗЖАЕТ»
# про рабочую задачу - то толкало бы резать не тот файл (нашёл оппонент на живой роли extractor-y).
$d = New-Case 'anchor-othername-fat' "- [Где я](task_where_i_stopped.md) — точка входа`n" @{
  'task_where_i_stopped.md' = (Body 'Где остановился' $big)
}
$out = Run $d
Check 'толстый файл запасного прохода -> только НЕ ПО ИМЕНИ, с размером' ($out.Contains('ЯКОРЬ НЕ ПО ИМЕНИ') -and $out.Contains('не помещается') -and -not $out.Contains('НЕ ДОЕЗЖАЕТ')) $out

# (д) Боевой вход впрыска - `-Owner/-Cwd`, каталог ищется ВВЕРХ от cwd: это единственный путь, которым
# хук ходит у всех ролей после каждого сжатия, и до 17.08 он не был покрыт ни одним тестом.
$proj = Join-Path $root 'proj'
$deep = Join-Path (Join-Path $proj 'a') 'b'
$null = New-Item -ItemType Directory -Path $deep -Force
$mem = Join-Path (Join-Path $proj '.memory') 'role-x'
$null = New-Item -ItemType Directory -Path $mem -Force
[IO.File]::WriteAllText((Join-Path $mem 'MEMORY.md'), "- [Якорь](task_session_state.md) — состояние`n", (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $mem 'task_session_state.md'), (Body 'ГДЕ Я ОСТАНОВИЛСЯ' $big), (New-Object Text.UTF8Encoding($false)))
$live = @(& $PsExe @PsArgs -File $Injector -Owner role-x -Cwd $deep 2>&1 | ForEach-Object { "$_" })
Check 'боевой вход -Owner/-Cwd находит каталог вверх от cwd и печатает якорь' (($live -join "`n").Contains('ПАМЯТЬ РОЛИ') -and ($live -join "`n").Contains('СЕРЕДИНА ВЫРЕЗАНА')) (($live | Select-Object -First 2) -join ' | ')
$mline = @(& $PsExe @PsArgs -File $Injector -Owner role-x -Cwd $deep -Measure 2>&1 | ForEach-Object { "$_" }) -join ''
$dline = @(& $PsExe @PsArgs -File $Injector -Dir $mem -Measure 2>&1 | ForEach-Object { "$_" }) -join ''
Check 'замер по -Owner/-Cwd и по -Dir - одна и та же строка' ($mline -and $mline -eq $dline) "$mline vs $dline"
Check 'маркер обрезки несёт числа и действие' (($live -join "`n") -match 'СЕРЕДИНА ВЫРЕЗАНА: якорь \d+ знаков, в контекст вклеено \d+ \(\d+ %\)' -and ($live -join "`n").Contains('СОСТОЯНИЕ'))

# (е) Точный адрес из настроек (-Dir) в АУДИТЕ: подъём от cwd - запасной путь для старых настроек.
# Повод - оппонент 18.08: подъём брал первого тёзку, а у qa-div родитель шины держит ПУСТОЙ каталог.
$Audit = Join-Path $PSScriptRoot 'memory-audit.ps1'
$noMem = Join-Path $root 'no-mem-here'
$null = New-Item -ItemType Directory -Path $noMem -Force
# cwd намеренно БЕЗ памяти: сработать может только -Dir. Мутация «аудит игнорирует -Dir» здесь красная.
$aud = @(& $PsExe @PsArgs -File $Audit -Owner probe-x -Cwd $noMem -Dir $mem -Reason manual 2>&1 | ForEach-Object { "$_" }) -join "`n"
Check 'аудит с -Dir работает по указанному каталогу, не по cwd' ($aud.Contains('[memory-audit] probe-x') -and $aud.Contains('структура')) $aud
# Адрес задан, но каталога нет -> тихий выход БЕЗ отката на подъём (cwd здесь нарочно такой, где подъём
# нашёл бы role-x: мутация «при битом -Dir гадаем подъёмом» станет красной именно тут).
$aud2 = @(& $PsExe @PsArgs -File $Audit -Owner role-x -Cwd $deep -Dir (Join-Path $root 'gone-dir') -Reason manual 2>&1 | ForEach-Object { "$_" }) -join "`n"
Check 'аудит: -Dir в несуществующее -> тихий выход, подъёмом не гадает' (-not $aud2.Contains('[memory-audit]')) $aud2

# Стенды компаньона 17.08 (сервер): (1) якорь на месте, а MEMORY.md нет - раньше впрыск обрывался ДО
# поиска якоря и молчал, проверка врала «ЯКОРЯ НЕТ»; (2) якорь из одной шапки - шапка ехала в контекст
# как содержание, замер рапортовал 100 %; (3) имя якоря в другом регистре - на Linux терялись оба прохода.
$d = New-Case 'anchor-no-index' "" @{
  'task_session_state.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' 'Остановился здесь. Следующий шаг такой-то.')
}
Remove-Item -LiteralPath (Join-Path $d 'MEMORY.md') -Force
$out = Run $d
Check 'нет MEMORY.md, якорь есть -> замечания про якорь НЕТ (только ИНДЕКСА НЕТ)' ((-not $out.Contains('ЯКОР')) -and $out.Contains('ИНДЕКСА НЕТ')) $out
$inj = @(& $PsExe @PsArgs -File $Injector -Dir $d 2>&1 | ForEach-Object { "$_" })
Check 'нет MEMORY.md, якорь есть -> впрыск печатает якорь, а не молчит' ((($inj -join "`n").Contains('ПАМЯТЬ РОЛИ')) -and (($inj -join "`n").Contains('Следующий шаг'))) (($inj | Select-Object -First 1) -join '')

$d = New-Case 'anchor-empty' "- [Якорь](task_session_state.md) — состояние`n" @{
  'task_session_state.md' = "---`nname: task_session_state`ndescription: `"ГДЕ Я ОСТАНОВИЛСЯ`"`n---"
}
$out = Run $d
Check 'якорь из одной шапки -> ЯКОРЬ ПУСТ, без НЕ ДОЕЗЖАЕТ' ($out.Contains('ЯКОРЬ ПУСТ') -and -not $out.Contains('НЕ ДОЕЗЖАЕТ')) $out
$inj = @(& $PsExe @PsArgs -File $Injector -Dir $d 2>&1 | ForEach-Object { "$_" })
Check 'якорь из одной шапки -> впрыск НЕ печатает шапку как точку входа' (-not (($inj -join "`n").Contains('точка входа после сжатия'))) (($inj | Select-Object -First 1) -join '')

$d = New-Case 'anchor-case' "- [Якорь](Task_Session_State.md) — состояние`n" @{
  'Task_Session_State.md' = (Body 'ГДЕ Я ОСТАНОВИЛСЯ' 'Остановился здесь. Следующий шаг такой-то.')
}
$out = Run $d
Check 'имя якоря в другом регистре -> считается якорем по имени (без НЕ ПО ИМЕНИ / ЯКОРЯ НЕТ)' (-not $out.Contains('ЯКОР')) $out

# (г) измерителя нет: копия проверки в пустом каталоге, без memory-inject.ps1 рядом.
$lone = Join-Path $root 'lone-checker'
$null = New-Item -ItemType Directory -Path $lone -Force
Copy-Item $Checker (Join-Path $lone 'memory-check.ps1')
$out = & $PsExe @PsArgs -File (Join-Path $lone 'memory-check.ps1') -Dir $d 2>&1 | Out-String
Check 'нет memory-inject.ps1 рядом -> ЗАМЕР ЯКОРЯ НЕ ВЫПОЛНЕН' ($out.Contains('ЗАМЕР ЯКОРЯ НЕ ВЫПОЛНЕН')) $out

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS=$pass FAIL=$fail"
if ($fail -gt 0) { exit 1 }
