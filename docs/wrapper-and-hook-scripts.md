# Wrapper and Hook Scripts

Полные рабочие примеры скриптов pool-инфраструктуры.

> ## ⚡ Координация — на maildir pool-шине (с этой ревизии)
>
> Hook и watcher теперь — **встроенные режимы общей pool-CLI** (`pool hook`
> / `pool watch`), читающей шину `<bus>` (`POOL_BUS_ROOT`), а не отдельные
> скрипты поверх Tasks-store. pool-CLI — **одна общая копия на весь
> workspace** (её устройство — §1.5), в пулы НЕ копируется. Wrapper'ы несут
> env `POOL_BUS_ROOT` (+ `POOL_INBOX_QUIET=1`); у ведущего агента — строка
> авто-запуска живой доски (`board`-окно).
>
> Старые скрипты `inject-inbox.ps1` (§4), `wait-for-task.ps1` +
> `Get-PendingTasks.ps1` (§4.5) **заменены** этими режимами — вместо их кода
> оставлена пометка **DEPRECATED** + чем заменено (сам код в bus-native пуле
> не нужен). `pool-launch` (§3) остаётся как есть; дворник **личных** todo
> `archive-completed-tasks.ps1` (§4.6) тоже остаётся, но его код вынесен в
> шаблон `scripts/templates/`.

Универсальные части (`pool-launch`, wrapper-батник на агента) обслуживают
любое число pool'ов в одной workspace.

> Целевая среда — Windows + PowerShell. На Linux/macOS принцип идентичен,
> но конкретный код адаптируется (bash вместо powershell, /bin/sh shebang
> вместо `.bat`).

---

## 1. Цепочка процессов

```
cmd.exe                                              ← wrapper-батник
  set AGENT_OWNER=<role>-<scope>
  set POOL_BUS_ROOT=<workspace-root>\.bus
  set CLAUDE_CODE_TASK_LIST_ID=<pool-name>   (личные todo)
  set POOL_INBOX_QUIET=1
  cd /d <workspace-root>
  ↓
powershell -NoProfile -ExecutionPolicy Bypass        ← pool-launch helper
  -File <workspace-root>\scripts\pool-launch.ps1
  -SessionTitle <SessionTitle>
  -ProjectKey <ProjectKey>
  ↓
claude.exe --dangerously-skip-permissions            ← Claude Code
  --resume <session-id>   ИЛИ   --name <SessionTitle>
  ↓
hook on UserPromptSubmit                             ← pool-CLI 'hook'
  reads env vars, scans <bus>/<owner>/new/,
  emits [POOL INBOX] banner
```

Env vars из `cmd.exe` наследуются всем дочерним процессам автоматически.
`-NoProfile` отключает загрузку `$PROFILE` пользователя — никаких
сторонних алиасов или эффектов. Прямой вызов `claude` (без алиаса
`cld` или подобных) исключает риск потери env vars из-за лишнего звена.

---

## 1.5. Ядро pool-CLI: `pool.ps1` (одна общая копия на workspace)

Всё, что ниже (`hook`, `watch`, борд, сама координация), — **подкоманды одного
скрипта** `pool.ps1`. Это ядро pool-инфраструктуры: wrapper (§2) и helper (§3)
лишь запускают сессию и прокидывают env, а обмен сообщениями между агентами
идёт через `pool.ps1`.

**Одна копия на весь workspace.** `pool.ps1` лежит в
`<workspace-root>\scripts\pool.ps1` (в этом репозитории —
[`../scripts/pool.ps1`](../scripts/pool.ps1)) и **в пулы НЕ копируется**. Пул
поставляет только:

- **данные** — свой каталог-шину `<bus>` (`POOL_BUS_ROOT`), пустой на старте,
  наполняется лениво при первом `send`;
- **тонкую привязку** — env в wrapper'е (§2) + регистрацию hook'а в
  `settings.local.json` (§4), где путь к `pool.ps1` абсолютный.

