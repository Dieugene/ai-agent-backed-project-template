**Русский** · [English](README.en.md)

# Воркспейс на агентах — база знаний и референсная реализация

![Карта стандартов](assets/standards-map.svg)

Проверенная на практике база знаний для организации Windows-воркспейса, в котором **несколько сессий Claude Code («агентов») работают параллельно под управлением одного человека-владельца** — координируясь друг с другом через файловую шину, **без человека-диспетчера в контуре**. Это одновременно и база знаний (`docs/`), и **обезличенная, рабочая референсная реализация** (`scripts/`, `commands/`, `remote-bridge/`), которую можно перенести на чистую машину как есть.

Материал рассчитан на тех, кому уже тесно в рамках одной сессии Claude Code и кто хочет устойчивый паттерн для *команды* специализированных агентов-пиров — Tech Lead, QA-пир, DevOps, — которые передают работу друг другу, переживают `/compact` и перезапуски и остаются наблюдаемыми. Всё здесь взято из реальной практики; каждый идентификатор — плейсхолдер, поэтому ничего не утекает и всё переиспользуемо.

> **Этот репозиторий (`main`) — база знаний и референсная реализация мульти-пир воркспейса**: стандарты, по которым работает команда параллельных агентов Claude Code.

---

## Как всё складывается вместе

Компоненты выстраиваются в зависимостный хребет — читайте сверху вниз, каждый слой опирается на предыдущий:

> **Foundation (A)** (Фундамент) лежит в основе всего → **Workspace Organization (C)** (Организация воркспейса) — это контейнер → **Pool Coordination Bus (D)** (Координационная шина пула) — ключевой протокол координации → **Pool Lifecycle Tooling (E)** (Инструменты жизненного цикла пула) разворачивает, запускает и наблюдает его → **Roles (F)** (Роли) и **DevOps (G)** делают свою работу *поверх* шины → **Skills System (B)** (Система скилов) доставляет все эти знания агентам, не раздувая контекст → **Shutdown & Context Hygiene (I)** (Завершение и гигиена контекста) сворачивает пул и держит контекст свежим, а **Agent Long-Term Memory (J)** (Долговременная память) отвечает за то, что переживёт это сворачивание → **Remote Bridge (H)** (Удалённый мост) — опциональный удалённый доступ к шине с телефона.

---

## Что внутри

База знаний разбита на **10 блоков стандартов (A–J)**. Каждый ведёт на свои ключевые документы.

### A — Foundation: Environment & Safety (Фундамент: окружение и безопасность)
Основа, на которой стоит каждая сессия: подводные камни Windows/PowerShell, гигиена секретов, глобальные защитные механизмы (жёсткая блокировка катастрофического `rm`, предупреждение при убийстве процессов, детектор искажённого вывода) и настройка окружения Claude Code.
→ [Windows / PowerShell Pitfalls](docs/windows-powershell-pitfalls.md) · [Handling Secrets](docs/handling-secrets.md) · [Safety Guards](docs/safety-guards.md) · [Claude Code Setup](docs/claude-code-setup.md) · [Self-Testing & False Greens](docs/self-testing-and-false-greens.md) · [Cross-Platform Port](docs/cross-platform-port.md)

### B — Skills System (Система скилов)
Как знания доходят до агентов, *не* раздувая их контекст: тонкие заглушки скилов плюс инжектор канона (`ref.ps1`), бюджет листинга и каскад дискаверинга. Плюс **рабочий минимум скилов** — четыре вместо четырнадцати, без хуков; постоянный расход контекста снижен с ~5.3 КБ до ~0.7 КБ. Отбор построен на замере: за 1288 сессий большой пакет был вызван 19 раз.
→ [The Skills System](docs/the-skills-system.md) · [lean-skills/](lean-skills/)

### C — Workspace Organization (Организация воркспейса)
Контейнер для всего остального: варианты монорепо A/B, plain- и pool-режим, анатомия воркспейса и подпроекта, бутстрап.
→ [Workspace Organization](docs/workspace-organization.md)

### D — Pool Coordination Bus (Координационная шина пула)  *(ядро)*
Сердце системы: **файловая maildir-шина**, поверх которой N сессий координируются **без человека-диспетчера**. Сообщение — это неизменяемый файл; адрес — это папка. Инвариант доставки держит *инструмент*, а не дисциплина агентов.
→ [Pool Communication](docs/pool-communication.md) · [Wrapper & Hook Scripts](docs/wrapper-and-hook-scripts.md) · [Pool Standard Tiers](docs/pool-standard-tiers.md) · [Lessons Learned](docs/lessons-learned.md)

### E — Pool Lifecycle Tooling (Инструменты жизненного цикла пула)
Развернуть → запустить → наблюдать. Одна команда поднимает bus-native пул; fzf-пикер запускает его в Warp; живой борд и вотчер держат его на виду.
→ [Pool Scaffolding](docs/pool-scaffolding.md) · [Pool Launcher & Warp](docs/pool-launcher-and-warp.md) · [Board & Watcher](docs/board-and-watcher.md) · [Intra-Project Pool Recipe](docs/intra-project-pool-recipe.md)

