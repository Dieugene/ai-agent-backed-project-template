# new-pool.selftest.ps1 - самопроверка скаффолдера пулов (new-pool.ps1 + гард имён в add-peer.ps1).
#   powershell -File new-pool.selftest.ps1
# Гоняется на одноразовом воркспейсе в TEMP: ни один живой пул не читается и не трогается.
# Раскатка настоящая, не -WhatIf: половина дефектов этого скрипта видна только на реальных файлах
# (гард уникальности слага находил САМ создаваемый пул, и под -WhatIf проба была зелёной).
# Unit checks for the pool scaffolder on a throwaway workspace. No live pool is touched.
$ErrorActionPreference = 'Continue'

# РЯДОМ С СОБОЙ, не абсолютом: копия обязана проверять КОПИЮ, иначе прогон из песочницы молча
# проверяет живой скрипт и зелёное относится не к тому объекту (обжигались на модуле памяти 04.08).
$NewPool = Join-Path $PSScriptRoot 'new-pool.ps1'
$AddPeer = Join-Path $PSScriptRoot 'add-peer.ps1'

# ⚠️ Движок зовём по платформе: на сервере исполняемого 'powershell' нет вовсе (там pwsh, обычно в
# ~/.local/pwsh/), и весь набор падал бы не на предмете, а на запуске — 15 красных из 29, все про
# «The term 'powershell' is not recognized». Нашёл компаньон первым же прогоном на Linux.
# -ExecutionPolicy — тоже windows-only параметр, на pwsh он лишний.
$OnWin = $true
try { $v = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($v) { $OnWin = [bool]$v.Value } } catch { }
$PsExe = if ($OnWin) { 'powershell' } else {
  $c = Join-Path $HOME '.local/pwsh/pwsh'
  if (Test-Path $c) { $c } else { 'pwsh' }
}
$PsArgs = if ($OnWin) { @('-NoProfile','-ExecutionPolicy','Bypass','-File') } else { @('-NoProfile','-File') }

$ws = Join-Path $env:TEMP ('new-pool-test-' + (Get-Random))
$null = New-Item -ItemType Directory -Path $ws -Force
$pass = 0; $fail = 0
function Check($name, $cond, $detail = '') {
  if ($cond) { $script:pass++; "  OK   $name" }
  else       { $script:fail++; "  FAIL $name $detail" }
}

