<#
  new-pool.ps1 — scaffolder for a new bus-native standalone agent pool.

  Generates the full skeleton of a standalone monorepo + agent pool wired to the
  shared maildir pool bus (__BUSTOOL__). Output shape
  mirrors the validated reference pool `pool-b`:

    <root>/
      .bus/                              (lazy maildir; created empty)
      .claude/settings.local.json        (single `pool.ps1 hook`)
      .mcp.json                          (per-agent Chrome profile: chrome-devtools --user-data-dir=...\${AGENT_OWNER})
      .gitignore
      CLAUDE.md                          (routing by AGENT_OWNER; roles table)
      README.md                          (user guide; wrappers table)
      claude-<owner>.bat  x N            (lead gets board auto-launch)
      board-<name>.bat
      _agent_pool_setup-<owner>.md  x N  (identity filled; mission/zones = TODO)
      scripts/{pool-launch.ps1, archive-completed-tasks.ps1, README.md}
      00_docs/{README.md, pool-roles.md, source-brief/{README.md, brief.md}}
      01_tasks/.gitkeep
      05_deliverables/{README.md, .gitkeep}

  The INFRA + structure is fully generated and working. DOMAIN content
  (role missions, methodology, checklist, brief fields) is left as TODO stubs —
  it is inherently bespoke and filled by the lead after scaffolding.

  Coordination is bus-native: pool.ps1 is NOT copied into the pool (one shared
  copy lives in .launcher\pool-bus). The pool carries only data (.bus), the hook
  registration (settings.local.json -> pool.ps1 hook by absolute path), and env
  in the wrappers (AGENT_OWNER / POOL_BUS_ROOT).

  USAGE
    # Rich (recommended): a UTF-8 JSON spec carries Cyrillic role labels cleanly.
    powershell -File new-pool.ps1 -Spec my-pool.json
    # Каталог назван иначе, чем сам пул (служебный префикс каталога — конвенция workspace):
    powershell -File new-pool.ps1 -Name _shop-crew -Slug shop-crew -Roles supervisor,devops
    # Quick inline (ASCII owners; labels become TODO placeholders):
    powershell -File new-pool.ps1 -Name pool-b -Roles methodist,author,critic -Lead methodist
    # Dry run:
    powershell -File new-pool.ps1 -Spec my-pool.json -WhatIf

  SPEC JSON
    {
      "name": "pool-b",                 (required; kebab-case; = ИМЯ КАТАЛОГА пула)
      "slug": "pool-b",                 (optional; default = name; ТЕХНИЧЕСКОЕ имя пула:
                                                 сессия tmux, ключ пикера, tab-конфиг Warp.
                                                 Строчная латиница/цифры/дефис/подчёркивание;
                                                 точка и двоеточие ЗАПРЕЩЕНЫ — ломают адресацию tmux)
      "pool": "pool-b-pool",            (optional; default "<slug>-pool")
      "poolTitle": "Уроки на каждый день",     (optional; default = slug; ЧЕЛОВЕЧЕСКОЕ имя пула —
                                                 именно его печатает строкой пикер)
      "title": "учебные задания на каждый день",(optional; one-liner for CLAUDE.md/README)
      "displaySuffix": "Daily",                (optional; default PascalCase of name's 1st segment)
      "leadEffort": "xhigh",                   (optional; default "xhigh"; усилие ВЕДУЩЕГО)
      "effort": "medium",                      (optional; default "medium"; усилие рядовых ролей.
                                                 Допустимые: low, medium, high, xhigh, max)
      "lead": "methodist",                     (optional; default first role)
      "roles": [
        { "owner": "methodist", "label": "Ведущий Методист — рамка и план" },
        { "owner": "author",    "label": "Автор — генерит задания" }
      ]
    }
#>
param(
    [string]   $Spec,
    [string]   $Name,
    # Слаг — ТЕХНИЧЕСКОЕ имя пула: сессия tmux, ключ пикера и его MRU, tab-конфиг Warp.
    # По умолчанию равен имени каталога; задаётся отдельно, когда каталог назван иначе. Служебный
    # префикс каталога («_foo», «.foo») в САМ слаг переносить нельзя — точка ломает адресацию tmux.
    [string]   $Slug,
    [string[]] $Roles,
    [string]   $Lead,
    [string]   $Title,
    # Человеческое имя пула — то, что видит владелец строкой в пикере («Супервайзоры: Launcher +
    # сервер»). По умолчанию равно слагу, и до этого параметра пикер печатал именно слаг: живые пулы
    # имя имеют, а сгенерированные — нет.
    [string]   $PoolTitle,
    [string]   $DisplaySuffix,
    [string]   $Pool,
    [string]   $WorkspaceRoot = '',
    # Корень ПРОСТРАНСТВА — не путать с предыдущим: в -WorkspaceRoot пул создаётся, а от -SpaceRoot
    # проверяется уникальность слага. Задавать руками нужно редко (нестандартная раскладка, прогон
    # набора проверок над песочницей); по умолчанию берётся конвенционный корень.
    [string]   $SpaceRoot     = '',
    # Усилия ролей. Раньше были зашиты константами, и владелец правил их в roles.tsv после создания
    # пула — то есть каждый следующий пул рождался снова со старым значением (просьба компаньона
    # 06.08). Значения по умолчанию прежние: ведущему выше, рядовым medium.
    [string]   $LeadEffort    = '',
    [string]   $Effort        = '',
    # --- витрина серверного пула (используется только при запуске на сервере) -
    # Пул живёт на сервере, но открывает его человек со своей машины: пикеру там нужны манифест и
    # обёртки со ssh. Скаффолдер кладёт их в <пул>/_windows/ как в выходной лоток, забирает оттуда
    # pull-server-pool.ps1. Второго генератора на той стороне НЕТ намеренно: две копии разъезжаются.
    [string]   $SshTarget    = 'agents@77.239.103.213',
    [string]   $SshKey       = 'C:\workspace-root\.launcher\secrets\owner_server',
    [string]   $WindowsRoot  = '',      # где витрина ляжет на рабочей машине; пусто = вывести из пути пула
    [switch]   $Force,
    [switch]   $WhatIf
)

$ErrorActionPreference = 'Stop'
$script:U8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- платформа -----------------------------------------------------------
# Та же идиома, что в pool.ps1: PowerShell 5.1 переменной $IsWindows не имеет ВООБЩЕ.
$script:OnWindows = $true
try { $__isWin = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue; if ($__isWin) { $script:OnWindows = [bool]$__isWin.Value } } catch { }

# ⚠️ Два РАЗНЫХ корня, и путать их нельзя:
#   $SpaceRoot     — корень пространства: где лежат общие инструменты (шина, память, канон).
#   $WorkspaceRoot — где создаётся сам пул. По умолчанию совпадает, но задаётся отдельно.
# Раньше инструменты были зашиты абсолютом, поэтому -WorkspaceRoot на них не влиял; сохраняем это.
# На сервере корень выводится от $HOME, а не зашивается: у коллеги другой домашний каталог, и
# зашитый /home/agents увёл бы его роли в чужое пространство.
if (-not $SpaceRoot) { $SpaceRoot = if ($script:OnWindows) { 'C:\workspace-root' } else { Join-Path $HOME 'workspace' } }
if (-not $WorkspaceRoot) { $WorkspaceRoot = $SpaceRoot }

# Общие инструменты пространства — одна копия на пространство, путь от корня ПРОСТРАНСТВА.
$WsBusTool    = Join-Path $SpaceRoot (Join-Path '.launcher' (Join-Path 'pool-bus' 'pool.ps1'))
$WsRefTool    = Join-Path $SpaceRoot (Join-Path '.references' 'ref.ps1')
$WsPrinciples = Join-Path $SpaceRoot (Join-Path '.launcher' (Join-Path 'standards' 'working-principles.md'))
$WsBoardTool  = Join-Path $SpaceRoot (Join-Path '.launcher' (Join-Path 'pool-bus' 'board-window.ps1'))

# Чем движок зовёт хуки. На сервере это pwsh по абсолютному пути: хук исполняется в неинтерактивной
# оболочке, где ~/.local/pwsh в PATH может не попасть.
$PwshExe = if ($script:OnWindows) { 'powershell' } else {
    $c = Join-Path $HOME '.local/pwsh/pwsh'
    if (Test-Path $c) { $c } else { 'pwsh' }
}
$HookPrefix  = if ($script:OnWindows) { 'powershell -NoProfile -ExecutionPolicy Bypass -File' } else { "$PwshExe -NoProfile -File" }
# Значение уезжает В JSON, поэтому экранируется здесь, а не в шаблоне.
$HookCmdJson = (('{0} "{1}"' -f $HookPrefix, $WsBusTool) -replace '\\', '\\') -replace '"', '\"'

# ---- канон параметров запуска для новых пулов -----------------------------
# Модель пиним ВСЕМ ролям: без явного --model сессия при `--resume` восстанавливается на своей
# старой модели, а глобальный /model владельца протекает во все пулы разом.
# Менять постфактум — .launcher\pool-bus\set-pool-runtime.ps1 (там те же значения).
$PoolModel      = 'claude-opus-5[1m]'
# Усилия задаются параметрами -LeadEffort / -Effort (или ключами спеки) и разбираются НИЖЕ, после
# чтения спеки: здесь их значения ещё не известны.

# ---- resolve spec --------------------------------------------------------
$roleList = @()   # array of [pscustomobject]@{ owner=..; label=..; lead=$bool }

if ($Spec) {
    if (-not (Test-Path $Spec)) { throw "spec file not found: $Spec" }
    $j = [System.IO.File]::ReadAllText($Spec, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $j.name)  { throw "spec.name is required" }
    $Name          = $j.name
    if ($j.pool)          { $Pool = $j.pool }
    if ($j.slug)          { $Slug = $j.slug }
    if ($j.title)         { $Title = $j.title }
    if ($j.poolTitle)     { $PoolTitle = $j.poolTitle }
    if ($j.leadEffort)    { $LeadEffort = $j.leadEffort }
    if ($j.effort)        { $Effort = $j.effort }
    if ($j.displaySuffix) { $DisplaySuffix = $j.displaySuffix }
    if ($j.lead)          { $Lead = $j.lead }
    if (-not $j.roles -or @($j.roles).Count -eq 0) { throw "spec.roles must be a non-empty array" }
    foreach ($r in $j.roles) {
        $roleList += [pscustomobject]@{ owner = [string]$r.owner; label = [string]$r.label }
    }
} else {
    if (-not $Name)  { throw "either -Spec <file> or -Name <name> -Roles <ids> is required" }
    if (-not $Roles -or $Roles.Count -eq 0) { throw "-Roles is required when not using -Spec" }
    # ⚠️ Через `powershell -File` массив НЕ разбирается: -Roles a,b,c приезжает ОДНОЙ строкой «a,b,c»
    # (замер: count=1). Ровно так вызов записан в шапке этого файла ⇒ пул молча создавался с одной
    # ролью по имени «a,b,c»: ящик шины, окно и обёртка — с запятой внутри. Дефект был невидим, пока
    # его не вскрыл гард на имена ролей. Из сессии PowerShell (& new-pool.ps1 -Roles a,b) массив
    # приходит нормальным, поэтому режем сами: настоящему массиву split безвреден, одну строку чинит.
    $Roles = @($Roles | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($o in $Roles) {
        $roleList += [pscustomobject]@{ owner = [string]$o; label = "TODO: роль <$o> — заполнить" }
    }
}

# ---- derive --------------------------------------------------------------
function To-Pascal([string]$s) {
    ($s -split '[-_]' | Where-Object { $_ } | ForEach-Object {
        $_.Substring(0,1).ToUpper() + $_.Substring(1)
    }) -join ''
}

if (-not $Slug)          { $Slug = $Name }

# ⚠️ Слаг становится ИМЕНЕМ СЕССИИ tmux, а там точка и двоеточие — служебные разделители адреса
# «сессия:окно.панель». Пул со слагом «.<organizer-pool>» создаётся молча, а первое же окно роли падает
# с «can't specify pane here» (боевой прогон; экранирование '=' не спасает, проверено).
# Каталог при этом может называться как угодно — он к tmux отношения не имеет.
# Регистр: сравнение слага разъезжается между сторонами — гарды сравнивают без учёта регистра,
# а tmux и поиск пула на сервере ([ "$s" = "$Pool" ]) — с учётом. Дешевле запретить заглавные.
# ⚠️ Поэтому сравнение здесь РЕГИСТРОЗАВИСИМОЕ: `-notmatch` регистр игнорирует, и класс [a-z0-9]
# пропускал бы '<Organizer-Pool>' — ровно тот случай, ради которого писан абзац выше (замер: -notmatch
# даёт False, -cnotmatch True). Обратно на -notmatch не менять, гард станет декорацией.
# Только цифры: в адресе tmux число в позиции окна читается как ИНДЕКС окна, а не имя.
if ($Slug -cnotmatch '^[a-z0-9][a-z0-9_-]*$' -or $Slug -match '^[0-9]+$') {
    throw ("имя пула '$Slug' не годится: строчная латиница, цифры, дефис и подчёркивание; первый знак — не разделитель; одни цифры нельзя. " +
           "Каталог называй как хочешь (-Name), а имя пула задай отдельно: -Slug <имя> либо slug в спеке. " +
           "Причина запрета: точка и двоеточие — служебные разделители адреса сессии tmux, пул с ними создаётся, но не поднимается.")
}
# Имя роли — ВТОРАЯ половина адреса tmux (сессия:окно): окно называется по owner, и точка в нём
# даёт тот же класс отказа, что и в слаге. Гард, написанный из-за служебных символов, обязан
# накрывать обе половины адреса, иначе роль не поднимется, а причина будет неочевидна.
foreach ($__r in $roleList) {
    if (-not $__r.owner) {
        throw "у роли в спеке пустой owner: это имя роли, по нему заводятся ящик шины, обёртка и окно. Заполни roles[].owner либо -Roles."
    }
    if ($__r.owner -cnotmatch '^[a-z0-9][a-z0-9_-]*$') {
        throw ("имя роли '$($__r.owner)' не годится: строчная латиница, цифры, дефис и подчёркивание. " +
               "Переименуй роль в -Roles либо в roles[].owner спеки. " +
               "Причина запрета: имя роли становится именем окна tmux, а точка и двоеточие в нём ломают адресацию.")
    }
}
# Производные считаются ПОСЛЕ проверки: иначе негодное значение сначала разъезжается по имени
# списка задач и заголовку сессии, и только потом выясняется, что оно негодное.
# Усилия: значения по умолчанию прежние (ведущему выше рядовых). Проверяем допустимость — опечатка
# иначе молча уезжает в roles.tsv и в обёртку роли, а движок споткнётся о неё только при старте,
# далеко от причины. Раньше обе величины были константами, и владелец правил их руками после
# создания пула ⇒ каждый следующий пул рождался снова со старым значением.
$__efforts = @('low','medium','high','xhigh','max')
foreach ($__pair in @(,@('-LeadEffort', $LeadEffort)) + @(,@('-Effort', $Effort))) {
    if ($__pair[1] -and ($__efforts -notcontains $__pair[1])) {
        throw ("значение " + $__pair[0] + " '" + $__pair[1] + "' не годится: " + ($__efforts -join ', ') + ".")
    }
}
$PoolLeadEffort = if ($LeadEffort) { $LeadEffort } else { 'xhigh' }
$PoolEffort     = if ($Effort)     { $Effort }     else { 'medium' }

if (-not $Pool)          { $Pool = "$Slug-pool" }
if (-not $PoolTitle)     { $PoolTitle = $Slug }
if (-not $DisplaySuffix) { $DisplaySuffix = To-Pascal (($Slug -split '-')[0]) }
if (-not $Lead)          { $Lead = $roleList[0].owner }
if (-not $Title)         { $Title = "TODO: одна строка — что делает пул" }
if (-not ($roleList.owner -contains $Lead)) { throw "lead '$Lead' is not among roles: $($roleList.owner -join ', ')" }

. (Join-Path $PSScriptRoot 'pool-manifest.ps1')
$Root       = Join-Path $WorkspaceRoot $Name
$Bus        = Join-Path $Root '.bus'
$ProjectKey = ($Root -replace '[^a-zA-Z0-9]', '-')
# ⚠️ Уникальность слага проверяется по ДВУМ областям сразу: от корня пространства и от каталога, где
# пул создаётся. Раньше проверялась только вторая, и вызов с -WorkspaceRoot <подкаталог проекта>
# сужал гард ДО ЭТОГО ПОДКАТАЛОГА: пулы уровнем выше не виделись вовсе, и об этом ничего не
# говорилось (боевой прогон компаньона: -WorkspaceRoot ~/workspace/sbs не видел ни <pool-a>, ни
# shop-<organizer-pool>). Слаг — глобальный ключ, по нему пикер и запускает, и ГАСИТ пул.
# Области СКЛАДЫВАЮТСЯ, а не выбираются: вопрос «лежит ли одно под другим» на Linux не отвечается —
# Test-PathOverlap сравнивает пути только по обратному слэшу, и любой ответ там был бы выдуман.
# -ExcludePath: манифест САМОГО целевого каталога конфликтом не считается. Без него повторный прогон
# (-Force дозаливает недостающие файлы в уже раскатанный пул — законный сценарий) отказывал «слаг
# занят», а занят он был сам собой. Видно только на настоящей раскатке: под -WhatIf манифеста ещё
# нет, и проба зелёная.
$__excl = [IO.Path]::Combine($Root, 'pool.manifest.json')   # не Join-Path: на несуществующем диске он БРОСАЕТ
$__areas = @($SpaceRoot)
$slugTaken = @(Get-SlugConflicts -Slug $Slug -WorkspaceRoot $SpaceRoot -ExcludePath $__excl)
if (-not [string]::Equals(([string]$SpaceRoot).TrimEnd([char]92, [char]47), ([string]$WorkspaceRoot).TrimEnd([char]92, [char]47), [StringComparison]::OrdinalIgnoreCase)) {
    $slugTaken += @(Get-SlugConflicts -Slug $Slug -WorkspaceRoot $WorkspaceRoot -ExcludePath $__excl)
    $__areas   += $WorkspaceRoot
}
$slugTaken = @($slugTaken | Select-Object -Unique)
if ($slugTaken.Count) { throw ((Get-GuardMessage 'slug') -f $Slug, $slugTaken[0]) }

foreach ($r in $roleList) {
    $r | Add-Member -NotePropertyName display -NotePropertyValue ((To-Pascal $r.owner) + '-' + $DisplaySuffix)
    $r | Add-Member -NotePropertyName isLead  -NotePropertyValue ($r.owner -eq $Lead)
}

$ownersInline = ($roleList.owner | ForEach-Object { '`' + $_ + '`' }) -join ', '
$roleCount   = $roleList.Count

# markdown roles table rows (CLAUDE.md / README / pool-roles)
# Чем роль поднимается — в текстах пула это упоминается в трёх таблицах. На сервере это не .bat,
# а окно фермы: обёртка одна на пул, роль передаётся ей аргументом.
function Get-RunHint([string]$owner) {
    if ($script:OnWindows) { 'claude-{0}.bat' -f $owner } else { 'scripts/role.sh {0}' -f $owner }
}
$rowsClaude = ($roleList | ForEach-Object {
    '| `' + $_.owner + '` | `' + $_.display + '` | ' + $_.label + ' | `' + (Get-RunHint $_.owner) + '` |'
}) -join "`n"
$rowsWrappers = ($roleList | ForEach-Object {
    $note = if ($_.isLead -and $script:OnWindows) { ' (лид; при старте открывает живую доску)' } else { '' }
    '| `' + (Get-RunHint $_.owner) + '` | ' + $_.label + $note + ' |'
}) -join "`n"

# Доска отдельным окном — только на рабочей машине. На сервере окон нет: доска живёт окном tmux
# (`board`), его поднимает pool-up.sh вместе с пулом, поэтому обёртке лида добавлять нечего.
$boardCmd = if ($script:OnWindows) {
    'powershell -NoProfile -ExecutionPolicy Bypass -File "' + $WsBoardTool + '" -BusRoot "' + $Bus + '"'
} else { '' }

# ---- shared coordination block (CLAUDE.md + onboarding) ------------------
# Slim: knowledge lives in skills (coordinating-on-the-pool-bus / operating-in-a-pool)
# backed by .references\ref.ps1; the direct ref.ps1 call is a self-sufficient fallback
# for live sessions that predate skill discovery.
$COORD = @'
### Координация с соседями — через `pool` (НЕ через Tasks API)
Задача соседу / ответ / отчёт / доска — командой `pool` (maildir-шина), НЕ `TaskCreate`/`TaskUpdate`. Команды и правила — скил **`coordinating-on-the-pool-bus`**; онбординг/вотчер/выход сессии — скил **`operating-in-a-pool`**. Прямой доступ без скилов: `& "__REF__" pool-coordination`. Крупные материалы — файлом, в сообщении — ссылка на путь. Личные todo — `TaskCreate(metadata={kind:"personal"})`.
'@

# ---- file bodies (single-quoted here-strings + token replace) -----------
$T_settings = @'
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "__HOOKCMD__ hook"
          },
          {
            "type": "command",
            "command": "__HOOKCMD__ activity"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "__HOOKCMD__ activity"
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "__HOOKCMD__ activity"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "__HOOKCMD__ activity"
          }
        ]
      }
    ]
  }
}
'@

