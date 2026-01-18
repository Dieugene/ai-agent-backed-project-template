# 001_example_module

## Назначение
[Краткое описание назначения модуля - что он делает, зачем нужен]

## Зависимости

### Внешние библиотеки
- `library_name >= X.Y.Z` — назначение
- `another_lib` — назначение

### Внутренние модули
- `002_core_module` — используется для [цель]
- `005_utils` — вспомогательные функции

## API

### Основные функции

#### `function_name(arg1, arg2)`
**Описание:** Краткое описание что делает функция

**Параметры:**
- `arg1` (str): Описание первого параметра
- `arg2` (int, optional): Описание второго параметра. Default: 10

**Возвращает:**
- `ResultType`: Описание возвращаемого значения

**Пример использования:**
```python
result = function_name("test", arg2=20)
print(result)
```

**Исключения:**
- `ValueError`: Когда возникает
- `TypeError`: Когда возникает

---

#### `another_function(data)`
**Описание:** Краткое описание

**Параметры:**
- `data` (dict): Описание

**Возвращает:**
- `bool`: True если успешно, False иначе

**Пример:**
```python
success = another_function({"key": "value"})
```

## Классы

### `ClassName`
**Описание:** Назначение класса

**Атрибуты:**
- `attr1` (str): Описание атрибута
- `attr2` (int): Описание атрибута

**Методы:**
- `method1(param)`: Описание метода
- `method2()`: Описание метода

**Пример:**
```python
obj = ClassName(attr1="value", attr2=42)
result = obj.method1("test")
```

## Конфигурация

### Переменные окружения
- `ENV_VAR_NAME`: Описание переменной, значение по умолчанию

### Конфигурационные файлы
- `config.json`: Описание формата
```json
{
  "key": "value",
  "setting": 123
}
```

## Примеры использования

### Базовый пример
```python
from 03_src.001_example_module import function_name

# Использование
result = function_name("input")
print(result)
```

### Расширенный пример
```python
from 03_src.001_example_module import ClassName

# Создание объекта
obj = ClassName(attr1="test")

# Вызов метода
result = obj.method1("param")

# Обработка результата
if result:
    print("Success")
```

## Тестирование

### Запуск тестов
```bash
# Все тесты модуля
pytest 03_src/001_example_module/tests/

# Конкретный тест
pytest 03_src/001_example_module/tests/test_functions.py::test_function_name
```

### Покрытие
```bash
pytest --cov=03_src.001_example_module 03_src/001_example_module/tests/
```

## Известные ограничения

1. [Ограничение 1, например: "Не работает с файлами > 100 MB"]
2. [Ограничение 2, например: "Требует Python 3.8+"]

## TODO / Будущие улучшения

- [ ] [Улучшение 1]
- [ ] [Улучшение 2]

## История изменений

### v1.1.0 (YYYY-MM-DD)
- Добавлено: [функция/feature]
- Исправлено: [баг]
- Изменено: [breaking change]

### v1.0.0 (YYYY-MM-DD)
- Начальная версия
