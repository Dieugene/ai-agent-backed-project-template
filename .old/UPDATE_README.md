# Инструкция по обновлению README.md

Из-за большого размера README.md, некоторые секции нужно обновить вручную.

## Секции для замены

### 1. Секция "Роли агентов" (строки ~90-150)

Заменить на:

```markdown
## Роли агентов

### Architect (Архитектор)
**Когда запускать:**
- Обсуждение архитектуры проекта
- Принятие архитектурных решений (ADR)
- Эскалация от Tech Lead

**Что делает:**
- Создает `00_docs/architecture/overview.md`
- Создает ADR при архитектурных решениях
- **НЕ** управляет backlog, **НЕ** создает задачи, **НЕ** принимает работу

**Файлы:** `.agents/architect.md`

### Tech Lead (Технический лидер)
**Когда запускать:**
- После создания архитектуры Architect
- Приемка работы от Reviewer
- Эскалация от Analyst

**Что делает:**
- Создает `implementation_plan.md` - план реализации
- **Создает и ведет `backlog.md`** - реестр задач
- **Создает `task_brief`** для задач (папки 01_tasks/NNN)
- Определяет порядок разработки модулей
- Проектирует интерфейсы между компонентами
- **Принимает выполненную работу**

**Файлы:** `.agents/tech-lead.md`

### Analyst (Аналитик)
**Когда запускать:**
- После получения промпта от Tech Lead (новая задача)
- После получения промпта от Reviewer (исправления)

**Что делает:**
- Создает детальное техническое задание `analysis_NN.md`
- Описывает КАК реализовать (компоненты, структуры, алгоритмы)
- Эскалирует к Tech Lead (план) или Architect (архитектура)

**Файлы:** `.agents/analyst.md`

### Developer (Разработчик)
**Когда запускать:**
- После получения промпта от Analyst (есть техническое задание)

**Что делает:**
- Пишет код в `02_src/`
- Создает отчет о реализации `implementation_NN.md`
- Эскалирует проблемы к Analyst

**Файлы:** `.agents/developer.md`

### Reviewer (Ревьюер)
**Когда запускать:**
- После получения промпта от Developer (код готов)

**Что делает:**
- Проверяет соответствие коду ТЗ и стандартам
- Создает отчет о проверке `review_NN.md`
- Решает: принять (→ Tech Lead), вернуть Analyst, или эскалировать к Tech Lead

**Файлы:** `.agents/reviewer.md`
```

### 2. Секция "Типичный workflow задачи" (строки ~150-200)

Заменить на:

```markdown
## Типичный workflow задачи

\```
0. Architect создает архитектуру (overview.md, ADR)
   Architect выдает промпт для Tech Lead
   
1. Вы копируете промпт → Tech Lead
   Tech Lead создает implementation_plan.md
   Tech Lead создает backlog.md
   Tech Lead создает первые task_brief
   Tech Lead выдает промпт для Analyst
   
2. Вы копируете промпт → Analyst
   Analyst читает task_brief + implementation_plan
   Analyst создает analysis_01.md
   Analyst выдает промпт для Developer
   
3. Вы копируете промпт → Developer
   Developer пишет код + implementation_01.md
   Developer выдает промпт для Reviewer
   
4. Вы копируете промпт → Reviewer
   Reviewer проверяет код + review_01.md
   
   Варианты:
   
   А) Все ок → Reviewer выдает промпт для Tech Lead (приемка)
      Вы → Tech Lead принимает работу, обновляет backlog
      
   Б) Проблемы реализации → Reviewer выдает промпт для Analyst
      Вы → Analyst создает analysis_02.md
      Вы → Developer исправляет + implementation_02.md
      Вы → Reviewer проверяет + review_02.md
      ... (итерации пока не будет ок)
      
   В) Проблемы постановки → Reviewer выдает промпт для Tech Lead
      Вы → Tech Lead обновляет task_brief_02.md
      Вы → Analyst создает analysis_02.md
      Вы → Developer реализует + implementation_02.md
      ...
      
   Г) Архитектурные проблемы → Reviewer выдает промпт для Tech Lead
      Вы → Tech Lead эскалирует к Architect
      Вы → Architect решает проблему + ADR
      Вы → Tech Lead обновляет task_brief_02.md
      Вы → Analyst обновляет analysis_02.md
      ...
\```
```

### 3. Секция "Быстрый старт" - подсекция "2. Tech Lead" (строки ~18-26)

Изменить с:
```markdown
### 2. Tech Lead создает план реализации

После того как Architect создаст архитектуру:

\```
Architect передает Tech Lead
\```

Tech Lead создает `implementation_plan.md` - план реализации.

### 3. Создание задачи

После того как Tech Lead создаст implementation plan, попросите Architect создать первую задачу:
```

На:
```markdown
### 2. Tech Lead создает план и задачи

После того как Architect создаст архитектуру, передайте промпт от Architect в Tech Lead.

Tech Lead:
- Создает `implementation_plan.md` - план реализации
- Создает `backlog.md` - реестр задач
- Создает первые `task_brief` - постановки задач
- Передает промпт для Analyst

### 3. Analyst создает техническое задание

Скопируйте промпт от Tech Lead и передайте Analyst:
```

## После обновления

Сохраните файл и проверьте что все секции обновлены корректно.