# Per-agent Chrome isolation: overrides the global (profile-less) chrome-devtools MCP
# so each agent gets its OWN Chrome profile keyed by AGENT_OWNER (set by the wrapper).
# Without --user-data-dir chrome-devtools-mcp falls back to ONE shared default profile
# (~/.cache/chrome-devtools-mcp/chrome-profile) -> concurrent browser agents evict each
# other. ${AGENT_OWNER:-_plain} is expanded by Claude Code (env-expansion works in
# project .mcp.json; project scope overrides the user-scope global by server name).
$T_mcp = @'
{
  "mcpServers": {
    "chrome-devtools": {
      "type": "stdio",
      "command": "npx",
      "args": [
        "chrome-devtools-mcp@latest",
        "--user-data-dir=D:\\_workspace\\.chrome-profiles\\${AGENT_OWNER:-_plain}"
      ],
      "env": {}
    }
  }
}
'@

# На сервере Chrome нет вовсе. Пустой список серверов лучше отсутствующего файла: иначе роль
# унаследует глобальный браузерный MCP пространства и потратит первый ход на попытку его поднять.
if (-not $script:OnWindows) {
    $T_mcp = @'
{
  "mcpServers": {}
}
'@
}

$T_gitignore = @'
# Claude Code local settings (per-machine; hook registration + MCP wiring w/ absolute paths)
.claude/settings.local.json
.mcp.json

