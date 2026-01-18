# Финальные требования к шаблону проекта для AI-агентов

## 1. Структура ролей агентов

### Иерархия (4 роли)

```
Coordinator (стратегия)
    ↓
Analyst (тактика/планирование)
    ↓
Developer (реализация)
    ↓
Reviewer (проверка)
    ↓
Coordinator (приемка)
```

**Важно:**
- Task Architect из старого шаблона → переименован в **Analyst**
- Analyst ≈ system-analytics.md из референса
- Reviewer может быть тем же Analyst в новой сессии, но с другим контекстом

### Принцип работы ролей

- Каждая роль работает в отдельной сессии
- Каждая роль может требовать несколько сессий (из-за ограничения контекста)
- Каждая роль читает ТОЛЬКО свои файлы (минимизация контекста)
- Файлы задач = интерфейсы между ролями

---

## 2. Структура проекта

```
project-name/
│
├── .git/
├── .gitignore
├── README.md                   # Для людей
├── AGENTS.md                   # Специфика проекта
│
├── .agents/
│   └── roles/
│       ├── coordinator.md
│       ├── analyst.md
│       ├── developer.md
│       └── reviewer.md
│
├── .worktrees/                 # В .gitignore, для параллельной работы
│
├── 00_docs/
│   ├── specs/
│   └── architecture/
│
├── 01_tasks/
│   └── 001_feature/
│       ├── objective.md        # Coordinator: ЧТО + acceptance criteria
│       ├── analysis.md         # Analyst: КАК + технические критерии
│       ├── implementation.md   # Developer: отчет о выполнении
│       └── review.md           # Reviewer: результаты проверки
│
├── 02_src/
├── 03_data/                    # В .gitignore
└── 04_logs/                    # В .gitignore
```

**Ключевые решения:**
- Нумерация папок сохранена: 00_, 01_, 02_, 03_, 04_
- `.agents/` - скрытая папка для служебных файлов
- `.bare/` НЕ используется (избыточное усложнение)
- `.worktrees/` в .gitignore
- `.agents/workflow.md` НЕ нужен - каждая роль имеет свой файл описания

---

## 3. Структура файлов задачи

### Файлы в 01_tasks/NNN_name/

**objective.md** (создает Coordinator)
- ЧТО нужно сделать (бизнес-цель)
- ЗАЧЕМ это нужно
- Acceptance criteria (критерии приемки)
- 30-50 строк

**analysis.md** (создает Analyst)
- КАК делать (детальный план)
- Технические требования
- Технические критерии приемки
- Может быть 200-400 строк
- Может требовать несколько сессий для создания

**implementation.md** (создает Developer)
- Что сделано
- Пути к файлам
- Результаты тестов
- Вопросы/риски

**review.md** (создает Reviewer)
- Результаты проверки
- Соответствие критериям из objective.md + analysis.md
- Вердикт: принять/вернуть на доработку

### Принцип минимизации контекста

**Coordinator читает:**
- objective.md (создает)
- review.md (при приемке)

**Analyst читает:**
- objective.md
- analysis.md (создает/обновляет)

**Developer читает:**
- objective.md (кратко - ЧТО)
- analysis.md (детально - КАК)
- implementation.md (создает)

**Reviewer читает:**
- objective.md
- analysis.md
- Код (выборочно)
- НЕ читает: implementation.md (для чистого контекста)

---

## 4. Критерии приемки

**Решение:** Analyst создает критерии приемки в рамках analysis.md

**НЕ делаем:** Разделение на business/technical acceptance (будет размываться на практике)

**Что включает analysis.md:**
- Детальный план реализации
- Технические требования
- Критерии приемки (checklist для Reviewer)
- Примеры кода/алгоритмов

---

## 5. Worktree

**Назначение:** Параллельная работа над РАЗНЫМИ задачами

**Структура:**
```
.worktrees/
├── main/              # Основная ветка
├── task-001/          # Агент работает над задачей 001
└── task-002/          # Другой агент параллельно над задачей 002
```

**Команды:**
```bash
# Создать worktree
git worktree add .worktrees/task-001 -b task-001

# Удалить worktree
git worktree remove .worktrees/task-001
```

**Важно:**
- `.worktrees/` в .gitignore
- `.bare/` НЕ используется
- Файлы задач (01_tasks/) общие для всех worktree (в git history)

---

## 6. AGENTS.md

**Назначение:** Практический справочник специфики ЭТОГО проекта

**Содержание:**
- 2-3 предложения о проекте
- Специфика проекта (Split Architecture, какие API, особенности)
- Структура папок (краткая)
- Примеры кода (ссылки на reference implementation)
- Boundaries (что всегда OK, что требует разрешения, что запрещено)

**НЕ включать:**
- Очевидные вещи типа "как запустить venv"
- Учебник по Python/JavaScript
- Детальный workflow (это в описаниях ролей)

