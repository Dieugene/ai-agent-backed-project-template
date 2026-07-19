<#
  new-pool.ps1 — scaffolder for a new bus-native standalone agent pool.

  Generates the full skeleton of a standalone monorepo + agent pool wired to the
  shared maildir pool bus (<workspace-root>\.launcher\pool-bus\pool.ps1). Output shape
  mirrors the validated reference pool `content`:

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
    # Quick inline (ASCII owners; labels become TODO placeholders):
    powershell -File new-pool.ps1 -Name content -Roles methodist,author,critic -Lead methodist
    # Dry run:
    powershell -File new-pool.ps1 -Spec my-pool.json -WhatIf

  SPEC JSON
    {
      "name": "content",                 (required; kebab-case; = workspace folder)
      "pool": "content-pool",            (optional; default "<name>-pool")
      "title": "учебные задания на каждый день",(optional; one-liner for CLAUDE.md/README)
      "displaySuffix": "Daily",                (optional; default PascalCase of name's 1st segment)
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
    [string[]] $Roles,
    [string]   $Lead,
    [string]   $Title,
    [string]   $DisplaySuffix,
    [string]   $Pool,
    [string]   $WorkspaceRoot = '<workspace-root>',
    [switch]   $Force,
    [switch]   $WhatIf
)

$ErrorActionPreference = 'Stop'
$script:U8NoBom = New-Object System.Text.UTF8Encoding($false)

# ---- resolve spec --------------------------------------------------------
$roleList = @()   # array of [pscustomobject]@{ owner=..; label=..; lead=$bool }

if ($Spec) {
    if (-not (Test-Path $Spec)) { throw "spec file not found: $Spec" }
    $j = [System.IO.File]::ReadAllText($Spec, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    if (-not $j.name)  { throw "spec.name is required" }
    $Name          = $j.name
    if ($j.pool)          { $Pool = $j.pool }
    if ($j.title)         { $Title = $j.title }
    if ($j.displaySuffix) { $DisplaySuffix = $j.displaySuffix }
    if ($j.lead)          { $Lead = $j.lead }
    if (-not $j.roles -or @($j.roles).Count -eq 0) { throw "spec.roles must be a non-empty array" }
    foreach ($r in $j.roles) {
        $roleList += [pscustomobject]@{ owner = [string]$r.owner; label = [string]$r.label }
    }
} else {
    if (-not $Name)  { throw "either -Spec <file> or -Name <name> -Roles <ids> is required" }
    if (-not $Roles -or $Roles.Count -eq 0) { throw "-Roles is required when not using -Spec" }
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

if (-not $Pool)          { $Pool = "$Name-pool" }
if (-not $DisplaySuffix) { $DisplaySuffix = To-Pascal (($Name -split '-')[0]) }
if (-not $Lead)          { $Lead = $roleList[0].owner }
if (-not $Title)         { $Title = "TODO: одна строка — что делает пул" }
if (-not ($roleList.owner -contains $Lead)) { throw "lead '$Lead' is not among roles: $($roleList.owner -join ', ')" }

$Root       = Join-Path $WorkspaceRoot $Name
$Bus        = Join-Path $Root '.bus'
$ProjectKey = ($Root -replace '[^a-zA-Z0-9]', '-')

foreach ($r in $roleList) {
    $r | Add-Member -NotePropertyName display -NotePropertyValue ((To-Pascal $r.owner) + '-' + $DisplaySuffix)
    $r | Add-Member -NotePropertyName isLead  -NotePropertyValue ($r.owner -eq $Lead)
}

$ownersInline = ($roleList.owner | ForEach-Object { '`' + $_ + '`' }) -join ', '
$roleCount   = $roleList.Count

# markdown roles table rows (CLAUDE.md / README / pool-roles)
$rowsClaude = ($roleList | ForEach-Object {
    '| `' + $_.owner + '` | `' + $_.display + '` | ' + $_.label + ' | `claude-' + $_.owner + '.bat` |'
}) -join "`n"
$rowsWrappers = ($roleList | ForEach-Object {
    $note = if ($_.isLead) { ' (лид; при старте открывает живую доску)' } else { '' }
    '| `claude-' + $_.owner + '.bat` | ' + $_.label + $note + ' |'
}) -join "`n"

$boardCmd = 'powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\.launcher\pool-bus\board-window.ps1" -BusRoot "' + $Bus + '"'

# ---- shared coordination block (CLAUDE.md + onboarding) ------------------
# Slim: knowledge lives in skills (coordinating-on-the-pool-bus / operating-in-a-pool)
# backed by .references\ref.ps1; the direct ref.ps1 call is a self-sufficient fallback
# for live sessions that predate skill discovery.
$COORD = @'
### Координация с соседями — через `pool` (НЕ через Tasks API)
Задача соседу / ответ / отчёт / доска — командой `pool` (maildir-шина), НЕ `TaskCreate`/`TaskUpdate`. Команды и правила — скил **`coordinating-on-the-pool-bus`**; онбординг/вотчер/handoff — скил **`operating-in-a-pool`**. Прямой доступ без скилов: `& "<workspace-root>\.references\ref.ps1" pool-coordination`. Крупные материалы — файлом, в сообщении — ссылка на путь. Личные todo — `TaskCreate(metadata={kind:"personal"})`.
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
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<workspace-root>\\.launcher\\pool-bus\\pool.ps1\" hook"
          },
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<workspace-root>\\.launcher\\pool-bus\\pool.ps1\" activity"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<workspace-root>\\.launcher\\pool-bus\\pool.ps1\" activity"
          }
        ]
      }
    ],
    "SubagentStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<workspace-root>\\.launcher\\pool-bus\\pool.ps1\" activity"
          }
        ]
      }
    ],
    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<workspace-root>\\.launcher\\pool-bus\\pool.ps1\" activity"
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
        "--user-data-dir=<workspace-root>\\.chrome-profiles\\${AGENT_OWNER:-_plain}"
      ],
      "env": {}
    }
  }
}
'@

