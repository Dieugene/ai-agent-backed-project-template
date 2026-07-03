# Pool Scaffolding

Два скрипта, которые собирают каркас pool'а за вас, вместо ручной сборки
десятков файлов. **`new-pool.ps1`** поднимает целый новый bus-native пул
одной командой; **`add-peer.ps1`** добавляет одну роль в уже живой пул.
Оба детерминированно делают всю **инфраструктуру** (шина, hook, wrapper'ы,
manifest, Warp-раскладка), а **домен** (миссии ролей, методология, зоны)
оставляют TODO-заглушками — его заполняет лид/человек после генерации.

Читайте перед тем, как заводить новый пул или расширять существующий.
Ручная пошаговая сборка (для случая, когда скаффолдер не подходит) —
[Intra-Project Pool Recipe](intra-project-pool-recipe.md); механику самой
шины и wrapper'ов см. [Pool Communication](pool-communication.md) и
[Wrapper and Hook Scripts](wrapper-and-hook-scripts.md).

> Все идентификаторы — placeholder'ы: `<pool-name>`, `<role>-<scope>`,
> `<owner>`, `<workspace-root>`, `<bus>`. Примеры из практики обезличены.

Скрипты: [`../scripts/new-pool.ps1`](../scripts/new-pool.ps1),
[`../scripts/add-peer.ps1`](../scripts/add-peer.ps1). Код в доке не
дублируется — здесь только устройство и «зачем».

---

## 1. Почему скаффолдер, а не руки

Каркас пула — это не один файл: шина, регистрация hook'а, по wrapper'у на
каждую роль, setup-скелет на каждую роль, board-батник, `pool.manifest.json`
для пикера, Warp-workflows, дерево `00_docs/`. Собирать это руками —
источник ошибок: забытый hook (баннер не появляется), кириллица в `.ps1`
без BOM превращается в mojibake, роль есть в CLAUDE.md, но нет в манифесте
(не появляется в пикере), и т.п.

Скаффолдеры делают эту механику **детерминированной**. Разделение
обязанностей одинаково у обоих:

- **ИНФРА** — генерится полностью рабочей (координация сразу на шине,
  отдельный rollout не нужен).
- **ДОМЕН** — миссии ролей, конвейер, методология, чек-листы, поля брифа,
  зоны записи — остаётся `TODO`-заглушками. Это по своей природе bespoke:
  заполняет лид пула или пользователь.

---

## 2. `new-pool.ps1` — новый пул одной командой

Поднимает **standalone-монорепо + агентный пул**, подключённый к общей
maildir-шине. Форма вывода повторяет валидированный эталонный пул.

### 2.1 Вызов

Два режима:

```
# Рекомендуемо — JSON-спека (несёт кириллические подписи ролей чисто, UTF-8):
powershell -File ..\scripts\new-pool.ps1 -Spec <spec.json>

# Быстро inline (ASCII owner-id; подписи ролей станут TODO-заглушками):
powershell -File ..\scripts\new-pool.ps1 -Name <pool-name> -Roles a,b,c -Lead a `
    [-DisplaySuffix Foo] [-WorkspaceRoot <workspace-root>] [-WhatIf]