# Pool bus (maildir coordination state, owned by pool.ps1; not source)
.bus/
# Agent long-term memory: local only, never leaves this machine
# (each role keeps its own git repo inside .memory\<role>\)
.memory/

# Standard
__pycache__/
*.pyc
.venv/
venv/
.env
node_modules/
*.log
'@

$T_poolLaunch = @'
# pool-launch.ps1
# Launcher for Claude Code in agent-pool mode with automatic session resume.
# Resumes the session whose customTitle matches $SessionTitle; else starts fresh
# with --name. Env vars from the parent .bat (AGENT_OWNER, CLAUDE_CODE_TASK_LIST_ID,
# POOL_BUS_ROOT) are inherited into the spawned `claude` process = pool mode.

param(
    [string]$Effort = '',   # high for pool leads, medium for the rest; empty = inherit global effortLevel
    [string]$Model = '',    # empty = inherit client default model
    [Parameter(Mandatory)][string]$SessionTitle,
    [string]$ProjectKey = '__PROJECTKEY__',
    # Optional UTF-8 file whose contents are submitted as the session's first prompt
    # (e.g. "arm your watcher and await tasks"). Re-sent on every launch/resume.
    [string]$InitialPromptFile = ''
)

$ErrorActionPreference = 'Continue'

# Task-store hygiene (best-effort): archive completed personal todos so the
# built-in task-list context injection stays small. See archive-completed-tasks.ps1.
try {
    $janitor = Join-Path $PSScriptRoot 'archive-completed-tasks.ps1'
    if ((Test-Path $janitor) -and $env:CLAUDE_CODE_TASK_LIST_ID) {
        & $janitor -ListId $env:CLAUDE_CODE_TASK_LIST_ID -Quiet
    }
} catch { }

$projectDir = Join-Path $env:USERPROFILE ".claude\projects\$ProjectKey"

function Find-SessionIdByTitle {
    param([string]$Title, [string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $titleEscaped = [regex]::Escape($Title)
    $matchPattern = '"customTitle":"' + $titleEscaped + '"'
    $files = Get-ChildItem -Path $Dir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        try {
            $titleLines = Select-String -Path $f.FullName -Pattern '"customTitle":"[^"]*"' -ErrorAction Stop
            if (-not $titleLines) { continue }
            if ($titleLines[-1].Line -match $matchPattern) { return $f.BaseName }
        } catch { continue }
    }
    return $null
}

# Optional startup prompt (read as UTF-8 so Cyrillic survives).
$initPrompt = ''
if ($InitialPromptFile -and (Test-Path $InitialPromptFile)) {
    try { $initPrompt = [System.IO.File]::ReadAllText($InitialPromptFile, [System.Text.Encoding]::UTF8).Trim() } catch { $initPrompt = '' }
}

# Stop-hook watcher arm-gate opt-in: watcher roles pass -InitialPromptFile; watcherless (devops/serverside) do not.
if ($InitialPromptFile) { $env:POOL_WATCHER = '1' }

$modelArgs = if ($Model) { @('--model', $Model) } else { @() }
$effortArgs = if ($Effort) { @('--effort', $Effort) } else { @() }

# Role-private auto-memory: one store per AGENT_OWNER instead of one shared per-cwd pile.
# Module lives in one place for the whole workspace (same model as pool.ps1).
$memoryArgs = @()
$agentMemoryModule = 'C:\workspace-root\.launcher\pool-bus\agent-memory.ps1'
if (Test-Path $agentMemoryModule) {
    . $agentMemoryModule
    $memoryArgs = Get-AgentMemoryArgs
} elseif ($env:POOL_ALLOW_SHARED_MEMORY -eq '1') {
    Write-Host "[pool-launch] ВНИМАНИЕ: модуль памяти не найден ($agentMemoryModule) — роль поднимается с ОБЩЕЙ памятью, это разрешено POOL_ALLOW_SHARED_MEMORY=1."
} else {
    # 🛑 Отказ, а не предупреждение. Предупреждение здесь печаталось в панель, которую первым же кадром
    # затирает интерфейс движка ⇒ след виден только тому, кто смотрел в эту секунду. А роль при этом
    # поднималась с ОБЩЕЙ памятью и без хуков сверки: записи уходили не туда, и обнаруживалось это в
    # лучшем случае через сутки. Дверь оставлена явной переменной — на случай, когда общая память
    # действительно задумана (память роли раскатана не везде).
    Write-Host "[pool-launch] ОТКАЗ: не найден модуль памяти $agentMemoryModule"
    Write-Host "  Без него роль поднялась бы с ОБЩЕЙ памятью и без хуков сверки — записи ушли бы не туда."
    Write-Host "  Почини раскладку пространства, либо задай POOL_ALLOW_SHARED_MEMORY=1, если так и задумано."
    exit 2
}

$sessionId = Find-SessionIdByTitle -Title $SessionTitle -Dir $projectDir

if ($sessionId) {
    Write-Host "[pool-launch] Resuming '$SessionTitle' (session $sessionId)"
    if ($initPrompt) { & claude --dangerously-skip-permissions @modelArgs @effortArgs @memoryArgs --resume $sessionId $initPrompt }
    else             { & claude --dangerously-skip-permissions @modelArgs @effortArgs @memoryArgs --resume $sessionId }
} else {
    Write-Host "[pool-launch] No prior session '$SessionTitle' found - starting fresh."
    if ($initPrompt) { & claude --dangerously-skip-permissions @modelArgs @effortArgs @memoryArgs --name $SessionTitle $initPrompt }
    else             { & claude --dangerously-skip-permissions @modelArgs @effortArgs @memoryArgs --name $SessionTitle }
}

exit $LASTEXITCODE
'@

# Серверный запускатель. Отличий от windows-оригинала ровно четыре, и все из-за ОС; логика подъёма
# роли (возобновление по заголовку сессии) не менялась — это инвариант владельца:
#   1. каталог транскриптов от $HOME (в PowerShell он есть на обеих платформах), а не от USERPROFILE;
#   2. ключ проекта выводится из cwd этой машины, а не зашивается: у коллеги другой домашний каталог;
#   3. общий модуль памяти лежит в пространстве пользователя, а не по абсолютному D:\...;
#   4. `claude` резолвится явно — в неинтерактивной оболочке ~/.local/bin в PATH может не попасть.
$T_poolLaunchLinux = @'
# pool-launch.linux.ps1 - серверная версия (Linux, pwsh 7).

param(
    [string]$Effort = '',
    [string]$Model = '',
    [Parameter(Mandatory)][string]$SessionTitle,
    [string]$ProjectKey = '',
    [string]$InitialPromptFile = '',
    # «Посчитай и уйди»: вместо запуска движка кладёт готовый список аргументов В ЭТОТ ФАЙЛ и выходит.
    # Нужен, чтобы движок стартовал прямым потомком окна tmux, а pwsh не висел родителем всю жизнь
    # роли. Именно файл, а не stdout: в stdout печатает и модуль памяти, и любой будущий вызов, а
    # такая строка склеивается с первым аргументом — роли уже ложились со статусом 127.
    # Разделитель внутри файла — нулевой байт: стартовый промпт многострочный.
    [string]$ArgsFile = ''
)

$ErrorActionPreference = 'Continue'

# Ключ проекта = путь рабочего каталога, где каждый не-буквенно-цифровой символ заменён дефисом.
# Считаем сами, а не зашиваем: движок выводит его так же из своего рабочего каталога.
if (-not $ProjectKey) {
    $ProjectKey = ((Get-Location).Path -replace '[^A-Za-z0-9]', '-')
}
$projectDir = Join-Path $HOME (Join-Path '.claude' (Join-Path 'projects' $ProjectKey))

try {
    $janitor = Join-Path $PSScriptRoot 'archive-completed-tasks.ps1'
    if ((Test-Path $janitor) -and $env:CLAUDE_CODE_TASK_LIST_ID) {
        & $janitor -ListId $env:CLAUDE_CODE_TASK_LIST_ID -Quiet
    }
} catch { }

function Find-SessionIdByTitle {
    param([string]$Title, [string]$Dir)
    if (-not (Test-Path $Dir)) { return $null }
    $titleEscaped = [regex]::Escape($Title)
    $matchPattern = '"customTitle":"' + $titleEscaped + '"'
    $files = Get-ChildItem -Path $Dir -Filter '*.jsonl' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending
    foreach ($f in $files) {
        try {
            $titleLines = Select-String -Path $f.FullName -Pattern '"customTitle":"[^"]*"' -ErrorAction Stop
            if (-not $titleLines) { continue }
            if ($titleLines[-1].Line -match $matchPattern) { return $f.BaseName }
        } catch { continue }
    }
    return $null
}

$initPrompt = ''
if ($InitialPromptFile -and (Test-Path $InitialPromptFile)) {
    try { $initPrompt = [System.IO.File]::ReadAllText($InitialPromptFile, [System.Text.Encoding]::UTF8).Trim() } catch { $initPrompt = '' }
}

# Арм-гейт Stop-хука включается только для ролей с вотчером (они получают стартовый промпт).
if ($InitialPromptFile) { $env:POOL_WATCHER = '1' }

$modelArgs  = if ($Model)  { @('--model', $Model) }   else { @() }
$effortArgs = if ($Effort) { @('--effort', $Effort) } else { @() }

# Память роли: одна копия модуля на пространство, путь от корня пространства, а не абсолютный.
$memoryArgs = @()
$agentMemoryModule = Join-Path $HOME 'workspace/.launcher/pool-bus/agent-memory.ps1'
if (Test-Path $agentMemoryModule) {
    . $agentMemoryModule
    $memoryArgs = Get-AgentMemoryArgs
} elseif ($env:POOL_ALLOW_SHARED_MEMORY -eq '1') {
    Write-Host "[pool-launch] ВНИМАНИЕ: модуль памяти не найден ($agentMemoryModule) — роль поднимается с ОБЩЕЙ памятью, это разрешено POOL_ALLOW_SHARED_MEMORY=1."
} else {
    # 🛑 Отказ, а не предупреждение. Предупреждение здесь печаталось в панель, которую первым же кадром
    # затирает интерфейс движка ⇒ след виден только тому, кто смотрел в эту секунду. А роль при этом
    # поднималась с ОБЩЕЙ памятью и без хуков сверки: записи уходили не туда, и обнаруживалось это в
    # лучшем случае через сутки. Дверь оставлена явной переменной — на случай, когда общая память
    # действительно задумана (память роли раскатана не везде).
    Write-Host "[pool-launch] ОТКАЗ: не найден модуль памяти $agentMemoryModule"
    Write-Host "  Без него роль поднялась бы с ОБЩЕЙ памятью и без хуков сверки — записи ушли бы не туда."
    Write-Host "  Почини раскладку пространства, либо задай POOL_ALLOW_SHARED_MEMORY=1, если так и задумано."
    exit 2
}

$claudeExe = 'claude'
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    $candidate = Join-Path $HOME '.local/bin/claude'
    if (Test-Path $candidate) { $claudeExe = $candidate }
    else { Write-Host "[pool-launch] WARNING: 'claude' не найден ни в PATH, ни в ~/.local/bin" }
}

$sessionId = Find-SessionIdByTitle -Title $SessionTitle -Dir $projectDir

