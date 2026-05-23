# DevOps Two-Layer Model

Двухслойная модель DevOps для workspace с несколькими подпроектами,
делящими один сервер (или несколько серверов с общими сервисами).
Дополняет [Pool Communication](pool-communication.md) и [Workspace
Organization](workspace-organization.md) — описывает, как делится
DevOps-ответственность между двумя независимыми Claude Code сессиями.

> Контекст: применимо, когда один владелец ведёт несколько
> монорепо-workspace на одном VPS с общими сервисами (PostgreSQL, Loki,
> Caddy). Идеи переносятся на multi-server setup, но фокус здесь —
> «один владелец, один (или несколько) серверов, несколько workspace».

---

## 1. Зачем два слоя

Когда DevOps ведёт **один агент на всё**:

- Контекст одной сессии забивается секретами, конфигами и историей
  деплоев всех подпроектов сразу.
- Изменение в одном проекте требует ревизии состояния всего сервера.
- Server-wide политики (общий Postgres, общий мониторинг, единые
  правила безопасности) перемешиваются с детальной локальной работой
  одного проекта.
- Невозможно дать одному подпроекту deploy-доступ, не пуская его в
  чужие зоны.

Решение — **два независимых слоя**:

| Слой | Сфера | Где живёт |
|------|-------|-----------|
| **DevOps Orchestrator** (server-wide) | VPS целиком: общие сервисы, server-wide политики, реестр развёрнутого, self-healing контур, межпроектная безопасность | Отдельная workspace `<server-state>/` или папка `.devops/` workspace-уровня выше монорепо |
| **Per-monorepo DevOps** | Конкретное монорепо: его подпроекты, его compose, его env vars, его deploys | Папка `.devops/` внутри монорепо |

Каждый слой — **отдельная Claude Code сессия** со своими env vars,
своим CLAUDE.md, своими секретами. Они общаются через общие
артефакты в `<server-state>/`, а не напрямую.

---

## 2. Слой A: DevOps Orchestrator

### Сфера

- **Server-wide** — VPS целиком, не привязан к одному монорепо.
- Общие сервисы: PostgreSQL (как общий контейнер), Loki+Promtail
  (централизованные логи), reverse proxy (Caddy/nginx), мониторинг.
- Server-wide политики: правила безопасности, межпроектная сеть,
  TLS, бэкапы.
- Self-healing контур — общий механизм мониторинга и реагирования на
  инциденты (см. `docs/sre-self-healing-pipeline.md` в этом же knowledge
  base).
- **REGISTRY** развёрнутого: какие проекты на сервере, по каким портам,
  какие compose, какие domain'ы.

### Где живёт

```
<server-state>/
├── CLAUDE.md                        # entry point оркестратора
├── server-state.md                  # источник правды по состоянию VPS
├── system-services/                 # общие сервисы (одна папка на сервис)
│   ├── postgres/
│   │   ├── access.md                # учётные данные (доступ к секретам)
│   │   ├── notes.md                 # как подключиться, операции
│   │   └── compose.yml              # сам compose общего Postgres
│   ├── loki/
│   │   ├── notes.md
│   │   └── compose.yml
│   └── ...
├── runbooks/                        # server-wide runbooks
│   ├── safe-deploy-standard.md      # стандарт безопасного деплоя для всех per-monorepo
│   ├── create-project-database.md   # как подключить новый проект к общему Postgres
│   └── ...
├── sre-pipeline.md                  # self-healing контур (source of truth)
└── REGISTRY.md                      # реестр развёрнутого
```

### Что делает

- Поддерживает актуальность `REGISTRY.md` и `server-state.md` (зеркало
  состояния VPS).
- Принимает запросы от per-monorepo DevOps на:
  - Создание новой БД в общем Postgres (по runbook'у).
  - Подключение проекта к общим сетям (`db_net`, `logging_net`).
  - Открытие новых портов / поддоменов.
- Сопровождает self-healing pipeline — диспетчер инцидентов,
  безопасный канал между monitoring loop'ом и per-monorepo агентами,
  которые чинят.
- Пишет server-wide stand'ы (например, общий стандарт безопасного
  деплоя в `runbooks/`).

### Что НЕ делает

- Не деплоит конкретный проект. Это работа per-monorepo DevOps.
- Не правит код приложения. Это работа Tech Lead'ов проекта.
- Не вмешивается в зону per-monorepo (`.devops/` конкретного монорепо).

---

## 3. Слой B: Per-monorepo DevOps

### Сфера

- **Один конкретный монорепо** (workspace, как описано в [Workspace
  Organization](workspace-organization.md)).
