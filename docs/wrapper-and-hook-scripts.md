# Wrapper and Hook Scripts

Полные рабочие примеры скриптов pool-инфраструктуры. Все три файла —
`pool-launch.ps1`, `inject-inbox.ps1`, wrapper-батник на агента —
универсальные: один комплект обслуживает любое число pool'ов в одной
workspace.

> Целевая среда — Windows + PowerShell. На Linux/macOS принцип идентичен,
> но конкретный код адаптируется (bash вместо powershell, /bin/sh shebang
> вместо `.bat`).

---

## 1. Цепочка процессов

```
cmd.exe                                              ← wrapper-батник
  set AGENT_OWNER=<role>-<scope>
  set CLAUDE_CODE_TASK_LIST_ID=<pool-name>
  cd /d <workspace-root>
  ↓
powershell -NoProfile -ExecutionPolicy Bypass        ← pool-launch.ps1
  -File <workspace-root>\scripts\pool-launch.ps1
  -SessionTitle <SessionTitle>
  -ProjectKey <ProjectKey>
  ↓
claude.exe --dangerously-skip-permissions            ← Claude Code
  --resume <session-id>   ИЛИ   --name <SessionTitle>
  ↓
hook on UserPromptSubmit                             ← inject-inbox.ps1
  reads env vars, scans ~/.claude/tasks/<TASK_LIST_ID>/,
  emits [POOL INBOX] banner
```

Env vars из `cmd.exe` наследуются всем дочерним процессам автоматически.
`-NoProfile` отключает загрузку `$PROFILE` пользователя — никаких
сторонних алиасов или эффектов. Прямой вызов `claude` (без алиаса
`cld` или подобных) исключает риск потери env vars из-за лишнего звена.

---

## 2. Wrapper-батник на агента

`<workspace-root>/scripts/claude-<role>-<scope>.bat`:

```batch
@echo off
REM Pool wrapper: <role> для подпроекта <scope>.
REM Owner ID: <role>-<scope>. Pool: <pool-name>.
REM Cwd = <workspace-root>. ProjectKey: <ProjectKey>.

set AGENT_OWNER=<role>-<scope>
set CLAUDE_CODE_TASK_LIST_ID=<pool-name>
cd /d <workspace-root>
powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\scripts\pool-launch.ps1" -SessionTitle "<SessionTitle>" -ProjectKey "<ProjectKey>"
if errorlevel 1 pause
```

**Что заменить под конкретный pool:**

| Placeholder | Что подставить | Пример |
|-------------|----------------|--------|
| `<role>` | Роль агента: `tech-lead`, `architect`, `frontend`, `backend`, `qa`, `devops` | `frontend` |
| `<scope>` | Имя pool'а или подпроекта (kebab-case) | `foo` |
| `<pool-name>` | Идентификатор `CLAUDE_CODE_TASK_LIST_ID`, обычно `<scope>-pool` или `<workspace>-pool` | `foo-pool` |
| `<workspace-root>` | Абсолютный путь к корню workspace | `C:\work\foo-workspace` |
| `<SessionTitle>` | Display name сессии в PascalCase | `Frontend-Foo` |
| `<ProjectKey>` | Имя проекта в `~/.claude/projects/`. Совпадает с `<workspace-root>` с заменой `\` и `:` на `---` | `C---work-foo-workspace` |

**Один батник на одного агента.** Двойной клик возвращает агента в его
же conversation (через auto-resume по `<SessionTitle>`).

---

## 3. Helper `pool-launch.ps1`

`<workspace-root>/scripts/pool-launch.ps1`:

```powershell
# Universal Claude Code launcher with automatic session resume by display name.
#
# Behavior:
#   1. Looks up the most recently used session in the project whose customTitle
#      (assigned via /rename or --name) matches $SessionTitle.
#   2. If found — runs `claude --dangerously-skip-permissions --resume <session-id>`.
#   3. If not found — starts a fresh session with `--name <SessionTitle>` so that
#      next launch can resume it automatically.
#
# Works for plain (non-pool) sessions and for pool sessions identically. When called
# from a wrapper-bat that sets pool env vars (AGENT_OWNER, CLAUDE_CODE_TASK_LIST_ID),
# pool mode activates; without those env vars, runs as plain.
#
# Runs with -NoProfile so the user's PowerShell $PROFILE (and any aliases) is not loaded.

param(
    [Parameter(Mandatory)][string]$SessionTitle,
    [Parameter(Mandatory)][string]$ProjectKey
)