Правка этого одного файла меняет поведение **сразу всех** пулов workspace —
per-pool rollout не нужен. `Owner` и `BusRoot` берутся из env
(`AGENT_OWNER` / `POOL_BUS_ROOT`), поэтому hook и watcher работают без явных
аргументов.

**Maildir-модель** (полный lifecycle — [Pool Communication §4](pool-communication.md)):

- **сообщение = один immutable-файл**; id = `<unix-ms>-<hex>`,
  лексикографически sortable, НИКОГДА не переиспользуется;
- **адрес получателя = ПАПКА** `<bus>/<owner>/new/` — не поле объекта, а
  каталог;
- **переход состояния = атомарный rename**: `tmp/`→`new/` (доставка),
  `new/`→`cur/` (claim), `cur/`→`archive/` (ack).

Файлы в шину руками не пишут — только через `pool.ps1`: он гарантирует
атомарный `tmp`→`new` rename и читает/пишет тела как UTF-8 без BOM.

**Кодировки — специфика Windows/PS 5.1.** Сам исходник `pool.ps1` —
**ASCII-only**: PowerShell 5.1 без BOM ломает кириллицу прямо в тексте
скрипта, поэтому в коде нет ни одной кириллической буквы. А **тела сообщений**
пишутся и читаются как **UTF-8 без BOM** в рантайме — значит кириллические
данные (темы, тексты задач) безопасны. Как следствие, режим `hook` сам
выставляет UTF-8 на stdout: отдельно чинить mojibake баннера (как приходилось
в старом кастомном hook'е) не нужно.

**Подкоманды** (полный код и шапка — [`../scripts/pool.ps1`](../scripts/pool.ps1);
здесь — карта, не дубль):

| Подкоманда | Назначение |
|-----------|-----------|
| `send` | поставить задачу: файл в `<bus>/<To>/new/` |
| `reply` | ответить/отчитаться (свежий id; `-InReplyTo <id>` тянет thread) |
| `note` | сообщение-FYI (не задача): секция `[POOL NOTE]`, гасится `dismiss`; `-Wake` будит watcher |
| `inbox` | входящие (`new/`) — то же, что печатает hook-баннер |
| `mine` | своя «тарелка»: `cur/` (в работе) + `new/` (ожидает) + notes — восстановление после `/compact` |
| `claim` | взять задачу: `new/`→`cur/` (атомарно; проигравший получит `CLAIM-MISS`) |
| `ack` | завершить: `cur/`→`archive/` |
| `dismiss` | закрыть note одним шагом: `new/`→`archive/` (без claim/ack) |
| `check` | один проход детекции watcher'а (для скриптов/теста) |
| `watch` | фоновый спящий watcher (§4.5) |
| `hook` | UserPromptSubmit-hook: баннер `[POOL INBOX]` (§4) |
| `activity` | hook активности: пишет `.activity/<owner>` (busy/idle/subagents) для борда |
| `board` | доска пула: снимок · `-Watch` живая здесь · `-Show` живая в новом окне |
| `help` | печатает шапку скрипта |

Разделение **задача vs note**: задача (`send`/`reply`) требует действия
(claim → работа → `ack`/`reply`), висит в `[POOL INBOX]` и на борде, будит
watcher. Note (`note`) — FYI: отдельная секция, на борде нет, гасится одним
`dismiss`; будит watcher только с флагом `-Wake`.

**Хук `activity` попутно чистит ready-флаг завершения.** На `UserPromptSubmit`
(новый ход) `activity` не только помечает owner'а `busy` для борда, но и
**удаляет** флаг готовности к завершению
`<user-home>\.claude\.control\shutdown-ready-<owner>`, если тот есть.
Source-agnostic: неважно, чем разбудили сессию (watcher / peer / прямой ввод) —
**любой** новый ход инвалидирует устаревшую метку, чтобы протухший «готов» не
авторизовал гашение сессии, чей handoff уже неактуален. Флаг ставит агент в
конце handoff-хода, а стирается он **только** здесь (не на `Stop` — тот снёс бы
его сразу). Механику завершения, читающую этот флаг, — [Pool Shutdown & Context
Refresh](pool-shutdown-and-context-refresh.md).

---

## 2. Wrapper-батник на агента

`<workspace-root>/scripts/claude-<role>-<scope>.bat`:

```batch
@echo off
REM Pool wrapper: <role> для подпроекта <scope>.
REM Owner ID: <role>-<scope>. Pool: <pool-name>.
REM Bus-native: координация через общую pool-CLI (maildir).
REM Cwd = <workspace-root>. ProjectKey: <ProjectKey>.

set AGENT_OWNER=<role>-<scope>
set POOL_BUS_ROOT=<workspace-root>\.bus
set CLAUDE_CODE_TASK_LIST_ID=<pool-name>
set POOL_INBOX_QUIET=1
REM Только для ВЕДУЩЕГО агента (lead) — раскомментировать: при старте откроется живая доска пула:
REM powershell -NoProfile -ExecutionPolicy Bypass -File "<path-to-pool-bus>\board-window.ps1" -BusRoot "<workspace-root>\.bus"
cd /d <workspace-root>
powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\scripts\pool-launch.ps1" -SessionTitle "<SessionTitle>" -ProjectKey "<ProjectKey>"
if errorlevel 1 pause
```

**Что заменить под конкретный pool:**

| Placeholder | Что подставить | Пример |
|-------------|----------------|--------|
| `<role>` | Роль агента: `tech-lead`, `architect`, `frontend`, `backend`, `qa`, `devops` | `frontend` |
| `<scope>` | Имя pool'а или подпроекта (kebab-case) | `foo` |
| `<workspace-root>` | Абсолютный путь к корню workspace | `C:\work\foo-workspace` |
| `<bus>` = `POOL_BUS_ROOT` | Корень шины, обычно `<workspace-root>\.bus` | `C:\work\foo-workspace\.bus` |
| `<pool-name>` | `CLAUDE_CODE_TASK_LIST_ID` — каталог **личных** todo, обычно `<scope>-pool` | `foo-pool` |
| `<SessionTitle>` | Display name сессии в PascalCase | `Frontend-Foo` |
| `<ProjectKey>` | Имя проекта в `~/.claude/projects/`. Совпадает с `<workspace-root>` с заменой `\` и `:` на `---` | `C---work-foo-workspace` |

**Один батник на одного агента.** Двойной клик возвращает агента в его
же conversation (через auto-resume по `<SessionTitle>`). `POOL_BUS_ROOT`
одинаков у всех агентов одного workspace (одна шина); у **ведущего**
агента дополнительно раскомментирована строка авто-запуска живой доски.

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

# Task-store hygiene (best-effort, never blocks launch): archive completed tasks
# so Claude Code's built-in task-list context injection (whole list_id, completed
# included, no owner filter) stays small. See section 4.6.
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

## 4. Hook = pool-CLI `hook` (bus-native)

В bus-native пуле hook — это **подкоманда общей pool-CLI**, а не отдельный
файл. Он читает `$env:AGENT_OWNER` и `$env:POOL_BUS_ROOT`, перечисляет
`<bus>/<owner>/new/` и эмитит баннер `[POOL INBOX]`. UTF-8 на stdout
выставляет сама pool-CLI (кириллица без mojibake), отдельный fix не нужен.

### Регистрация hook'а

`<workspace-root>/.claude/settings.local.json` (gitignored,
локально-машинная конфигурация); путь к pool-CLI **абсолютный**, в пул не
копируется:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "powershell -NoProfile -ExecutionPolicy Bypass -File \"<path-to-pool-cli>\" hook"
          }
        ]
      }
    ]
  }
}
```

`<path-to-pool-cli>` — абсолютный путь к общей pool-CLI workspace.

**Поведенческие гарантии:** при пустых env vars — тихий выход (pool не
активен, plain-сессии не шумят); один битый файл шины не валит баннер;
зависимостей нет (встроенные cmdlet'ы PowerShell 5.1).

### DEPRECATED — старый `inject-inbox.ps1`

Прежний отдельный hook-скрипт поверх Tasks-store
(`<workspace-root>/.claude/hooks/inject-inbox.ps1`): читал
`~/.claude/tasks/<list>/*.json` и фильтровал строго по top-level `owner`.
**Заменён** режимом `pool hook`. Ключевая разница: адрес получателя теперь —
папка `<bus>/<owner>/new/`, а не поле `owner` объекта-задачи, поэтому граблю
«двух половин» (payload без правильного owner → невидимое сообщение) шина
снимает **структурно**. Отдельный hook-файл в bus-native пуле не нужен —
код убран за ненадобностью.

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
  абсолютным путём в `command` к одной и той же pool-CLI в workspace).

### Первое одобрение hook'а

`--dangerously-skip-permissions` **НЕ** обходит подтверждение нового
hook'а — это отдельный security gate. На первом запуске Claude Code
покажет prompt: «Allow command: powershell ... pool ... hook?».
Нажать «Yes / Always allow for this project», со второго промпта баннер
появится сам.

---

## 4.5. Опциональный push-watcher = pool-CLI `watch`

Опция «по согласованию», **не для всех агентов** (см. [Pool Communication §7.5](pool-communication.md)). Фоновый watcher будит простаивающую сессию при входящем сообщении. В bus-native пуле это **встроенный режим общей pool-CLI** — `pool watch` (Owner/BusRoot из env). Спит в shell-процессе (ноль контекста на ожидании), **read-only** по шине; состояние — внутри `<bus>` (gitignored): per-owner леджер `<bus>/.ledger/seen-<owner>.txt` + heartbeat-lock `<bus>/.watch/lock-<owner>.txt`. На **новом** сообщении в `<bus>/<owner>/new/` завершается с докладом → харнесс будит сессию.

Запуск — **из сессии агента**, фоновой задачей (`Bash run_in_background: true`):

```
powershell -NoProfile -ExecutionPolicy Bypass -File "<path-to-pool-cli>" watch
```

**Инварианты и дисциплина** — в [Pool Communication §7.5](pool-communication.md): идемпотентный перевзвод через леджер, один watcher на owner через heartbeat-lock, дисциплина «перевзвод — ШАГ 1». Механизм экспериментальный: подтвердить idle-wake + поведение при `/compact` на своём окружении до раскатки.

### DEPRECATED — старые `Get-PendingTasks.ps1` + `wait-for-task.ps1`

Прежняя пара скриптов push-watcher'а поверх Tasks-store: `Get-PendingTasks.ps1`
(читалка pending-задач одного owner, тот же фильтр, что у старого hook'а) +
`wait-for-task.ps1` (спящий фоновый watcher с per-owner леджером
`.watcher-state/seen-<owner>.txt` и heartbeat-lock). **Заменены** режимом
`pool watch`: он читает `<bus>/<owner>/new/`, а состояние держит внутри `<bus>`
(`.ledger/` + `.watch/`) — отдельные файлы больше не нужны. Инварианты
(идемпотентный перевзвод через леджер, singleton через heartbeat-lock,
дисциплина «перевзвод — ШАГ 1») перенесены в `pool watch`; их описание —
в [Pool Communication §7.5](pool-communication.md).

---

## 4.6. Дворник стора ЛИЧНЫХ todo (`archive-completed-tasks.ps1`)

**Обязателен для любого пула, где агенты ведут личные todo через Tasks API** (координация на шине его не касается — у неё свой `archive/` внутри `<bus>`). Причина — в [Pool Communication §5 «Накопление completed»](pool-communication.md): встроенная система задач Claude Code инжектит в контекст **весь** список `list_id` почти каждый ход, **включая `completed`** и **без фильтра по `owner`**; в текущих сборках `completed` файл не удаляет, completed копятся, и список на сотни задач съедает 10–15k токенов/ход у каждого peer'а. Выключить только напоминание нельзя. Рычаг — держать живой список коротким.

Дворник переносит (move, не delete → обратимо) `status=completed` старше `-MinAgeHours` из `~/.claude/tasks/<list>/` в соседний `~/.claude/tasks/<list>-archive/` (архив — не `list_id`, харнесс его не инжектит). Read-only по активным; нечитаемые/mid-write пропускает; safe при гонке с CLI. **Collision-safe:** харнесс переиспользует id после архивации (`max+1` по усохшему живому стору), поэтому существующий архивный `<id>.json` не перезатирается — клон уезжает как `<id>.dupN.json`.

Вызывается автоматически из `pool-launch.ps1` (блок «Task-store hygiene» в §3) при старте/резюме каждой сессии, `-ListId $env:CLAUDE_CODE_TASK_LIST_ID` → чистит только пул этой сессии. Однократно на запуск; общий список подрезает старт любого peer'а. Разовая большая чистка — вручную `-MinAgeHours 0`, затем `/compact` открытым сессиям.

Полный рабочий скрипт (со всеми safety-проверками выше) — шаблон
[`../scripts/templates/archive-completed-tasks.ps1.template`](../scripts/templates/archive-completed-tasks.ps1.template),
копируется в `<workspace-root>\scripts\archive-completed-tasks.ps1` при
заведении пула. Ещё один инвариант из кода: каталог архива — **сосед**
`<list>-archive`, а не подпапка `<list>/`, и его имя не является `list_id`
ни одной сессии → харнесс его не инжектит, чистка контекста работает.

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

1. Проверь `$env:AGENT_OWNER` и `$env:POOL_BUS_ROOT` в запущенной
   сессии — попроси Claude вывести их.
2. Проверь наличие `<bus>` (`POOL_BUS_ROOT`) — каталоги шины создаются
   лениво при первом `pool send`. Если ящика `<bus>/<owner>/new/` нет —
   входящих нет, это норма.
3. Проверь `<workspace-root>/.claude/settings.local.json` —
   блок `hooks.UserPromptSubmit` на месте, путь к pool-CLI абсолютный и
   валидный, режим `hook` указан.
4. Проверь, что hook был одобрен. На первом запуске после регистрации
   нового hook'а Claude Code просит подтверждение — без него hook не
   выполняется.
5. Запусти hook вручную с выставленными env vars:
   ```
   $env:AGENT_OWNER='<owner>'
   $env:POOL_BUS_ROOT='<bus>'
   powershell -NoProfile -File <path-to-pool-cli> hook
   ```
   Должен вывести баннер или `clean (0 pending)`.

## Диагностика: mojibake в баннере

Симптом: вместо имён роли/сообщений — мусорные символы.

Причина (редко): кастомный hook вместо `pool hook` не выставил UTF-8 для
stdout. pool-CLI сам держит UTF-8 на выводе и чтении шины — сверь
`settings.local.json` с актуальной регистрацией (§4).
```

---

## 6. Связанные документы

- [Pool Communication](pool-communication.md) — как эта инфра работает в
  координации через maildir pool-шину.
- [Workspace Organization](workspace-organization.md) — куда эти скрипты
  кладутся в общей структуре.
- [Intra-Project Pool Recipe](intra-project-pool-recipe.md) — пошаговый
  bootstrap, который использует эти скрипты.
- [Pool Shutdown & Context Refresh](pool-shutdown-and-context-refresh.md) —
  контроллер, ради которого хук `activity` чистит `shutdown-ready`-флаг (§1.5).
- [Lessons Learned §3](lessons-learned.md) — антипаттерны разработки
  pool-инфры.