$T_gitignore = @'
# Claude Code local settings (per-machine; hook registration + MCP wiring w/ absolute paths)
.claude/settings.local.json
.mcp.json

# Pool bus (maildir coordination state, owned by pool.ps1; not source)
.bus/

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
    [string]$Effort = '',   # xhigh for pool leads; empty = inherit global effortLevel (flag, not env var)
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

$effortArgs = if ($Effort) { @('--effort', $Effort) } else { @() }

$sessionId = Find-SessionIdByTitle -Title $SessionTitle -Dir $projectDir

if ($sessionId) {
    Write-Host "[pool-launch] Resuming '$SessionTitle' (session $sessionId)"
    if ($initPrompt) { & claude --dangerously-skip-permissions @effortArgs --resume $sessionId $initPrompt }
    else             { & claude --dangerously-skip-permissions @effortArgs --resume $sessionId }
} else {
    Write-Host "[pool-launch] No prior session '$SessionTitle' found - starting fresh."
    if ($initPrompt) { & claude --dangerously-skip-permissions @effortArgs --name $SessionTitle $initPrompt }
    else             { & claude --dangerously-skip-permissions @effortArgs --name $SessionTitle }
}

exit $LASTEXITCODE
'@

$T_startup = @'
Старт пула.

1. Взведи свой **вотчер** входящих: следуй скилу `operating-in-a-pool` (или прямо `& "<workspace-root>\.references\ref.ps1" pool-lifecycle`), раздел «Выход хода» — фоновой задачей.
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
    [string]$TasksRoot   = (Join-Path $env:USERPROFILE '.claude\tasks'),
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
# scripts/ — pool helpers (__NAME__)

Служебные скрипты запуска пула. Двойной клик по `.bat` в корне репозитория — обычный способ старта; эти файлы дёргаются ими.

| Файл | Что делает |
|------|------------|
| `pool-launch.ps1` | Запускает Claude Code в pool-режиме; ищет прошлую сессию по display name и **возобновляет** её (`--resume`), иначе стартует свежую (`--name`). |
| `archive-completed-tasks.ps1` | Дворник стора задач: уносит завершённые личные todo из живого списка в `<list>-archive`. Безопасен (move, не delete). |

Координация между ролями — через общую **pool-шину** (`<workspace-root>\.launcher\pool-bus\pool.ps1`), не через эти скрипты. Живая доска — `board-__NAME__.bat` в корне.
'@

$T_claude = @'
# __NAME__ — точка входа Claude Code

Этот файл Claude Code читает при старте сессии с cwd `__ROOT__`. **Действуй по нему до любых других файлов.**

Проект: **__TITLE__.** Над проектом работает **pool из __COUNT__ ролей**. Параметрическую рамку (что конкретно делаем) держит `00_docs/source-brief/brief.md`; роли и конвейер — `00_docs/pool-roles.md`.

## Принципы работы (стоячие — действуют всегда)

- **Субагенты вместо своего контекста.** Рутину и параллельные куски делегируй субагентам; свой контекст береги для синтеза и решений.
- **Автономность до результата.** Пойми образ результата и работай автономно до него. Остановись и спроси только если: решение ответственное / вне твоей зоны; вскрылась развилка без контекста; нужен peer (поставил задачу — пингани). Иначе — разумный дефолт, причину зафиксируй, продолжай.