$ErrorActionPreference = 'Continue'

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
            # Find the LAST customTitle entry in the file and check if it matches.
            # Sessions can be renamed mid-conversation; the latest rename wins.
            $titleLines = Select-String -Path $f.FullName `
                                        -Pattern '"customTitle":"[^"]*"' `
                                        -ErrorAction Stop
            if (-not $titleLines) { continue }

            $latest = $titleLines[-1].Line
            if ($latest -match $matchPattern) {
                return $f.BaseName
            }
        } catch {
            continue
        }
    }
    return $null
}

$sessionId = Find-SessionIdByTitle -Title $SessionTitle -Dir $projectDir

if ($sessionId) {
    Write-Host "[pool-launch] Resuming '$SessionTitle' (session $sessionId)"
    & claude --dangerously-skip-permissions --resume $sessionId
} else {
    Write-Host "[pool-launch] No prior session '$SessionTitle' found - starting fresh."
    & claude --dangerously-skip-permissions --name $SessionTitle
}

exit $LASTEXITCODE
```

**Ключевые особенности:**

- `Select-String` ищет **все** `customTitle`-entries в jsonl и берёт
  **последний** — защита от того, что сессию переименовывали в течение
  её жизни.
- Defensive: если папка проекта отсутствует или jsonl нечитаемы — fallback
  на свежую сессию, не падает.
- Универсальный: работает и без pool env vars (тогда просто запускает
  именованную plain-сессию).

---

## 4. Hook `inject-inbox.ps1`

`<workspace-root>/.claude/hooks/inject-inbox.ps1`:

```powershell
# UserPromptSubmit hook for pool sessions.
#
# Behavior:
#   1. Reads $env:AGENT_OWNER and $env:CLAUDE_CODE_TASK_LIST_ID.
#      If either is missing, exits silently (exit 0) — pool inactive, no noise.
#   2. Scans ~/.claude/tasks/<TASK_LIST_ID>/*.json.
#   3. Filters: status == 'pending' AND owner == $AGENT_OWNER
#                                  AND metadata.kind != 'personal'.
#   4. Emits [POOL INBOX] banner to stdout.
#      Claude Code wraps stdout into <user-prompt-submit-hook> block
#      and injects it into the session context before each user prompt.
#
# CRITICAL invariant: filtering is strictly by top-level "owner" field.
# metadata.to / metadata.assignee are NOT consulted.

# UTF-8 stdout — without this, cyrillic banner arrives as mojibake.
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

$owner  = $env:AGENT_OWNER
$listId = $env:CLAUDE_CODE_TASK_LIST_ID

if ([string]::IsNullOrEmpty($owner) -or [string]::IsNullOrEmpty($listId)) {
    exit 0   # pool inactive — silent
}

$tasksDir = Join-Path $HOME ".claude/tasks/$listId"
$tasks = @()

if (Test-Path $tasksDir) {
    Get-ChildItem -Path $tasksDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '^\.' } |
        ForEach-Object {
            try {
                $raw = Get-Content -Path $_.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                $task = $raw | ConvertFrom-Json -ErrorAction Stop
                if ($task) { $tasks += $task }
            } catch {
                # malformed file — skip silently
            }
        }
}

$pending = @($tasks | Where-Object {
    if ($_.status -ne 'pending')   { return $false }
    if ($_.owner  -ne $owner)      { return $false }
    $kind = $null
    if ($_.metadata -and ($_.metadata.PSObject.Properties.Name -contains 'kind')) {
        $kind = $_.metadata.kind
    }
    return $kind -ne 'personal'
})

if ($pending.Count -eq 0) {
    if ($env:POOL_INBOX_QUIET -ne '1') {
        Write-Output "[POOL INBOX] ${owner}: clean (0 pending)"
    }
    exit 0
}

Write-Output "[POOL INBOX] ${owner}: $($pending.Count) pending"
foreach ($t in $pending) {
    $from = ''
    $payload = ''
    if ($t.metadata) {
        if ($t.metadata.PSObject.Properties.Name -contains 'from') {
            $from = " (from $($t.metadata.from))"
        }
        if ($t.metadata.PSObject.Properties.Name -contains 'payload_path') {
            $payload = "`n  payload: $($t.metadata.payload_path)"
        }
    }
    Write-Output "- $($t.id)${from}: $($t.subject)${payload}"
}
Write-Output "Details: TaskList(owner='${owner}', status='pending')"

