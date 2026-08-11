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

$root = Join-Path $env:TEMP ('memory-check-test-' + (Get-Random))
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
function Run([string]$dir) {
  $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $Checker -Dir $dir 2>&1 | Out-String
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

Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS=$pass FAIL=$fail"
if ($fail -gt 0) { exit 1 }