# Аргументы движка собираются ОДНИМ списком: он либо исполняется здесь, либо отдаётся вызывающему.
$claudeArgs = @('--dangerously-skip-permissions') + $modelArgs + $effortArgs + $memoryArgs
if ($sessionId) { $claudeArgs += @('--resume', $sessionId) } else { $claudeArgs += @('--name', $SessionTitle) }
if ($initPrompt) { $claudeArgs += $initPrompt }

$note = if ($sessionId) { "[pool-launch] Resuming '$SessionTitle' (session $sessionId)" }
        else            { "[pool-launch] No prior session '$SessionTitle' found - starting fresh." }

if ($ArgsFile) {
    # Режим «посчитай и уйди»: движок запускает сам вызывающий (role.sh делает exec), поэтому pwsh
    # не остаётся висеть родителем на всё время жизни роли — это ~135 МиБ на роль ни за что.
    #
    # 🛑 Аргументы отдаются ФАЙЛОМ, а не через stdout, и это не стиль, а единственный надёжный способ.
    # Первая версия печатала их в stdout — и роли легли со статусом 127: строку «[agent-memory] <роль>
    # -> <каталог>» печатает МОДУЛЬ ПАМЯТИ, в pwsh при перенаправлении Write-Host идёт в поток, и она
    # склеилась с путём к движку прямо в argv. Глушить конкретного печатающего (-Quiet у модуля) —
    # лечение случая: завтра напечатает кто-то ещё, и роль снова не поднимется. Файл закрывает класс:
    # stdout свободен для любой диагностики, включая полезную человеку в панели.
    #
    # Разделитель — НУЛЕВОЙ БАЙТ: стартовый промпт многострочный, любой строковый разделитель разорвал
    # бы его на несколько аргументов. Читать: readarray -d '' ARR < "$файл".
    Write-Host $note
    $out = @($claudeExe) + $claudeArgs   # первым элементом сам движок: вызывающий делает exec "${ARR[@]}"
    [IO.File]::WriteAllBytes($ArgsFile, [Text.Encoding]::UTF8.GetBytes(($out -join "`0")))
    exit 0
}

Write-Host $note
& $claudeExe @claudeArgs

exit $LASTEXITCODE
'@

$T_startup = @'
Старт пула.

1. Взведи свой **вотчер** входящих: следуй скилу `operating-in-a-pool` (или прямо `& "__REF__" pool-lifecycle`), раздел «Выход хода» — инструментом `Monitor` с `persistent: true`.
2. Подтверди идентичность: `pool mine`.

Дальше — по своему onboarding (`CLAUDE.md` → `_agent_pool_setup-<owner>.md`), жди задач. Если возобновлён в работе — проверь, что вотчер активен, и продолжай прерванное.
'@

$T_janitor = @'
# archive-completed-tasks.ps1
# Task-store janitor: moves COMPLETED task JSONs out of the live pool task-store
# into a sibling "<ListId>-archive" dir, so Claude Code's whole-list context
# injection (completed included, no owner filter) stays small. Coordination now
# lives on the maildir bus; this only keeps personal todos from accumulating.
# Safe: only status=completed older than -MinAgeHours; move (not delete); never
# overwrites an archived id (reused ids -> <id>.dupN.json). Best-effort.

param(
    [string]$ListId      = '__POOL__',
    # $HOME есть в PowerShell на обеих платформах; $env:USERPROFILE на Linux ПУСТ, и Join-Path с
    # пустым первым аргументом не возвращает пустоту, а бросает — дворник падал бы на первом запуске.
    [string]$TasksRoot   = (Join-Path $HOME (Join-Path '.claude' 'tasks')),
    [int]   $MinAgeHours = 12,
    [switch]$Quiet
)

$ErrorActionPreference = 'Continue'
$src = Join-Path $TasksRoot $ListId
$dst = Join-Path $TasksRoot ($ListId + '-archive')

if (-not (Test-Path $src)) {
    if (-not $Quiet) { Write-Host "[task-janitor] store not found: $src" }
    exit 0
}

$cutoff = (Get-Date).AddHours(-[math]::Abs($MinAgeHours))
$moved = 0; $failed = 0

Get-ChildItem -Path $src -Filter '*.json' -File -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_
    if ($file.LastWriteTime -ge $cutoff) { return }
    try {
        $task = (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction Stop) | ConvertFrom-Json -ErrorAction Stop
    } catch { return }
    if ($task.status -ne 'completed') { return }
    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    $destPath = Join-Path $dst $file.Name
    if (Test-Path -LiteralPath $destPath) {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
        $ext  = [System.IO.Path]::GetExtension($file.Name)
        $n = 1
        do { $destPath = Join-Path $dst ('{0}.dup{1}{2}' -f $stem, $n, $ext); $n++ } while (Test-Path -LiteralPath $destPath)
    }
    try { Move-Item -LiteralPath $file.FullName -Destination $destPath -ErrorAction Stop; $moved++ }
    catch { $failed++ }
}

if (-not $Quiet) { Write-Host "[task-janitor] $ListId : archived $moved completed task(s) older than ${MinAgeHours}h (failed $failed)" }
exit 0
'@

$T_scriptsReadme = @'
# scripts/ — pool helpers (__SLUG__)

Служебные скрипты запуска пула. Двойной клик по `.bat` в корне репозитория — обычный способ старта; эти файлы дёргаются ими.

| Файл | Что делает |
|------|------------|
| `pool-launch.ps1` | Запускает Claude Code в pool-режиме; ищет прошлую сессию по display name и **возобновляет** её (`--resume`), иначе стартует свежую (`--name`). |
| `archive-completed-tasks.ps1` | Дворник стора задач: уносит завершённые личные todo из живого списка в `<list>-archive`. Безопасен (move, не delete). |

Координация между ролями — через общую **pool-шину** (`__BUSTOOL__`), не через эти скрипты. Живая доска — `board-__SLUG__.bat` в корне.
'@

$T_claude = @'
# __NAME__ — точка входа Claude Code

Этот файл Claude Code читает при старте сессии с cwd `__ROOT__`. **Действуй по нему до любых других файлов.**

Проект: **__TITLE__.** Над проектом работает **pool из __COUNT__ ролей**. Параметрическую рамку (что конкретно делаем) держит `00_docs/source-brief/brief.md`; роли и конвейер — `00_docs/pool-roles.md`.

## Принципы работы (стоячие — действуют всегда)

- **Субагенты вместо своего контекста.** Рутину и параллельные куски делегируй субагентам; свой контекст береги для синтеза и решений.
- **Автономность до результата.** Пойми образ результата и работай автономно до него. Остановись и спроси только если: решение ответственное / вне твоей зоны; вскрылась развилка без контекста; нужен peer (поставил задачу — пингани). Иначе — разумный дефолт, причину зафиксируй, продолжай.

Полная версия — `__PRINCIPLES__`.

## Шаг 1. Определи режим работы

```
$env:AGENT_OWNER
$env:CLAUDE_CODE_TASK_LIST_ID
```

| Состояние | Режим |
|-----------|-------|
| `AGENT_OWNER` ∈ {__OWNERS_INLINE__} | **Pool-режим** — иди в Шаг 2 |
| `AGENT_OWNER` пустая | **Plain-сессия** — действуй по запросу пользователя |

## Шаг 2. Pool-режим: onboarding

Pool `__POOL__` — __COUNT__ ролей (полные описания и конвейер — `00_docs/pool-roles.md`):

| `AGENT_OWNER` | Display | Роль | Wrapper |
|---------------|---------|------|---------|
__ROWS_CLAUDE__

Все роли: cwd = `__ROOT__` (весь workspace); координация между ролями — через `pool` (см. Шаг 3); владелец задаётся `$env:AGENT_OWNER`.

**По порядку:** (1) не меняй cwd; (2) **открой свою память** — оглавление `MEMORY.md` приходит в контекст само, тела записей нет: начни с якорной записи «где я остановился» (первая строка оглавления) и записей `task_`; (3) прочитай свой `_agent_pool_setup-<owner>.md`; (4) прочитай общий контекст — `00_docs/source-brief/brief.md`, `00_docs/pool-roles.md`; (5) проверь `[POOL INBOX]` (баннер каждый ход) и `pool mine`.

После `/compact` — тот же порядок.

Признак активации pool — баннер `[POOL INBOX] <owner>: ...` в начале каждого промпта.

## Шаг 3. Общие правила

- **Workspace = зона пула.** Пиши в любую часть `__ROOT__` кроме `.bus/` (служебная шина), `.claude/` и чужих каталогов памяти `.memory/<другая роль>/`. Зоны записи по ролям — см. `pool-roles.md` и свой onboarding.
- **Чужая память — на чтение, не на запись.** Свой `.memory/<твоя роль>/` пишешь только ты; в чужой не пишешь и ничего оттуда не удаляешь, даже увидев устаревшее: там чужие открытые хвосты, и пропажу не заметит ни ты, ни владелец записи. Ошибку в чужой памяти — письмом её владельцу по шине. Источник правила при расхождении — `& "__REF__" pool-lifecycle`. ⚠️ **Появился у пула собственный свод правил — правило переносится ТУДА, а здесь остаётся одна строка со ссылкой:** две редакции одного правила хуже одной, работать будут по той, что короче и ближе.
- **Конвейер.** TODO (лид заполнит в `00_docs/pool-roles.md`): кто за кем, где гейты/приёмка.
__COORD__

## Связанные документы

- `00_docs/source-brief/brief.md` — параметрическая рамка (заполняет пользователь; роли читают отсюда).
- `00_docs/pool-roles.md` — роли и конвейер пула.
- `_agent_pool_setup-<owner>.md` — onboarding по каждой роли.
- `.memory/<owner>/` — долговременная память роли между запусками (файл на предмет, индекс `MEMORY.md` грузится сам).
- Координация — скилы `coordinating-on-the-pool-bus` / `operating-in-a-pool`.
- `__PRINCIPLES__` — принципы работы агентов.
'@

$T_readme = @'
# __NAME__

Монорепо с пулом ИИ-агентов: __TITLE__. Над проектом работает __COUNT__ ролей, координация — через общую pool-шину.

## Как запустить

Двойной клик по `.bat` в корне — каждая открывает свою роль в отдельном окне (сессия возобновляется автоматически):

| Файл | Роль |
|------|------|
__ROWS_WRAPPERS__
| `board-__SLUG__.bat` | Живая доска пула (кто чем занят) — отдельным окном |

Запускай те роли, что нужны прямо сейчас; необязательно все разом.

## Первый шаг

Заполни рамку — `00_docs/source-brief/brief.md`. Пока она пустая, лид уточняет, а не запускает работу на полную.

## Структура

| Папка | Что внутри |
|-------|------------|
| `00_docs/` | Рамка (`source-brief/`), роли, методические материалы. |
| `01_tasks/` | Рабочие циклы (по папке на задачу). |
| `05_deliverables/` | Готовый продукт. |
| `scripts/` | Служебные скрипты запуска. |
'@

$T_onboard = @'
# Pool Setup: __OWNER__ (__POOL__)

Onboarding роли «__LABEL__». Pool `__POOL__` — __COUNT__ ролей. Полные роли и конвейер — `00_docs/pool-roles.md`.

## Идентичность

