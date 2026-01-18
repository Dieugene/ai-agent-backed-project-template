---
title: Launch AI Agent Project
description: Initialize a new project from ai-agent-backed-project-template
---

# Launch AI Agent Project

This command clones the AI Agent Project Template and sets it up in your workspace.

## Repository
https://github.com/Dieugene/ai-agent-backed-project-template

## Process

1. Ask user about project type
2. Fetch available tags from repository
3. Select latest version tag for chosen branch
4. Clone repository with selected tag
5. Setup project structure
6. Remove .git and launch-project.md
7. Initialize new git repository

---

# Project Type Selection

Прежде чем начать, давайте определим как вы будете работать с проектом:

**Вариант 1: Итеративная разработка (iterative)**
- Вы движетесь по задачам итеративно
- Architect создает задачи по мере необходимости
- Подходит для исследовательских проектов
- Более гибкий подход

**Вариант 2: Системная разработка (specified)**
- Вы готовы описать продукт целиком
- Tech Lead создает детальный план реализации
- Architect фокусируется на архитектуре
- Подходит для системной разработки

Какой подход вам подходит?
1. Итеративная разработка (iterative)
2. Системная разработка (specified)

[Дождитесь ответа пользователя: 1 или 2]

---

После получения ответа выполните следующие действия:

## Step 1: Fetch Tags

```bash
git ls-remote --tags https://github.com/Dieugene/ai-agent-backed-project-template
```

Проанализируйте вывод и найдите последнюю версию для выбранной ветки:
- Если пользователь выбрал iterative: найдите самый новый тег вида `iterative-v1.X` или `iterative-vX.X.X`
- Если пользователь выбрал specified: найдите самый новый тег вида `specified-v1.X` или `specified-vX.X.X`

Сортировка по версиям: v1.2 > v1.1 > v1.0, v1.1.2 > v1.1.1

## Step 2: Clone Repository

```bash
# Замените TAG_NAME на найденный тег
git clone --branch TAG_NAME --depth 1 https://github.com/Dieugene/ai-agent-backed-project-template.git .
```

## Step 3: Remove Git History and Setup Files

```bash
# Удалите .git директорию
rm -rf .git

# Удалите launch-project.md (этот файл)
rm -f .claude/commands/launch-project.md

# Переименуйте .gitignore.template в .gitignore
mv .gitignore.template .gitignore
```

## Step 4: Initialize New Git Repository

```bash
# Инициализируйте новый git репозиторий
git init

# Добавьте все файлы
git add .

# Создайте первый коммит
git commit -m "Initial commit from ai-agent-backed-project-template (TAG_NAME)"
```

## Step 5: Inform User

Сообщите пользователю:

```
✅ Проект успешно инициализирован!

Использован шаблон: TAG_NAME

Следующие шаги:
1. Прочитайте README.md для понимания структуры проекта
2. Изучите AGENTS.md для понимания ролей агентов
3. Запустите Architect для создания архитектуры проекта

Команда для запуска Architect:

Ты — агент Architect (см. .agents/architect.md).

Прочитай:
- .agents/architect.md
- AGENTS.md
- Все файлы из 00_docs/standards/common/
- Все файлы из 00_docs/standards/architect/

Задача: Обсуди со мной проект и создай архитектуру.
```

---

## Error Handling

Если возникнут проблемы:
- Проверьте доступ к интернету
- Убедитесь что git установлен
- Проверьте что текущая директория пуста или готова к клонированию
- Попробуйте выполнить команды вручную
