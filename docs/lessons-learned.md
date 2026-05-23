# Lessons Learned

Антипаттерны и грабли, собранные через практику Claude Code в multi-pool
multi-project setup. Каждый пункт — реально случившийся инцидент с
выводом, не теоретическое предупреждение.

> Все идентификаторы обезличены. Числа и метрики — округлены до порядка
> для иллюстрации, не как метрика для воспроизведения.

---

## 1. Инвариант top-level `owner` в Tasks API

### Симптом

Получатель в pool жалуется: «hook сказал `clean`, но в `.inbox/` лежат
несколько свежих задач, явно адресованных мне». Отправитель уверен, что
«отправил».

### Что произошло

Отправитель положил payload в `.inbox/<pool-id>/TASK-NNN.md` (правильно)
и вызвал `TaskCreate`. Но **top-level поле `owner`** в task-файле либо
не было выставлено (пустая строка / null), либо стояло имя отправителя
вместо получателя. Поле `metadata.to` было заполнено корректно.

Hook `inject-inbox.ps1` фильтрует POOL INBOX **строго по top-level
`owner`**. `metadata.to`, `metadata.assignee`, `metadata.owner` он **не
смотрит** — это конструкция Tasks API: фильтрация задач по получателю
идёт по `owner` верхнего уровня.

В одной из ревизий рабочего pool обнаружилось **11 pending-записей без
top-level `owner`** одновременно. Из них несколько были релиз-блокерами,
которые получатель не видел трое суток.

### Митигация

1. **В каждом `_agent_pool_setup-<role>.md`** — явный блок «Как отправить
   задачу соседу» с шаблоном `TaskCreate` и красным предупреждением
   «top-level `owner` обязателен». См. [Pool Communication §4](pool-communication.md#инвариант-top-level-owner-критично).
2. **Периодическая ревизия** pending-записей без top-level `owner` —
   раз в неделю, или при жалобе peer'а:
   ```bash
   for f in ~/.claude/tasks/<pool-name>/*.json; do
     status=$(jq -r .status "$f")
     owner=$(jq -r .owner "$f")
     if [ "$status" = "pending" ] && [ -z "$owner" -o "$owner" = "null" ]; then
       echo "MISSING OWNER: $f"
     fi
   done
   ```
3. **При создании task'а руками** (например, чтобы починить пропущенную
   адресацию) — `"owner": "<получатель>"` на верхнем уровне обязателен.
4. **Шаблоны в setup-файлах должны явно показывать `owner='<сосед>'` на
   уровне аргументов TaskCreate**, не в metadata.

---

## 2. Hook walk-up не работает

### Симптом

В intra-project pool env vars выставлены (`$env:AGENT_OWNER` непустой),
но баннер `[POOL INBOX]` не появляется ни на одном промпте. Tasks API
функционально работает (`TaskList()` возвращает задачи), но hook не
показывает баннер.

### Что произошло

Claude Code ищет `.claude/settings.local.json` с блоком `hooks` только в
**cwd** и в **project-root** (определяется наличием `.git/` или
маркеров). Hooks из ancestor-директорий **не подхватываются**
автоматическим walk-up.