| Поле | Значение |
|------|----------|
| Owner ID | `__OWNER__` |
| Роль | __LABEL__ |
| TASK_LIST_ID | `__POOL__` |
| Display name | `__DISPLAY__` |
| Cwd | `__ROOT__` (весь workspace) |
| Launcher | `claude-__OWNER__.bat`__LEAD_NOTE__ |
| Память | `.memory\__OWNER__\` — пишешь только сюда; оглавление `MEMORY.md` приходит в контекст само, тела записей открываешь по строке |
| Шина | путь в `$env:POOL_BUS_ROOT` (ставит wrapper); **соседи, кому можно писать, — `ls` по нему**, а не по памяти |

## Миссия

> TODO: опиши миссию роли — что делает, каким методом, что на выходе, где границы. (Лид/пользователь заполняет под рамку `00_docs/source-brief/brief.md`.)

## Контекст pool (__COUNT__ ролей)

| Owner | Display | Роль |
|-------|---------|------|
__ROWS_ONBOARD__

Конвейер — `00_docs/pool-roles.md` (TODO: лид опишет поток и гейты).

## Связь с peer'ами

__COORD__

## Зоны записи

> TODO: где пишет эта роль (какие папки), чего НЕ трогает.

## Как ты работаешь

__TYPING__Скилы по необходимости (`superpowers:verification-before-completion` перед «готово»; лид — `superpowers:writing-plans`, subagent-driven режим). `superpowers:brainstorming` по умолчанию НЕ использовать.

## Личные todo

`TaskCreate(subject='...', activeForm='...', metadata={ "kind": "personal" })` → `TaskUpdate(taskId, owner='__OWNER__')` — не зашумит баннер соседей.

## Связанные документы

- `CLAUDE.md` — точка входа workspace.
- `00_docs/source-brief/brief.md` — рамка (источник конкретики).
- `00_docs/pool-roles.md` — роли и конвейер.
- Координация — скилы `coordinating-on-the-pool-bus` / `operating-in-a-pool`.
'@

$T_poolRoles = @'
# Роли и конвейер пула __SLUG__

Pool `__POOL__` — __COUNT__ ролей. Цель: __TITLE__.

## Роли

| Owner | Display | Роль | Wrapper |
|-------|---------|------|---------|
__ROWS_CLAUDE__

> TODO (лид): по каждой роли — абзац: что держит, что на выходе, где границы. Перенеси сюда суть из `_agent_pool_setup-<owner>.md`.

## Конвейер

> TODO (лид): нарисуй поток — кто за кем, где гейты/право вето, где приёмка, как идёт петля правок. Один цикл работы живёт в `01_tasks/NNN_short_name/`.

## Зоны записи

> TODO (лид): таблица «роль → какие папки пишет».

## Координация

Между ролями — только через `pool` (maildir-шина), не Tasks API. Команды и правила — скил `coordinating-on-the-pool-bus`; онбординг/вотчер/выход сессии — скил `operating-in-a-pool`; прямой доступ — `& "__REF__" pool-coordination`. Живая доска — `board-__SLUG__.bat`.
'@

$T_sbReadme = @'
# source-brief/ — параметрическая рамка пула

Здесь живёт **рамка проекта** — всё, что делает пул конкретным. Каркас пула предметно-нейтрален; конкретику задаёт `brief.md`, роли читают её оттуда.

- **`brief.md`** — сам бриф (шаблон с полями). Заполняет пользователь (или лид со слов пользователя). Пока поля в `???` — пул в режиме согласования.

**Менять рамку безопасно в любой момент** — пул пересоздавать не нужно: обнови `brief.md`, роли подхватят на следующем запуске. Доп. материалы (сканы, программы) можно класть сюда же подпапками.
'@

$T_brief = @'
# Рамка проекта (source-brief)

> **Параметрическая рамка пула.** Заполняет пользователь; все роли читают отсюда. Пока поля в `???` — лид собирает уточняющие вопросы и согласует, работу на полную не запускает. Менять можно в любой момент.

## Контекст

- **Что делаем (одной фразой):** ???
- **Для кого / целевая аудитория:** ???
- **Ключевые ограничения:** ???

## Параметры (TODO под домен)

> Лид адаптирует список полей под проект (например: класс/предметы/учебники; источники; формат вывода; нормы).

| Параметр | Значение |
|----------|----------|
| ??? | ??? |

## Цели периода

- **Чего хотим достичь:** ???
- **Пожелания пользователя:** ???

---

*Заполнено: нет. Последнее обновление: —.*
'@

$T_delivReadme = @'
# 05_deliverables/ — готовый продукт

Сюда попадает **только принятое** — то, что прошло конвейер пула (`00_docs/pool-roles.md`). Раскладку определяет лид под рамку.

> TODO (лид): опиши формат итогового артефакта (шаблон карточки/документа/файла).
'@

$T_docsReadme = @'
# 00_docs/ — рамка и методические материалы

Постановка и стоячие документы пула.

| Файл / папка | Что это |
|--------------|---------|
| `source-brief/brief.md` | **Параметрическая рамка** — конкретика проекта. Заполняет пользователь; роли читают отсюда. |
| `pool-roles.md` | Роли пула и конвейер. |

> TODO (лид): по мере наполнения добавь сюда методологию, чек-листы, глоссарий — что нужно домену.
'@

# ---- skill stubs (thin: trigger + ref.ps1 injection; canon lives in .references) ----
# Bodies are single-quoted here-strings so backticks (code fences) stay literal.
$SK_windows = @'
# Ловушки среды Windows на этой машине

Выполни и следуй выводу:

```powershell
& "__REF__" windows
```
'@
$SK_secrets = @'
# Обращение с секретами

Выполни и следуй выводу:

```powershell
& "__REF__" secrets
```

**Жёсткое правило:** значение секрета не печатается никогда — ни в терминал, ни в лог, ни в отчёт. Проверяй наличие/длину, не значение.
'@
$SK_coord = @'
# Координация через pool-шину

Выполни и следуй выводу:

```powershell
& "__REF__" pool-coordination
```

**Жёсткое правило — сбой шины:** ошибка `pool: owner/bus not set`, нет баннера, падает pool.ps1 → это инфраструктура пула, НЕ твоя зона.
- НЕ читай и не правь скрипты шины (pool.ps1 и соседние).
- НЕ выставляй `$env:AGENT_OWNER`/`POOL_BUS_ROOT` вручную и не подставляй `-From <роль>` литералом — это маскирует корневую причину (сессия поднята не через wrapper, возможно у тебя чужая идентичность).
- Доложи пользователю (одной строкой: команда, ошибка) и продолжай свою работу.
'@
$SK_lifecycle = @'
# Жизненный цикл агента в пуле

Выполни и следуй выводу:

```powershell
& "__REF__" pool-lifecycle
```
'@
$SK_techlead = @'
# Работа Tech Lead'а

Выполни и следуй выводу:

```powershell
& "__REF__" tech-lead
```
'@
$SK_qa = @'
# Работа QA

Выполни и следуй выводу:

```powershell
& "__REF__" qa
```
'@
# name -> @{ desc; body }. Base 4 go to every pool; typing 2 added by role-name match.
$D_win  = 'Используй когда правишь .ps1/.bat/файлы с кириллицей, видишь кракозябры (mojibake), делаешь полный поиск или аудит по репозиторию («ничего не потерять»), либо получаешь EPERM (uv_spawn) при запуске дочерних процессов.'
$D_sec  = 'Используй когда рядом .env, ключи или токены; когда отлаживаешь docker/systemctl окружение (переменная «не доходит»); когда готовишь деплой или переносишь конфиги. Часть привычных команд незаметно печатает секреты в открытом виде.'
$D_coo  = 'Используй когда ставишь задачу соседу по пулу, отвечаешь или отчитываешься, видишь баннер [POOL INBOX], вернулся после /compact, спрашивают про доску пула, или команда pool выдаёт ошибку.'
$D_lif  = 'Используй на старте роли в пуле (первый ход после запуска, онбординг), при уходе в ожидание в конце хода, и при завершении сессии или перед /compact.'
$D_tl   = 'Используй если ты tech-lead (ведущий) и начинаешь задачу разработки, решаешь нужен ли TDD/план/ревью, стоишь на архитектурной развилке или собираешься делегировать работу.'
$D_qa   = 'Используй если ты qa и начинаешь тестирование — exploratory, регрессия, приёмка фичи, воспроизведение бага.'

# ---- emit ----------------------------------------------------------------
function Apply([string]$tmpl, [hashtable]$map) {
    # Loop until stable: a replacement value (e.g. __COORD__) may itself contain
    # another token (e.g. __NAME__); a single pass in arbitrary key order would
    # leave the freshly-injected token raw. Bounded to avoid runaway.
    for ($pass = 0; $pass -lt 5; $pass++) {
        $prev = $tmpl
        foreach ($k in $map.Keys) { $tmpl = $tmpl.Replace($k, [string]$map[$k]) }
        if ($tmpl -eq $prev) { break }
    }
    $tmpl
}

$baseMap = @{
    '__NAME__'          = $Name
    '__SLUG__'          = $Slug
    '__POOL__'          = $Pool
    '__ROOT__'          = $Root
    '__BUS__'           = $Bus
    '__PROJECTKEY__'    = $ProjectKey
    '__TITLE__'         = $Title
    '__COUNT__'         = [string]$roleCount
    '__OWNERS_INLINE__' = $ownersInline
    '__ROWS_CLAUDE__'   = $rowsClaude
    '__ROWS_WRAPPERS__' = $rowsWrappers
    '__COORD__'         = $COORD
    # Пути инструментов пространства: на рабочей машине те же, что были зашиты, на сервере — от $HOME.
    '__REF__'           = $WsRefTool
    '__PRINCIPLES__'    = $WsPrinciples
    '__BUSTOOL__'       = $WsBusTool
    '__HOOKCMD__'       = $HookCmdJson
    # Чем человек запускает роль. Разное по платформам, а в текстах пула упоминается часто.
    '__RUNROLE__'       = $(if ($script:OnWindows) { 'claude-<owner>.bat' } else { 'scripts/role.sh <owner>' })
}

# ---- серверная обвязка роли ---------------------------------------------
# На рабочей машине роль поднимает свой .bat. На сервере окно tmux зовёт одну обёртку на весь пул,
# а всё, что отличает роль от роли, лежит рядом данными: roles.tsv (заголовок сессии, усилие,
# вотчер) и pool.env (список задач, модель). Так добавление роли лидом — это строка в таблице,
# а не правка кода.
$T_roleSh = @'
#!/usr/bin/env bash
# Обёртка роли пула — серверная, одна на весь пул. Аналог claude-<owner>.bat с рабочей машины.
#
#   role.sh <роль> [--dry-run]
#
# Запускается ВНУТРИ окна tmux (окно = роль): exec отдаёт панель движку, чтобы владелец,
# подключившись, увидел живую сессию.
#
# ⚠️ Роли, которой нет в roles.tsv, обёртка НЕ поднимает и заголовок сессии не угадывает.
# Заголовок — ручка возобновления разговора: промахнёшься на символ, и движок начнёт пустой
# разговор вместо прежнего, а выглядеть это будет как успешный старт.
set -euo pipefail

# readarray -d '' появился в bash 4.4; на более старом отказ будет громким («invalid option»), но
# невнятным. Проверяем сами и говорим, чего не хватает.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 4 ]; }; then
  echo "role.sh: нужен bash >= 4.4 (сейчас ${BASH_VERSION:-?}): без readarray -d '' список аргументов движка не прочитать" >&2
  exit 2
fi
OWNER="${1:?укажи роль (см. scripts/roles.tsv)}"; shift || true
DRY=0
for a in "$@"; do case "$a" in --dry-run|-n) DRY=1 ;; esac; done

POOL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSV="$POOL/scripts/roles.tsv"
ENVF="$POOL/scripts/pool.env"

[ -f "$TSV" ] || { echo "нет описания ролей: $TSV" >&2; exit 2; }

LINE="$(awk -F'\t' -v o="$OWNER" '$1 !~ /^#/ && $1 == o { print; exit }' "$TSV")"
[ -n "$LINE" ] || {
  echo "роль '$OWNER' не описана в $TSV. Известные:" >&2
  awk -F'\t' '$1 !~ /^#/ && NF { print "  " $1 }' "$TSV" >&2
  exit 2
}

TITLE="$(printf '%s' "$LINE" | cut -f2 | tr -d '\r')"
EFFORT="$(printf '%s' "$LINE" | cut -f3 | tr -d '\r')"
WATCHER="$(printf '%s' "$LINE" | cut -f4 | tr -d '\r')"
# ⚠️ tr -d '\r' обязателен: таблицу правят и с Windows, и тогда в последнем поле приезжает «1\r»,
# которое не равно «1». Роль молча стартует БЕЗ стартового промпта и без POOL_WATCHER, а подъём
# продолжает ждать от неё хода — выглядит как зависание на ровном месте.
# ⚠️ Пустое поле вотчера = «не указано», и трактуется как 1 — так же, как его понимает pool-up.sh.
# Разойтись тут нельзя: у него пустое поле значит «ждать хода роли», и при обратном дефолте здесь
# подъём ждал бы вечно события от роли, которой промпт не отправляли.
if [ -z "${WATCHER:-}" ]; then
  echo "role.sh: у роли '$OWNER' пустое поле вотчера в $TSV — считаю 1 (как pool-up.sh). Проставь 0 или 1 явно." >&2
  WATCHER=1
fi
[ -n "$TITLE" ] || { echo "у роли '$OWNER' пустой заголовок сессии в $TSV" >&2; exit 2; }

# ⚠️ unset ПЕРЕД сорсингом: без него состояние переменной отражает файл ПЛЮС унаследованное окружение
# окна, и значение из профиля/tmux выдаётся за содержимое pool.env — молча и правдоподобно.
unset POOL_TASK_LIST_ID POOL_MODEL
TASK_LIST_ID=""; MODEL=""
if [ -f "$ENVF" ]; then
  # shellcheck disable=SC1090
  . "$ENVF"
  TASK_LIST_ID="${POOL_TASK_LIST_ID:-}"
  MODEL="${POOL_MODEL:-}"
fi
# Три случая, и они РАЗНЫЕ. `none` — законное «список намеренно не пиним» (пул из одной роли: защита
# от «роли растащили задачи по спискам» там без предмета). ПУСТАЯ строка остаётся ОТКАЗОМ: в этом же
# файле пустое поле вотчера значит «не указано», и две противоположные трактовки пустоты в одном
# месте — ловушка для человека, который правит pool.env через месяц.
if [ "$TASK_LIST_ID" = "none" ] || [ "$TASK_LIST_ID" = "-" ]; then
  TASK_LIST_ID=""
  PIN_TASK_LIST=0
else
  [ -n "$TASK_LIST_ID" ] || { echo "нет POOL_TASK_LIST_ID в $ENVF (пусто = «забыли»; намеренно не пинить список — впиши none)" >&2; exit 2; }
  PIN_TASK_LIST=1
fi

export AGENT_OWNER="$OWNER"
if [ "$PIN_TASK_LIST" = "1" ]; then
  export CLAUDE_CODE_TASK_LIST_ID="$TASK_LIST_ID"
else
  # ⚠️ «Не пиним» ≠ «не экспортируем»: переменная может прийти из окружения окна, и движок возьмёт
  # унаследованное. Проверяется `printenv CLAUDE_CODE_TASK_LIST_ID` в окне ДО вызова этой обёртки.
  unset CLAUDE_CODE_TASK_LIST_ID
fi
export POOL_BUS_ROOT="$POOL/.bus"
export POOL_INBOX_QUIET=1

# ⚠️ ~/.local/bin — там лежит обёртка `pool`, на которую ссылаются стартовый текст роли и вся
# документация. Без этой строки роль получает «command not found» на ПЕРВОЙ ЖЕ команде из своего
# онбординга (поймано на живом пуле 09.08). Идемпотентно: двойной прогон не плодит дублей в PATH.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) PATH="$HOME/.local/bin:$PATH" ;;
esac
export PATH

# Токен подписки пространства (файл режима 600). Не в argv и не в скрипте — только окружением.
if [ -f "$HOME/.config/agents/env" ]; then
  set -a; . "$HOME/.config/agents/env"; set +a
fi

PWSH="$HOME/.local/pwsh/pwsh"
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"
[ -n "$PWSH" ] && [ -x "$PWSH" ] || { echo "не найден pwsh" >&2; exit 2; }

LAUNCHER="$POOL/scripts/pool-launch.linux.ps1"
[ -f "$LAUNCHER" ] || { echo "нет запускателя: $LAUNCHER" >&2; exit 2; }

ARGS=( -NoProfile -File "$LAUNCHER" -SessionTitle "$TITLE" )
[ -n "$EFFORT" ] && ARGS+=( -Effort "$EFFORT" )
[ -n "$MODEL" ]  && ARGS+=( -Model "$MODEL" )
if [ "${WATCHER:-0}" = "1" ] && [ -f "$POOL/scripts/startup-prompt.md" ]; then
  ARGS+=( -InitialPromptFile "$POOL/scripts/startup-prompt.md" )
  # ⚠️ Арм-гейт Stop-хука включается этой переменной, а раньше её ставил ЗАПУСКАТЕЛЬ. Теперь он
  # считает аргументы и умирает до старта движка, поэтому ставим здесь — иначе гейт замолчал бы у
  # всех ролей разом, и заметили бы это не сразу.
  export POOL_WATCHER=1
fi

cd "$POOL"

if [ "$DRY" = "1" ]; then
  echo "роль:         $OWNER"
  echo "заголовок:    $TITLE"
  echo "усилие:       ${EFFORT:-<по умолчанию>}"
  echo "модель:       ${MODEL:-<по умолчанию>}"
  echo "список задач: $([ "$PIN_TASK_LIST" = "1" ] && echo "$TASK_LIST_ID" || echo "НЕ пиним (POOL_TASK_LIST_ID=none)")"
  echo "шина:         $POOL_BUS_ROOT"
  echo "вотчер:       $([ "${WATCHER:-0}" = "1" ] && echo "да, стартовый промпт передаётся" || echo "нет")"
  echo "аргументы:    $PWSH ${ARGS[*]} -ArgsFile <tmp>"
  exit 0
fi

# Движок запускаем САМИ. Раньше здесь был exec pwsh, а pwsh уже запускал claude и оставался ждать
# родителем на всё время жизни роли — ~135 МиБ на роль ни за что (замер фермы: обвязка = 40%).
# Теперь запускатель считает аргументы, кладёт их в файл и уходит, а движок становится прямым
# потомком окна tmux. ⚠️ Именно ФАЙЛ, а не stdout: в stdout печатает и модуль памяти, и любой
# будущий вызов, и такая строка склеивается с первым аргументом (роли уже ложились со статусом 127).
ARGF="$(mktemp "${TMPDIR:-/tmp}/pool-launch-argv.XXXXXX")"
trap 'rm -f "$ARGF"' EXIT INT TERM HUP
if ! "$PWSH" "${ARGS[@]}" -ArgsFile "$ARGF"; then
  echo "запускатель завершился с ошибкой — роль не поднята" >&2
  exit 2
fi
CLAUDE_ARGV=()
readarray -d '' CLAUDE_ARGV < "$ARGF"
if [ "${#CLAUDE_ARGV[@]}" -eq 0 ]; then
  echo "запускатель не вернул аргументов (см. сообщения выше) — роль не поднята" >&2
  exit 2
fi
# Файл удаляем ДО exec: exec заменяет процесс, и trap уже не сработает.
rm -f "$ARGF"
trap - EXIT
exec "${CLAUDE_ARGV[@]}"
'@

$T_poolEnv = @'
# Общие параметры запуска пула __SLUG__. Читает scripts/role.sh.
# Модель пиним всем ролям: без явного --model сессия при --resume восстанавливается на своей старой
# модели, а глобальный /model владельца протекает во все пулы разом.
# POOL_TASK_LIST_ID: идентификатор списка задач. Особые значения — `none` (или `-`): список намеренно
# НЕ пиним, роль работает со списком по умолчанию. ПУСТАЯ строка значением не является: это «забыли
# заполнить», и обёртка на ней отказывает.
POOL_TASK_LIST_ID=__POOL__
POOL_MODEL=__MODEL__
'@

# Таблица ролей: заголовок сессии = display (ровно то, что уходило в -SessionTitle в .bat),
# усилие по канону, вотчер всем кроме серверных/devops-ролей (стандарт: их взводит человек).
$rolesTsvHeader = @'
# Данные запуска ролей пула. Разделитель — ТАБУЛЯЦИЯ, четыре поля:
#   owner <TAB> заголовок сессии <TAB> усилие <TAB> вотчер (1 = получает стартовый промпт)
# Заголовок сессии — ручка возобновления разговора. Менять нельзя никогда: другой заголовок
# означает не «переименовали роль», а «начали пустой разговор вместо прежнего».
# ⚠️ Вотчер 0 — это НЕ поломка: роль поднимается в ПУСТОЙ сеанс и первого хода не делает, пока
# человек не напишет ей сам. По стандарту так живут devops и серверные роли (их входящие смотрит
# человек). Всё, что ждёт от роли события «начала ход» — в том числе pool-up.sh — обязано такие роли
# пропускать, иначе ждёт вечно: подъём висел восемь минут ровно по этой причине.
'@
# ⚠️ Перевод строки после шапки ОБЯЗАТЕЛЕН: here-string не включает последний перевод перед '@,
# и без него первая роль слипается с последней строкой комментария — обёртка её не находит.
# Поймано прогоном: лид пула оказался «не описан в roles.tsv».
$rolesTsv = $rolesTsvHeader + "`n" + (($roleList | ForEach-Object {
    $eff = if ($_.isLead) { $PoolLeadEffort } else { $PoolEffort }
    $wch = if ($_.owner -match 'devops') { '0' } else { '1' }
    "{0}`t{1}`t{2}`t{3}" -f $_.owner, $_.display, $eff, $wch
}) -join "`n") + "`n"

