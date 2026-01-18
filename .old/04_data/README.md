# 04_data — Рабочие данные

## Назначение
Хранение всех данных, генерируемых в процессе работы проекта.

## Ответственный
**Разработчик** (автоматическая генерация пайплайном)

## Что хранится

- Входные данные (если они не слишком большие)
- Промежуточные результаты обработки
- Выходные данные (JSON, CSV, Excel, изображения и т.д.)
- Индексы, кэши
- Специализированные подпапки для разных типов данных

## Структура (примеры)

Структура внутри `04_data/` **зависит от специфики проекта**. Ниже примеры организации:

### Вариант 1: По типам данных
```
04_data/
├── input/              # Входные данные
│   └── documents/
├── processed/          # Обработанные данные
│   ├── extracted/
│   └── normalized/
├── output/             # Финальные результаты
│   ├── json/
│   └── csv/
└── cache/              # Кэшированные данные
```

### Вариант 2: По источникам
```
04_data/
├── api_responses/      # Ответы от API
├── user_uploads/       # Загрузки пользователей
├── generated/          # Сгенерированные данные
└── exports/            # Экспортированные данные
```

### Вариант 3: По этапам обработки
```
04_data/
├── stage_01_ingestion/     # Этап 1
├── stage_02_processing/    # Этап 2
├── stage_03_validation/    # Этап 3
└── stage_04_output/        # Этап 4
```

### Вариант 4: По документам/сущностям
```
04_data/
├── document_001/
│   ├── pages/
│   ├── tables/
│   └── metadata.json
├── document_002/
│   ├── pages/
│   ├── tables/
│   └── metadata.json
└── index.json
```

## Что НЕ хранится

- **Логи запусков** → `05_logs/`
- **Метаданные запусков** → `05_logs/`
- **Usage статистика** → `05_logs/`
- **Код** → `03_src/`
- **Документация** → `00_docs/`

## Правила

### 1. Не хранить здесь JSON логи
- Если JSON содержит метаданные запуска, usage, диагностику → это в `05_logs/`
- Если JSON содержит результаты обработки данных → это в `04_data/`

### 2. Организация папок
- Создавать подпапки по логике проекта
- Документировать структуру в этом README
- Обновлять `00_docs/AI_README.md` при изменении структуры

### 3. Именование файлов
- Использовать понятные имена
- Включать временные метки при необходимости: `output_20251216.json`
- Избегать пробелов в именах: `my_data.json`, не `my data.json`

### 4. Размер файлов
- Большие файлы (> 100 MB) рассмотреть для Git LFS или отдельного хранилища
- Не коммитить в Git, если файлы генерируются автоматически

## Примеры файлов

### JSON данные
```
04_data/output/results.json
04_data/processed/normalized_table_001.json
```

### CSV/Excel
```
04_data/exports/report_2025Q1.csv
04_data/exports/summary.xlsx
```

### Изображения
```
04_data/pages/document_001/page_001.png
04_data/visualizations/chart_001.png
```

### Бинарные данные
```
04_data/cache/embeddings.pkl
04_data/models/trained_model.bin
```

## Git и контроль версий

### Что коммитить
- Примеры данных для документации (маленькие файлы)
- Тестовые данные (fixtures)
- Этот README.md

### Что НЕ коммитить
- Большие файлы данных
- Генерируемые автоматически файлы
- Конфиденциальные данные

### .gitignore
```
# В корне проекта добавить:
04_data/*
!04_data/README.md
!04_data/examples/          # Если есть примеры для документации
```

## Очистка данных

### Периодическая очистка
- Старые промежуточные файлы можно удалять
- Финальные результаты сохранять или архивировать
- Кэши можно пересоздать

### Скрипт очистки (пример)
```bash
#!/bin/bash
# clean_data.sh

# Удалить файлы старше 30 дней
find 04_data/cache/ -type f -mtime +30 -delete

# Удалить временные файлы
rm -f 04_data/*/temp_*
```

## Резервное копирование

### Важные данные
- Финальные результаты обработки
- Входные данные (если их нельзя получить повторно)
- Индексы и метаданные

### Не требуют бэкапа
- Кэши (можно пересоздать)
- Промежуточные файлы (можно пересоздать)

## Документирование структуры

При изменении организации данных **обязательно обновить:**
1. Этот README.md
2. `00_docs/AI_README.md` (таблица структуры каталогов)
3. `00_docs/policies.md` (если изменились правила)

## Примеры использования в коде

### Python
```python
import json
from pathlib import Path

# Чтение данных
data_path = Path("04_data/input/data.json")
with data_path.open("r", encoding="utf-8") as f:
    data = json.load(f)

# Запись результатов
output_path = Path("04_data/output/results.json")
output_path.parent.mkdir(parents=True, exist_ok=True)
with output_path.open("w", encoding="utf-8") as f:
    json.dump(results, f, ensure_ascii=False, indent=2)
```

### Node.js
```javascript
const fs = require('fs').promises;
const path = require('path');

// Чтение данных
const dataPath = path.join('04_data', 'input', 'data.json');
const data = JSON.parse(await fs.readFile(dataPath, 'utf8'));

// Запись результатов
const outputPath = path.join('04_data', 'output', 'results.json');
await fs.mkdir(path.dirname(outputPath), { recursive: true });
await fs.writeFile(outputPath, JSON.stringify(results, null, 2));
```