В первой версии intra-project pool wrapper'ы делали `cd /d
<workspace-root>/01_projects/<подпроект>/`, рассчитывая, что hook,
зарегистрированный в `<workspace-root>/.claude/settings.local.json`,
подхватится. Не подхватился. Hook сидел уровнем выше.

### Митигация

- **Предпочтительно:** wrapper делает `cd /d <workspace-root>` (umbrella
  cwd), даже если pool — intra-project. Тогда один
  `settings.local.json` на workspace-уровне покрывает все pool'ы. См.
  [Wrapper and Hook Scripts §4](wrapper-and-hook-scripts.md#discovery-walk-up-не-работает).
- **Если cwd обязательно подпроект** — `settings.local.json` дублируется
  в `<подпроект>/.claude/` с абсолютным путём к hook-скрипту в
  workspace.

---

## 3. Не создавать helper-launchers по аналогии без явной просьбы

### Симптом

Пользователь попросил создать wrapper для одной роли. Агент по аналогии
создал «удобный» дополнительный батник `launch-everything.bat`, который
никто не просил. Через неделю никто не помнит, что это и зачем.

### Что произошло

Когнитивный шорткат «раз есть claude-X.bat, наверное нужен и
launch-X.bat для удобства». Никаких явных требований не было.

### Митигация

- Default: **не создавать convenience-bat'ники и helper-скрипты без
  явной просьбы пользователя**. Один wrapper на одного агента — этого
  достаточно.
- Если пользователь регулярно делает одну и ту же последовательность
  через несколько bat'ников — предложить ему обёртку, спросить
  подтверждение, потом создать.

---

## 4. Размытие границ в intra-project pool

### Симптом

Два peer'а в одном подпроекте, спустя месяц работы, по факту правят
одни и те же файлы. Git-конфликты раз в неделю. «А я думал это моя
зона, а ты что — тоже её правил?»

### Что произошло

`_agent_pool_setup-<peer>.md` каждого peer'а был общим описанием роли
(«ты frontend, твоя зона — frontend»), без явной таблицы файлов /
поддиректорий. `agent-pool-zones.md` подпроекта либо отсутствовал, либо
был неконкретен.

### Митигация

- **Конкретная таблица зон в `agent-pool-zones.md`** до запуска peer'ов:
  ```
  | Файл/папка | Кто пишет | Кто читает |
  |------------|-----------|------------|
  | `02_src/frontend/` | `frontend-<sub>` | все |
  | `02_src/backend/` | `backend-<sub>` | все |
  | `02_src/backend/models.py` | `backend-<sub>` (общая модель!) | все |
  | `02_src/backend/search/` | `backend-search-<sub>` | все |
  ```
- **В setup-файле peer'а** — отдельный блок «Граница с <соседом>» с
  таблицей точек трения и правилом координации (`TaskCreate(owner='<сосед>')`,
  не прямая правка).
- Любая правка вне своей зоны — через TaskCreate. Это дисциплина, не
  технический контроль.

---

## 5. Per-monorepo agent boundary

### Симптом

Server-wide DevOps Orchestrator пересмотрел compose конкретного
подпроекта «чтобы исправить общую сеть», не согласовав с per-monorepo
DevOps. Per-monorepo не знает почему. Через два дня — конфликт при
следующем деплое.

### Что произошло

«Я же DevOps, я могу всё трогать» — спутанные зоны двух слоёв (см.
[DevOps Two-Layer](devops-two-layer.md)).

### Митигация

- Server-wide агент не правит зону per-monorepo. Если требует — через
  `TaskCreate(owner='<per-monorepo DevOps>')` или, если уровень изменения
  выходит за рамки, эскалация к пользователю.
- Per-monorepo агент не правит зону server-wide. То же правило в обратную
  сторону.
- Источник правды по состоянию подпроекта — `<workspace-root>/.devops/REGISTRY.md`
  per-monorepo, не server-wide REGISTRY. Server-wide агрегирует, не
  диктует.

---

## 6. Не править зону peer'а в его pool по умолчанию

### Симптом

В intra-project pool один peer написал длинный handoff с подробностями
работы в его зоне. Parent-сессия (или другой peer) «причесала» этот
handoff — переименовала переменные, изменила структуру. Когда peer
возобновился — handoff не сходился с его памятью, потерял контекст.

### Что произошло

Handoff peer'а — его персональная зона. Даже если со стороны видно как
«можно лучше» — это не повод вмешиваться. Peer сам разберётся с своим
контекстом при возобновлении.

### Митигация

- Чужие `_handoff_<owner>.md`, чужие personal-todo, чужие setup-файлы —
  read-only context, не writable.
- Если объективно нашёл проблему в чужой зоне (например, опечатка в его
  setup, которая мешает координации) — `TaskCreate(owner='<peer>')` с
  обоснованием. Не прямая правка.

---

## 7. Skip ceremony для templated tasks

### Симптом

Пользователь: «добавь ещё одного peer'а по образцу существующего».
Агент входит в полный цикл brainstorming → writing-plans → review →
implementation. На задачу «копия файла X с заменой Y» уходит 30 минут.

### Что произошло

Привычка применять `superpowers:brainstorming` ко всему творческому без
оценки, что «творческого» в копии нет вообще.

### Митигация

- Когда задача — **копия по существующему образцу** (peer, runbook,
  артефакт), brainstorming и formal plan = ceremony. Делать сразу.
- Brainstorming оправдан, когда есть **выбор** между подходами. Когда
  выбор уже сделан (это копия X), выбора нет — есть процедура.

См. [Tech Lead Mode §2 — Когда brainstorming пропускать](tech-lead-mode.md#когда-brainstorming-пропускать).

---

## 8. PowerShell 5.1 + UTF-8 кириллица

### Симптом

`[POOL INBOX]` баннер выводится, но имена ролей и subject задач — в виде
mojibake (`т═ехL═ад-foo`). Pool технически работает, но читать невозможно.

### Что произошло

Hook на Windows крутится в Windows PowerShell 5.1 (старая версия). По
умолчанию её stdout кодируется в OEM/ANSI (cp866/cp1251), и кириллица
приходит к Claude Code как mojibake. Файлы задач Tasks API пишутся UTF-8
без BOM — без явной фиксации `Get-Content` читает их в ANSI.

### Митигация

Первые две строки `inject-inbox.ps1` (или любого PS-hook'а с кириллицей):

```powershell
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding           = [System.Text.UTF8Encoding]::new($false)
```

И при чтении task-файлов:

```powershell
Get-Content -Path $_.FullName -Raw -Encoding UTF8 -ErrorAction Stop
```

То же для batch-replace в файлах с кириллицей: `Get-Content` без
`-Encoding utf8` на ru-RU systems читает как cp1251 и ломает кириллицу.
Для bulk операций — `[System.IO.File]::ReadAllBytes`/`WriteAllBytes` с
явным UTF-8 encoder'ом.

---

## 9. Pool infrastructure caution

### Симптом

Агент по инициативе «улучшил» pool-инфру работающего pool'а:
переименовал `TASK_LIST_ID`, или подкаталог `.inbox/<pool-id>/`. Сделал
аккуратно — все ссылки в documents обновил. Но Tasks API store с
задачами остался в старом каталоге. Peer'ы при перезапуске увидели пустой
inbox и решили что задач нет.

### Что произошло

Смена `TASK_LIST_ID` или путей mailbox = миграция данных, не
переименование. Tasks API store физически в другой папке;
payload-файлы — в другой.

### Митигация

- Изменения pool-инфры работающего pool — **всегда через согласование с
  пользователем**, даже если выглядят «косметическими».
- Перед `rm` каталогов работающего pool — `ls` и согласование.
- «Решай DevOps-выборы сам» (правило из feedback'ов) — **не
  применяется** к изменениям, которые могут сломать live координацию.
  DevOps-выборы — про внешнюю инфру (выбор бэкапа, выбор сети), не про
  внутреннюю pool-инфру.

---

## 10. Personal todo без `kind: personal` шумит в чужих POOL INBOX

### Симптом

Peer A создал себе локальный todo через `TaskCreate(owner='<self>', ...)`,
но забыл выставить `metadata.kind='personal'`. Hook других peer'ов
этот todo **не показал** (фильтр по `owner` отсёк), но через `TaskList`
с любым параметром локальный todo засветился — он не «личный» с точки
зрения metadata, просто owned by self.

(Этот случай **не такой грубый**, как §1 — но засоряет общую видимость
pool и затрудняет ревизию pending'ов соседей.)

### Митигация

В каждом setup-файле peer'а — явный блок «Личные todo»:

```markdown
## Личные todo

