# Workspace Organization Knowledge Base

Набор паттернов, стандартов и рабочих скриптов для организации рабочего пространства, в котором
команда сессий Claude Code (несколько специализированных peer-агентов) работает параллельно под
управлением человека-владельца. Цель — воспроизвести такое пространство **с нуля на новой машине**.

Ветка описывает **multi-peer параллельную модель** и всё вокруг неё: среду, скилы, координацию
(файловая **maildir pool-шина**, общая команда `pool`), запуск/мониторинг, роли, DevOps, стиль.
Ортогонально single-developer веткам шаблона (`iterative`, `specified`).

## Предварительные требования (новая машина)

Порядок установки на чистой Windows-машине, прежде чем поднимать пространство:

1. **Node.js** (LTS) — рантайм Claude Code; заодно добавьте `node.exe` в доверенные антивируса (см. [Windows / PowerShell Pitfalls](windows-powershell-pitfalls.md)).
2. **Claude Code CLI** — установить и залогиниться (аутентификация).
3. **Git for Windows** — даёт `bash`, нужный статус-лайну (см. [Claude Code Setup](claude-code-setup.md)).
4. **Warp** (терминал) — от него зависит запуск пулов через сгенерированный tab-config (см. [Pool Launcher & Warp](pool-launcher-and-warp.md)); без него роли запускаются wrapper-батниками напрямую.
5. **fzf** (`fzf.exe`) — для терминального пикера пулов; **jq** — для хука статус-лайна.

Далее — по пути «Если поднимаете пространство с нуля» ниже.

## Содержание

### Основа
| Документ | О чём |
|----------|-------|
| [Windows / PowerShell Pitfalls](windows-powershell-pitfalls.md) | Кириллица в `.ps1` → UTF-8 с BOM; байт-безопасные правки; Kaspersky/AV душит `uv_spawn` (EPERM); поисковый инструмент пропускает файлы → `Select-String`. |
| [Handling Secrets](handling-secrets.md) | Не печатать/бейкать `.env`; шифрованный перенос + `chmod 600`; плейсхолдеры в публичном репо; команды, тихо раскрывающие секреты. |
| [Safety Guards](safety-guards.md) | Глобальный PreToolUse-hook против катастрофического рекурсивного `rm`; работает под `--dangerously-skip-permissions`; регистрация и self-test. |
| [Claude Code Setup](claude-code-setup.md) | Effort-уровни и персистентность; статус-лайн; постоянные именованные сессии (compaction); файловая система памяти; изоляция браузера по агентам. |
| [The Skills System](the-skills-system.md) | Механика скилов; listing budget (1%); тонкие стабы + вынос канона в `.references/` + инжектор `ref.ps1`; каскад дискаверинга и перенос cwd; meta-skill (Iron Law). |

### Организация workspace
| Документ | О чём |
|----------|-------|
| [Workspace Organization](workspace-organization.md) | Монорепо variant A/B, анатомия workspace и подпроекта, plain vs pool режим, мульти-пулинг, bootstrap. |

### Пулы
| Документ | О чём |
|----------|-------|
| [Pool Communication](pool-communication.md) | Координационный стандарт: env vars, maildir-шина (сообщение=immutable-файл, адрес=папка), pool-CLI, hook, вотчер, топология, per-owner handoff. Инвариант доставки держит инструмент, а не дисциплина. |
| [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) | Ядро `pool.ps1` (14 подкоманд); wrapper на роль; hook/вотчер как режимы CLI; дворник личных todo. Legacy-скрипты помечены DEPRECATED. |
| [Pool Launcher & Warp](pool-launcher-and-warp.md) | Терминальный fzf-пикер пулов (`pool.manifest.json`, `control.json`, авто-раскладка) → разовый Warp tab-config; Warp Workflows. |
| [Board and Watcher](board-and-watcher.md) | Вотчер (`pool watch`, push поверх pull); доска с колонками живости вотчера и активности агента; хук `pool activity`; нотификатор idle. |
| [Pool Scaffolding](pool-scaffolding.md) | `new-pool.ps1` — новый bus-native пул одной командой; `add-peer.ps1` — добавить роль в живой пул. |
| [Pool Standard Tiers](pool-standard-tiers.md) | Расслоение координационного стандарта на L1 (операционный `COORDINATION.md`) и L2 (детали); naming-convention. |
| [Intra-Project Pool Recipe](intra-project-pool-recipe.md) | Пошаговый bootstrap intra-project pool (N peer-агентов в одном подпроекте): скаффолдер, зоны, smoke-тест, расширение. |
| [Lessons Learned](lessons-learned.md) | Антипаттерны и пределы с реальной практики; обобщающий урок — корректность координации перенесена из памяти-агента в инструмент. |

