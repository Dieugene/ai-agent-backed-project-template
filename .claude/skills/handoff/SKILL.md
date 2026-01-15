---
name: handoff
description: >
  Формирование промпта для передачи задачи другому агенту (Analyst, Developer, Reviewer).
  Используй когда Architect передает задачу, когда нужен промпт для запуска агента,
  при упоминании "передать", "запустить агента", "handoff", "transition".
---

# Handoff Skill

Когда агент передает задачу другому агенту, создай короткий промпт для копирования.

## Формат промпта

```
Ты — агент [Role] (см. .agents/roles/[role].md).

Прочитай:
- .agents/roles/[role].md
- [базовый файл 1]
- [базовый файл 2]
- [файл с задачей]

Задача: [Краткая формулировка - что сделать и где]

После завершения сообщи [Кому].
```

## Правила

- **НЕ дублируй** содержимое файлов в промпте
- **Только:** роль + список файлов + краткая задача
- **Объем:** 5-7 строк
- **Формат:** Положи в markdown блок (```) для удобного копирования

## Примеры

### Передача Analyst для анализа

```
Ты — агент Analyst (см. .agents/roles/analyst.md).

Прочитай:
- .agents/roles/analyst.md
- AGENTS.md
- 00_docs/architecture/overview.md
- 00_docs/standards.md
- 01_tasks/003_feature/task_brief_01.md

Задача: Создай детальный технический план в 01_tasks/003_feature/analysis_01.md

После завершения сообщи Architect.
```

### Передача Analyst для повторной итерации

```
Ты — агент Analyst (см. .agents/roles/analyst.md).

Прочитай:
- .agents/roles/analyst.md
- 01_tasks/003_feature/task_brief_02.md
- 01_tasks/003_feature/review.md
- 01_tasks/003_feature/analysis_01.md

Задача: Обнови технический план с учетом замечаний в 01_tasks/003_feature/analysis_02.md

После завершения сообщи Architect.
```
