# Ответы на вопросы от Analyst

Когда Analyst эскалирует вопросы к Tech Lead при работе с implementation plan.

## Когда Analyst эскалирует к Tech Lead

**Типичные ситуации:**
- Неясность в интерфейсах модулей
- Противоречия в implementation plan
- Нужны детали о стратегии моков
- Вопросы о последовательности реализации

## Формат вопросов от Analyst

Analyst создаст файл `01_tasks/NNN/_questions_tech_lead.md`:

```markdown
# Вопросы к Tech Lead от Analyst

## Контекст

Работаю над задачей: [название]
Создаю analysis для: [модуль/компонент]

## Проблема

[Описание проблемы с implementation plan]

**Где именно:**
- implementation_plan.md: [раздел/итерация]

## Вопрос

[Конкретный вопрос]
```

## Как отвечать

### 1. Прочитай вопрос

```
.agents/tech-lead.md
AGENTS.md
00_docs/standards/common/*
00_docs/standards/tech-lead/*
00_docs/architecture/implementation_plan.md
01_tasks/NNN/_questions_tech_lead.md
```

### 2. Проанализируй проблему

**Если это:**
- Недостающие детали → дополни implementation_plan
- Противоречие → исправь plan
- Архитектурный вопрос → эскалируй к Architect
- Просто уточнение → ответь в _questions файле

### 3. Обнови план если нужно

Если нужно дополнить implementation_plan.md:
- Добавь недостающие интерфейсы
- Уточни стратегию моков
- Детализируй последовательность

### 4. Сформируй промпт для возврата

```markdown
# Ответ для Analyst

## Обновления

[Что обновлено в implementation_plan.md]

## Ответ на вопрос

[Прямой ответ на вопрос Analyst]

## Дополнительный контекст

[Если нужно, дополнительные пояснения]
```

Затем создай промпт:

```
Ты - Analyst (см. .agents/analyst.md).

Прочитай:
- .agents/analyst.md
- AGENTS.md
- 00_docs/standards/common/*
- 00_docs/standards/analyst/*
- 00_docs/architecture/implementation_plan.md (обновлен)
- 01_tasks/NNN/_questions_tech_lead.md (есть ответ)

Tech Lead ответил на вопросы и обновил implementation plan.

Удали _questions_tech_lead.md и продолжи создание analysis.
```

## Примеры

### Пример 1: Недостающий интерфейс

**Вопрос Analyst:**
```markdown
# Вопросы к Tech Lead от Analyst

## Контекст
Работаю над задачей: Реализация PersonalAssistant
Создаю analysis для: PersonalAssistant модуль

## Проблема
В implementation_plan.md описан интерфейс для DataBus → PersonalAssistant,
но не описан обратный интерфейс PersonalAssistant → DataBus.

**Где именно:**
- implementation_plan.md: Iteration 2, Module Interfaces

## Вопрос
Какой интерфейс должен предоставить PersonalAssistant для DataBus?
```

**Ответ Tech Lead:**

1. Обновляет implementation_plan.md, добавляет:

```typescript
interface IContextProvider {
  getCurrentContext(): Promise<Context>;
  subscribeToUpdates(callback: (ctx: Context) => void): Subscription;
}
```

2. Создает ответ и промпт для Analyst

### Пример 2: Противоречие в плане

**Вопрос Analyst:**
```markdown
## Проблема
В Iteration 1 сказано "Module A первым",
в Iteration 2 сказано "Module A зависит от Module B".

Это противоречие - не могу определить порядок.

## Вопрос
Какой правильный порядок реализации?
```

**Ответ Tech Lead:**

1. Исправляет implementation_plan.md
2. Объясняет правильную последовательность
3. Возвращает Analyst для продолжения

## Чеклист перед ответом

- [ ] Проблема действительно в implementation plan
- [ ] Обновил plan если нужно
- [ ] Ответ конкретный и практичный
- [ ] Создан промпт для возврата Analyst
- [ ] Не принял архитектурное решение (это для Architect)