```

`-WhatIf` печатает раскладку без единой записи — прогоняйте первым.

### 2.2 Спека

```json
{
  "name": "<pool-name>",              // required; kebab-case; = имя папки монорепо
  "pool": "<pool-name>-pool",         // optional; default "<name>-pool"
  "title": "<одна строка о пуле>",    // optional; для CLAUDE.md / README
  "displaySuffix": "Foo",             // optional; default PascalCase 1-го сегмента name
  "lead": "<owner-лида>",             // optional; default первая роль
  "roles": [
    { "owner": "<role>-<scope>", "label": "<подпись роли>" },
    { "owner": "<role2>-<scope>", "label": "<подпись роли>" }
  ]
}
```

Пример-образец лежит рядом со скриптом (`new-pool.spec.example.json`).
JSON в UTF-8 — единственный чистый способ передать кириллические `label`;
в inline-режиме `label` не задаются и становятся TODO.

### 2.3 Что генерит (ИНФРА — всё рабочее)

```
<root>/
├── .bus/                              # ленивый maildir (создаётся пустым)
├── .claude/settings.local.json        # единственный hook → pool.ps1 hook (абс. путь)
├── .mcp.json                          # пер-агентная изоляция Chrome
│                                      #   (--user-data-dir=...\${AGENT_OWNER})
├── .gitignore
├── CLAUDE.md                          # routing по AGENT_OWNER; таблица ролей
├── README.md                          # user-guide; таблица wrapper'ов
├── claude-<owner>.bat        × N      # wrapper на роль (у лида — авто-старт борда)
├── board-<pool-name>.bat
├── _agent_pool_setup-<owner>.md × N   # identity заполнена; mission/zones = TODO
├── .claude/skills/                    # тонкие стабы (см. 2.4)
├── scripts/{pool-launch.ps1, archive-completed-tasks.ps1, README.md}
├── 00_docs/{README.md, pool-roles.md, source-brief/{README.md, brief.md}}
├── 01_tasks/.gitkeep
├── 05_deliverables/{README.md, .gitkeep}
└── pool.manifest.json  +  .warp/workflows/<owner>.yaml
```

Ключевое:

- **Координация сразу на шине.** `pool.ps1` в пул **не копируется** — одна
  общая копия на весь workspace. Пул несёт только данные (`.bus`),
  регистрацию hook'а (`settings.local.json` → `pool.ps1 hook` по
  абсолютному пути) и env в wrapper'ах (`AGENT_OWNER` / `POOL_BUS_ROOT`).
  Отдельный rollout не нужен.
- **`pool.manifest.json` + Warp-workflows** — роли сразу видны в
  fzf-пикере пула и в авто-раскладке Warp-панелей (см. [Pool Launcher and
  Warp](pool-launcher-and-warp.md)).
- **Лид на повышенном effort.** Генерируемый `scripts/pool-launch.ps1`
  несёт параметр `-Effort` (splat в вызов `claude`); wrapper лида получает
  `-Effort xhigh` (флаг сессии, не пишется в `settings.json`), executor'ы —
  без флага (на глобальном уровне).

### 2.4 Скилы-стабы + слим-координация

Скаффолдер кладёт `<root>/.claude/skills/` с **тонкими стабами** (триггер +
вызов канона `& <workspace-root>\.references\ref.ps1 <тема>`; сам контент
единый в `.references/`, single-source — см. [The Skills
System](the-skills-system.md)):

- **базовые** — всем ролям: `avoiding-windows-pitfalls`,
  `handling-secrets-safely`, `coordinating-on-the-pool-bus`,
  `operating-in-a-pool`;
- **typing по имени роли** — `working-as-tech-lead` если среди ролей есть
  `*tech-lead*`/`*lead*`; `testing-as-qa` если есть `*qa*` (qa приоритетнее
  при совпадении обоих).

Координационный блок в `CLAUDE.md`/onboarding поэтому **слим** — ссылка на
скилы + фолбэк `ref.ps1 pool-coordination`, а не дублированные буллеты
`pool send/reply/...`. Стабы — в git (`.claude/skills/` не в `.gitignore`).

### 2.5 Что НЕ генерит (домен, руками)

Миссии ролей, конвейер (`00_docs/pool-roles.md`), методология и чек-листы,
поля брифа (`source-brief/brief.md`) — остаются TODO-заглушками. Для
intra-project pool скаффолдер задаёт каркас, но **зоны записи** внутри общей
папки подпроекта прописываются вручную (см. [Intra-Project Pool Recipe
§1.3](intra-project-pool-recipe.md)).

### 2.6 Непустая целевая папка — неразрушающе

`Emit` работает **create-only**: существующий файл **никогда** не
затирается (пишется только отсутствующее, попадает в отчёт как `= (kept)`).
Два файла не перезаписываются, а **сливаются**:

- `.gitignore` — дописываются только недостающие пул-строки под маркером
  (идемпотентно);
- `.claude/settings.local.json` — пул-хуки вливаются, **сохраняя**
  существующие permissions/hooks; unparseable JSON не трогается, только
  рапортуется.

Итоговый отчёт делит файлы на `+ (new) / ~ (merged) / = (kept)`. Гард на
непустой каталог остаётся (нужен `-Force`), но теперь он неразрушающий.
Всё равно прогоняйте `-WhatIf` до записи.

### 2.7 Кодировки и гочи

- Сам скрипт — UTF-8 **с BOM** (иначе PowerShell 5.1 бьёт кириллицу в
  here-strings). **Генерируемые** файлы — без BOM, `.bat` — без BOM.
- `ProjectKey` = полный путь с заменой `[^a-zA-Z0-9]`→`-`
  (напр. `<workspace-root>\<pool-name>` → `<...>-<pool-name>`).
- Кириллица в `.ps1`-скриптах вообще — отдельная тема, см. [Windows
  PowerShell Pitfalls](windows-powershell-pitfalls.md).

---

## 3. `add-peer.ps1` — одна роль в живой пул

Брат `new-pool.ps1`: тот скаффолдит пул целиком, этот добавляет **одну
роль (peer)** в уже существующий пул. Механику вшивает детерминированно, а
то, что требует человеческого взгляда, отдаёт paste-ready сниппетами.
Валидирован на живом пуле (real-run + чистый откат).

### 3.1 Вызов

```
..\scripts\add-peer.ps1 -Manifest <pool.manifest.json> -Owner <role>-<scope> `
    -Title "<заголовок для пикера>" -Display <SessionTitle> `
    -Mission "<одна строка миссии>" -Zone <relpath> `
    -After <owner> [-CopyFrom <owner>] [-DryRun]
```