exit 0
```

**Поведенческие гарантии:**

- При пустых env vars — выход без вывода. Pool не активен → не шумим в
  plain-сессиях.
- Malformed JSON в `~/.claude/tasks/<id>/` — пропускается молча.
  Один сломанный файл не валит весь баннер.
- Тривиальный, без зависимостей. Только встроенные cmdlet'ы PowerShell 5.1.

### Регистрация hook'а

`<workspace-root>/.claude/settings.local.json` (gitignored,
локально-машинная конфигурация):

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<workspace-root>\\.claude\\hooks\\inject-inbox.ps1\""
          }
        ]
      }
    ]
  }
}
```

`<workspace-root>` — заменить на абсолютный путь.

### Discovery: walk-up НЕ работает

Claude Code ищет `.claude/settings.local.json` с блоком `hooks` только в
**cwd** и в **project-root** (определяется наличием `.git/` или
маркеров). Hooks из ancestor-директорий не подхватываются walk-up.

Следствия:

- Если wrapper делает `cd /d <workspace-root>` (рекомендуется) —
  `settings.local.json` в `<workspace-root>/.claude/` подхватывается
  правильно для любого agent'а workspace, в т.ч. в intra-project pool.
- Если wrapper делает `cd /d <workspace-root>\01_projects\<подпроект>`
  — `settings.local.json` обязательно в `<подпроект>/.claude/` (с
  абсолютным путём в `command` к одному и тому же hook-скрипту в
  workspace).

### Первое одобрение hook'а

`--dangerously-skip-permissions` **НЕ** обходит подтверждение нового
hook'а — это отдельный security gate. На первом запуске Claude Code
покажет prompt: «Allow command: powershell ... inject-inbox.ps1?».
Нажать «Yes / Always allow for this project», со второго промпта баннер
появится сам.

---

## 4.5. Опциональный push-watcher (`wait-for-task.ps1`)

Опция «по согласованию», **не для всех агентов** (см. [Pool Communication §7.5](pool-communication.md)). Фоновый watcher будит простаивающую сессию при входящей задаче. Спит в shell-процессе (ноль контекста на ожидании), **read-only** по Tasks-store; состояние — в `<workspace-root>/.watcher-state/` (gitignored): per-owner леджер + heartbeat-lock.

Запуск — **из сессии агента**, фоновой задачей (`Bash run_in_background: true`):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\scripts\wait-for-task.ps1" -Owner <owner> -ListId <pool-name>
```

### Общая читалка `Get-PendingTasks.ps1`

Тот же фильтр, что у hook'а (§4), вынесен в общую функцию — pull и push опираются на одну логику.

```powershell
# Get-PendingTasks.ps1
# Shared reader: returns pending, actionable tasks for one owner from a pool Tasks store.
# Same filter as inject-inbox.ps1 (status=pending, owner match, kind != personal).
# Dot-source it:  . (Join-Path $PSScriptRoot 'Get-PendingTasks.ps1')

function Get-PendingTasks {
    param(
        [Parameter(Mandatory)][string]$Owner,
        [Parameter(Mandatory)][string]$ListId,
        [string]$TasksDir
    )

    if ([string]::IsNullOrWhiteSpace($TasksDir)) {
        $TasksDir = Join-Path $HOME ".claude/tasks/$ListId"
    }

    $tasks = @()
    if (Test-Path $TasksDir) {
        Get-ChildItem -Path $TasksDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '^\.' } |
            ForEach-Object {
                try {
                    $raw  = Get-Content -Path $_.FullName -Raw -Encoding UTF8 -ErrorAction Stop
                    $task = $raw | ConvertFrom-Json -ErrorAction Stop
                    if ($task) { $tasks += $task }
                } catch {
                    # malformed task file - skip silently
                }
            }
    }

    $pending = @($tasks | Where-Object {
        if ($_.status -ne 'pending') { return $false }
        if ($_.owner -ne $Owner)     { return $false }
        $kind = $null
        if ($_.metadata -and ($_.metadata.PSObject.Properties.Name -contains 'kind')) {
            $kind = $_.metadata.kind
        }
        return $kind -ne 'personal'
    })

    return $pending
}
```

### Watcher `wait-for-task.ps1`

```powershell
# wait-for-task.ps1
# Background "sleeping watcher" for ONE pool agent.
#
# Polls the pool Tasks store for NEW pending tasks addressed to $Owner. The sleep happens
# inside this shell process (Start-Sleep) - so it costs ZERO model context while waiting.
# On the FIRST newly-detected task it records the task id in a private per-owner ledger and
# EXITS with a report; the harness then wakes the agent. Re-arm is idempotent: an already
# detected task stays in the ledger and will NOT re-trigger the next watcher.
#
# Read-only on the Tasks store (never writes task files). All state lives in $StateDir
# (ledger + heartbeat lock), which is gitignored and fully owned by the watcher.
#
# Launch from the agent session as a BACKGROUND task (Bash run_in_background: true), so it
# survives across turns and the harness re-invokes the agent when it exits:
#   powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\scripts\wait-for-task.ps1" -Owner <owner> -ListId <pool-name>

