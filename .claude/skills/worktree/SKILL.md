---
name: worktree
description: >
  Управление git worktree для параллельной работы над задачами. Используй когда 
  пользователь просит создать worktree, работать параллельно над задачами, 
  создать эксперимент, или посмотреть список worktree.
---

# Worktree Management Skill

Этот skill помогает Architect создавать git worktree для параллельной работы над задачами и экспериментами.

## Назначение

Git worktree позволяет работать над несколькими задачами одновременно в разных директориях, используя один репозиторий. Каждый worktree - отдельная рабочая директория на своей ветке.

## Когда использовать

- **Параллельные задачи:** Работа над задачей 002 пока 001 на review
- **Проверка гипотез:** Тестирование разных подходов к реализации
- **Эксперименты:** Пробные изменения без влияния на main
- **Срочные правки:** Hotfix пока feature в разработке

## Команды

### create - Создать worktree

**ВАЖНО: Проверь текущие изменения перед созданием worktree!**

```bash
# 1. Проверь статус
git status
```

**Если есть незакоммиченные изменения:**

Спроси пользователя:
```
Есть незакоммиченные изменения:
[list changes]

Закоммитить их перед созданием worktree? (да/нет)
```

**Если пользователь ответил "да":**
```bash
# 2. Сделать commit
git add .
git commit -m "Work in progress before creating worktree"
```

**Если пользователь ответил "нет":**
Предупреди что незакоммиченные изменения не попадут в worktree.

---

**Создать worktree:**

**Вариант 1 (основной): Имя папки = имя ветки**

Спроси у пользователя только имя ветки/папки:
```
Как назвать ветку и папку worktree? (например: experiment, task-002, feature-auth)
```

Создай worktree:
```bash
# Создаст ветку branch-name и папку .worktrees/branch-name
git worktree add .worktrees/branch-name
```

**Примеры:**
```bash
git worktree add .worktrees/experiment
git worktree add .worktrees/task-002
git worktree add .worktrees/feature-auth
```

**Вариант 2 (если пользователь явно указал разные имена):**

Если пользователь указал "ветка X, папка Y":
```bash
# Создаст ветку branch-name в папке .worktrees/folder-name
git worktree add -b branch-name .worktrees/folder-name
```

**Пример:**
```bash
git worktree add -b experiment-v2 .worktrees/exp2
```

---

**После создания:**
- Сообщи пользователю путь к worktree: `.worktrees/branch-name`
- Сформируй промпт для работы в worktree

### list - Список worktree

```bash
git worktree list
```

Покажи пользователю активные worktree с их ветками и расположением.

## Naming conventions

**Правило по умолчанию:** Имя папки worktree = имя ветки

**Примеры:**
- `.worktrees/task-002` на ветке `task-002`
- `.worktrees/experiment` на ветке `experiment`
- `.worktrees/feature-auth` на ветке `feature-auth`

## Workflow с worktree

### 1. Создание worktree

Пользователь:
```
Создай worktree для эксперимента
```

Architect:
- Проверяет git status
- Спрашивает о коммите если есть изменения
- Спрашивает имя ветки/папки
- Создает worktree: `git worktree add .worktrees/experiment`
- Формирует промпт для работы в worktree

### 2. Работа в worktree

Analyst, Developer, Reviewer работают в worktree как обычно:
- Создают файлы в `01_tasks/NNN_название/`
- Пишут код в `02_src/`
- Коммитят изменения в своей ветке

### 3. После завершения

Пользователь самостоятельно выполняет merge и удаление worktree через git команды.

## Важные моменты

1. **Один worktree = одна задача/эксперимент**
2. **Незакоммиченные изменения** из main не попадут в новый worktree
3. **Всегда проверяй** git status перед созданием
4. **Коммить регулярно** в worktree ветке при работе
