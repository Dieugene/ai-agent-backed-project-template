# Workspace Organization

Описание модели рабочего пространства для команды AI-агентов (Claude Code
и совместимые). Базовый паттерн, на котором стоит [Pool
Communication](pool-communication.md) и [Tech Lead Mode](tech-lead-mode.md).

> Это описание паттерна, не инструкция под конкретный проект. Все
> идентификаторы заменены плейсхолдерами вида `<workspace-root>`,
> `<subproject>`, `<role>-<scope>`.

---

## 1. TL;DR

**Workspace** — общая родительская папка над набором связанных проектов.
Каждый проект — отдельный git-репозиторий внутри `01_projects/<name>/`.
Workspace-root обычно тоже git-репо (для версионирования стандартов и
pool-инфры); подпроекты он игнорирует через `.gitignore`. Claude Code
запускается из корня workspace, чтобы каждый агент видел соседей.

**Активная агентская модель — одна:** Tech Lead, работающий в
subagent-driven режиме через `superpowers`-скилы. Прежние роли Architect,
Developer, Reviewer **архивированы** — Tech Lead закрывает их функции
через скилы (planning, TDD, code review). См. [Tech Lead Mode](tech-lead-mode.md).

**Workspace может работать в двух режимах:**

- **Plain monorepo** — общая папка для visibility, без координации между
  сессиями. Default для нового workspace.
- **Pool monorepo** — то же + слой координации через **maildir pool-шину**
  (общая команда `pool` поверх `<bus>`) + UserPromptSubmit-hook
  (`pool hook`). Используется когда несколько сессий должны обмениваться
  задачами без участия пользователя как диспетчера. Поднимается одной
  командой-скаффолдером. Полный стандарт — [Pool
  Communication](pool-communication.md).

**Принцип границ:** агент читает что угодно в workspace (для контекста и
согласования API), но пишет/коммитит только в своей рабочей папке.
Workspace-root и чужие подпроекты — read-only.

---

## 2. Когда монорепо, когда — нет

### Объединять в один workspace

- Проекты разрабатываются параллельно одним владельцем.
- Производитель/потребитель — один проект продуцирует артефакт, второй
  его потребляет.
- Идейная семья — разные модули одной платформы, разные ассистенты на
  одном движке.
- Совместный пул задач — нужна координация между сессиями (см. pool).

### НЕ объединять

- Проекты ничем не связаны (личный pet и рабочий заказчик).
- Радикально разные стеки (Python ML-проект и Go-сервис с своей
  инфраструктурой).
- Только один проект — workspace избыточен. Стартуй прямо как одиночный
  репо.

### Два варианта по git-уровню

**Вариант A. Workspace как координационный layer.**

```
workspace-root/.git/                   ← один git-репо: стандарты, шаблоны, pool-инфра
01_projects/<subproject-A>/.git/       ← отдельный git-репо со своим remote
01_projects/<subproject-B>/.git/       ← отдельный git-репо со своим remote
```

- Каждый подпроект — независимый git-репозиторий со своим remote.
- Workspace-root тоже git-репо (стандарты, pool-инфра). Подпроекты явно
  перечислены в его `.gitignore`.

**Когда выбирать A:**

- Подпроекты ничего не делят на уровне кода.
- Могут разойтись по релизной истории, версионированию, владельцам.
- Нужно отдавать `git clone <subproject-repo>` стороннему разработчику.
- Workspace появился как «надкоммунальная» координация над существующими
  репозиториями.

**Вариант B. Полный монорепо.**

```
workspace-root/.git/                   ← один git-репо на ВСЁ
├── 01_projects/<subproject-A>/        ← обычные папки внутри одного репо
├── 01_projects/<subproject-B>/
└── 02_src/                            ← общий код, разделяемый между подпроектами
```

- Один `.git/` на весь workspace. Подпроекты — обычные папки.
- Общий код в `02_src/` импортируется подпроектами как локальные пакеты.

**Когда выбирать B:**

- Есть общий код, который реально шарится между подпроектами.
- Подпроекты эволюционируют синхронно — изменение в одном часто требует
  поправок в `02_src/` и в соседях.
- Один владелец, одна релизная история, единый CI.

**Что одинаково в A и B:** pool-инфраструктура, агентская модель, запуск
Claude Code из корня workspace, правила границ, структура подпроекта —
идентичны. Разница касается только git-уровня.