Полная версия — `<workspace-root>\.launcher\standards\working-principles.md`.

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

**По порядку:** (1) не меняй cwd; (2) прочитай свой `_agent_pool_setup-<owner>.md`; (3) прочитай общий контекст — `00_docs/source-brief/brief.md`, `00_docs/pool-roles.md`; (4) проверь `[POOL INBOX]` (баннер каждый ход) и `pool mine`.

Признак активации pool — баннер `[POOL INBOX] <owner>: ...` в начале каждого промпта.

## Шаг 3. Общие правила

- **Workspace = зона пула.** Пиши в любую часть `__ROOT__` кроме `.bus/` (служебная шина) и `.claude/`. Зоны записи по ролям — см. `pool-roles.md` и свой onboarding.
- **Конвейер.** TODO (лид заполнит в `00_docs/pool-roles.md`): кто за кем, где гейты/приёмка.
__COORD__

## Связанные документы

- `00_docs/source-brief/brief.md` — параметрическая рамка (заполняет пользователь; роли читают отсюда).
- `00_docs/pool-roles.md` — роли и конвейер пула.
- `_agent_pool_setup-<owner>.md` — onboarding по каждой роли.
- `_handoff_<owner>.md` — handoff между запусками роли (перезаписывать, не плодить).
- Координация — скилы `coordinating-on-the-pool-bus` / `operating-in-a-pool`.
- `<workspace-root>\.launcher\standards\working-principles.md` — принципы работы агентов.
'@

$T_readme = @'
# __NAME__

Монорепо с пулом ИИ-агентов: __TITLE__. Над проектом работает __COUNT__ ролей, координация — через общую pool-шину.

## Как запустить

Двойной клик по `.bat` в корне — каждая открывает свою роль в отдельном окне (сессия возобновляется автоматически):

| Файл | Роль |
|------|------|
__ROWS_WRAPPERS__
| `board-__NAME__.bat` | Живая доска пула (кто чем занят) — отдельным окном |

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
# Роли и конвейер пула __NAME__

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

Между ролями — только через `pool` (maildir-шина), не Tasks API. Команды и правила — скил `coordinating-on-the-pool-bus`; онбординг/вотчер/handoff — скил `operating-in-a-pool`; прямой доступ — `& "<workspace-root>\.references\ref.ps1" pool-coordination`. Живая доска — `board-__NAME__.bat`.
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
& "<workspace-root>\.references\ref.ps1" windows
```
'@
$SK_secrets = @'
# Обращение с секретами

Выполни и следуй выводу:

```powershell
& "<workspace-root>\.references\ref.ps1" secrets
```

**Жёсткое правило:** значение секрета не печатается никогда — ни в терминал, ни в лог, ни в отчёт. Проверяй наличие/длину, не значение.
'@
$SK_coord = @'
# Координация через pool-шину

Выполни и следуй выводу:

```powershell
& "<workspace-root>\.references\ref.ps1" pool-coordination
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
& "<workspace-root>\.references\ref.ps1" pool-lifecycle
```
'@
$SK_techlead = @'
# Работа Tech Lead'а

Выполни и следуй выводу:

```powershell
& "<workspace-root>\.references\ref.ps1" tech-lead
```
'@
$SK_qa = @'
# Работа QA

Выполни и следуй выводу:

```powershell
& "<workspace-root>\.references\ref.ps1" qa
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
}

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
    [System.IO.File]::WriteAllText($full, $content, $script:U8NoBom)
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

# guard
if (-not $WhatIf) {
    if ((Test-Path $Root) -and @(Get-ChildItem $Root -Force -ErrorAction SilentlyContinue).Count -gt 0 -and -not $Force) {
        throw "target exists and is non-empty: $Root  (use -Force to scaffold into it; writes are non-destructive: existing files are kept, only missing ones added, .gitignore/settings.local.json merged)"
    }
    [void][System.IO.Directory]::CreateDirectory($Bus)   # lazy maildir root
}

Write-Host ""
Write-Host "new-pool: $Name  (pool=$Pool, lead=$Lead, roles=$($roleList.owner -join ','))"
Write-Host "  root=$Root"
Write-Host "  projectKey=$ProjectKey"
Write-Host ""