$created = @()
$skipped = @()
$merged  = @()
# Respectful writer: NEVER overwrites an existing file. If the target already exists it is left
# intact and recorded as skipped -> scaffolding into a populated project cannot destroy anything.
# Files that must blend into a pre-existing one (.gitignore, settings.local.json) go through the
# Merge-* helpers below instead of Emit.
function Emit([string]$rel, [string]$content, [switch]$Crlf) {
    $full = Join-Path $Root $rel
    if ($Crlf) { $content = ($content -replace "`r?`n", "`r`n") }
    if (Test-Path $full) { $script:skipped += $rel; return }
    if ($WhatIf) { $script:created += $rel; return }
    $dir = Split-Path $full -Parent
    [void][System.IO.Directory]::CreateDirectory($dir)
    # 🛑 .ps1 пишем С BOM, остальное — без. Windows PowerShell 5.1 читает .ps1 БЕЗ BOM как ANSI
    # (cp1251), и тогда байты 0x91/0x92 внутри многобайтных UTF-8 символов превращаются в «умные»
    # кавычки ‘ ’ — а движок считает их настоящими кавычками. Файл перестаёт ПАРСИТЬСЯ.
    # Поймано песочницей 09.08: свежесозданный пул не поднимался вовсе — `pool-launch.ps1` падал с
    # «The string is missing the terminator», хотя текст его синтаксически верен. Хватило ОДНОГО
    # эмодзи в комментарии. Отказ невидим до первого запуска роли, а радиус — все новые пулы.
    # ⚠️ Только .ps1: .sh с BOM ломается ещё хуже (shebang перестаёт быть первым байтом), .json с BOM
    # не читается частью парсеров.
    $enc = if ($rel -match '\.ps1$') { New-Object System.Text.UTF8Encoding($true) } else { $script:U8NoBom }
    [System.IO.File]::WriteAllText($full, $content, $enc)
    $script:created += $rel
}