| Сигнал | Скорее A | Скорее B |
|--------|----------|----------|
| Общий код | нет | да |
| Релизы по подпроектам разные | да | нет |
| Подпроекты могут уйти к другим людям | да | нет |
| Подпроекты эволюционируют параллельно с тесной связкой | нет | да |
| Существующие независимые репо собираются под крышу | да | нет |

Default для нового стартового workspace без общего кода — **A**. Default
когда строится платформа с общими пакетами — **B**.

---

## 3. Анатомия workspace

```
<workspace-root>/                          # git-репо (см. §2 — варианты A и B)
├── .git/                                  # workspace-уровневая история
├── .gitignore                             # вариант A: подпроекты явно игнорируются
│                                          # вариант B: подпроекты в репо
├── README.md                              # 1-страничное описание workspace
├── AGENTS.md                              # обзор для Claude Code в plain-режиме
├── CLAUDE.md                              # routing entry point
│                                          # обязательный для pool, опц. для plain
├── 00_docs/                               # общие документы workspace
│   ├── architecture/                      # кросс-проектные ADR
│   └── standards/                         # стандарты, специфичные для workspace
├── 01_projects/                           # подпроекты
│   ├── <subproject-A>/                    # A: со своим .git/. B: обычная папка
│   └── <subproject-B>/
├── 02_src/                                # ОПЦИОНАЛЬНО: общий код (характерно для B)
│
│   --- pool-only ---
├── .bus/                                  # данные pool-шины (maildir; gitignored, ленивый)
│   ├── <owner>/{tmp,new,cur}/             # личный «ящик» каждого owner'а
│   ├── archive/                           # обработанные сообщения
│   ├── .ledger/                           # ledger вотчера
│   └── .watch/                            # heartbeat-lock вотчера
├── .claude/
│   └── settings.local.json                # регистрация hook = pool-CLI 'hook' (gitignored)
├── board-<name>.bat                       # открыть живую доску пула
└── scripts/
    ├── pool-launch.ps1                    # auto-resume helper
    ├── archive-completed-tasks.ps1        # дворник ЛИЧНЫХ todo (Tasks API)
    ├── claude-<role>-<scope>.bat          # launcher на каждого агента (у лида — авто-доска)
    └── README.md                          # справка по pool'ам и диагностика
```

(Сама pool-CLI — одна общая копия на весь workspace, в пул НЕ копируется.)

**Обязательно у каждого workspace:**

- `.git/`, `.gitignore`, `README.md`, `01_projects/`.
- `AGENTS.md` или `CLAUDE.md` (хотя бы один).

**Опционально (по необходимости):**

- `00_docs/` — если есть общие стандарты или кросс-проектные ADR.
- `02_src/` — если есть общий код. Характерно для варианта B.
- Pool-инфраструктура (`.bus/`, hook-регистрация, scripts) — только если
  включаем pool-режим.

### `AGENTS.md` vs `CLAUDE.md`

Оба файла Claude Code подгружает на старте, но играют разные роли:

- **`AGENTS.md`** — описывает workspace для разработчика и для агента в
  обычном режиме: что за проект, какие подпроекты, как они связаны.
  Растёт медленно.
- **`CLAUDE.md`** — операционный entry point: «куда пойти и что
  прочитать перед тем как отвечать пользователю». Routing для pool,
  ссылки на стандарты, шаги первичного onboarding. Может быть короче
  AGENTS.md, но более директивный.

Если workspace без pool — `CLAUDE.md` можно опустить или сделать тонкой
ссылкой на `AGENTS.md`. Если с pool — `CLAUDE.md` обязателен.

---

## 4. Анатомия подпроекта

```
01_projects/<subproject>/
├── .git/                                  # вариант A: собственный git со своим remote
│                                          # вариант B: отсутствует, всё в parent
├── .gitignore                             # локальные правила (data, logs, venv)
├── README.md                              # о подпроекте
├── CLAUDE.md                              # навигация для Claude
│                                          # в pool-mode: блок «Pool-режим (читать первым)»
├── 00_docs/
│   ├── architecture/                      # overview.md, ADR, plans
│   ├── specs/                             # спецификации, референсы
│   ├── qa/                                # если есть QA-peer
│   └── backlog.md                         # реестр задач
├── 01_tasks/                              # папки задач NNN_*/
│   └── 001_*/
│       ├── task_brief_01.md
│       ├── implementation_01.md
│       └── review_01.md
├── 02_src/                                # исходный код подпроекта
├── 03_data/                               # обычно gitignored
├── 04_logs/                               # обычно gitignored
└── _agent_pool_setup-<scope>.md           # ОПЦИОНАЛЬНО (только в pool-mode)
                                           # onboarding peer'а: owner ID,
                                           # POOL_BUS_ROOT, peer-контекст, зоны
```

