# Pool Patterns — Knowledge Base

Эта ветка — **обезличенный knowledge base** по организации workspace с
командой Claude Code сессий, работающих параллельно (multi-peer pool).
Не шаблон проекта. Не запускается через `/launch-project`. Читается по
ссылке.

Сценарий ортогонален основным веткам этого репозитория:

| Ветка | Сценарий |
|-------|----------|
| `main` | Точка входа: `/launch-project` slash-command, README, branch-switch-guide |
| `iterative` | Single-developer, итеративная разработка (analyst → architect → developer → reviewer) |
| `specified` | Single-developer, spec-driven с Tech Lead'ом (architect → tech-lead → developer → reviewer) |
| **`pool-patterns`** (эта) | **Multi-peer pool**: N специализированных peer-агентов координируются через Tasks API + общий mailbox + UserPromptSubmit hook |

## С чего начать

→ [`docs/README.md`](docs/README.md) — индекс knowledge base с описанием
каждого документа и тремя путями входа (только знакомитесь / поднимаете
pool с нуля / разбираете production-инцидент).

## Что внутри

В `docs/` — 8 документов:

- `workspace-organization.md` — монорепо variants A/B, plain vs pool режим.
- `pool-communication.md` — координационный стандарт pool (Tasks API,
  mailbox, hook, **инвариант top-level `owner`**).
- `tech-lead-mode.md` — subagent-driven Tech Lead и superpowers-скилы.
- `wrapper-and-hook-scripts.md` — полный рабочий код `pool-launch.ps1`
  и `inject-inbox.ps1`.
- `intra-project-pool-recipe.md` — пошаговый bootstrap pool с нуля.
- `devops-two-layer.md` — server-wide orchestrator + per-monorepo split.
- `lessons-learned.md` — 16 антипаттернов с реальной практики.
- `sre-self-healing-pipeline.md` — замкнутый контур самовосстановления
  AI-сервисов (опубликовано ранее).

В `commands/` — переиспользуемые **slash-команды** Claude Code (готовые
промпт-шаблоны, кладутся в `~/.claude/commands/`):

- `handoff-myself.md` — handoff агента самому себе перед `/compact` или
  закрытием сессии (поддерживает мульти-агентные пулы). См.
  [`commands/README.md`](commands/README.md).

## Анонимизация

Все идентификаторы — placeholder'ы: `<workspace-root>`, `<pool-name>`,
`<role>-<scope>`, `<vps-ip>`. Никаких реальных хостов, путей, имён
подпроектов. Примеры обозначены как «из практики».

## Для других сценариев

Если ищете шаблон проекта под single-developer workflow — переключитесь
на ветку `main` и читайте `README.md` там (про `/launch-project` + ветки
`iterative`/`specified`).
