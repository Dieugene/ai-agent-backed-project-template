# Изменения для ветки specified (с Tech Lead)

## Ключевое отличие от ветки iterative

**Ветка iterative:**
```
Architect → Analyst → Developer → Reviewer → Architect
```
Architect управляет всем: архитектура, backlog, задачи, приемка.

**Ветка specified:**
```
Architect → Tech Lead → Analyst → Developer → Reviewer → Tech Lead
```
Разделение ответственности:
- **Architect:** архитектура системы, ADR
- **Tech Lead:** план реализации, backlog, задачи, приемка

## Новая структура ответственности

### Architect
- Обсуждает архитектуру с пользователем
- Создает `overview.md`, ADR
- Принимает архитектурные решения при эскалации
- **НЕ** управляет backlog
- **НЕ** создает задачи
- **НЕ** принимает работу

### Tech Lead
- Получает архитектуру от Architect
- Создает `implementation_plan.md`
- **Создает и ведет `backlog.md`**
- **Создает `task_brief`** (папки 01_tasks/NNN)
- **Принимает работу** от Reviewer
- Может быть несколько Tech Lead агентов параллельно

### Analyst
- Получает постановку от **Tech Lead** (не Architect)
- Эскалация: Tech Lead для плана, Architect для архитектуры

### Developer
- Без изменений

### Reviewer
- Передает **Tech Lead** для приемки (не Architect)
- Эскалация к **Tech Lead** (не Architect)

## Workflow

```
1. Пользователь → Architect
   Architect создает overview.md, ADR
   
2. Architect → Tech Lead
   Tech Lead создает implementation_plan.md
   Tech Lead создает backlog.md
   Tech Lead создает первые task_brief
   
3. Tech Lead → Analyst
   Analyst создает analysis.md
   
4. Analyst → Developer → Reviewer
   
5. Reviewer → Tech Lead (приемка)
   Tech Lead обновляет backlog
```

## Цепочка эскалации

```
Analyst/Developer → Tech Lead → Architect
```

**Analyst может эскалировать:**
- К Tech Lead: вопросы по implementation plan, интерфейсам, мокам
- К Architect: архитектурные решения, ADR

**Tech Lead может эскалировать:**
- К Architect: противоречия в архитектуре, архитектурные решения

## Созданные файлы

### Роль Tech Lead
1. `.agents/tech-lead.md` - описание роли
2. `00_docs/standards/tech-lead/implementation-plan-template.md` - шаблон плана
3. `00_docs/standards/tech-lead/escalation-to-architect.md` - эскалация к Architect
4. `00_docs/standards/tech-lead/escalation-from-analyst.md` - ответы на вопросы Analyst

## Обновленные файлы

### Роли агентов
1. `.agents/architect.md` - убраны backlog, создание задач, приемка; только архитектура и ADR
2. `.agents/tech-lead.md` - добавлены backlog, создание задач, приемка
3. `.agents/analyst.md` - получает от Tech Lead, эскалация к Tech Lead и Architect
4. `.agents/reviewer.md` - передает Tech Lead, эскалация к Tech Lead

### Документация
5. `README.md` - обновлен workflow с Tech Lead
6. `AGENTS.md` - обновлены описания ролей
7. `00_docs/standards/common/structure.md` - обновлена структура

## Управление backlog

**Tech Lead полностью владеет backlog.md:**
- Создает при первом запуске
- Добавляет задачи
- Обновляет статусы
- Нумерация задач: 001, 002, 003...

**Architect не работает с backlog:**
- Не создает
- Не обновляет
- Не читает

## Итерации доработки

**Решает пользователь в зависимости от объема:**

**Мелкие правки (bugs, недочеты):**
```
Reviewer → Analyst (обновить analysis_02.md)
```

**Проблемы постановки:**
```
Reviewer → Tech Lead → Analyst
Tech Lead обновляет task_brief_02.md
```

**Архитектурные проблемы:**
```
Reviewer → Tech Lead → Architect → Tech Lead → Analyst
```

## Множественные Tech Lead

**Может быть несколько Tech Lead агентов:**
- Каждый работает над своей частью implementation_plan
- Каждый создает свои задачи
- Каждый принимает свои задачи
- Координация через пользователя

## Файлы в 00_docs/architecture/

**От Architect:**
- `overview.md` - архитектура системы
- `decision_NNN_*.md` - ADR

**От Tech Lead:**
- `implementation_plan.md` - план реализации
- Может создавать дополнительные файлы рядом с архитектурными

## Преимущества specified над iterative

1. **Четкое разделение уровней:**
   - Architect = стратегия
   - Tech Lead = тактика
   - Analyst = детали

2. **Более детальные постановки:**
   - Tech Lead включает контракты/интерфейсы в task_brief
   - Analyst работает с четкими интерфейсами

3. **Планирование реализации:**
   - Порядок модулей продуман заранее
   - Стратегия моков определена
   - Зависимости учтены

4. **Правильная эскалация:**
   - Analyst → Tech Lead (план)
   - Tech Lead → Architect (архитектура)
   - Каждый на своем уровне