### F — Roles & Working Style (Роли и стиль работы)
Модель единственного активного агента (subagent-driven Tech Lead), QA-пир и стоячие принципы работы, которые держат агентов автономными и соразмерными задаче.
→ [Tech Lead Mode](docs/tech-lead-mode.md) · [QA Role](docs/qa-role.md) · [Working Principles](docs/working-principles.md) · [Right-Sizing & Artifacts](docs/right-sizing-and-artifacts.md)

### G — DevOps & Self-Healing (DevOps и самовосстановление)
Двухслойная модель DevOps (server-wide оркестратор + per-monorepo DevOps) и замкнутый контур самовосстановления для production-сервисов.
→ [DevOps Two-Layer Model](docs/devops-two-layer.md) · [Self-Healing Pipeline](docs/sre-self-healing-pipeline.md)

### H — Remote Bridge (Удалённый мост)  *(опциональное дополнение)*
Управляйте живой сессией или пулом **с телефона через Telegram** — текстом или голосом, из-за NAT, без открытых портов. По одной копии движка на воркспейс; инстансы разводятся конфигом. Единственный исходящий канал — из allowlist; писать может только владелец.
→ [remote-bridge/](remote-bridge/)

### I — Shutdown & Context Hygiene (Завершение и гигиена контекста)
Вторая половина жизненного цикла после *запуска и наблюдения* (E): аккуратное сворачивание пула и поддержание свежести контекста. Внешний контроллер выполняет **handoff → compact → kill** (*лёгкое закрытие* пропускает оба шага для почти пустой сессии), читает метрику контекста по каждой сессии, а пикер заодно служит **пультом** — единой панелью управления, чтобы запустить, погасить или открыть борд. Направление движения: агенты, которые сами себя чистят, вместо человека, нянчащего `/compact`.
→ [Pool Shutdown & Context Refresh](docs/pool-shutdown-and-context-refresh.md)

### J — Agent Long-Term Memory (Долговременная память агента)
Что роль знает **после** сжатия контекста и перезапуска. Своя память на роль вместо общей кучи по рабочему каталогу; каталог записей вместо одного растущего handoff-файла; индекс, который движок вклеивает сам, как интерфейс извлечения; впрыск точки входа сразу после сжатия — **потому что провал памяти невидим изнутри**: пересказ выглядит полным, и повода заглянуть в память не возникает. Что именно доезжает в контекст — замерено, а не выведено из документации.
→ [Agent Long-Term Memory](docs/agent-long-term-memory.md) · [`commands/handoff-myself`](commands/handoff-myself.md)

### Каталоги верхнего уровня

| Каталог | Что содержит |
|-----------|---------------|
| [`docs/`](docs/) | База знаний — 9 блоков выше. Начните с [`docs/README.md`](docs/README.md). |
| [`scripts/`](scripts/) | Обезличенный референсный PowerShell: ядро шины `pool.ps1` и его **приёмочный самотест** `selftest.ps1`, скаффолдеры `new-pool.ps1` / `add-peer.ps1` / `fresh-session.ps1`, лаунчер/пульт `launch-pool.ps1`, контроллер завершения `pool-shutdown.ps1`, защитные механизмы `block-dangerous-rm.ps1` / `warn-process-kill.ps1` / `stop-detect-malformed.ps1`, инжектор канона `ref.ps1`, **память ролей** `agent-memory.ps1` с аудитом, впрыском, проверками и доской, борд/нотификатор и шаблоны. |
| [`commands/`](commands/) | Переиспользуемые slash-команды Claude Code (шаблоны промптов для `~/.claude/commands/`), например [`handoff-myself`](commands/handoff-myself.md) — сверка долговременной памяти роли. |
| [`lean-skills/`](lean-skills/) | Рабочий минимум скилов: шесть штук вместо большого пакета, ставятся как личные скилы, **без плагина и без единого хука**. Внутри — замер фактического использования, на котором построен отбор. |
| [`remote-bridge/`](remote-bridge/) | Telegram-«пульт» — рабочий движок моста на long-polling плюс руководство «подключи своего бота». Секреты живут вне репозитория. |

---

## Предварительные требования

Установите это на чистую Windows-машину, прежде чем поднимать воркспейс:

| Инструмент | Зачем |
|------|-----|
| **Node.js** (LTS) | Рантайм для Claude Code. Также добавьте `node.exe` в доверенные у антивируса — см. [Windows Pitfalls](docs/windows-powershell-pitfalls.md). |
| **Claude Code CLI** | Рантайм агента; установить и авторизоваться. |
| **Git for Windows** | Даёт `bash`, от которого зависит статус-лайн. |
| **Warp** (терминал) | Пулы запускаются через сгенерированный Warp tab-config; без него роли стартуют напрямую из wrapper-файлов `.bat`. |
| **fzf** (`fzf.exe`) | Обеспечивает терминальный пикер пула. |
| **jq** | Используется хуком статус-лайна. |