# Дочерним процессом, а не дот-сорсингом: скрипт имеет свой param и Write-Host, который в текущей
# сессии не перехватывается (давало «0 файлов в плане» на исправном прогоне).
function Scaffold([string[]]$a) {
  $out = & $PsExe ($PsArgs + @($NewPool) + $a + @('-WorkspaceRoot',$ws)) 2>&1
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
}
# Без -WorkspaceRoot по умолчанию: нужен блоку про две области проверки, где корни РАЗНЫЕ.
function ScaffoldRaw([string[]]$a) {
  $out = & $PsExe ($PsArgs + @($NewPool) + $a) 2>&1
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
}
function Manifest([string]$folder) {
  $p = Join-Path $ws ($folder + '\pool.manifest.json')
  if (-not (Test-Path $p)) { return $null }
  return (Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json)
}
# ⚠️ Доска лежит В РАЗНЫХ МЕСТАХ по платформам: на Windows это .bat в корне пула, а на сервере пул
# живёт окном tmux, и .bat кладётся в витрину _windows/ для рабочей машины. Проверка, искавшая только
# windows-путь, на Linux краснела не по предмету — а соседняя («доски по имени каталога НЕТ») там
# зеленела по НЕВЕРНОЙ причине: в том месте не было ничего ни под каким именем. Нашёл компаньон
# прогоном на сервере.
function Boards([string]$folder) {
  $dir = Join-Path $ws $folder
  if (-not $OnWin) { $dir = Join-Path $dir '_windows' }
  return @(Get-ChildItem -LiteralPath $dir -Filter 'board-*.bat' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

'--- 1. слаг = имя сессии tmux: служебные символы отвергаются'
# Пул со слагом «.foo» создавался молча, а первое окно роли падало с «can't specify pane here».
foreach ($bad in @('.dotted', 'Capitalized', '123', '-leading', 'has space', 'colon:here')) {
  $r = Scaffold @('-Name','probe-bad','-Slug',$bad,'-Roles','lead')
  Check "отвергает слаг '$bad'" ($r.Code -ne 0)
}
# Регистр отдельной строкой: -notmatch его игнорирует, и гард на заглавных был декорацией.
$r = Scaffold @('-Name','probe-bad','-Slug','MixedCase','-Roles','lead')
Check 'сравнение слага регистрозависимое (-cnotmatch, не -notmatch)' ($r.Code -ne 0)

'--- 2. имя роли = имя окна tmux: та же проверка на второй половине адреса'
foreach ($bad in @('tech.lead', 'TechLead', 'has space', 'a:b')) {
  $r = Scaffold @('-Name','probe-bad2','-Roles',$bad)
  Check "отвергает роль '$bad'" ($r.Code -ne 0)
}
$r = Scaffold @('-Name','probe-bad3','-Roles','lead','-Lead','lead')
Check 'здоровое имя роли проходит' ($r.Code -eq 0)

'--- 3. -Roles через -File приезжает ОДНОЙ строкой и режется по запятой'
# powershell -File массив не разбирает (замер: count=1). Без разреза пул получал единственную роль
# по имени «a,b,c» — с запятой в имени ящика, окна и обёртки. Дефект жил невидимым до гарда имён.
$r = Scaffold @('-Name','probe-roles','-Roles','alpha,beta,gamma','-Lead','alpha')
$m = Manifest 'probe-roles'
Check 'три роли, а не одна склеенная' ($null -ne $m -and @($m.roles).Count -eq 3) ("got " + $(if ($m) { @($m.roles).Count } else { 'no manifest' }))
Check 'имена ролей без запятых' ($null -ne $m -and ((@($m.roles | ForEach-Object { $_.owner }) -join '') -notlike '*,*'))

'--- 4. каталог и слаг развязаны'
$r = Scaffold @('-Name','_hidden-crew','-Slug','shopcrew','-PoolTitle','Смена магазина','-Roles','supervisor,devops','-Lead','supervisor')
Check 'раскатка прошла' ($r.Code -eq 0) $r.Text
$m = Manifest '_hidden-crew'
Check 'манифест несёт СЛАГ, а не имя каталога' ($null -ne $m -and $m.slug -eq 'shopcrew') ("got '" + $(if ($m) { $m.slug }) + "'")
Check 'корень манифеста указывает на КАТАЛОГ' ($null -ne $m -and ([string]$m.root).EndsWith('_hidden-crew'))
Check 'доска названа по слагу' ((Boards '_hidden-crew') -contains 'board-shopcrew.bat')
Check 'доска по имени каталога НЕ создана' (-not ((Boards '_hidden-crew') -contains 'board-_hidden-crew.bat'))

'--- 5. человеческое имя пула: его печатает строкой пикер'
Check 'poolTitle доехал в title' ($null -ne $m -and $m.title -eq 'Смена магазина') ("got '" + $(if ($m) { $m.title }) + "'")
$r = Scaffold @('-Name','plain-crew','-Roles','lead,helper')
$m2 = Manifest 'plain-crew'
Check 'без poolTitle title падает на слаг' ($null -ne $m2 -and $m2.title -eq 'plain-crew') ("got '" + $(if ($m2) { $m2.title }) + "'")

'--- 6. повторный прогон: дозаливка законна, переименование - нет'
# Emit никогда не переписывает существующее, поэтому прогон с ДРУГИМ слагом не переименовывал пул,
# а проходил вхолостую и клал рядом вторую доску. Снаружи это выглядело успехом.
$r = Scaffold @('-Name','_hidden-crew','-Slug','shopcrew','-Roles','supervisor,devops','-Force')
Check 'тот же слаг: прогон проходит (дозаливка недостающего)' ($r.Code -eq 0) $r.Text
$r = Scaffold @('-Name','_hidden-crew','-Slug','shopteam','-Roles','supervisor,devops','-Force')
Check 'другой слаг: отказ, а не холостой проход' ($r.Code -ne 0)
Check 'вторая доска рядом не появилась' ((Boards '_hidden-crew').Count -eq 1) (((Boards '_hidden-crew') -join ','))

'--- 7. гард уникальности слага: чужой пул ловится, свой собственный - нет'
$r = Scaffold @('-Name','other-folder','-Slug','shopcrew','-Roles','lead')
Check 'слаг чужого пула занят' ($r.Code -ne 0)

'--- 8. add-peer: та же проверка имени на пути добавления роли в ЖИВОЙ пул'
$mfPath = Join-Path $ws 'plain-crew\pool.manifest.json'
# add-peer выводит каталог шаблонов от своего расположения (..\templates\add-peer). У копии, лежащей
# в песочнице, соседа-templates нет, и скрипт умирает на «template missing» ДО гарда имён — блок
# краснел бы четырьмя проверками сразу, а мутация гарда при этом не меняла бы ничего. Поэтому путь
# ищется явно, а если шаблонов нет вовсе — блок ПРОПУСКАЕТСЯ вслух, а не притворяется зелёным.
$tplDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\add-peer'
if (-not (Test-Path $tplDir) -and $env:POOL_SELFTEST_TEMPLATES) { $tplDir = $env:POOL_SELFTEST_TEMPLATES }
# ⚠️ Обязательные параметры (-Title -Display -Mission) передаём ВСЕ. Без них скрипт падает на разборе
# аргументов, и проверка «плохое имя отвергнуто» зеленела по НЕВЕРНОЙ причине — гард при этом не
# исполнялся вовсе. Поймано тем, что положительный случай оказался красным на исправном коде.
function Peer([string]$owner) {
  $out = & $PsExe ($PsArgs + @($AddPeer,
                   '-Manifest',$mfPath,'-Owner',$owner,'-Title','Ревьюер',
                   '-Display',('Reviewer-' + $owner),'-Mission','проверяет',
                   '-TemplatesDir',$tplDir,'-DryRun')) 2>&1
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
}
if (-not (Test-Path $tplDir)) {
  "  SKIP блок 8: нет каталога шаблонов ($tplDir). Задай POOL_SELFTEST_TEMPLATES, чтобы гонять его над копией."
} else {
  foreach ($bad in @('tech.lead', 'TechLead', 'a:b')) {
    $p = Peer $bad
    # Мало ненулевого кода: он бывает и от разбора аргументов, и от отсутствия шаблона. Требуем
    # ИМЕННО текст гарда - иначе проверка зеленеет по посторонней причине, а гард не исполняется.
    Check "add-peer отвергает '$bad'" ($p.Code -ne 0 -and $p.Text -like '*tmux*') $p.Text
  }
  Check 'add-peer пропускает здоровое имя' ((Peer 'reviewer').Code -eq 0)
}

'--- 9. уникальность слага ищется в ДВУХ областях, а не только там, где создаётся пул'
# Боевой случай: пул создавали в подкаталоге проекта (-WorkspaceRoot ~/workspace/sbs), и гард искал
# конфликты ТОЛЬКО внутри него - пулы уровнем выше не виделись вовсе, молча. Слаг при этом ключ
# глобальный: по нему пикер и запускает, и ГАСИТ пул.
$mono = Join-Path $ws 'mono'
$null = New-Item -ItemType Directory -Path $mono -Force
$r = ScaffoldRaw @('-Name','nested-crew','-Slug','plain-crew','-Roles','lead','-SpaceRoot',$ws,'-WorkspaceRoot',$mono)
Check 'конфликт из корня пространства виден при создании в подкаталоге' ($r.Code -ne 0) $r.Text
# Контроль: свободный слаг в том же подкаталоге создаётся - гард не стал отказывать всему подряд.
$r = ScaffoldRaw @('-Name','nested-ok','-Slug','nested-ok','-Roles','lead','-SpaceRoot',$ws,'-WorkspaceRoot',$mono)
Check 'свободный слаг в подкаталоге проходит' ($r.Code -eq 0) $r.Text
# И обратное направление: пул, созданный в подкаталоге, виден при создании в корне пространства.
$r = ScaffoldRaw @('-Name','nested-ok','-Slug','nested-ok','-Roles','lead','-SpaceRoot',$ws,'-WorkspaceRoot',$ws)
Check 'конфликт из подкаталога виден при создании в корне' ($r.Code -ne 0) $r.Text

'--- 10. усилия ролей: параметр, а не константа'
$r = Scaffold @('-Name','effort-crew','-Roles','boss,hand','-Lead','boss','-LeadEffort','xhigh','-Effort','low')
Check 'раскатка с усилиями прошла' ($r.Code -eq 0) $r.Text
$leadBat = Join-Path $ws 'effort-crew\claude-boss.bat'
$handBat = Join-Path $ws 'effort-crew\claude-hand.bat'
$tsvE    = Join-Path $ws 'effort-crew\scripts\roles.tsv'
if (Test-Path $leadBat) {
  Check 'усилие ведущего доехало в обёртку' ((Get-Content $leadBat -Raw) -like '*-Effort xhigh*')
  Check 'усилие рядового доехало в обёртку'  ((Get-Content $handBat -Raw) -like '*-Effort low*')
} elseif (Test-Path $tsvE) {
  $rows = @(Get-Content $tsvE -Encoding UTF8 | Where-Object { $_ -notmatch '^#' -and $_.Trim() })
  Check 'усилие ведущего доехало в roles.tsv' (@($rows | Where-Object { $_ -like "boss`t*`txhigh`t*" }).Count -eq 1) ($rows -join ' / ')
  Check 'усилие рядового доехало в roles.tsv' (@($rows | Where-Object { $_ -like "hand`t*`tlow`t*" }).Count -eq 1) ($rows -join ' / ')
} else {
  Check 'усилия доехали до данных запуска' $false 'ни обёрток, ни roles.tsv'
}
$r = Scaffold @('-Name','effort-bad','-Roles','lead','-Effort','turbo')
Check 'неизвестное усилие отвергнуто' ($r.Code -ne 0)
$r = Scaffold @('-Name','effort-default','-Roles','boss,hand','-Lead','boss')
$defBat = Join-Path $ws 'effort-default\claude-boss.bat'
$defTsv = Join-Path $ws 'effort-default\scripts\roles.tsv'
if (Test-Path $defBat) {
  Check 'без параметра усилие ведущего прежнее (xhigh)' ((Get-Content $defBat -Raw) -like '*-Effort xhigh*')
} elseif (Test-Path $defTsv) {
  $rows = @(Get-Content $defTsv -Encoding UTF8 | Where-Object { $_ -notmatch '^#' -and $_.Trim() })
  Check 'без параметра усилие ведущего прежнее (xhigh)' (@($rows | Where-Object { $_ -like "boss`t*`txhigh`t*" }).Count -eq 1) ($rows -join ' / ')
} else {
  Check 'дефолт усилия проверяем' $false 'ни обёрток, ни roles.tsv'
}

'--- 11. серверная обвязка: pwsh считает аргументы и уходит, движок — прямой потомок окна tmux'
# Раньше role.sh делал exec pwsh, а pwsh запускал движок и оставался ждать родителем всю жизнь роли —
# ~135 МиБ на роль ни за что (замер фермы: обвязка = 40% памяти). Проверки строковые: собрать живую
# роль в песочнице нельзя, а разъезд шаблонов ловится и так.
# Сравнение через .Contains, а не -like: в шаблонах есть [switch] и ${ARR[@]}, а в -like квадратные
# скобки — класс символов, и совпадение получилось бы ложным.
# ⚠️ Проверяем ТЕКСТ ШАБЛОНОВ, а не сгенерированные файлы. Серверная тройка создаётся только в
# linux-ветке генератора, поэтому на Windows блок целиком пропускался — половина проверок ехала
# только на сервер и там же впервые падала. Шаблоны — обычные строки внутри генератора и читаются
# на любой платформе; заодно проверка перестаёт зависеть от того, где её запустили.
function Template([string]$var) {
  $all = [IO.File]::ReadAllText($NewPool)
  $i = $all.IndexOf('$' + $var + ' = @' + "'")
  if ($i -lt 0) { return '' }
  $s = $all.IndexOf("`n", $i) + 1
  $e = $all.IndexOf("`n'@", $s)
  if ($e -lt 0) { return '' }
  return $all.Substring($s, $e - $s)
}
$l = Template 'T_poolLaunchLinux'
$r = Template 'T_roleSh'
if (-not $l -or -not $r) {
  Check 'шаблоны серверной обвязки найдены в генераторе' $false 'T_poolLaunchLinux / T_roleSh не извлеклись'
} else {
  Check 'у запускателя есть режим -ArgsFile' ($l.Contains('[string]$ArgsFile'))
  Check 'аргументы разделены нулевым байтом' ($l.Contains('-join "`0"'))
  # 🛑 Аргументы отдаются ФАЙЛОМ, а не stdout. Первая версия печатала их в поток — и роли легли со
  # статусом 127: строку «[agent-memory] …» печатает МОДУЛЬ ПАМЯТИ, в pwsh при перенаправлении
  # Write-Host идёт в поток, и она склеилась с путём к движку в argv. Проверяем именно отсутствие
  # печати списка: глушить очередного печатающего — лечение случая, файл закрывает класс.
  Check 'список пишется в файл, а не в stdout' ($l.Contains('[IO.File]::WriteAllBytes($ArgsFile'))
  Check 'печати списка в stdout не осталось' (-not $l.Contains('[Console]::Out.Write'))
  Check 'следов первой схемы не осталось' ((-not $l.Contains('PrintArgs')) -and (-not $r.Contains('PrintArgs')))
  Check 'role.sh читает список нулевым разделителем из файла' ($r.Contains("readarray -d '' CLAUDE_ARGV < ""`$ARGF"""))
  Check 'временный файл убирается до exec' ($r.Contains('rm -f "$ARGF"'))
  Check 'role.sh делает exec ДВИЖКОМ' ($r.Contains('exec "${CLAUDE_ARGV[@]}"'))
  Check 'role.sh больше не делает exec pwsh' (-not $r.Contains('exec "$PWSH"'))
  # Переменную арм-гейта раньше ставил запускатель; он теперь умирает до старта движка, и без этой
  # строки гейт замолчал бы у всех ролей разом.
  Check 'вотчерная переменная ставится в role.sh' ($r.Contains('export POOL_WATCHER=1'))
  # 🛑 Дефолт вотчера обязан совпадать с тем, как его понимает pool-up.sh: у него пустое поле = 1
  # («жди хода роли»). При обратном дефолте здесь подъём ждал бы вечно события от роли, которой
  # промпт не отправляли — ровно тот сбой, что уже стоил восьми минут висящего подъёма.
  Check 'пустое поле вотчера трактуется как 1' ($r.Contains('WATCHER=1'))
  # Таблицу ролей правят и с Windows: без tr -d '\r' в поле приезжает «1\r», роль стартует без
  # промпта, а наблюдатель считает, что промпт был.
  Check 'поля roles.tsv чистятся от CR' ($r.Contains("tr -d '\r'"))
  Check 'временный файл убирается и по сигналам' ($r.Contains('EXIT INT TERM HUP'))
  Check 'есть проверка версии bash под readarray -d' ($r.Contains('BASH_VERSINFO'))
  # 🛑 Пропажа модуля памяти обязана быть ОТКАЗОМ, а не предупреждением: предупреждение печатается в
  # панель, которую первым же кадром затирает интерфейс движка, а роль тем временем поднимается с
  # ОБЩЕЙ памятью и без хуков сверки — записи уходят не туда, и замечают это через сутки.
  Check 'пропажа модуля памяти — отказ, а не предупреждение' ($l.Contains('[pool-launch] ОТКАЗ: не найден модуль памяти'))
  Check 'у отказа есть явная дверь' ($l.Contains('POOL_ALLOW_SHARED_MEMORY'))
  Check 'прежнего тихого WARNING не осталось' (-not $l.Contains('starts with SHARED memory'))
}

'--- 12. тот же отказ в windows-запускателе: раскладка платформ разная, правило одно'
$wl = Template 'T_poolLaunch'
if (-not $wl) {
  Check 'шаблон windows-запускателя найден' $false 'T_poolLaunch не извлёкся'
} else {
  Check 'windows: пропажа модуля памяти — отказ' ($wl.Contains('[pool-launch] ОТКАЗ: не найден модуль памяти'))
  Check 'windows: дверь на месте' ($wl.Contains('POOL_ALLOW_SHARED_MEMORY'))
}

Remove-Item $ws -Recurse -Force -ErrorAction SilentlyContinue
''
"PASS=$pass FAIL=$fail"
# Ненулевой код при провале: без него автогейт по exit code рапортует «прошло» даже при FAIL=5.
if ($fail -gt 0) { exit 1 }
