# Intra-Project Pool Recipe

Пошаговый recipe подъёма intra-project pool (N peer-агентов внутри одного
подпроекта) на готовой workspace-инфраструктуре. Используйте, когда:

- В подпроекте несколько направлений (frontend / backend / qa / architect),
  которые могут идти параллельно.
- Уже есть [pool-инфра workspace](wrapper-and-hook-scripts.md)
  (pool-launch helper, общая pool-CLI, `settings.local.json` с hook'ом).
- Появилась нагрузка, при которой один Tech Lead уже не успевает.

Если pool-инфры ещё нет — сначала [Workspace
Organization §8](workspace-organization.md#8-bootstrap-нового-workspace).

> ## ⚡ Координация — на maildir pool-шине
>
> Координация в пуле идёт через общую команду `pool` (pool-CLI) поверх
> шины `<bus>` (`POOL_BUS_ROOT`): сообщение = immutable-файл, адрес = папка
> `<bus>/<owner>/new/`. Hook на входящие — `pool hook`. **Канонический путь
> поднять пул — скаффолдер** (одна команда генерит весь bus-native каркас
> из спеки, §2.0); ручная сборка ниже — fallback для существующего
> нестандартного монорепо. Личные todo остаются на Tasks API.

> Все идентификаторы — placeholder'ы. Сценарий ниже описывает поднятие
> пула из 4 peer'ов в подпроекте `<sub>`: `architect-<sub>`,
> `frontend-<sub>`, `backend-<sub>`, `qa-<sub>`. Расширение на 5+
> ролей — естественное (добавляем ещё `_agent_pool_setup-*.md` +
> wrapper'ы + routing).

---

## 1. Решения «до того как»

### 1.1 Состав peer'ов

Сценарии:

| Состав | Когда подходит |
|--------|----------------|
| `tech-lead-<sub>` (1) | Подпроект с одним направлением, ничего не разделяется. Не intra-project pool — обычный inter-project. |
| `frontend-<sub>` + `backend-<sub>` (2) | Классический разделённый стек. |
| `frontend-<sub>` + `backend-<sub>` + `qa-<sub>` (3) | + ручной QA через Chrome DevTools MCP. См. §3. |
| `architect-<sub>` + `frontend-<sub>` + `backend-<sub>` + `qa-<sub>` (4) | + выделенный архитектор для ADR и контрактов. |
| 4 + `devops-<sub>` (5) | + персональный DevOps для подпроекта. Только если есть отдельный deploy и self-healing контур, см. [DevOps Two-Layer](devops-two-layer.md). |

Default для нового intra-project pool — **3 peer'а** (frontend / backend /
qa). Усложнение — по мере появления потребности, не превентивно.

### 1.2 Naming convention

- **Owner ID:** `<role>-<sub>` или `<role>-<spec>-<sub>` если у одной
  роли несколько peer'ов с разными специализациями.
- **Display name:** PascalCase `Frontend-Sub`, `Backend-Sub`, `QA-Sub`.
- **Wrapper:** `claude-<role>-<sub>.bat` в папке подпроекта (или в
  `<workspace-root>/scripts/` если решили централизованно).
- **Setup:** `_agent_pool_setup-<role>.md` (или `<role>-<spec>` если
  несколько peer'ов одной роли).
- **Шина:** `POOL_BUS_ROOT = <bus>` (обычно `<workspace-root>\.bus`) —
  одна на весь workspace; ящик каждого peer'а — `<bus>/<owner>/new/`.
- **TASK_LIST_ID:** `<sub>-pool` — каталог **личных** todo (Tasks API), не
  координация.

### 1.3 Зоны записи

До поднятия peer'ов — нарисовать `00_docs/architecture/agent-pool-zones.md`
(хотя бы черновик):

```markdown
| Peer | Зона записи | Read-only context |
|------|-------------|-------------------|
| `architect-<sub>` | `00_docs/architecture/` (ADR, overview, agent-pool-zones), `00_docs/specs/` | весь подпроект |
| `frontend-<sub>` | `02_src/frontend/` | весь подпроект |
| `backend-<sub>` | `02_src/backend/` | весь подпроект |
| `qa-<sub>` | `00_docs/qa/` (backlog, findings, regression-runs) + `Owner-claimed` поле в чужих backlog'ах | весь подпроект |
```

Без этого файла peer'ы будут «слегка заходить в чужое» — а это
[грабли](lessons-learned.md#размытие-границ-в-intra-project-pool).

---

## 2. Bootstrap

### 2.0. Основной путь — скаффолдер (одна команда)

**Канонический способ поднять bus-native пул — скаффолдер**: одна команда
генерит весь каркас из спеки (`spec.json`: имя пула, лид, заголовок, список
ролей `owner`+`label`).

```
<pool-scaffolder> -Spec <spec.json>
```

Что он генерит (всё уже рабочее): `<bus>` (ленивый maildir),
`.claude/settings.local.json` с hook'ом `pool hook`, `CLAUDE.md` (routing по
`AGENT_OWNER`), `claude-<owner>.bat` на каждую роль (env
`AGENT_OWNER`/`CLAUDE_CODE_TASK_LIST_ID`/`POOL_BUS_ROOT`/`POOL_INBOX_QUIET`;
у лида — авто-доска), `board-<name>.bat`, `_agent_pool_setup-<owner>.md`,
`scripts/{pool-launch, archive-completed-tasks}`, каркас `00_docs/`. Сама
pool-CLI НЕ копируется — одна общая копия на весь workspace.

INFRA генерится полностью рабочей; ДОМЕН (миссии ролей, зоны, конвейер)
остаётся TODO-заглушками — заполняется после скаффолдинга (зоны — §1.3,
smoke-test — §2 «Шаг 7-8»). Для intra-project pool скаффолдер задаёт каркас;
зоны записи внутри общей папки подпроекта (§1.3) всё равно прописываются
вручную.

### 2.1. Ручной fallback (нетиповой монорепо) — шаг за шагом

Если скаффолдер не подходит (вписываешь pool-слой в уже существующий
нестандартный монорепо) — собери каркас вручную.

### Шаг 1. Шина

`<bus>` (`POOL_BUS_ROOT`, обычно `<workspace-root>\.bus`) создаётся **лениво**
самой pool-CLI при первом `pool send` — заранее каталоги создавать не нужно.
Добавь `.bus/` в `.gitignore` workspace-root (служебное состояние шины).

### Шаг 2. Сводный routing в workspace CLAUDE.md

В `<workspace-root>/CLAUDE.md` (если ещё нет — создать) добавить блок:

```markdown
## Pool `<sub>-pool`

`<sub>-pool` — intra-project pool из N peer'ов в подпроекте `<sub>`.

| AGENT_OWNER | Wrapper | Setup |
|-------------|---------|-------|
| `architect-<sub>` | `01_projects/<sub>/claude-architect-<sub>.bat` | `01_projects/<sub>/_agent_pool_setup-architect.md` |
| `frontend-<sub>` | `01_projects/<sub>/claude-frontend-<sub>.bat` | `01_projects/<sub>/_agent_pool_setup-frontend.md` |
| `backend-<sub>` | `01_projects/<sub>/claude-backend-<sub>.bat` | `01_projects/<sub>/_agent_pool_setup-backend.md` |
| `qa-<sub>` | `01_projects/<sub>/claude-qa-<sub>.bat` | `01_projects/<sub>/_agent_pool_setup-qa.md` |

Шина: `POOL_BUS_ROOT = <bus>` (ящик каждого — `<bus>/<owner>/new/`).
TASK_LIST_ID: `<sub>-pool` (личные todo).
```

### Шаг 3. CLAUDE.md подпроекта — блок «Pool-режим (читать первым)»

В `01_projects/<sub>/CLAUDE.md` (в начало, перед основным содержанием):

```markdown
## Pool-режим (читать первым)

`<sub>-pool` — intra-project pool из N peer-агентов:

- `claude-architect-<sub>.bat` → ты `architect-<sub>`. **Прочитай:**
  [`_agent_pool_setup-architect.md`](_agent_pool_setup-architect.md).
  При возобновлении — также
  [`_handoff_architect-<sub>.md`](_handoff_architect-<sub>.md).
- `claude-frontend-<sub>.bat` → ты `frontend-<sub>`. **Прочитай:**
  [`_agent_pool_setup-frontend.md`](_agent_pool_setup-frontend.md).
  При возобновлении — [`_handoff_frontend-<sub>.md`](_handoff_frontend-<sub>.md).
- `claude-backend-<sub>.bat` → ты `backend-<sub>`. **Прочитай:**
  [`_agent_pool_setup-backend.md`](_agent_pool_setup-backend.md).
  При возобновлении — [`_handoff_backend-<sub>.md`](_handoff_backend-<sub>.md).
- `claude-qa-<sub>.bat` → ты `qa-<sub>`. **Прочитай:**
  [`_agent_pool_setup-qa.md`](_agent_pool_setup-qa.md). При возобновлении
  — [`_handoff_qa-<sub>.md`](_handoff_qa-<sub>.md).

После своего setup-файла —
[`00_docs/architecture/agent-pool-zones.md`](00_docs/architecture/agent-pool-zones.md)
(разделение зон). Затем `00_docs/specs/` (детали проекта).

Признак активного pool-режима — баннер `[POOL INBOX] <owner>: ...` в
блоке `<user-prompt-submit-hook>`. Если нет — диагностика в
`<workspace-root>/scripts/README.md`.

Полный стандарт — [Pool Communication](<path-to-this-knowledge-base>/pool-communication.md).
```

### Шаг 4. Wrapper-батники

По одному на peer'а. Образец см.
[Wrapper and Hook Scripts §2](wrapper-and-hook-scripts.md#2-wrapper-батник-на-агента).

Пример для `frontend-<sub>`:

```batch
@echo off
REM Pool wrapper: Frontend для подпроекта <sub>.
REM Owner ID: frontend-<sub>. Pool: <sub>-pool. Bus-native (maildir).
REM Cwd = <workspace-root>. ProjectKey: <ProjectKey>.

set AGENT_OWNER=frontend-<sub>
set POOL_BUS_ROOT=<workspace-root>\.bus
set CLAUDE_CODE_TASK_LIST_ID=<sub>-pool
set POOL_INBOX_QUIET=1
cd /d <workspace-root>
powershell -NoProfile -ExecutionPolicy Bypass -File "<workspace-root>\scripts\pool-launch.ps1" -SessionTitle "Frontend-Sub" -ProjectKey "<ProjectKey>"
if errorlevel 1 pause
```

Cwd = **`<workspace-root>`**, не `01_projects/<sub>/`. Это критично для
discovery hook'а ([почему](wrapper-and-hook-scripts.md#discovery-walk-up-не-работает)).

### Шаг 5. Setup-файлы peer'ов

Один файл на peer. Шаблонная структура:

```markdown
# Pool Setup: <role>-<sub>

Onboarding в pool `<sub>-pool` как peer с <список других peer'ов>.

## Идентичность

| Поле | Значение |
|------|----------|
| Owner ID | `<role>-<sub>` |
| TASK_LIST_ID | `<sub>-pool` |
| Display name | `<Role>-<Sub>` |
| Cwd | `<workspace-root>` (umbrella) |
| Проектная папка | `<workspace-root>\01_projects\<sub>\` |
| Зона записи | <конкретные подпапки 02_src/ или 00_docs/> |
| Шина (мой ящик) | `<bus>\<role>-<sub>\new\` (`POOL_BUS_ROOT = <bus>`) |
| Launcher | `claude-<role>-<sub>.bat` |

## Контекст pool

<Кто есть кто в pool, краткое описание роли каждого peer'а.>

## Зоны записи

- <Папка 1> — что туда пишешь.
- <Папка 2> — что туда пишешь.
- `00_docs/architecture/api-changes-pending.md` — анонс изменений (если
  применимо к роли).

## Граница с <соседом>

<Главная точка трения, если есть. Таблица зон, что-кто-пишет, как
координируется при пересечении.>

## Чего НЕ делаешь

- <Чужая зона 1>.
- <Чужая зона 2>.
- Долгие процессы через `run_in_background` (стек поднимает пользователь).

## Как отправить задачу соседу

Канон pool — одна команда (тело — в md-файл, `-BodyFile`):

```
pool send -To <сосед> -From <role>-<sub> -Subject "<тема>" -BodyFile <файл.md>
```

Сообщение атомарно появляется в `<bus>/<сосед>/new/` — никакого второго
шага. Отчёт по входящей задаче — `pool reply -InReplyTo <id>` (не закрытие
чужой задачи). См. [Pool Communication §4](<path>/pool-communication.md).

## Личные todo

`TaskCreate(subject='...', metadata={ "kind": "personal" })` →
`TaskUpdate(<id>, owner='<role>-<sub>')` — не зашумляет POOL INBOX соседей
(координация идёт по шине, не по Tasks API).

## Как ты работаешь

- TDD для всего нетривиального.
- `superpowers:writing-plans` для multi-step задач.
- `superpowers:verification-before-completion` перед заявлением о готовности.
- `superpowers:requesting-code-review` перед коммитом нетривиального кода.
- `superpowers:brainstorming` — пропускать для копий по образцу,
  использовать для новой творческой работы.

## Ссылки

- `00_docs/architecture/agent-pool-zones.md` — разделение зон в pool.
- <другие ссылки на стандарты и образцы>
```

### Шаг 6. agent-pool-zones.md подпроекта

В `01_projects/<sub>/00_docs/architecture/agent-pool-zones.md` — таблица
из §1.3. Этот файл — общий источник правды по зонам. Любой peer
обращается сюда при сомнениях «моё / не моё».

### Шаг 7. Первый запуск

1. По очереди (или параллельно) запустить wrapper-батники каждого peer'а.
2. На первом запуске Claude Code может попросить одобрение нового hook'а
   («Allow command: powershell ... pool ... hook?») — **Yes / Always
   allow for this project**.
3. Попросить каждого peer'а вывести `<user-prompt-submit-hook>` —
   убедиться что баннер `[POOL INBOX] <owner>: clean (0 pending)`
   появляется (или тихо при `POOL_INBOX_QUIET=1`). Если `clean` — pool
   активен.

### Шаг 8. Smoke-тест координации

С одного peer'а отправить тестовое сообщение соседу (тело — минимальный
md-файл):

```
pool send -To <peer> -From <self> -Subject "smoke test" -BodyFile <файл.md>
```

Сообщение появится в `<bus>/<peer>/new/`. Открыть/возобновить сессию
peer'а, проверить что баннер `[POOL INBOX]` показывает 1 pending и
`pool mine` его видит. Если показывает — pool работает. Завершить:
peer делает `pool claim -Id <id>` → `pool ack -Id <id>`.

---

## 3. Добавление QA-peer'а (при потребности)

QA-peer — опциональная дополнительная роль. Базовая модель — ручной
exploratory + чек-лист регрессии через Chrome DevTools MCP, бэклог
находок (pull-модель для dev-агентов). См. [§3.6 в Pool
Communication](pool-communication.md#36-qa-peer-как-роль-в-intra-project-pool)
(если соответствующий раздел в репликации сохранён).

Артефакты QA-peer'а:

- Wrapper: `claude-qa-<sub>.bat`.
- Setup: `_agent_pool_setup-qa.md`.
- Зона записи: `00_docs/qa/` — `README.md`, `backlog.md`,
  `regression-checklist.md`, `findings/`, `regression-runs/`, опц.
  `hints-from-<role>.md`.

Pull-модель бэклога — главное:

- QA пишет `open` находки в `backlog.md` с severity S1/S2/S3.
- Dev-агенты при возобновлении сессии открывают `backlog.md`, вписывают
  себя в `Owner-claimed` → `wip`. После починки → `fixed`. QA при
  следующем прогоне → `verified` или возврат в `open`.
- Для S1 разрешено продублировать явным пингом через шину: `pool send -To
  <нужный> -From <qa-owner> -Subject "S1: ..." -BodyFile <ссылка на находку>`.
  Для S2/S3 — только бэклог, без пинга.

QA не пишет автотесты (Playwright/Vitest), не правит код dev-агентов, не
трогает БД (только select для проверки состояния).

---

## 4. Расширение pool: добавление нового peer'а в существующий

Когда нужен ещё один peer (например, второй backend с специализацией на
поиске):

1. Решить naming: `backend-search-<sub>` (если специализация),
   `backend2-<sub>` (если просто дублёр).
2. Создать wrapper `claude-<новый>-<sub>.bat`.
3. Создать `_agent_pool_setup-<новый>.md` с **явной границей** против
   существующих peer'ов (раздел «Граница с backend-<sub>»: что моё, что
   его, какие файлы общие, как координируется при пересечении).
4. Обновить `01_projects/<sub>/CLAUDE.md` — добавить строку в блок
   «Pool-режим», обновить структуру.
5. Обновить `<workspace-root>/CLAUDE.md` — добавить в routing-таблицу.
6. Обновить `00_docs/architecture/agent-pool-zones.md` — новая строка в
   таблице зон.
7. Запустить wrapper нового peer'а, smoke-тест координации с существующим
   peer'ом этой же роли.

**Что НЕ делать:** не править зону существующего peer'а «под нового» из
parent-сессии. Если граница пересматривается — это `pool send -To <тот
peer>` с обоснованием, не прямая правка его файлов.

---

## 5. Деактивация peer'а (пауза, не удаление)

Если решено приостановить peer'а (он «не справился» или временно не
нужен):

1. **Не удалять** wrapper, setup, handoff — сохранить как контекст.
2. В `<workspace-root>/CLAUDE.md` и в `01_projects/<sub>/CLAUDE.md`
   пометить: «`<owner>` — на паузе по решению пользователя YYYY-MM-DD.
   `pool send -To <owner>` не отправлять».
3. В `agent-pool-zones.md` пометить зону как «временно без owner'а».
4. Если есть второй peer той же роли (`frontend2-<sub>` как замена) —
   завести его по recipe §4. Граница: новый peer берёт активные задачи,
   старый сохранён как архив контекста.

---

## 6. Связанные документы

- [Pool Communication](pool-communication.md) — координационный стандарт.
- [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) — pool-инфра.
- [Workspace Organization](workspace-organization.md) — общая модель
  workspace.
- [Lessons Learned](lessons-learned.md) — частые грабли.
