# scripts/ — референс-реализация инфраструктуры

Здесь лежит рабочий код инфраструктуры, описанной в [`../docs/`](../docs/): pool-шина,
терминальный пикер пулов, скаффолдеры, инжектор канон-доков скилов, глобальный
предохранитель. Это **референс**, а не «запусти-и-работает-из-коробки»: перед
использованием замени плейсхолдеры путей под свою машину.

## Плейсхолдер путей

Во всех скриптах абсолютный корень рабочего пространства вынесен как `<workspace-root>`.
Замени его на свой путь (например, глобальным поиском-заменой) — это папка, где живут
`.launcher/`, `.references/` и монорепы с пулами. Общая инфра ожидается по путям:

| Что | Ожидаемое расположение |
|-----|------------------------|
| Ядро шины | `<workspace-root>\.launcher\pool-bus\pool.ps1` |
| Пикер + манифесты | `<workspace-root>\.launcher\pool-launcher\` |
| Инжектор канона | `<workspace-root>\.references\ref.ps1` |
| Глобальный rm-guard | `<user-home>\.claude\hooks\block-dangerous-rm.ps1` |

## Состав

| Файл | Роль | Документация |
|------|------|--------------|
| `pool.ps1` | Ядро maildir-шины: `send/reply/note/inbox/mine/claim/ack/dismiss/check/watch/hook/activity/board`. Одна общая копия на workspace. | [pool-communication](../docs/pool-communication.md), [wrapper-and-hook-scripts](../docs/wrapper-and-hook-scripts.md) |
| `ref.ps1` | Инжектор: `& ref.ps1 <topic>` печатает канон-док в контекст. Маршрутная карта topic→файл внутри. | [the-skills-system](../docs/the-skills-system.md) |
| `launch-pool.ps1` | fzf-пикер пулов → разовый Warp tab-config. Требует `bin\fzf.exe` (скачать отдельно). | [pool-launcher-and-warp](../docs/pool-launcher-and-warp.md) |
| `control.json.example` | Реестр одиночных управляющих сессий для пикера. Скопируй в `control.json`, впиши свои. | [pool-launcher-and-warp](../docs/pool-launcher-and-warp.md) |
| `new-pool.ps1` | Скаффолдер нового bus-native пула из JSON-спеки или inline. | [pool-scaffolding](../docs/pool-scaffolding.md) |
| `add-peer.ps1` | Добавить одну роль в живой пул. Использует `templates/add-peer/`. | [pool-scaffolding](../docs/pool-scaffolding.md) |
| `board-window.ps1` | Открыть живую доску пула в отдельном окне. | [board-and-watcher](../docs/board-and-watcher.md) |
| `notify-pool-idle.ps1` | Тост «пул остановился» на переход active→0. | [board-and-watcher](../docs/board-and-watcher.md) |
| `block-dangerous-rm.ps1` | Глобальный PreToolUse-hook против катастрофического рекурсивного rm. | [safety-guards](../docs/safety-guards.md) |
| `templates/` | Шаблоны: wrapper пула, дворник личных todo, add-peer/. | [wrapper-and-hook-scripts](../docs/wrapper-and-hook-scripts.md) |

## Установка (минимум для одного пула)

1. **Шина.** Положи `pool.ps1` в `<workspace-root>\.launcher\pool-bus\`. Каждый агент-wrapper
   выставляет env `AGENT_OWNER=<роль>` и `POOL_BUS_ROOT=<путь к .bus пула>`.
2. **Hook.** В `.claude/settings.local.json` пула зарегистрируй баннер входящих:
   `UserPromptSubmit` → команда `pool.ps1 hook` (см. `templates/`).
3. **Предохранитель.** Скопируй `block-dangerous-rm.ps1` в `<user-home>\.claude\hooks\`,
   зарегистрируй в `~/.claude/settings.json` → `hooks.PreToolUse`, matcher `Bash|PowerShell`.
   Проверка: `powershell -File block-dangerous-rm.ps1 -SelfTest`.
4. **Пикер (опционально).** Положи `launch-pool.ps1` в `.launcher\pool-launcher\`, рядом
   `bin\fzf.exe` (скачай с github.com/junegunn/fzf), `control.json` из примера.
5. **Скилы (опционально).** `ref.ps1` в `<workspace-root>\.references\`, канон-доки рядом;
   тонкие стабы `SKILL.md` зовут `& ref.ps1 <topic>`.

## Кодировки (Windows / PowerShell 5.1)

`.ps1` с кириллицей должны быть **UTF-8 с BOM**, иначе PowerShell 5.1 читает кириллицу как
cp1251 (mojibake). ASCII-only скрипты (`pool.ps1`, `ref.ps1`, `block-dangerous-rm.ps1`) — без
BOM намеренно. Правки байт-безопасно. Подробности — [windows-powershell-pitfalls](../docs/windows-powershell-pitfalls.md).