# infra
Merge-Settings '.claude\settings.local.json' (Apply $T_settings $baseMap)   # blend hooks, keep existing permissions/hooks
Emit '.mcp.json'                   $T_mcp   # per-agent Chrome profile (no token replace: ${AGENT_OWNER} is expanded by Claude Code at runtime)
Merge-Gitignore '.gitignore'       (Apply $T_gitignore $baseMap)            # append only missing pool rules, keep existing
Emit 'scripts\pool-launch.ps1'             (Apply $T_poolLaunch $baseMap)
Emit 'scripts\startup-prompt.md'           $T_startup
Emit 'scripts\archive-completed-tasks.ps1' (Apply $T_janitor $baseMap)
Emit 'scripts\README.md'                   (Apply $T_scriptsReadme $baseMap)
Emit 'CLAUDE.md'                   (Apply $T_claude $baseMap)
Emit 'README.md'                   (Apply $T_readme $baseMap)
Emit '00_docs\README.md'           (Apply $T_docsReadme $baseMap)
Emit '00_docs\pool-roles.md'       (Apply $T_poolRoles $baseMap)
Emit '00_docs\source-brief\README.md' (Apply $T_sbReadme $baseMap)
Emit '00_docs\source-brief\brief.md'  (Apply $T_brief $baseMap)
Emit '05_deliverables\README.md'   (Apply $T_delivReadme $baseMap)
Emit '01_tasks\.gitkeep'           ''
Emit '05_deliverables\.gitkeep'    ''

# per-role wrappers + onboarding
$rowsOnboard = ($roleList | ForEach-Object {
    '| `' + $_.owner + '` | `' + $_.display + '` | ' + $_.label + ' |'
}) -join "`n"

foreach ($r in $roleList) {
    $boardLine = if ($r.isLead) { $boardCmd + "`r`n" } else { '' }
    $leadNote  = if ($r.isLead) { ' (открывает живую доску пула при старте)' } else { '' }
    # watcherless: DevOps/серверные роли НЕ взводят вотчер (стандарт); остальным — стартовый промпт.
    $ipfArg    = if ($r.owner -match 'devops') { '' } else { ' -InitialPromptFile "' + $Root + '\scripts\startup-prompt.md"' }
    $effortArg = if ($r.isLead) { ' -Effort xhigh' } else { '' }   # lead runs at xhigh; executors inherit global effortLevel (settings.json)

    $wrapper = @'
@echo off
REM Wrapper: __OWNER__ agent for __NAME__ (pool __POOL__).
REM Bus-native: coordination via shared pool.ps1 (maildir). Auto-resume by session title.

set AGENT_OWNER=__OWNER__
set CLAUDE_CODE_TASK_LIST_ID=__POOL__
set POOL_BUS_ROOT=__BUS__
set POOL_INBOX_QUIET=1
__BOARD_LINE__cd /d __ROOT__
powershell -NoProfile -ExecutionPolicy Bypass -File "__ROOT__\scripts\pool-launch.ps1" -SessionTitle "__DISPLAY__"__IPF____EFFORT__
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
    $rmap['__EFFORT__']     = $effortArg
    $rmap['__TYPING__']     = $typing
    $rmap['__ROWS_ONBOARD__'] = $rowsOnboard

    Emit ("claude-{0}.bat" -f $r.owner) (Apply $wrapper $rmap) -Crlf
    Emit ("_agent_pool_setup-{0}.md" -f $r.owner) (Apply $T_onboard $rmap)
}

# board launcher
$boardBat = @'
@echo off
REM Open the live pool board for __NAME__ in a separate terminal window.
REM Idempotent: if a board window for this bus is already open, does nothing.
powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\.launcher\pool-bus\board-window.ps1" -BusRoot "__BUS__"
'@
Emit ("board-{0}.bat" -f $Name) (Apply $boardBat $baseMap) -Crlf

# skill stubs -> <root>\.claude\skills\<name>\SKILL.md (in git; discovered by pool agents at cwd)
function Emit-Skill([string]$name, [string]$desc, [string]$body) {
    Emit (".claude\skills\{0}\SKILL.md" -f $name) ("---`nname: {0}`ndescription: {1}`n---`n`n{2}`n" -f $name, $desc, $body)
}
# base 4 — every pool agent
Emit-Skill 'avoiding-windows-pitfalls'    $D_win $SK_windows
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
    schema = 'pool-manifest/v1'; slug = $Name; title = $Name; project = $Title; root = $Root; lead = $Lead; roles = $manifestRoles
}
Emit 'pool.manifest.json' ($manifest | ConvertTo-Json -Depth 6)
foreach ($r in $roleList) {
    $cmd  = 'cmd /c "{0}\claude-{1}.bat"' -f $Root, $r.owner
    $yaml = "---`nname: `"> Запустить: {0}`"`ncommand: '{1}'`ndescription: `"Старт '{2}' пула {3}`"`ntags: [`"pool:{3}`"]`n" -f $r.label, $cmd, $r.owner, $Name
    Emit (".warp\workflows\{0}.yaml" -f $r.owner) $yaml
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
    Write-Host "  3. Launch a role: claude-$Lead.bat   |  board: board-$Name.bat"
}
