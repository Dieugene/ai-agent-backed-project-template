# Worktree Management Skill

Этот skill помогает Architect управлять git worktree для параллельной работы над задачами и экспериментами.

## Назначение

Git worktree позволяет работать над несколькими задачами одновременно в разных директориях, используя один репозиторий. Каждый worktree - отдельная рабочая директория на своей ветке.

## Когда использовать

- **Параллельные задачи:** Работа над задачей 002 пока 001 на review
- **Проверка гипотез:** Тестирование разных подходов к реализации
- **Эксперименты:** Пробные изменения без влияния на main
- **Срочные правки:** Hotfix пока feature в разработке

## Команды

### create - Создать worktree

```bash
# Создать worktree на ветке branch-name
git worktree add .worktrees/branch-name branch-name
```

**Примеры:**
```bash
git worktree add .worktrees/task-002 task-002
git worktree add .worktrees/experiment experiment
git worktree add .worktrees/feature-auth feature-auth
```

**После создания:**
- Сообщи пользователю путь к worktree
- Сформируй промпт для работы в worktree

### list - Список worktree

```bash
git worktree list
```

Покажи пользователю активные worktree с их ветками и статусом.

### status - Статус worktree

```bash
cd .worktrees/NNN_task-name
git status
git log --oneline -5
```

Покажи статус конкретного worktree: есть ли uncommitted изменения, последние коммиты.

### merge - Слияние в main

```bash
# Проверка чистоты worktree
cd .worktrees/branch-name
git status  # Должно быть чисто

# Возврат в main
cd ../..
git checkout main

# Слияние
git merge branch-name

# Если конфликты - разреши их
# git add .
# git commit
```

### remove - Удаление worktree

**Только после успешного merge!**

```bash
# Удаление worktree
git worktree remove .worktrees/branch-name

# Удаление ветки
git branch -d branch-name
```

## Workflow с worktree

### 1. Создание worktree

Architect:
```
Создай worktree experiment на ветке experiment
```

Skill выполняет:
```bash
git worktree add .worktrees/experiment experiment
```

Architect формирует промпт для работы в worktree.

### 2. Работа в worktree

Analyst, Developer, Reviewer работают в worktree как обычно:
- Создают файлы в `01_tasks/NNN_название/`
- Пишут код в `02_src/`
- Коммитят изменения

### 3. Merge после приемки

Architect после приемки:
```bash
cd ../..  # Вернуться в main
git merge experiment
git worktree remove .worktrees/experiment
git branch -d experiment
```

## Naming conventions

**Правило:** Имя директории worktree = имя ветки

**Примеры:**
- `.worktrees/task-002` на ветке `task-002`
- `.worktrees/experiment` на ветке `experiment`
- `.worktrees/feature-auth` на ветке `feature-auth`

## Важные моменты

1. **Один worktree = одна задача/эксперимент**
2. **Коммить регулярно** в worktree ветку
3. **Синхронизация с main:** Периодически мержить main в worktree ветку при долгой работе
4. **Удаление только после merge** успешного
5. **Конфликты:** Разрешать при merge, не откладывать

## Troubleshooting

**Worktree "грязный" при попытке merge:**
```bash
cd .worktrees/branch-name
git add .
git commit -m "Final changes"
```

**Конфликты при merge:**
```bash
git merge branch-name
# Разреши конфликты в файлах
git add .
git commit -m "Merge branch-name: resolved conflicts"
```

**Удаление "застрявшего" worktree:**
```bash
git worktree remove --force .worktrees/branch-name
git branch -D branch-name  # Осторожно! Удаляет ветку принудительно
```