param(
    [string]$Owner          = $env:AGENT_OWNER,
    [string]$ListId         = $env:CLAUDE_CODE_TASK_LIST_ID,
    [int]$IntervalSeconds   = 45,
    [double]$MaxMinutes     = 0,        # 0 = unlimited
    [string]$TasksDir,                  # default: $HOME\.claude\tasks\$ListId
    [string]$StateDir                   # default: <scripts>\..\.watcher-state
)

$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($Owner) -or [string]::IsNullOrWhiteSpace($ListId)) {
    Write-Output "[WATCHER] ERROR: Owner / ListId not set (pass -Owner / -ListId, or set AGENT_OWNER / CLAUDE_CODE_TASK_LIST_ID)."
    exit 0
}

. (Join-Path $PSScriptRoot 'Get-PendingTasks.ps1')

if ([string]::IsNullOrWhiteSpace($StateDir)) {
    $StateDir = Join-Path $PSScriptRoot '..\.watcher-state'
}
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}
$ledgerPath = Join-Path $StateDir ("seen-{0}.txt" -f $Owner)
$lockPath   = Join-Path $StateDir ("lock-{0}.txt"  -f $Owner)

$reArm = '  Bash(run_in_background:true): powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -Owner {1} -ListId {2}' -f $PSCommandPath, $Owner, $ListId

function Remove-Lock { if (Test-Path $lockPath) { Remove-Item $lockPath -Force -ErrorAction SilentlyContinue } }
function Touch-Lock  { Set-Content -Path $lockPath -Value ((Get-Date).ToString('o')) -Encoding ASCII }

# --- singleton heartbeat-lock: never run two watchers for the same owner ---
$staleSeconds = [Math]::Max(120, $IntervalSeconds * 3)
if (Test-Path $lockPath) {
    $age = ((Get-Date) - (Get-Item $lockPath).LastWriteTime).TotalSeconds
    if ($age -lt $staleSeconds) {
        Write-Output ("[WATCHER] {0}: another watcher already active (lock age {1:N0}s) - exiting (not re-arming)." -f $Owner, $age)
        exit 0
    }
}
Touch-Lock