- Все подпроекты этого монорепо: их compose, их env vars, их domain'ы,
  их deploys.
- Связь подпроектов с общими сервисами (через external networks).
- Локальный self-healing — runbook'и и контурные артефакты подпроектов
  этого монорепо.

### Где живёт

```
<workspace-root>/.devops/
├── CLAUDE.md                                  # entry point per-monorepo DevOps
├── REGISTRY.md                                # реестр развёрнутого ИЗ этого монорепо
├── HANDOFF.md                                 # handoff между сессиями
├── projects/                                  # по одному каталогу на подпроект
│   ├── <subproject-A>/
│   │   ├── compose.prod.yml                   # production compose
│   │   ├── caddy.site                         # reverse proxy фрагмент
│   │   ├── .env.prod.enc                      # зашифрованный env (не открытый!)
│   │   └── deploy-notes.md                    # специфика этого проекта
│   └── <subproject-B>/
│       └── ...
└── runbooks/                                  # локальные runbook'и
    └── <subproject-A>-rollback.md
```

В каждом подпроекте также:

```
01_projects/<subproject>/05_sre/               # контурные артефакты подпроекта
├── runbooks/                                  # как чинить специфичные инциденты
├── policies/                                  # политики этого проекта
├── audit/                                     # аудит-логи
└── incidents/                                 # история инцидентов
```

### Что делает

- Развёртывает проекты в production: pull кода, build, compose up.
- Управляет per-project env vars, секретами (через шифрованные .env или
  внешний secret manager).
- Подключает новые подпроекты к общим сервисам через runbook'и из слоя A.
- Ведёт `REGISTRY.md` своего монорепо — какие подпроекты задеплоены, в
  каких контейнерах, на каких портах.
- Реагирует на инциденты в своих проектах через self-healing pipeline
  (получает диспетчированную задачу от слоя A, чинит, отчитывается).

### Что НЕ делает

- Не правит код приложения. Это Tech Lead'ы (или peer'ы intra-project pool).
- Не лезет в server-wide политики или общие сервисы. Это слой A.
- Не правит зону соседнего монорепо.

---

## 4. Граница между слоями

| Действие | Кто |
|----------|-----|
| Поднять общий Postgres-контейнер на VPS | Orchestrator (A) |
| Создать БД `<subproject>_db` в общем Postgres | Per-monorepo (B), по runbook'у из A |
| Подключить compose проекта к общей сети `db_net` | Per-monorepo (B) |
| Установить общую политику бэкапов | Orchestrator (A) |
| Восстановить БД конкретного проекта из бэкапа | Per-monorepo (B), opc. с поддержкой A |
| Открыть HTTPS-домен на Caddy | Per-monorepo (B), фрагмент `caddy.site` в `.devops/projects/<sub>/`. A агрегирует |
| Реакция на алёрт «контейнер упал X раз за час» | Self-healing pipeline (A) диспетчеризует → Per-monorepo (B) чинит конкретный сервис |
| Server-wide upgrade Docker / kernel / OS | Orchestrator (A) |

Принцип: **A знает «что есть на сервере и как оно общается между
проектами», B знает «как живёт один конкретный проект».**

---

## 5. Каналы коммуникации между слоями

Прямой call A → B или B → A — **нет**. Они общаются через артефакты:

- **`REGISTRY.md` (в A)** — A пишет общее состояние сервера; B читает,
  чтобы знать соседей и общие точки.
- **`<workspace-root>/.devops/REGISTRY.md` (в B)** — B пишет состояние
  своего монорепо; A читает для агрегации.
- **`runbooks/` (в A)** — A публикует стандарты (например,
  `safe-deploy-standard.md`); B следует.
- **Tasks API + `.inbox/` self-healing pipeline'а** — A диспетчеризует
  инциденты в B через task'у с правильным `owner` (за самим B).
- **Через пользователя** — если что-то спорное или новое (например, B
  хочет добавить новую общую систему), эскалация к пользователю, не
  прямая модификация зоны A.

---

## 6. Безопасность

### Секреты

- **Никогда** не публиковать `.env` файлы (cat/print/коммит).
- Шифровать `.env.prod` (например, через `sops` или вручную через `gpg`)
  — открытый файл `.env.prod` в репозитории — антипаттерн.
- Передача секретов на сервер: `scp` зашифрованный файл → chmod 600 →
  decrypt на месте.
- В Docker compose ссылаться на расшифрованный `.env` файл, не пихать
  переменные в `compose.yml` хардкодом.
- Server-wide секреты (доступ к общему Postgres root, к Loki API) — в
  слое A; per-project секреты (DB password конкретного проекта, API
  keys внешних сервисов) — в слое B.

