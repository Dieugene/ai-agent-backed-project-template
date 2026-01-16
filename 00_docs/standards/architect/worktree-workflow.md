# Workflow с Git Worktree

Правила и best practices для работы с worktree в проекте.

## Когда создавать worktree

### ✅ Создавай worktree:

1. **Параллельные задачи**
   - Задача 001 на review, можно начать 002
   - Несколько независимых фич одновременно

2. **Проверка гипотез**
   - Тестирование разных подходов к реализации
   - Сравнение алгоритмов

3. **Срочные правки**
   - Hotfix пока feature в разработке
   - Критичный баг при работе над feature

4. **Эксперименты**
   - Пробные изменения без риска для main
   - Proof of concept

### ❌ НЕ создавай worktree:

- Для последовательной работы (просто работай в main)
- Для мелких правок (commit в текущую ветку)
- "На всякий случай" без конкретной цели

## Naming conventions

**Задачи:**
- Папка worktree: `.worktrees/NNN_task-name`
- Ветка: `task-NNN`
- Пример: `.worktrees/002_api-integration` → ветка `task-002`

**Эксперименты:**
- Папка worktree: `.worktrees/experiment-name`
- Ветка: `experiment-name`
- Пример: `.worktrees/experiment-caching` → ветка `experiment-caching`

## Жизненный цикл worktree

### 1. Создание

**Architect создает через skill:**
```
Создай worktree для задачи 002_api-integration
```

**Skill выполняет:**
- Создает worktree в `.worktrees/002_api-integration`
- Создает ветку `task-002`
- Копирует `task_brief_01.md` в worktree (если задача)

### 2. Работа

**В worktree работают как обычно:**
- Analyst → Developer → Reviewer
- Коммиты в ветку `task-002`
- Регулярные коммиты (не реже раза в сессию)

### 3. Синхронизация (для долгих задач)

**Если задача длится >3 дней:**
```bash
cd .worktrees/002_api-integration
git merge main  # Подтянуть изменения из main
# Разрешить конфликты если есть
git add .
git commit -m "Merge main into task-002"
```

### 4. Приемка и merge

**После review и приемки:**
```bash
# В worktree: убедиться что все чисто
cd .worktrees/002_api-integration
git status  # Должно быть: nothing to commit, working tree clean

# Вернуться в main
cd ../..
git checkout main

# Слить
git merge task-002

# При конфликтах - разрешить
```

### 5. Удаление

**Только после успешного merge:**
```bash
git worktree remove .worktrees/002_api-integration
git branch -d task-002
```

## Best practices

### Регулярные коммиты

❌ **Плохо:**
```
# Работа 3 дня без коммитов
# Потом один гигантский коммит
```

✅ **Хорошо:**
```
# Analyst завершил - коммит
# Developer реализовал компонент - коммит
# Developer завершил - коммит
# Reviewer завершил - коммит
```

### Описательные коммиты в worktree

```bash
git commit -m "task-002: Complete analysis"
git commit -m "task-002: Implement API client"
git commit -m "task-002: Add error handling"
git commit -m "task-002: Pass review"
```

### Синхронизация с main

**Если работаешь >3 дней:**
```bash
# Каждые 2-3 дня
cd .worktrees/NNN_task-name
git merge main
```

**Зачем:** Меньше конфликтов при финальном merge.

### Чистый worktree перед merge

```bash
# Перед merge убедись что нет uncommitted changes
git status  # Должно быть чисто
```

## Разрешение конфликтов

### При merge main → worktree

```bash
cd .worktrees/002_api-integration
git merge main
# CONFLICT in file.py

# Открыть file.py, разрешить конфликты
git add file.py
git commit -m "task-002: Merge main, resolve conflicts"
```

### При merge worktree → main

```bash
git checkout main
git merge task-002
# CONFLICT in file.py

# Открыть file.py, разрешить конфликты
git add file.py
git commit -m "Merge task-002: resolve conflicts"
```

## Troubleshooting

### Забыл закоммитить перед merge

```bash
cd .worktrees/002_api-integration
git add .
git commit -m "task-002: Final changes"
cd ../..
git merge task-002
```

### Worktree "застрял"

```bash
# Принудительное удаление (осторожно!)
git worktree remove --force .worktrees/002_api-integration
git branch -D task-002  # Удаляет ветку даже если не merged
```

### Нужно переключиться между worktree

```bash
# Нельзя использовать git checkout между worktree
# Используй cd:

cd .worktrees/002_api-integration  # Работа в worktree
cd ../..                           # Возврат в main
cd .worktrees/003_feature          # Другой worktree
```

## Архитектурные решения в worktree

**Если в worktree нужен ADR:**

1. Создай ADR в worktree
2. После merge ADR попадет в main
3. Другие worktree синхронизируют через `git merge main`

**Если ADR нужен для нескольких worktree:**

1. Создай ADR в main (не в worktree)
2. Все worktree подтянут через `git merge main`