### Роли
| Документ | О чём |
|----------|-------|
| [Tech Lead Mode](tech-lead-mode.md) | Subagent-driven Tech Lead, superpowers-скилы, эскалация; координация через pool-шину. |
| [QA Role](qa-role.md) | QA-peer: Chrome DevTools MCP, exploratory + чек-лист регрессии, pull-модель бэклога, браузер-изоляция. |

### DevOps
| Документ | О чём |
|----------|-------|
| [DevOps Two-Layer Model](devops-two-layer.md) | Server-wide оркестратор + per-monorepo DevOps: границы, каналы (шина + файловый брифинг), безопасность, бутстрап. |
| [Self-Healing Pipeline](sre-self-healing-pipeline.md) | Замкнутый контур самовосстановления production-сервисов под управлением AI-агентов. |

### Стиль работы
| Документ | О чём |
|----------|-------|
| [Working Principles](working-principles.md) | Два стоячих принципа: субагенты вместо контекста; автономность до результата. Вшиваются врезкой в авто-загружаемый CLAUDE.md. |
| [Right-Sizing and Artifacts](right-sizing-and-artifacts.md) | Соразмерять инструмент задаче; не плодить артефакты; skip-ceremony; решать инфра-развилки самому; pre-aggregate для LLM в CI. |

### Удалённый доступ
| Раздел | О чём |
|----------|-------|
| [remote-bridge](../remote-bridge/) | Удалённый пульт к своей Claude-сессии через Telegram: живой мост (long-polling бот → журнал → побудка сессии-цели) + исходящий канал из сессии + STT + модель доверия «пишет только владелец». Рабочий код + инструкция подключить своего бота. За NAT, без открытых портов. |

### Рабочий код
→ [`../scripts/`](../scripts/) — референс-реализация всей инфраструктуры + [инструкция установки](../scripts/README.md).

## С чего читать

**Если только знакомитесь:**
1. [Workspace Organization](workspace-organization.md) — общая модель.
2. [The Skills System](the-skills-system.md) — как знания раздаются агентам без раздувания контекста.
3. [Pool Communication](pool-communication.md) — как несколько агентов координируются.
4. [Tech Lead Mode](tech-lead-mode.md) — как работает один агент.

**Если поднимаете пространство с нуля на новой машине:**
1. [Claude Code Setup](claude-code-setup.md) — среда, память, сессии.
2. [Safety Guards](safety-guards.md) + [Windows / PowerShell Pitfalls](windows-powershell-pitfalls.md) — предохранители и гочи Windows.
3. [Workspace Organization](workspace-organization.md) — bootstrap самой workspace.
4. [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) + [`../scripts/`](../scripts/) — собрать pool-инфру.
5. [Pool Scaffolding](pool-scaffolding.md) — поднять пул одной командой.
6. [Pool Launcher & Warp](pool-launcher-and-warp.md) + [Board and Watcher](board-and-watcher.md) — запуск и мониторинг.
7. [The Skills System](the-skills-system.md) — раздать знания через скилы.
8. [Lessons Learned](lessons-learned.md) — что не повторять.

**Если разбираете production-инцидент:**
1. [Self-Healing Pipeline](sre-self-healing-pipeline.md) — общий контур.
2. [DevOps Two-Layer](devops-two-layer.md) — кто из слоёв чинит.
3. Конкретный runbook (per-monorepo, не в этой базе знаний).

## Что НЕ в этой базе знаний

- Code-style стандарты, конкретные стэки (Python/TypeScript/Go), CI-шаблоны — локальные стандарты
  конкретного workspace.
- Секреты, конфиги, IP-адреса, имена production-серверов — всё обезличено.
- Детальные DevOps-runbooks (safe-deploy, provisioning, детали sre-контура) — зона DevOps-оркестратора,
  сюда включена только модель разделения и координация.
- Превентивные шаблоны проекта — для single-developer workflow смотрите ветки
  [iterative](https://github.com/Dieugene/ai-agent-backed-project-template/tree/iterative)
  или [specified](https://github.com/Dieugene/ai-agent-backed-project-template/tree/specified).