### Доступ к VPS

- SSH-ключи — в `<server-state>/.ssh/` (зона A) или в локальном
  хранилище ключей.
- Один deploy-ключ на проект (если используется CI deploy) — в слое B,
  отдельно от server-wide ключей.

### Destructive operations

`rm -rf`, `DROP DATABASE`, `docker system prune` — всегда с подтверждением
пользователя. Никогда не автоматизировать в self-healing pipeline без
явного одобрения через runbook (где runbook = рецепт, который A или B
проходит по шагам, не как auto-fix).

---

## 7. Бутстрап двухслойной модели на существующей одинокой DevOps-сессии

Если сейчас у вас один DevOps-агент, который ведёт и общее, и
per-monorepo, и пора разделить:

### Шаг 1. Выделить server-wide артефакты

В `<server-state>/` (отдельный workspace или папка над монорепо):

- `REGISTRY.md` — выписать все развёрнутые проекты текущего сервера, по
  каким портам, в каких compose'ах.
- `system-services/` — описать общие сервисы (Postgres, Loki etc.) и
  как они подключены.
- `runbooks/safe-deploy-standard.md` — стандарт безопасного деплоя,
  применимый ко всем per-monorepo.
- `sre-pipeline.md` — описание self-healing контура (если используется).

### Шаг 2. Создать в каждом монорепо папку `.devops/`

С `CLAUDE.md` (entry point per-monorepo DevOps), `REGISTRY.md` (что из
этого монорепо задеплоено), `projects/<sub>/` для каждого подпроекта,
`runbooks/` для локальных рецептов.

### Шаг 3. Создать wrapper'ы

- `<server-state>/scripts/devops-orchestrator.bat` — запуск слоя A.
- `<workspace-root>/.devops/claude-devops.bat` — запуск слоя B
  (per-monorepo).

Если слои в pool — env vars `AGENT_OWNER=devops-orchestrator` (для A) и
`AGENT_OWNER=devops` или `devops-<сокращение монорепо>` (для B).

### Шаг 4. Перенести истории и handoff'ы

Старая объединённая сессия — закрыть или преобразовать в одну из двух.
Handoff одной → в `<server-state>/HANDOFF.md` (A), handoff другой → в
`<workspace-root>/.devops/HANDOFF.md` (B).

### Шаг 5. Smoke

Проверить, что:

- A видит все per-monorepo `REGISTRY.md` (через `git pull` или прямой
  доступ к файлам).
- B знает, как подключиться к общим сервисам (через `<server-state>/runbooks/`).
- Self-healing контур (если есть) корректно диспетчеризует инциденты в
  правильный per-monorepo агент (по `owner` в Tasks API).

---

## 8. Антипаттерны

### 1. Один DevOps-агент на всё

**Симптом:** контекст забит секретами и историей всех проектов. Любое
изменение требует ревизии всего сервера.

**Митигация:** двухслойная модель.

### 2. Слой A правит зону слоя B (или наоборот)

**Симптом:** Orchestrator переписывает `compose.prod.yml` конкретного
подпроекта, чтобы «исправить общую сеть». Per-monorepo меняет общую
политику.

**Митигация:** строгая граница из §4. Любая правка чужой зоны — через
`TaskCreate(owner=<нужный слой>)`, не прямая.

### 3. Дублирование REGISTRY между слоями

**Симптом:** `REGISTRY.md` в A и `.devops/REGISTRY.md` в B расходятся в
данных. A считает что задеплоен один порт, B — другой.

**Митигация:**

- A агрегирует, B детализирует. A читает B (не наоборот).
- A не выдаёт новые порты/домены/контейнеры — это делает B и обновляет
  свой `REGISTRY.md`. A только консолидирует.

### 4. Server-wide секреты в per-monorepo

**Симптом:** в `<workspace-root>/.devops/` лежит root-доступ к общему
Postgres. Если репо случайно станет публичным или к нему получит доступ
сторонний — взлом всего сервера.

**Митигация:** server-wide секреты — только в `<server-state>/` или в
секрет-менеджере. В per-monorepo — только secrets своего проекта.

---

## 9. Связанные документы

- [Workspace Organization](workspace-organization.md) — общая модель
  workspace, в которой работает слой B.
- [Pool Communication](pool-communication.md) — если оба слоя в pool, они
  координируются через Tasks API.
- `sre-self-healing-pipeline.md` (в этом же knowledge base) — детальная
  реализация self-healing контура для слоя A.
- [Lessons Learned](lessons-learned.md) — DevOps-related грабли.