### Нумерация и именование

- **Папки задач**: `NNN_short_name` — трёхзначный, единый стиль в подпроекте.
- **ADR**: `decision_NNN_*.md`.
- **Итерации файлов в задаче**: суффикс `_NN` — `task_brief_01.md`, при
  возврате — `task_brief_02.md`. Не перезаписываем.
- **Служебные файлы**: префикс `_` — `_questions_to_user.md`, `_draft_*.md`.

### Backlog

Каждый подпроект ведёт свой `backlog.md` в `00_docs/`:

```markdown
| ID  | Название       | Приоритет | Статус        | Дата начала | Дата завершения |
|-----|----------------|-----------|---------------|-------------|-----------------|
| 001 | Skeleton MVP   | High      | Выполнена     | YYYY-MM-DD  | YYYY-MM-DD      |
| 002 | Add SSE viz    | Medium    | В работе      | YYYY-MM-DD  | -               |
```

Workspace-root не ведёт backlog — задачи привязаны к подпроектам.
Кросс-проектная задача = две связанные задачи, по одной в каждом, плюс
координация через pool-mailbox или через пользователя.

---

## 5. Plain vs pool режим

### A. Plain monorepo (default)

**Что включено:**

- Общий workspace-root → каждая Claude Code сессия видит соседей.
- Каждый подпроект — независимая Tech Lead-сессия.
- Координация между подпроектами **через пользователя**.

**Что НЕ включено:**

- Pool-шина (`.bus/`) не разворачивается.
- Hook на UserPromptSubmit не нужен.
- Сессии не знают друг о друге автоматически.

### B. Pool monorepo

**Координация — через общую maildir pool-шину.** Сообщение = immutable-файл,
адрес получателя = папка `<bus>/<owner>/new/`. Что добавляется поверх plain
(несёт сам пул; pool-CLI — одна общая копия на весь workspace, не
копируется):

- `.bus/` — данные шины (maildir: `<owner>/{tmp,new,cur}/`, `archive/`,
  `.ledger/`, `.watch/`). Создаётся лениво, gitignored.
- `.claude/settings.local.json` с hook'ом `pool hook` (по абсолютному пути).
- `scripts/pool-launch.ps1` + `scripts/archive-completed-tasks.ps1` (дворник
  личных todo) + `claude-<role>-<scope>.bat` на каждого агента (у лида —
  авто-доска); `board-<name>.bat`.
- `CLAUDE.md` workspace-root с routing-таблицей `AGENT_OWNER` → папка.
- `_agent_pool_setup-<scope>.md` в каждой рабочей папке.
- env vars `AGENT_OWNER`, `POOL_BUS_ROOT`, `POOL_INBOX_QUIET=1` (и
  `CLAUDE_CODE_TASK_LIST_ID` под личные todo), выставляемые wrapper'ом.

**Создание pool — одной командой:** скаффолдер из спеки генерит весь
bus-native каркас. Подробности механики — [Pool
Communication](pool-communication.md). Подъём intra-project pool с нуля —
[Intra-Project Pool Recipe](intra-project-pool-recipe.md).

---

## 6. Мульти-пулинг

В одном workspace может работать **несколько pool'ов параллельно**:

- Несколько подпроектов, каждый со своим intra-project pool.
- Один подпроект как inter-project pool, другие — без pool.
- Разные команды владеют разными pool'ами.

На maildir-шине изоляция структурно проще, чем в Tasks-API-эпоху: у каждого
пула — свой `BusRoot` (`POOL_BUS_ROOT`, обычно `<repo>\.bus`); hook
`pool hook` сам читает `<bus>/<owner>/new/` по env, отдельных под-каталогов
под адресацию не нужно (получатель = папка owner внутри своей шины).

### Что общее у всех pool'ов