# .gitignore: fresh file -> whole; existing -> append ONLY the pool lines it lacks, under a
# marker (idempotent). Never rewrites the user's existing rules.
function Merge-Gitignore([string]$rel, [string]$content) {
    $full = Join-Path $Root $rel
    if (-not (Test-Path $full)) { Emit $rel $content; return }
    $existing = [System.IO.File]::ReadAllText($full)
    $marker = '# --- bus-native agent pool ---'
    if ($existing -match [regex]::Escape($marker)) { $script:skipped += ($rel + ' (pool block present)'); return }
    $have = @($existing -split "`r?`n" | ForEach-Object { $_.Trim() })
    $want = @($content -split "`r?`n" | Where-Object { $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim() })
    $add  = @($want | Where-Object { $have -notcontains $_ })
    if ($add.Count -eq 0) { $script:skipped += ($rel + ' (all pool rules present)'); return }
    if ($WhatIf) { $script:merged += ("{0} (+{1} lines)" -f $rel, $add.Count); return }
    $nl = if ($existing.Contains("`r`n")) { "`r`n" } else { "`n" }
    [System.IO.File]::AppendAllText($full, ($nl + $marker + $nl + ($add -join $nl) + $nl), $script:U8NoBom)
    $script:merged += ("{0} (+{1} lines)" -f $rel, $add.Count)
}

# settings.local.json: fresh -> whole; existing -> blend pool hooks in, preserving permissions
# and any hooks already present (matched by command string, idempotent). Unparseable -> left
# intact + reported for manual merge.
function Merge-Settings([string]$rel, [string]$content) {
    $full = Join-Path $Root $rel
    if (-not (Test-Path $full)) { Emit $rel $content; return }
    try { $cur = [System.IO.File]::ReadAllText($full) | ConvertFrom-Json } catch { $script:skipped += ($rel + ' (exists, unparseable - left intact, merge pool hooks manually)'); return }
    $pool = $content | ConvertFrom-Json
    if (-not $cur.PSObject.Properties['hooks']) { $cur | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{}) }
    $added = 0
    foreach ($evt in $pool.hooks.PSObject.Properties.Name) {
        if (-not $cur.hooks.PSObject.Properties[$evt]) {
            $cur.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue $pool.hooks.$evt
            $added += @($pool.hooks.$evt.hooks.command).Count
        } else {
            $haveCmds = @($cur.hooks.$evt.hooks.command)
            $missing  = @($pool.hooks.$evt.hooks | Where-Object { $haveCmds -notcontains $_.command })
            if ($missing.Count) { $cur.hooks.$evt = @($cur.hooks.$evt) + $missing; $added += $missing.Count }
        }
    }
    if ($added -eq 0) { $script:skipped += ($rel + ' (pool hooks present)'); return }
    if ($WhatIf) { $script:merged += ("{0} (+{1} hook cmds)" -f $rel, $added); return }
    [System.IO.File]::WriteAllText($full, ($cur | ConvertTo-Json -Depth 20), $script:U8NoBom)
    $script:merged += ("{0} (+{1} hook cmds, permissions preserved)" -f $rel, $added)
}

# ⚠️ Каркас в этом каталоге уже раскатан, а слаг просят другой. Emit НИКОГДА не переписывает
# существующее, поэтому повторный прогон не переименовывает пул: он проходит вхолостую и кладёт
# рядом ВТОРУЮ доску board-<новый слаг>.bat. Снаружи выглядит как успех (боевой прогон компаньона).
# Миграционного пути нет намеренно: слаг задаёт заголовок сессии, а он — ручка возобновления
# разговора, и переименование живого пула теряет транскрипты. Это ручная операция, не скриптовая.
$__existing = Join-Path $Root 'pool.manifest.json'
if (Test-Path $__existing) {
    $__cur = $null
    try { $__cur = [System.IO.File]::ReadAllText($__existing) | ConvertFrom-Json } catch { }
    if ($__cur -and $__cur.slug -and ([string]$__cur.slug) -cne $Slug) {
        throw ("в $Root уже раскатан пул '$($__cur.slug)', а запрошен слаг '$Slug'. Переименовывать генератор не умеет: существующие файлы он не трогает, прогон прошёл бы вхолостую и добавил вторую доску. Варианты: задать -Slug $($__cur.slug), снести каркас и раскатать заново, либо переименовать руками — но помни, что слаг задаёт заголовок сессии, а он ручка возобновления разговора.")
    }
}

# guard
if (-not $WhatIf) {
    if ((Test-Path $Root) -and @(Get-ChildItem $Root -Force -ErrorAction SilentlyContinue).Count -gt 0 -and -not $Force) {
        throw "target exists and is non-empty: $Root  (use -Force to scaffold into it; writes are non-destructive: existing files are kept, only missing ones added, .gitignore/settings.local.json merged)"
    }
    [void][System.IO.Directory]::CreateDirectory($Bus)   # lazy maildir root
}

Write-Host ""
Write-Host "new-pool: $Name  (slug=$Slug, pool=$Pool, lead=$Lead, roles=$($roleList.owner -join ','))"
Write-Host "  root=$Root"
Write-Host "  projectKey=$ProjectKey"
Write-Host ""

# infra
# ⚠️ Пути пишутся ТОЛЬКО через прямой слэш. На Linux 'scripts\pool-launch.ps1' — это не подкаталог,
# а ОДНО имя файла с обратным слэшем внутри: пул собрался бы «успешно», а дерева бы не было. Windows
# прямой слэш понимает везде, так что платформенной ветки тут не нужно — нужна дисциплина записи.
Merge-Settings '.claude/settings.local.json' (Apply $T_settings $baseMap)   # blend hooks, keep existing permissions/hooks
Emit '.mcp.json'                   $T_mcp   # per-agent Chrome profile (no token replace: ${AGENT_OWNER} is expanded by Claude Code at runtime)
Merge-Gitignore '.gitignore'       (Apply $T_gitignore $baseMap)            # append only missing pool rules, keep existing
if ($script:OnWindows) {
    Emit 'scripts/pool-launch.ps1'         (Apply $T_poolLaunch $baseMap)
} else {
    # Серверная тройка: запускатель, одна обёртка на пул и данные ролей рядом с ней.
    Emit 'scripts/pool-launch.linux.ps1'   $T_poolLaunchLinux
    Emit 'scripts/role.sh'                 $T_roleSh
    Emit 'scripts/pool.env'                (Apply $T_poolEnv ($baseMap + @{ '__MODEL__' = $PoolModel }))
    Emit 'scripts/roles.tsv'               $rolesTsv
}
Emit 'scripts/startup-prompt.md'           $T_startup
Emit 'scripts/archive-completed-tasks.ps1' (Apply $T_janitor $baseMap)
Emit 'scripts/README.md'                   (Apply $T_scriptsReadme $baseMap)
Emit 'CLAUDE.md'                   (Apply $T_claude $baseMap)
Emit 'README.md'                   (Apply $T_readme $baseMap)
Emit '00_docs/README.md'           (Apply $T_docsReadme $baseMap)
Emit '00_docs/pool-roles.md'       (Apply $T_poolRoles $baseMap)
Emit '00_docs/source-brief/README.md' (Apply $T_sbReadme $baseMap)
Emit '00_docs/source-brief/brief.md'  (Apply $T_brief $baseMap)
Emit '05_deliverables/README.md'   (Apply $T_delivReadme $baseMap)
Emit '01_tasks/.gitkeep'           ''
Emit '05_deliverables/.gitkeep'    ''

# per-role wrappers + onboarding
$rowsOnboard = ($roleList | ForEach-Object {
    '| `' + $_.owner + '` | `' + $_.display + '` | ' + $_.label + ' |'
}) -join "`n"

foreach ($r in $roleList) {
    $boardLine = if ($r.isLead) { $boardCmd + "`r`n" } else { '' }
    $leadNote  = if ($r.isLead) { ' (открывает живую доску пула при старте)' } else { '' }
    # watcherless: DevOps/серверные роли НЕ взводят вотчер (стандарт); остальным — стартовый промпт.
    $ipfArg    = if ($r.owner -match 'devops') { '' } else { ' -InitialPromptFile "' + $Root + '\scripts\startup-prompt.md"' }
    # Канон параметров запуска: модель пиним ВСЕМ (иначе `--resume` восстанавливает сессию на её
    # старой модели, а глобальный /model протекает в пулы), effort — ведущему выше рядовых.
    # Точечно меняется потом через .launcher\pool-bus\set-pool-runtime.ps1.
    $runtimeArg = ' -Model "' + $PoolModel + '" -Effort ' + $(if ($r.isLead) { $PoolLeadEffort } else { $PoolEffort })

    $wrapper = @'
@echo off
REM Wrapper: __OWNER__ agent for __SLUG__ (pool __POOL__).
REM Bus-native: coordination via shared pool.ps1 (maildir). Auto-resume by session title.

set AGENT_OWNER=__OWNER__
set CLAUDE_CODE_TASK_LIST_ID=__POOL__
set POOL_BUS_ROOT=__BUS__
set POOL_INBOX_QUIET=1
__BOARD_LINE__cd /d __ROOT__
powershell -NoProfile -ExecutionPolicy Bypass -File "__ROOT__\scripts\pool-launch.ps1" -SessionTitle "__DISPLAY__"__IPF____RUNTIME__
if errorlevel 1 pause
'@
    # typing skill pointer in onboarding «Как ты работаешь» (qa wins if name has both)
    $typing = ''
    if     ($r.owner -match 'qa')           { $typing = 'Методика тестирования — скил `testing-as-qa`.' + "`n`n" }
    elseif ($r.owner -match 'tech-lead|lead') { $typing = 'Методика ведения — скил `working-as-tech-lead`.' + "`n`n" }

    $rmap = $baseMap.Clone()
    $rmap['__OWNER__']      = $r.owner
    $rmap['__DISPLAY__']    = $r.display
    $rmap['__LABEL__']      = $r.label
    $rmap['__LEAD_NOTE__']  = $leadNote
    $rmap['__BOARD_LINE__'] = $boardLine
    $rmap['__IPF__']        = $ipfArg
    $rmap['__RUNTIME__']    = $runtimeArg
    $rmap['__TYPING__']     = $typing
    $rmap['__ROWS_ONBOARD__'] = $rowsOnboard

    # Обёртка роли: на рабочей машине — своя .bat рядом с пулом; на сервере роль поднимает окно tmux
    # через scripts/role.sh, а человеку нужна витринная обёртка со ssh — она собирается ниже, в _windows/.
    if ($script:OnWindows) { Emit ("claude-{0}.bat" -f $r.owner) (Apply $wrapper $rmap) -Crlf }
    Emit ("_agent_pool_setup-{0}.md" -f $r.owner) (Apply $T_onboard $rmap)
}