- `-Manifest` — манифест целевого пула (из него скрипт берёт `root`,
  `slug`, `lead`, список ролей).
- `-After <owner>` — после какой роли вставить (по умолчанию — лид);
  `-CopyFrom <owner>` — чей wrapper клонировать (по умолчанию `-After`).
- `-Display` — PascalCase ASCII (идёт в `.bat`).
- `-DryRun` печатает план без записи.

### 3.2 Что авто-вшивает (детерминированно)

- **`claude-<owner>.bat`** — **клон соседнего wrapper'а**
  (`-CopyFrom`/`-After`); подменяются только `AGENT_OWNER` и
  `SessionTitle`. Форма обёртки (umbrella `launch-claude.ps1` vs standalone
  `pool-launch.ps1`), `POOL_BUS_ROOT`, `ProjectKey`, `-InitialPromptFile`
  (взвод вотчера) переносятся как есть → скрипт pool-агностичен.
- **`pool.manifest.json`** — вставка роли (byte-safe text, формат
  клонируется с блока `-After`, JSON валидируется перед записью) → агент
  появляется в пикере и в авто-раскладке Warp-панелей.
- **`.warp/workflows/<owner>.yaml`** — Warp-лаунчер (Ctrl-Shift-R).
- **`_agent_pool_setup-<owner>.md`** — скелет из шаблона (боилерплейт
  координации / личных todo / рабочего режима готов; доменное — `<!-- TODO -->`).

Шаблоны, из которых рендерятся артефакты, — `workflow.yaml`, `setup.md`,
`snippets.md` (лежат рядом со скриптом в его `templates/add-peer/`).

### 3.3 Что отдаёт сниппетами (нужен человеческий глаз)

То, что требует доменного суждения, а не механики, скрипт **не вставляет
сам** — пишет paste-ready фрагменты в `<root>\_add-peer-<owner>.snippets.md`:

- bullet роли в подпроектный `CLAUDE.md` + строки дерева структуры;
- routing-строка в umbrella-`CLAUDE.md` + буллет онбординга;
- раздел в `agent-pool-zones.md` (зона записи новой роли vs соседей);
- строка в memory.

Причина ручной вставки — граница новой роли против существующих peer'ов
(что моё / что его / как координируется пересечение) требует взгляда, а не
шаблона. Правьте зоны соседей только через `pool send`, не прямой правкой
из parent-сессии.

### 3.4 Кодировки

Сам скрипт — ASCII no-BOM (кириллица только в шаблонах и параметрах → нет
риска mojibake в `.ps1`). Пишет: `.bat` — ASCII; `.yaml`/`.md`/`.json` —
UTF-8 no-BOM.

---

## 4. Связанные документы

- [Intra-Project Pool Recipe](intra-project-pool-recipe.md) — пошаговая
  сборка (основной путь = `new-pool.ps1`, ручная — fallback).
- [Pool Launcher and Warp](pool-launcher-and-warp.md) — как манифест и
  Warp-workflows попадают в пикер и раскладку панелей.
- [Pool Communication](pool-communication.md) — координационный стандарт
  шины, поверх которой скаффолдер собирает пул.
- [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) — что именно
  генерятся wrapper'ы и hook-регистрация.
- [The Skills System](the-skills-system.md) — стабы + `ref.ps1`, которые
  раскладывает `new-pool.ps1`.
