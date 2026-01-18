# Эскалация к Tech Lead

Когда и как Analyst эскалирует вопросы к Tech Lead.

## Когда эскалировать

### ✅ Эскалируй когда:

**1. Неясность в implementation plan**
- Интерфейсы описаны недостаточно детально
- Противоречия между разными частями плана
- Непонятна стратегия моков
- Неясна последовательность реализации модулей

**2. Противоречия в постановке**
- task_brief противоречит implementation_plan
- Acceptance Criteria неясны или противоречивы
- Недостаточно деталей для создания analysis

**3. Вопросы о стратегии реализации**
- Как именно мокировать зависимость
- Какую библиотеку использовать для интерфейса
- Как организовать модули

### ❌ НЕ эскалируй когда:

- Вопрос об архитектуре системы (это к Architect)
- Можешь решить сам на уровне технического задания
- Просто нужно изучить существующий код
- Вопрос о деталях реализации (это твоя зона)

## Как эскалировать

### 1. Создай файл вопросов

```markdown
# Вопросы к Tech Lead от Analyst

## Контекст

Работаю над задачей: [название задачи]
Создаю analysis для: [какой модуль/компонент]

## Проблема

[Конкретное описание проблемы]

**Где обнаружено:**
- task_brief_01.md: [раздел]
- implementation_plan.md: [раздел/итерация]

**Суть проблемы:**
[Детальное описание]

## Вопрос

[Конкретный вопрос к Tech Lead]

## Что мне нужно для продолжения

[Какая информация нужна для создания analysis]
```

Сохрани в: `01_tasks/NNN/_questions_tech_lead.md`

### 2. Сформируй промпт для Tech Lead

```
Ты - Tech Lead (см. .agents/tech-lead.md).

Прочитай:
- .agents/tech-lead.md
- AGENTS.md
- 00_docs/standards/common/*
- 00_docs/standards/tech-lead/*
- 00_docs/architecture/implementation_plan.md
- 01_tasks/NNN/_questions_tech_lead.md

Analyst обнаружил проблему при создании технического задания.
Нужно уточнить implementation plan или task_brief.

После решения обнови план/task_brief и сформируй промпт для возврата Analyst.
```

### 3. Ожидай ответ

Tech Lead:
- Прочитает вопросы
- Обновит implementation_plan или task_brief если нужно
- Ответит в файле `_questions_tech_lead.md`
- Сформирует промпт для возврата

### 4. Продолжи работу

После получения промпта от Tech Lead:
- Прочитай обновленный plan/task_brief
- Прочитай ответ в `_questions_tech_lead.md`
- Удали `_questions_tech_lead.md`
- Продолжи создание analysis

## Примеры эскалации

### Пример 1: Неясный интерфейс

```markdown
# Вопросы к Tech Lead от Analyst

## Контекст

Работаю над задачей: Реализация PersonalAssistant
Создаю analysis для: PersonalAssistant модуль

## Проблема

**Где обнаружено:**
- implementation_plan.md: Iteration 2, Module Interfaces

**Суть проблемы:**
В implementation_plan описан интерфейс IContextProvider, но не указано:
- Формат Context объекта
- Как часто вызывается getCurrentContext()
- Что возвращает в случае отсутствия контекста

## Вопрос

Какая структура Context? Нужна TypeScript interface с полями.

## Что мне нужно для продолжения

Детализация интерфейса IContextProvider с типами и примерами использования.
```

### Пример 2: Противоречие в task_brief

```markdown
# Вопросы к Tech Lead от Analyst

## Контекст

Работаю над задачей: Интеграция с DataBus
Создаю analysis для: подключение к шине данных

## Проблема

**Где обнаружено:**
- task_brief_01.md: Acceptance Criteria
- implementation_plan.md: Iteration 1, Mocking Strategy

**Суть проблемы:**
task_brief требует "подключение к реальной DataBus",
но implementation_plan для Iteration 1 говорит "mock DataBus".

## Вопрос

Какой подход правильный для этой задачи? Реальная шина или мок?

## Что мне нужно для продолжения

Уточнение: использовать мок или реальную интеграцию.
```

### Пример 3: Выбор библиотеки

```markdown
# Вопросы к Tech Lead от Analyst

## Контекст

Работаю над задачей: Визуализация данных
Создаю analysis для: компонент графиков

## Проблема

**Где обнаружено:**
- task_brief_01.md: Контекст
- implementation_plan.md: Iteration 3

**Суть проблемы:**
Нужно выбрать библиотеку для графиков.
В плане упомянуты "современные инструменты визуализации" без конкретики.

## Вопрос

Какую библиотеку использовать? D3.js, Chart.js, Plotly?
Или есть предпочтения из implementation_plan?

## Что мне нужно для продолжения

Конкретная библиотека или критерии выбора.
```

## Формат ответа от Tech Lead

Tech Lead может:

**Вариант A: Обновить implementation_plan**
```markdown
Обновил implementation_plan.md - добавил детали интерфейса IContextProvider.

См. раздел "Iteration 2 - Interfaces".
```

**Вариант B: Обновить task_brief**
```markdown
Обновил task_brief_02.md - уточнил что для этой задачи используем мок DataBus.

AC-2 изменен: "Подключение к mock DataBus".
```

**Вариант C: Ответить в файле**
```markdown
Используй D3.js - она уже используется в проекте для других графиков.

См. 02_src/visualization/ для примеров.
```

И сформирует промпт:

```
Ты - Analyst (см. .agents/analyst.md).

Прочитай:
- .agents/analyst.md
- AGENTS.md
- 00_docs/standards/common/*
- 00_docs/standards/analyst/*
- 00_docs/architecture/implementation_plan.md (обновлен)
- 01_tasks/NNN/_questions_tech_lead.md (есть ответ)

Tech Lead ответил на вопросы [и обновил план/task_brief].

Удали _questions_tech_lead.md и продолжи создание analysis.
```

## Чеклист перед эскалацией

- [ ] Проблема действительно про plan/task_brief
- [ ] Я не могу решить сам на уровне analysis
- [ ] Вопрос конкретный и понятный
- [ ] Указал где именно проблема
- [ ] Указал что мне нужно для продолжения
- [ ] Это не архитектурный вопрос (иначе → Architect)
