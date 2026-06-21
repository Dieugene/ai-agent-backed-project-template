# Pool Patterns Knowledge Base

Набор паттернов и стандартов для организации workspace с командой
Claude Code сессий (несколько специализированных peer-агентов, работающих
параллельно над одним подпроектом или над набором связанных подпроектов).

Сценарий ортогонален основным веткам шаблона (`iterative`, `specified`) —
там описан single-developer workflow с 4 sequential ролями. Эти
документы описывают **multi-peer параллельную модель**: pool из N
сессий, координирующихся через файловую **maildir pool-шину** (общая
команда `pool` поверх `<bus>`) + UserPromptSubmit hook.

## Содержание

| Документ | О чём |
|----------|-------|
| [Workspace Organization](workspace-organization.md) | Базовая модель: монорепо (variant A — отдельные репо подпроектов + parent для стандартов; variant B — один git на всё), анатомия workspace и подпроекта, plain vs pool режим, мульти-пулинг. |
| [Pool Communication](pool-communication.md) | Координационный стандарт pool: env vars, **maildir pool-шина** (`<bus>`, immutable-файл = сообщение, адрес = папка получателя), pool-CLI (`send`/`reply`/`claim`/`ack`/`mine`/`board`), UserPromptSubmit hook (`pool hook`), вотчер (`pool watch`), топология (inter-project vs intra-project), per-owner handoff. Инвариант доставки держит инструмент, а не дисциплина. Личные todo остаются на Tasks API (+ дворник стора). |
| [Tech Lead Mode](tech-lead-mode.md) | Единственная активная агентская роль и её subagent-driven работа. Какие superpowers-скилы и когда применять. Что Tech Lead не делает в одиночку, когда эскалирует к пользователю. |
| [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) | Рабочие примеры скриптов pool-инфры: `pool-launch.ps1` (auto-resume по display name), wrapper-батник на агента (с `POOL_BUS_ROOT`, у лида — board-окно), hook = pool-CLI `hook`, вотчер = pool-CLI `watch`, дворник ЛИЧНЫХ todo `archive-completed-tasks.ps1` (§4.6). Старые `inject-inbox.ps1` / `wait-for-task.ps1` помечены DEPRECATED. Discovery walk-up, UTF-8 для кириллицы. |
| [Intra-Project Pool Recipe](intra-project-pool-recipe.md) | Пошаговый recipe подъёма intra-project pool (N peer-агентов внутри одного подпроекта). Основной путь — скаффолдер; зоны до bootstrap, naming, smoke-тест координации, расширение pool, деактивация peer'а. |
| [DevOps Two-Layer Model](devops-two-layer.md) | Server-wide DevOps Orchestrator + per-monorepo DevOps. Граница ответственности, каналы коммуникации, безопасность, бутстрап двухслойной модели. |
| [Lessons Learned](lessons-learned.md) | 17 антипаттернов и пределов с реальной практики: top-level owner (legacy), hook walk-up, размытие границ, helper-launcher по аналогии, mojibake кириллицы, изменения pool-инфры без согласования, перевзвод push-watcher'а как действие агента, коллизия имени «watcher», накопление `completed`, и обобщающий §17 — корректность координации перенесена из памяти-агента в инструмент (maildir-шина). |
| [Self-Healing Pipeline](sre-self-healing-pipeline.md) | Архитектура замкнутого контура самовосстановления для production-сервисов под управлением AI-агентов. Опубликована ранее, дополняет DevOps Two-Layer. |

## С чего читать

**Если только знакомитесь:**

1. [Workspace Organization](workspace-organization.md) — общая модель.
2. [Tech Lead Mode](tech-lead-mode.md) — как работает один агент.
3. [Pool Communication](pool-communication.md) — как несколько агентов
   координируются.

**Если поднимаете pool с нуля:**

1. [Workspace Organization §8](workspace-organization.md#8-bootstrap-нового-workspace) —
   bootstrap самой workspace.
2. [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) — собрать
   pool-инфру.
3. [Intra-Project Pool Recipe](intra-project-pool-recipe.md) — поднять
   peer'ов.
4. [Lessons Learned](lessons-learned.md) — что не повторять.

**Если разбираете production-инцидент:**

1. [Self-Healing Pipeline](sre-self-healing-pipeline.md) — общий контур.
2. [DevOps Two-Layer](devops-two-layer.md) — кто из слоёв чинит.
3. Конкретный runbook (per-monorepo, не в этом knowledge base).

## Что НЕ в этом knowledge base

- Code-style стандарты, конкретные стэки (Python/TypeScript/Go), CI-шаблоны
  — это локальные стандарты конкретного workspace.
- Конкретные секреты, конфиги, IP-адреса, имена production-серверов —
  все идентификаторы здесь обезличены.
- Превентивные шаблоны проекта (`.agents/`, `00_docs/standards/`) — для
  single-developer workflow используйте ветки [iterative](https://github.com/Dieugene/ai-agent-backed-project-template/tree/iterative)
  или [specified](https://github.com/Dieugene/ai-agent-backed-project-template/tree/specified).

## Связь с другими ветками шаблона

| Сценарий | Ветка |
|----------|-------|
| Single-developer, итеративная разработка (analyst → architect → developer → reviewer) | [iterative](https://github.com/Dieugene/ai-agent-backed-project-template/tree/iterative) |
| Single-developer, spec-driven с Tech Lead'ом (architect → tech-lead → developer → reviewer) | [specified](https://github.com/Dieugene/ai-agent-backed-project-template/tree/specified) |
| **Multi-peer pool в одном подпроекте или поверх нескольких подпроектов** | **pool-patterns (эта ветка)** — knowledge base, не шаблон проекта |