**Пример структуры:**
```markdown
# Project: [Name]

[2-3 sentences about what this project does]

## This Project Uses
- Split Architecture (UI Service + Worker Job)
- Gemini REST API (NOT SDK)
- Google Sheets for data

## Project Structure
- 00_docs/ - specs and architecture
- 01_tasks/ - task tracking
- 02_src/ - source code

## Code Examples
- Reference: 02_src/example_module/

## Boundaries
**Always OK:** read files, run single tests, format code
**Ask first:** pip install, git push, full test suite
**Never:** modify outside 02_src/ and 01_tasks/, hardcode secrets
```

---

## 7. Описание ролей (.agents/roles/*.md)

### Формат каждой роли

```markdown
# [Role Name]

## WHO
[Краткое описание роли, одно предложение]

## WHAT
[Что делает, список основных функций]

## WHAT NOT
[Что НЕ делает, ограничения]

## READS
[Какие файлы читает]

## WRITES
[Какие файлы создает/обновляет]

## WORKFLOW
[Пошаговый процесс работы]

## INTERACTS WITH
[С кем взаимодействует]
```

**Детализация:** ~50-80 строк на роль
**Язык:** (ТРЕБУЕТСЯ УТОЧНЕНИЕ - английский или русский)

### Что НЕ включать

- Промпты для запуска агента
- Детали конкретных папок/файлов (есть в AGENTS.md)
- Дублирование информации из других ролей
- Очевидные вещи ("агент умеет читать файлы")

---

## 8. Итерации внутри задачи

**Решение:** (ТРЕБУЕТСЯ УТОЧНЕНИЕ)

**Варианты обсуждались:**
- Вариант A: objective_v1.md, objective_v2.md
- Вариант B: objective.md (перезапись) + history.md (лог изменений)
- Вариант C: Версии в git commits

**Текущий статус:** Вопрос открыт

---

## 9. Референсы

**Использованные материалы:**
- https://www.anthropic.com/engineering/claude-code-best-practices
- https://code.claude.com/docs/en/skills
- https://agents.md/
- https://github.com/AlexGladkov/claude-code-agents/blob/main/kotlin/system-analytics.md

**Skills:**
- Папка `.agents/skills/` создается, но пока пустая
- Skills будут добавляться позже, это отдельная задача

---

## 10. Что нужно создать

### Минимально необходимые файлы шаблона:

1. **Структура папок:**
   - .agents/roles/
   - .worktrees/ (пустая, в .gitignore)
   - 00_docs/specs/, 00_docs/architecture/
   - 01_tasks/
   - 02_src/
   - 03_data/ (пустая, в .gitignore)
   - 04_logs/ (пустая, в .gitignore)

2. **Файлы в корне:**
   - README.md (для людей, описание шаблона)
   - AGENTS.md (шаблон с плейсхолдерами)
   - .gitignore

3. **Описания ролей:**
   - .agents/roles/coordinator.md
   - .agents/roles/analyst.md
   - .agents/roles/developer.md
   - .agents/roles/reviewer.md

4. **Шаблоны файлов задач:** (опционально)
   - templates/objective.md
   - templates/analysis.md
   - templates/implementation.md
   - templates/review.md

---

## 11. Открытые вопросы

1. **Язык описания ролей:** Английский или русский?
2. **Итерации внутри задачи:** Какой подход к версионированию objective.md и analysis.md?
3. **Детализация шаблонов файлов:** Нужны ли шаблоны objective.md, analysis.md и т.д.?
4. **Формат описания ролей:** Утверждение предложенного формата (WHO/WHAT/WHAT NOT/READS/WRITES/WORKFLOW/INTERACTS)

---

## 12. Что НЕ делаем (явно исключено)

- ❌ `.bare/` папка (избыточное усложнение)
- ❌ `.agents/workflow.md` (дублирование, каждая роль имеет свой файл)
- ❌ Разделение acceptance criteria на business/technical (размывается на практике)
- ❌ Skills наполнение (отдельная будущая задача)
- ❌ GitHub repository структура (отдельная будущая задача)
- ❌ Launcher-agent (отдельная будущая задача)
- ❌ Обучающий контент в AGENTS.md (только специфика проекта)

---

## 13. Следующие шаги для агента-исполнителя

1. Утвердить открытые вопросы (раздел 11)
2. Написать 4 файла описания ролей по утвержденному формату
3. Написать AGENTS.md с плейсхолдерами
4. Создать структуру папок
5. Создать .gitignore
6. Создать README.md для шаблона

---

## Контекст из предыдущей работы

**Старые файлы (для справки):**
- `.old/01_agents/roles.md` - старое описание ролей (есть полезное, но много мусора)
- `.old/02_tasks/001_template_task/iteration_001.md` - старый шаблон задачи (детальный)

**Что переиспользовать из старого:**
- Структура: Зона ответственности / Ограничения / Ключевые действия
- Требование отчета разработчика
- Правило эскалации вопросов

**Что выбросить:**
- Промпты внутри описания ролей
- Упоминания конкретных путей к файлам (AI_README.md, policies.md)
- Детали, которые очевидны
- Дублирование workflow