# board launcher
$boardBat = @'
@echo off
REM Open the live pool board for __SLUG__ in a separate terminal window.
REM Idempotent: if a board window for this bus is already open, does nothing.
powershell -NoProfile -ExecutionPolicy Bypass -File "__BOARDTOOL__" -BusRoot "__BUS__"
'@
# На сервере отдельного окна доски нет: она живёт окном tmux, которое поднимает pool-up.sh.
if ($script:OnWindows) { Emit ("board-{0}.bat" -f $Slug) (Apply $boardBat ($baseMap + @{ '__BOARDTOOL__' = $WsBoardTool })) -Crlf }

# skill stubs -> <root>\.claude\skills\<name>\SKILL.md (in git; discovered by pool agents at cwd)
function Emit-Skill([string]$name, [string]$desc, [string]$body) {
    Emit (".claude/skills/{0}/SKILL.md" -f $name) ("---`nname: {0}`ndescription: {1}`n---`n`n{2}`n" -f $name, $desc, $body)
}
# base 4 — every pool agent
# Скил о ловушках Windows на сервере вреден: он учит обходить то, чего здесь нет, и занимает место
# в контексте роли. Остальные три предметны на обеих платформах.
if ($script:OnWindows) { Emit-Skill 'avoiding-windows-pitfalls' $D_win $SK_windows }
Emit-Skill 'handling-secrets-safely'      $D_sec $SK_secrets
Emit-Skill 'coordinating-on-the-pool-bus' $D_coo $SK_coord
Emit-Skill 'operating-in-a-pool'          $D_lif $SK_lifecycle
# typing 2 — only if a role name matches (tech-lead/lead -> TL; qa -> QA)
$wantTL = @($roleList | Where-Object { $_.owner -match 'tech-lead|lead' }).Count -gt 0
$wantQA = @($roleList | Where-Object { $_.owner -match 'qa' }).Count -gt 0
if ($wantTL) { Emit-Skill 'working-as-tech-lead' $D_tl $SK_techlead }
if ($wantQA) { Emit-Skill 'testing-as-qa'        $D_qa $SK_qa }

# pool manifest (для терминального пикера .launcher\pool-launcher) + Warp workflows доднятия ролей.
# layout не пишем — пикер строит авто-раскладку из ролей. project/role-title = TODO-заглушки (label), правятся вручную.
$manifestRoles = @($roleList | ForEach-Object {
    $h = [ordered]@{ owner = $_.owner; title = $_.label; bat = ('claude-{0}.bat' -f $_.owner) }
    if ($_.isLead) { $h.lead = $true }
    $h
})
$manifest = [ordered]@{
    schema = 'pool-manifest/v1'; slug = $Slug; title = $PoolTitle; project = $Title; root = $Root; lead = $Lead; roles = $manifestRoles
}
Emit 'pool.manifest.json' ($manifest | ConvertTo-Json -Depth 6)
if ($script:OnWindows) {
    foreach ($r in $roleList) {
        $cmd  = 'cmd /c "{0}\claude-{1}.bat"' -f $Root, $r.owner
        $yaml = "---`nname: `"> Запустить: {0}`"`ncommand: '{1}'`ndescription: `"Старт '{2}' пула {3}`"`ntags: [`"pool:{3}`"]`n" -f $r.label, $cmd, $r.owner, $Slug
        Emit (".warp/workflows/{0}.yaml" -f $r.owner) $yaml
    }
} else {
    # ---- витрина серверного пула --------------------------------------------
    # Пул работает здесь, а открывает его человек со своей машины. Пикеру там нужны манифест и
    # обёртки; собираем их ЗДЕСЬ, потому что источник истины о составе пула один — этот манифест.
    # Лежат в _windows/ как в выходном лотке; забирает их pull-server-pool.ps1 с той стороны.
    if (-not $WindowsRoot) {
        # Витрина повторяет положение пула ОТНОСИТЕЛЬНО КОРНЯ ПРОСТРАНСТВА: пул в
        # ~/workspace/sobesednik/shtab ложится в <workspace-root>\sobesednik\shtab.
        # ⚠️ Только если пул ВНУТРИ пространства. Иначе вычитание длины даёт мусор — поймано
        # прогоном в /tmp: корень витрины вышел «<workspace-root>\ol» (хвост чужого пути).
        $rel = if ($Root.StartsWith($SpaceRoot)) {
            $Root.Substring($SpaceRoot.Length).TrimStart('/', '\')
        } else {
            $Name   # пул вне пространства: положение витрины из пути не выводится, кладём по имени
        }
        $WindowsRoot = 'C:\workspace-root\' + ($rel -replace '/', '\')
    }
    $sshOpts = '-o IdentitiesOnly=yes -o ServerAliveInterval=20 -o ServerAliveCountMax=9 -o TCPKeepAlive=no -t'

    foreach ($r in $roleList) {
        $bat = @"
@echo off
REM Обёртка роли $($r.owner) пула $Slug. Роль живёт НА СЕРВЕРЕ ($SshTarget).
REM Локально ничего не запускается: панель подключается к живой сессии в ферме tmux.

set AGENT_OWNER=$($r.owner)
set CLAUDE_CODE_TASK_LIST_ID=$Pool
title $($r.owner) - $Slug (server)

ssh -i "$SshKey" $sshOpts $SshTarget "~/workspace/.launcher/console/enter.sh $Slug $($r.owner)"

if errorlevel 1 pause
"@
        Emit ("_windows/claude-{0}.bat" -f $r.owner) ($bat + "`n") -Crlf
        $cmd  = 'cmd /c "{0}\claude-{1}.bat"' -f $WindowsRoot, $r.owner
        $yaml = "---`nname: `"> Запустить: {0}`"`ncommand: '{1}'`ndescription: `"Старт '{2}' пула {3}`"`ntags: [`"pool:{3}`"]`n" -f $r.label, $cmd, $r.owner, $Slug
        Emit ("_windows/.warp/workflows/{0}.yaml" -f $r.owner) $yaml
    }

    $boardSsh = @"
@echo off
REM Доска пула $Slug. Пул на сервере, поэтому открывается пульт смены в ферме tmux.

set AGENT_OWNER=board
title $Slug board (server)

ssh -i "$SshKey" $sshOpts $SshTarget "~/workspace/.launcher/console/enter.sh $Slug"

if errorlevel 1 pause
"@
    Emit ("_windows/board-{0}.bat" -f $Slug) ($boardSsh + "`n") -Crlf

    # Манифест витрины отличается от серверного ровно одним полем — корнем: пикер ищет обёртки у
    # себя. Всё остальное (слаг, состав, ведущий) обязано совпадать, поэтому берётся из того же
    # объекта, а не набирается заново.
    $winManifest = [ordered]@{
        schema = 'pool-manifest/v1'; slug = $Slug; title = $PoolTitle; project = $Title
        root = $WindowsRoot; lead = $Lead; roles = $manifestRoles
    }
    Emit '_windows/pool.manifest.json' ($winManifest | ConvertTo-Json -Depth 6)

    $pullNote = @"
# _windows/ — витрина пула $Slug для рабочей машины

Пул живёт на сервере; здесь лежит то, что нужно **на стороне человека**, чтобы его открыть:
манифест для пикера, обёртки ролей со `ssh` и доска.

Забрать одной командой с рабочей машины:

    powershell -File C:\workspace-root\.launcher\pool-launcher\pull-server-pool.ps1 -Pool $Slug

Разложится в ``$WindowsRoot``. Руками отсюда ничего копировать не надо, и **править обёртки на той
стороне нельзя**: источник состава пула один — `pool.manifest.json` рядом с этим файлом. Изменился
состав (лид добавил роль) — перезапусти стягивание, оно перезапишет витрину целиком.
"@
    Emit '_windows/README.md' $pullNote
}

# ---- серверные постусловия ------------------------------------------------
if (-not $script:OnWindows -and -not $WhatIf) {
    # Обёртка обязана быть исполняемой: окно tmux зовёт её напрямую, и неисполняемый файл выглядит
    # как «роль не поднялась», без внятной причины в панели.
    try { & chmod '+x' (Join-Path $Root 'scripts/role.sh') 2>$null } catch { }

    # Первый запуск роли в НОВОМ каталоге упирается в диалог доверия и молча ждёт человека внутри
    # окна tmux. Каталог создали мы сами, поэтому доверие проставляем заранее — иначе подъём пула
    # выглядит как зависший старт.
    try {
        $cj  = Join-Path $HOME '.claude.json'
        $cfg = if (Test-Path $cj) { [System.IO.File]::ReadAllText($cj, [System.Text.Encoding]::UTF8) | ConvertFrom-Json } else { [pscustomobject]@{} }
        if (-not $cfg.PSObject.Properties['projects']) { $cfg | Add-Member -NotePropertyName projects -NotePropertyValue ([pscustomobject]@{}) }
        if (-not $cfg.projects.PSObject.Properties[$Root]) { $cfg.projects | Add-Member -NotePropertyName $Root -NotePropertyValue ([pscustomobject]@{}) }
        $cfg.projects.$Root | Add-Member -NotePropertyName hasTrustDialogAccepted -NotePropertyValue $true -Force
        [System.IO.File]::WriteAllText($cj, ($cfg | ConvertTo-Json -Depth 30), $script:U8NoBom)
        Write-Host "  доверие каталогу проставлено: $Root"
    } catch {
        Write-Host "  ⚠ доверие каталогу проставить не удалось ($_). Первая роль встанет на диалоге."
    }
}

# ---- report --------------------------------------------------------------
Write-Host ($created | ForEach-Object { "  + (new)    $_" } | Out-String)
if ($merged.Count)  { Write-Host ($merged  | ForEach-Object { "  ~ (merged) $_" } | Out-String) }
if ($skipped.Count) { Write-Host ($skipped | ForEach-Object { "  = (kept)   $_" } | Out-String) }
if ($WhatIf) {
    Write-Host "[WhatIf] $($created.Count) new / $($merged.Count) merged / $($skipped.Count) kept intact (nothing written)."
} else {
    Write-Host "Done: $($created.Count) new, $($merged.Count) merged, $($skipped.Count) kept intact under $Root"
    Write-Host ""
    Write-Host "Next:"
    Write-Host "  1. Fill 00_docs/source-brief/brief.md (the parametric frame)."
    Write-Host "  2. Fill TODO stubs: role missions in _agent_pool_setup-*.md, conveyor in 00_docs/pool-roles.md."
    if ($script:OnWindows) {
        Write-Host "  3. Launch a role: claude-$Lead.bat   |  board: board-$Slug.bat"
    } else {
        Write-Host "  3. Поднять пул:   ~/workspace/.launcher/scripts/pool-up.sh $Root"
        Write-Host "  4. Забрать витрину НА РАБОЧЕЙ МАШИНЕ, иначе пул не появится в пикере:"
        Write-Host "     powershell -File C:\workspace-root\.launcher\pool-launcher\pull-server-pool.ps1 -Pool $Slug"
    }
}