| Компонент | Почему общий |
|-----------|--------------|
| pool-CLI (`hook`/`send`/`watch`/...) | Одна общая копия на весь workspace; читает `$env:AGENT_OWNER` и `$env:POOL_BUS_ROOT`, не знает ничего про конкретный pool. В пулы не копируется. |
| `.claude/settings.local.json` (блок `hooks.UserPromptSubmit`) | Один hook (`pool hook`) обслуживает любое число pool'ов — изоляция через `POOL_BUS_ROOT`. |
| `scripts/pool-launch.ps1` | Принимает `$SessionTitle` параметром. Универсальный. |

### Что естественно изолировано

| Компонент | Изоляция |
|-----------|----------|
| `<bus>` (`POOL_BUS_ROOT`) | Каждый пул — своя шина (свой `.bus/`). Pool A работает по `<repo-A>\.bus`, pool B — по `<repo-B>\.bus`. Адрес = папка owner внутри своей шины; пулы не пересекаются. |
| `~/.claude/tasks/<TASK_LIST_ID>/` | Tasks API (личные todo) хранит per-`TASK_LIST_ID`. Pool A пишет в `foo-pool/`, pool B — в `bar-pool/`. Не пересекаются. |

### Что изолировать вручную

| Компонент | Природа коллизии | Решение |
|-----------|------------------|---------|
| `scripts/claude-*.bat` | По одному батнику на агента | Convention: `claude-<role>-<scope>.bat`, scope включает имя pool'а |
| `CLAUDE.md` routing | Маппинг растёт по мере pool'ов | Разделы на каждый pool в одном файле |
| `_agent_pool_setup.md` | В intra-project pool в одной папке N агентов | Суффикс scope: `_agent_pool_setup-<scope>.md` |

Канонический способ поднять каждый пул — скаффолдер (генерит bus-native
каркас, свой `.bus/`); коллизий имён сообщений между пулами не бывает —
адресация по папке owner внутри своей шины.

---

## 7. Общие правила (для обоих режимов)

### cwd = workspace root

Claude Code всегда стартует с cwd `<workspace-root>`. Это:

- Подгружает workspace-уровневые `CLAUDE.md`, `AGENTS.md`,
  `.claude/settings.local.json` (с hook-ами).
- Даёт сессии видимость всех подпроектов.
- В pool-режиме — обязательное условие, иначе `settings.local.json` с
  hook'ом не подхватится.

Не делать `cd 01_projects/<subproject>/` в начале сессии. Если задача
требует относительных путей внутри подпроекта — Bash может временно
`cd`, но «домашний» cwd — корень workspace.

### Чужое можно читать, писать — только в своём

- **Читать** что угодно в workspace: соседние подпроекты, для
  согласования API, поиска похожих паттернов.
- **Писать** (создавать файлы, модифицировать, коммитить) — только в
  своей рабочей папке (`01_projects/<свой-scope>/`).
- Категорически **не** модифицировать файлы соседнего подпроекта или
  чужого peer'а в intra-project pool. Изменение в чужой зоне →
  координация через `pool send -To <сосед>`.

### Cross-boundary writes — осторожно

- `git add -A` / `git add .` запускать **только из подпроекта**, не из
  workspace-root.
- Не использовать `git commit -a` без явных pathspec'ов в общих
  директориях.
- Служебный `.bus/` (шина) — gitignored, в коммиты не попадает.

### Стандарты не дублируются в подпроекты

Standards в `<workspace-root>/00_docs/standards/` — общие для всех
подпроектов workspace. Подпроект не копирует их к себе, а ссылается.
Если подпроекту нужен специфичный стандарт — он живёт в
`<subproject>/00_docs/`, а в общих стандартах workspace его нет.

---

## 8. Bootstrap нового workspace

### Шаг 1. Состав

- Имя workspace (kebab-case, описывает тему).
- Список первых подпроектов (минимум 1, обычно 2-3).
- Решить: будет ли общий код в `02_src/`? (Если да — вариант B.)
- Решить: plain или pool? (Default — plain.)

### Шаг 2. Каркас

```
mkdir <workspace-name>
cd <workspace-name>
git init -b main
mkdir 01_projects 00_docs 00_docs/architecture 00_docs/standards
```

В `.gitignore` workspace-root **обязательно** (вариант A):