# --- load ledger (ids already reported as detected) ---
$seen = @{}
if (Test-Path $ledgerPath) {
    foreach ($line in (Get-Content -Path $ledgerPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $id = "$line".Trim()
        if ($id) { $seen[$id] = $true }
    }
}

$startTime = Get-Date

while ($true) {
    $pending    = @(Get-PendingTasks -Owner $Owner -ListId $ListId -TasksDir $TasksDir)
    $pendingIds = @($pending | ForEach-Object { "$($_.id)" })
    $new        = @($pending | Where-Object { -not $seen.ContainsKey("$($_.id)") })

    if ($new.Count -gt 0) {
        # mark ALL current pending as seen (adds new ids, prunes completed ones), persist, report, exit
        Set-Content -Path $ledgerPath -Value $pendingIds -Encoding UTF8
        Remove-Lock

        Write-Output ("[WATCHER] {0}: {1} new task(s). Do TWO steps IN ORDER." -f $Owner, $new.Count)
        Write-Output ""
        Write-Output "STEP 1 (do this FIRST, before reading the task below - non-negotiable): re-arm the watcher:"
        Write-Output $reArm
        Write-Output "(Safe: re-arm will NOT re-fire on the task(s) below - they are already in the ledger.)"
        Write-Output ""
        Write-Output "STEP 2 (only after STEP 1 is launched) - handle the task(s):"
        foreach ($t in $new) {
            $from = ''
            if ($t.metadata -and ($t.metadata.PSObject.Properties.Name -contains 'from')) { $from = " (from $($t.metadata.from))" }
            $title = $null
            if ($t.PSObject.Properties.Name -contains 'subject' -and -not [string]::IsNullOrWhiteSpace($t.subject)) { $title = $t.subject }
            elseif ($t.PSObject.Properties.Name -contains 'title' -and -not [string]::IsNullOrWhiteSpace($t.title)) { $title = $t.title }
            if ([string]::IsNullOrWhiteSpace($title)) { $title = '<no title>' }
            Write-Output ("- {0}{1}: {2}" -f $t.id, $from, $title)
            if ($t.metadata -and ($t.metadata.PSObject.Properties.Name -contains 'payload_path')) {
                Write-Output ("  payload: {0}" -f $t.metadata.payload_path)
            }
        }
        exit 0
    }

    # prune in-memory ledger of ids no longer pending (keeps it tidy over long runs)
    if ($seen.Count -gt 0) {
        $stillPending = @{}
        foreach ($id in $pendingIds) { if ($seen.ContainsKey($id)) { $stillPending[$id] = $true } }
        $seen = $stillPending
    }

    if ($MaxMinutes -gt 0 -and ((Get-Date) - $startTime).TotalMinutes -ge $MaxMinutes) {
        Set-Content -Path $ledgerPath -Value (@($seen.Keys)) -Encoding UTF8
        Remove-Lock
        Write-Output ("[WATCHER] {0}: max runtime ({1} min) reached, no new tasks. Re-arm to keep watching:" -f $Owner, $MaxMinutes)
        Write-Output $reArm
        exit 0
    }

    Touch-Lock                       # heartbeat
    Start-Sleep -Seconds $IntervalSeconds
}
```

**Инварианты и дисциплина** — в [Pool Communication §7.5](pool-communication.md): идемпотентный перевзвод через леджер, один watcher на owner через heartbeat-lock, дисциплина «перевзвод — ШАГ 1». Механизм экспериментальный: подтвердить idle-wake + поведение при `/compact` на своём окружении до раскатки.

---

## 5. README для скриптов

`<workspace-root>/scripts/README.md` — справка по pool'ам и диагностика:

```markdown
# Pool Launcher Scripts

## Запуск

| Pool | Agent | Wrapper |
|------|-------|---------|
| `<pool-A>` | `<role>-<scope-A>` | `claude-<role>-<scope-A>.bat` |
| `<pool-A>` | `<role>-<scope-B>` | `claude-<role>-<scope-B>.bat` |
| `<pool-B>` | `<role>-<scope>` | `claude-<role>-<scope-B-pool>.bat` |

Двойной клик по wrapper'у. Auto-resume по display name.

## Диагностика: pool не активирован

Признак: env vars выставлены, но баннер `[POOL INBOX]` не появляется.

1. Проверь `$env:AGENT_OWNER` и `$env:CLAUDE_CODE_TASK_LIST_ID` в
   запущенной сессии — попроси Claude вывести их.
2. Проверь наличие `~/.claude/tasks/<TASK_LIST_ID>/` — папка создаётся
   при первом `TaskCreate`. Если её нет — никаких pending нет, это норма.
3. Проверь `<workspace-root>/.claude/settings.local.json` —
   блок `hooks.UserPromptSubmit` на месте, путь к скрипту абсолютный и
   валидный.
4. Проверь, что hook был одобрен. На первом запуске после регистрации
   нового hook'а Claude Code просит подтверждение — без него hook не
   выполняется.
5. Запусти hook вручную с выставленными env vars:
   ```
   $env:AGENT_OWNER='<owner>'
   $env:CLAUDE_CODE_TASK_LIST_ID='<pool-name>'
   powershell -NoProfile -File <workspace-root>\.claude\hooks\inject-inbox.ps1
   ```
   Должен вывести баннер или `clean (0 pending)`.

## Диагностика: mojibake в баннере

Симптом: вместо имён роли/задач — мусорные символы.

Причина: hook не выставил UTF-8 для stdout. Проверь, что первые две
строки скрипта — это `[Console]::OutputEncoding = ...` и
`$OutputEncoding = ...` (см. inject-inbox.ps1 в этой папке).
```

---

## 6. Связанные документы

- [Pool Communication](pool-communication.md) — как эта инфра работает в
  координации с Tasks API и mailbox.
- [Workspace Organization](workspace-organization.md) — куда эти скрипты
  кладутся в общей структуре.
- [Intra-Project Pool Recipe](intra-project-pool-recipe.md) — пошаговый
  bootstrap, который использует эти скрипты.
- [Lessons Learned §3](lessons-learned.md) — антипаттерны разработки
  pool-инфры.
