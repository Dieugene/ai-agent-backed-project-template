# Pool Scaffolding

Два скрипта, которые собирают каркас pool'а за вас, вместо ручной сборки
десятков файлов. **`new-pool.ps1`** поднимает целый новый bus-native пул
одной командой; **`add-peer.ps1`** добавляет одну роль в уже живой пул.
Оба детерминированно делают всю **инфраструктуру** (шина, hook, wrapper'ы,
manifest, Warp-раскладка), а **домен** (миссии ролей, методология, зоны)
оставляют TODO-заглушками — его заполняет лид/человек после генерации.
Третий, родственный, — **`fresh-session.ps1`** (§4): он ничего не скаффолдит,
а **пересаживает** уже существующую роль в свежую сессию (лечение застрявшего
транскрипта), не трогая identity.

Читайте перед тем, как заводить новый пул или расширять существующий.
Ручная пошаговая сборка (для случая, когда скаффолдер не подходит) —
[Intra-Project Pool Recipe](intra-project-pool-recipe.md); механику самой
шины и wrapper'ов см. [Pool Communication](pool-communication.md) и
[Wrapper and Hook Scripts](wrapper-and-hook-scripts.md).

> Все идентификаторы — placeholder'ы: `<pool-name>`, `<role>-<scope>`,
> `<owner>`, `<workspace-root>`, `<bus>`. Примеры из практики обезличены.

Скрипты: [`../scripts/new-pool.ps1`](../scripts/new-pool.ps1),
[`../scripts/add-peer.ps1`](../scripts/add-peer.ps1),
[`../scripts/fresh-session.ps1`](../scripts/fresh-session.ps1). Код в доке не
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
то, что требует доменного суждения, отдаёт paste-ready сниппетами. Помимо
каркаса он **сам обвязывает `CLAUDE.md`**, синхронизирует явный `layout` и
в конце **сам себя проверяет** (self-verify). Валидирован на живом пуле
(real-run + чистый откат) и на выброс-скаффолде в трёх сценариях:
авто-раскладка, явный `layout`, расходящийся `CLAUDE.md` (фолбэк).

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
  появляется в пикере. **Явный `layout` синхронизируется**: панель новой
  роли вставляется рядом с `-After`-соседом (byte-safe splice). Если явного
  `layout` нет — пикер выводит раскладку из `roles` сам, вставлять нечего.
- **`.warp/workflows/<owner>.yaml`** — Warp-лаунчер (Ctrl-Shift-R).
- **`_agent_pool_setup-<owner>.md`** — скелет из шаблона (боилерплейт
  координации / личных todo / рабочего режима готов; доменное — `<!-- TODO -->`).
- **`CLAUDE.md` (папка манифеста) — детерминированная авто-обвязка:** owner в
  множество mode-detection Шага 1 (**критично**: без него сессия падает в
  Plain-режим), bump счётчика «N ролей», строка в таблицу ролей после
  `-After`. Якорь — по канонической форме `new-pool` (mode-set ловится по
  ASCII-токену `AGENT_OWNER`, а не по глифу `∈`).

Шаблоны, из которых рендерятся артефакты, — `workflow.yaml`, `setup.md`,
`snippets.md` (лежат рядом со скриптом в его `templates/add-peer/`).

**Правило безопасности (anchor-or-fallback).** Авто-правка `CLAUDE.md`
срабатывает только там, где док совпал с шаблонной формой. Разошёлся
(bespoke `CLAUDE.md`) — скрипт **не правит молча**: печатает громкий `WARN`
и оставляет фрагмент в сниппете. Молчаливая порча хуже ручной вставки.

**Self-verify (в конце real-run).** Скрипт читает результат с диска и
проверяет ~12 инвариантов: JSON валиден, owner в `roles` (и в `layout`,
если он явный), wrapper несёт нужные `AGENT_OWNER`/`SessionTitle`, файлы на
месте, кодировки (no-BOM у json/setup/wf, ASCII у `.bat`), `CLAUDE.md`
mode-set и строка вставлены. Печатает `ALL PASS` или `N FAILED` красным —
то, что раньше проверялось глазами.