---

## Маршруты чтения

Три коротких проводника. Полный индекс — с однострочным описанием каждого документа — лежит в **[`docs/README.md`](docs/README.md)**.

**(a) Просто осмотреться** — понять модель:
1. [Workspace Organization](docs/workspace-organization.md) — общая форма.
2. [The Skills System](docs/the-skills-system.md) — как знания доходят до агентов.
3. [Pool Communication](docs/pool-communication.md) — как несколько агентов координируются.
4. [Tech Lead Mode](docs/tech-lead-mode.md) — как работает один агент.

**(b) Бутстрап новой машины** — поднять с нуля:
1. [Claude Code Setup](docs/claude-code-setup.md) — окружение, память, сессии.
2. [Safety Guards](docs/safety-guards.md) + [Windows Pitfalls](docs/windows-powershell-pitfalls.md) — защитные механизмы и подводные камни Windows.
3. [Workspace Organization](docs/workspace-organization.md) — бутстрап самого воркспейса.
4. [Wrapper & Hook Scripts](docs/wrapper-and-hook-scripts.md) + [`scripts/`](scripts/) — собрать инфру пула.
5. [Pool Scaffolding](docs/pool-scaffolding.md), затем [Pool Launcher & Warp](docs/pool-launcher-and-warp.md) + [Board & Watcher](docs/board-and-watcher.md) — запустить и наблюдать.

**(c) Разбор production-инцидента** — найти контур и слой:
1. [Self-Healing Pipeline](docs/sre-self-healing-pipeline.md) — замкнутый контур.
2. [DevOps Two-Layer Model](docs/devops-two-layer.md) — какой слой выполняет починку.
3. Конкретный per-monorepo runbook (живёт вместе с проектом, а не в этой базе знаний).

**(d) Перенос на Linux-сервер** — что поедет, а что придётся переписать:
1. [Cross-Platform Port](docs/cross-platform-port.md) — классы отказов и **матрица переносимости** (§4).
2. [Self-Testing & False Greens](docs/self-testing-and-false-greens.md) — начинать перенос с того, **чем** проверяют, иначе «зелёный тест» на сервере не значит ничего.
3. [Agent Long-Term Memory](docs/agent-long-term-memory.md) §6 — файл-флаг, без которого память ролей молча не включится.

---

## Соглашение о структуре проекта

Каждый воркспейс и подпроект следует одной и той же нумерованной раскладке. Это краткая версия — полную анатомию, оба варианта монорепо и шаги бутстрапа см. в [Workspace Organization](docs/workspace-organization.md).

**Нумерованные папки верхнего уровня** (подпроект):

```
00_docs/            # architecture/ | standards/ | specs/ | backlog.md
01_tasks/           # task folders NNN_short_name/   (workspace root uses 01_projects/)
02_src/             # source code
03_data/            # gitignored
04_logs/            # gitignored
```

**Dot-папки:** `.agents/` (настройка агентов), `.claude/` (настройки и хуки Claude Code), `.worktrees/` (git worktrees). В pool-режиме шина живёт в `.bus/` (maildir, gitignored, создаётся лениво).

**Правила именования:**

| Что | Соглашение |
|-------|-----------|
| Папки задач | `NNN_short_name` (трёхзначный префикс) |
| Итерации файлов | суффикс `_NN` — `task_brief_01.md`, затем `_02` при переработке; **никогда не перезаписывать** |
| ADR | `decision_NNN_*.md` |
| Handoff / черновые файлы | с префиксом `_` — `_handoff_*.md`, `_questions_to_user.md` |

**Три doc-файла (все автоматически подгружаются Claude Code, у каждого своя задача):**

- **`AGENTS.md`** — описывает воркспейс для разработчика и для агента в plain-режиме: что это, какие подпроекты, как они связаны. Растёт медленно.
- **`README.md`** — обзор проекта для человека.
- **`CLAUDE.md`** — операционная точка входа для роутинга: «куда идти и что прочитать перед ответом». Обязателен в pool-режиме; опционален (или тонкий указатель на `AGENTS.md`) в plain-режиме.

---

## Обезличивание

Всё здесь — референс, а не готовый к запуску пакет. **Все идентификаторы — плейсхолдеры**: `<workspace-root>`, `<user-home>`, `<pool-name>`, `<role>-<scope>`, `<vps-ip>`. Никаких реальных хостов, путей, имён подпроектов или секретов. Прежде чем использовать скрипты, сделайте глобальную замену `<workspace-root>` на свой фактический путь (см. [`scripts/README.md`](scripts/README.md)). Примеры, взятые из живой практики, помечены как таковые.
