---
name: launch-agent
description: >
  Запуск AI-агента в новом окне терминала для параллельной работы.
  Используй когда нужно запустить architect, techlead, analyst, developer или reviewer
  в отдельной сессии Claude.
---

# Launch Agent Skill

Запускает указанного AI-агента в новом окне терминала с правильным промптом.

## Использование

Когда пользователь просит запустить агента в новом окне, создай команду для PowerShell.

## Доступные роли

- `architect` — Архитектор
- `techlead` — Технический лидер
- `analyst` — Аналитик
- `developer` — Разработчик
- `reviewer` — Ревьюер

## Формат команды

```powershell
powershell -Command "Start-Process cmd -ArgumentList '/k', 'cd /d D:\_workspace\team-assistant && claude \"ПРОМПТ\"'"
```

**Важно:**
- Используй экранированные двойные кавычки `\"` внутри промпта
- Пробелы внутри промпта работают корректно
- Окно останется открытым (`/k`)

## Промпты для разных ролей

### Architect

```
Ты — агент Architect (см. .agents/architect.md).

Прочитай:
- .agents/architect.md
- AGENTS.md
- Все файлы из 00_docs/standards/common/
- Все файлы из 00_docs/standards/architect/
- 00_docs/architecture/overview.md

Задача: Продолжи работу над архитектурой проекта.

Обсуди со мной дальнейшие шаги.
```

### Tech Lead

```
Ты — агент Tech Lead (см. .agents/tech-lead.md).

Прочитай:
- .agents/tech-lead.md
- AGENTS.md
- Все файлы из 00_docs/standards/common/
- Все файлы из 00_docs/standards/tech-lead/
- 00_docs/architecture/overview.md

Задача: Создай план реализации и backlog.

Обсуди со мной следующие шаги.
```

### Analyst

```
Ты — агент Analyst (см. .agents/analyst.md).

Прочитай:
- .agents/analyst.md
- AGENTS.md
- Все файлы из 00_docs/standards/common/
- Все файлы из 00_docs/standards/analyst/
- 00_docs/architecture/overview.md
- [укажи файл задачи]

Задача: Создай детальное техническое задание.

После завершения сообщи Tech Lead.
```

### Developer

```
Ты — агент Developer (см. .agents/developer.md).

Прочитай:
- .agents/developer.md
- AGENTS.md
- Все файлы из 00_docs/standards/common/
- Все файлы из 00_docs/standards/developer/
- [укажи файлы задачи]

Задача: Реализуй задачу согласно техническому заданию.

Создай отчет о реализации.
```

### Reviewer

```
Ты — агент Reviewer (см. .agents/reviewer.md).

Прочитай:
- .agents/reviewer.md
- AGENTS.md
- Все файлы из 00_docs/standards/common/
- Все файлы из 00_docs/standards/reviewer/
- [укажи файлы задачи]

Задача: Проверь реализацию на соответствие ТЗ и стандартам.

Создай отчет о проверке.
```

## Пример использования

**Запрос пользователя:**
> Запусти мне архитектора в новом окне

**Ответ:**
Вот команда для запуска Architect в новом окне:

```powershell
powershell -Command "Start-Process cmd -ArgumentList '/k', 'cd /d D:\_workspace\team-assistant && claude \"Ты — агент Architect (см. .agents/architect.md). Прочитай: .agents/architect.md, AGENTS.md, Все файлы из 00_docs/standards/common/, Все файлы из 00_docs/standards/architect/, 00_docs/architecture/overview.md. Задача: Продолжи работу над архитектурой проекта. Обсуди со мной дальнейшие шаги.\"'"
```

Скопируйте и выполните эту команду в PowerShell или командной строке.