**Split-layout пулы.** Три группы артефактов расходятся по трём местам:
doc-артефакты (`_agent_pool_setup-*`, авто-обвязка `CLAUDE.md`, сниппеты) — в
**папку манифеста**; wrapper — в `manifest.root`; а **`.warp/workflows/` — в
cwd агента** (его `cd /d`-target), потому что Warp ищет workflows от cwd и
вверх по дереву, а не в подкаталогах. Для standalone-пула все три совпадают;
у split-layout пула (манифест и `00_docs`/`CLAUDE.md` в проектной подпапке,
wrapper'ы в общей `scripts/` = `root`, а cwd — корень монорепо) они
расходятся — скрипт разводит их сам. Определяется автоматически (папка
`-Manifest` для доков, `cd /d` соседнего wrapper'а для `.warp`), отдельного
параметра не нужно.

### 3.3 Что отдаёт сниппетами (осталось доменное суждение)

Механику `CLAUDE.md` скрипт теперь делает сам (§3.2). Сниппетами
(`<root>\_add-peer-<owner>.snippets.md`) остаётся только то, что требует
**суждения о содержании**, а не шаблона:

- **раздел роли + строка зон в `00_docs/pool-roles.md`** — проза: что роль
  делает, где в конвейере, какая зона записи vs соседей;
- **фолбэк-фрагменты для нетиповых `CLAUDE.md`** — строка таблицы / дерево,
  если авто-обвязка не нашла якорь (см. правило безопасности в §3.2);
- **строка в memory.**

Причина ручной вставки прозы — граница новой роли против существующих
peer'ов (что моё / что его / как координируется пересечение) требует
взгляда, а не шаблона. Правьте зоны соседей только через `pool send`, не
прямой правкой из parent-сессии.

### 3.4 Кодировки

Сам скрипт — ASCII no-BOM (кириллица только в шаблонах и параметрах → нет
риска mojibake в `.ps1`). Пишет: `.bat` — ASCII; `.yaml`/`.md`/`.json` —
UTF-8 no-BOM.

### 3.5 Делегирование: лид сам растит команду

`add-peer.ps1` снял барьер умений (вся фидлерская обвязка внутри), поэтому
формирование команды можно **отдать ведущему пула** — он лучше знает, кого
нанять. Разделение:

- **лид** — решает, кого нанять, пишет роль-бриф и запускает `add-peer.ps1`
  на **своём** манифесте (own-pool discipline: чужой пул не растит);
- **человек** — запускает саму сессию нового агента (`.bat` / пикер). Это
  ресурсный гейт: постоянную интерактивную named-сессию поднимает человек, не
  агент. Полностью авто-найм не делается сознательно.

**Имя wrapper'а — по конвенции пула.** По умолчанию add-peer назовёт обёртку
`claude-<owner>.bat`. Если пул именует их иначе (частый случай в
multi-subproject монорепо — `claude-<тег>-<роль>.bat`, тег подпроекта
впереди), лид смотрит на соседние обёртки и передаёт `-Bat claude-<…>.bat`
явно, чтобы новая совпала с соседями.

Порядок для лида: `-DryRun` → прочитать `self-verify` (нужно `ALL PASS`) →
заполнить доменные `<!-- TODO -->` в setup + роль-бриф → сказать человеку
запустить wrapper. Границы: только свой пул; удаление/переименование ролей,
смена шины/`TASK_LIST_ID` — эскалация оркестратору, не лид. Согласуется с
принципом «оркестратор мостит дорогу (скрипт + стандарт), лид по ней идёт» —
делегирование способности в рамках, не раздача задач.

---

## 4. `fresh-session.ps1` — свежая сессия для СУЩЕСТВУЮЩЕЙ роли

Третий брат. `new-pool.ps1` поднимает пул, `add-peer.ps1` добавляет **новую**
роль, а `fresh-session.ps1` даёт **той же** роли **свежую сессию** (новый
`SessionTitle` → чистый транскрипт), **не трогая** ни манифест, ни `CLAUDE.md`,
ни identity, ни mailbox.

**Когда.** Живая `--resume`-сессия **застряла** — транскрипт замусорен, модель
уехала в format drift (утёкший tool-call как текст, см. [Safety Guards
§7](safety-guards.md)), и повторный resume лишь перечитывает тот же плохой
транскрипт. Лечение — не `/compact` (ненадёжен, если «яд» дошёл до handoff), а
**пересадка в чистую сессию** того же owner'а.

**Что делает.** Клонирует **второй wrapper** (+ его Warp-workflow), который
запускает **тот же** `owner` / mailbox / `ProjectKey` под **новым**
`SessionTitle`. Свежая сессия видит **тот же inbox**, а `pool mine`
восстанавливает её in-flight работу из `cur/` + `new/`. Именно потому, что owner
и адрес те же, скрипт **сознательно НЕ правит** манифест и `CLAUDE.md` — в
отличие от `add-peer.ps1`, который заводит новую identity.

### 4.1 Вызов

```
..\scripts\fresh-session.ps1 -Manifest <pool.manifest.json> -Owner <role>-<scope> `
    [-Tag 2] [-Bat claude-<...>.bat] [-Force] [-DryRun]
```

- `-Manifest` / `-Owner` — целевой пул и **существующая** роль. Роли нет в
  манифесте → скрипт откажет и пошлёт к `add-peer.ps1` (это инструмент для
  **уже заведённого** owner'а, а не для новой identity).
- `-DryRun` печатает план без записи; `-Force` перезаписывает уже существующий
  `<...>-<tag>.bat` / `.yaml`.
- `-Bat` — если пул именует обёртки не `claude-<owner>.bat` (та же оговорка,
  что у `add-peer.ps1`).

### 4.2 Именование — числовой суффикс

Новая сессия той же роли получает **номер** (`2`, затем `3`, …), а не метку
`fresh`: `-Tag` по умолчанию `2`, для более поздней пересадки — `-Tag 3` и т.д.
Суффикс уходит и в имя `.bat`, и в `SessionTitle` (`<SessionTitle>-2`), чтобы в
picker'е свежая сессия не путалась со сбоящей.

### 4.3 Свойства

- **Byte-preserving клон** (latin1-кодек, 1 байт ↔ 1 символ): кириллические
  `REM` / имена переносятся дословно, меняются только ASCII `SessionTitle`,
  ссылка на `.bat` и префикс имени Warp-workflow. Сам скрипт — ASCII no-BOM
  (PS 5.1 его не ломает, см. [Windows PowerShell
  Pitfalls](windows-powershell-pitfalls.md)).
- **Split-layout-aware**: базу для `.warp\workflows\` берёт из `cd /d`-таргета
  соседнего wrapper'а (Warp ищет workflows от cwd вверх), а не из `manifest.root`.
- **Self-verify** в конце: перечитывает записанное (no-BOM; `AGENT_OWNER` **не**
  изменён; новый `SessionTitle` на месте; кириллица цела) → `ALL PASS` /
  `N FAILED`.
- **Дисциплина запуска.** Одновременно два окна одного owner'а держать нельзя
  (сольются в один транскрипт) — **старое окно закрыть**, затем поднять свежее
  (двойной клик по новому `.bat` или Warp-workflow; Warp переоткрыть, чтобы
  подхватил новый yaml).

---

## 5. Связанные документы

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
- [Safety Guards §7](safety-guards.md) — malformed-детектор, чей сигнал
  format-drift'а лечит пересадка через `fresh-session.ps1` (§4).