```gitignore
# Подпроекты — отдельные git-репо
/01_projects/<subproject-A>/
/01_projects/<subproject-B>/

# Claude Code локальные настройки
.claude/settings.local.json

# Стандартное
__pycache__/
*.pyc
.venv/
venv/
.env
```

Имена подпроектов в gitignore перечисляются **явно** (не
`/01_projects/*/`) — иначе при добавлении нового подпроекта легко забыть
и закоммитить его в parent.

### Шаг 3. Подпроекты

- Если уже существует — переместить (`mv`).
- Если новый — `git init` или `git clone` прямо в `01_projects/<name>/`.

В каждом: `README.md`, `00_docs/`, `01_tasks/`, `02_src/`, `CLAUDE.md`.

### Шаг 4. Первый коммит workspace

```bash
git add README.md AGENTS.md .gitignore 00_docs/
git commit -m "Initial <name> workspace"
```

Подпроекты в первом коммите не участвуют — они в своих репо (вариант A).

### Шаг 5 (опционально). Pool

Когда появились сигналы — **канонический способ** поднять пул (bus-native, на
общей maildir-шине) — одна команда-скаффолдер из спеки (`spec.json`: имя
пула, лид, заголовок, роли `owner`+`label`). Он генерит весь каркас: `.bus/`
(ленивый maildir), `.claude/settings.local.json` с hook'ом `pool hook`,
`CLAUDE.md` (routing по `AGENT_OWNER`), `claude-<owner>.bat` на каждую роль (у
лида — авто-доска), `board-<name>.bat`, `_agent_pool_setup-<owner>.md`,
`scripts/{pool-launch, archive-completed-tasks}`, каркас `00_docs/`. Сама
pool-CLI НЕ копируется. Пошагово, smoke-test и intra-project нюансы — [Pool
Communication](pool-communication.md) и [Intra-Project Pool
Recipe](intra-project-pool-recipe.md).

---

## 9. Антипаттерны

### 1. Скачком создавать «всю архитектуру с 4 ролями»

**Симптом:** создаём `architect.md`, `tech-lead.md`, `developer.md`,
`reviewer.md`, расписываем handoff'ы — и потом 90% работы делает один
Tech Lead, потому что роли не наполняются.

**Митигация:** только Tech Lead. Если дисциплина теряется — добавлять
`superpowers`-скил, не отдельную роль. Подробно — [Tech Lead Mode](tech-lead-mode.md).

### 2. Подпроекты внутри parent-репо без `.gitignore`-изоляции

**Симптом:** `git status` в parent показывает кучу изменений из
подпроектов. `git add .` ловит всё подряд.

**Митигация:** в `.gitignore` workspace-root **явно перечислить** пути
всех подпроектов. Не использовать `01_projects/*/` — глоб не защищает от
случайно забытого нового подпроекта.

### 3. Workspace-root без git

**Симптом:** стандарты и pool-инфра живут «где-то», нет истории, нельзя
откатить.

**Митигация:** workspace-root — git-репо даже если remote'а нет.

### 4. cwd = подпроект при старте Claude Code

**Симптом:** Claude не видит соседей. Pool-hook не активируется
(`settings.local.json` в parent не подхватывается). Нужно мысленно
держать «в каком я сейчас подпроекте».

**Митигация:** стартовать всегда с cwd = workspace root.

### 5. Дублирование стандартов в каждый подпроект

**Симптом:** «Стандарты называния» лежат в 4 подпроектах одновременно.
Когда правишь — забываешь про какую-то копию.

**Митигация:** standards живут в `<workspace-root>/00_docs/standards/`.
Подпроекты ссылаются.

### 6. Pool-режим в одиноком workspace

**Симптом:** один подпроект, один Tech Lead, но навешана вся pool-инфра.
Пользователь путается.

**Митигация:** default — plain. Pool — когда реально 3+ агентов с
координацией.

---

## 10. Связанные документы

- [Pool Communication](pool-communication.md) — координация через
  maildir pool-шину + hook.
- [Tech Lead Mode](tech-lead-mode.md) — рабочий режим единственной
  активной роли.
- [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) — pool-инфра
  скриптами.
- [Intra-Project Pool Recipe](intra-project-pool-recipe.md) — пошаговый
  bootstrap intra-project pool.
- [DevOps Two-Layer Model](devops-two-layer.md) — server-wide
  оркестратор + per-monorepo DevOps.
- [Lessons Learned](lessons-learned.md) — антипаттерны и грабли.