`TaskCreate(subject='...', owner='<self>', metadata={ "kind": "personal" })`
— не зашумляет POOL INBOX соседей и не мешает фильтрам.
```

Hook фильтрует personal по `metadata.kind`. Без этого поля personal-todo
никому не видна в баннере (это норма), но «личный» статус неявный.

---

## 11. `--dangerously-skip-permissions` не обходит новые hooks

### Симптом

Первый запуск нового pool. Wrapper делает `--dangerously-skip-permissions`,
но Claude Code всё равно просит подтверждение: «Allow command:
powershell ... inject-inbox.ps1?». Пользователь думает что что-то не
работает.

### Что произошло

`--dangerously-skip-permissions` — флаг для tool-call permissions. Hooks
проходят через **отдельный security gate**, который этим флагом не
снимается. На первом запуске после регистрации нового hook'а — всегда
запрос.

### Митигация

В `scripts/README.md` каждого нового pool — явно документировать: «на
первом промпте Claude Code попросит одобрить новый hook — нажать **Yes
/ Always allow for this project**, со второго промпта баннер появится
сам».

---

## 12. Decide infrastructure choices yourself

### Симптом

Агент при инфра-вопросе («какой контейнер использовать», «куда положить
конфиг») задаёт пользователю развилку: «А1 — Postgres community, A2 —
managed на Cloud SQL, A3 — etc.». Пользователь — не-технический, не
может ответить.

### Что произошло

Привычка эскалировать выбор. У не-технического пользователя нет
сравнительной базы; для него такая развилка = тупик.

### Митигация

- При инфра-выборе **принимать решение самому**, объяснять простыми
  словами **что выбрал и почему**.
- Эскалировать только: (а) trade-off в бизнес-плоскости (стоимость,
  безопасность данных, доступность для конкретного пользователя),
  (б) если выбор требует расходов / новых external accounts,
  (в) разрушительные операции.

См. [Tech Lead Mode §5](tech-lead-mode.md#5-эскалация-к-пользователю).

---

## 13. Doc files не дублируются между peer'ами и общими стандартами

### Симптом

«Стандарт коммита» лежит в setup'ах трёх peer'ов одновременно. Поправили
один — забыли два других.

### Митигация

- Общие стандарты — в `<workspace-root>/00_docs/standards/` (или в
  knowledge base типа этого репозитория).
- Setup peer'а — **только специфика этого peer'а** (его зона, его
  граница с конкретными соседями). Общие правила — ссылкой.
- При совпадении контента 2+ файлов — это сигнал к экстракту, не к
  параллельному поддержанию.

---

## Связанные документы

- [Pool Communication](pool-communication.md) — §1, §2 (top-level owner),
  §7 (hook discovery).
- [Wrapper and Hook Scripts](wrapper-and-hook-scripts.md) — §4 (UTF-8),
  §5 (диагностика).
- [Tech Lead Mode](tech-lead-mode.md) — §4 (что Tech Lead не делает), §5
  (эскалация).
- [DevOps Two-Layer](devops-two-layer.md) — §4 (граница), §8 (антипаттерны).
- [Intra-Project Pool Recipe](intra-project-pool-recipe.md) — §1.3 (зоны
  до bootstrap), §4 (расширение pool).
