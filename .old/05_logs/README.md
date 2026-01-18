# 05_logs — Логи запусков

## Назначение
Лог-файлы, диагностические отчеты, метаданные о запусках пайплайна.

## Ответственный
**Разработчик**

## Структура

```
05_logs/
├── run_20251216_143000/        # Каждый запуск в отдельной папке
│   ├── run.log                  # Основной текстовый лог
│   ├── metadata.json            # Метаданные запуска
│   ├── usage.json               # Usage статистика (API calls, tokens)
│   └── errors.log               # Лог ошибок (опционально)
├── run_20251216_150030/
│   ├── run.log
│   ├── metadata.json
│   └── usage.json
└── README.md
```

## Правила именования

### Папки запусков
- **Формат:** `run_YYYYMMDD_HHMMSS/`
- **Пример:** `run_20251216_143000/` = 16 декабря 2025, 14:30:00
- Папка создается автоматически при каждом запуске

### Специальные папки (опционально)
- `run_<label>_<timestamp>/` — для именованных прогонов
- **Пример:** `run_tables_full_20251216_143000/`

## Что хранится

### 1. Текстовые логи (.log)
**Основной лог (`run.log`):**
- Все этапы выполнения пайплайна
- Временные метки каждого шага
- Информационные сообщения
- Warnings
- Пути к созданным артефактам

**Формат записи:**
```
2025-12-16 14:30:00,123 | INFO | Starting PDF processing
2025-12-16 14:30:01,456 | INFO | Rendered 10 pages to 04_data/pages/
2025-12-16 14:30:15,789 | WARNING | Page 5 has low quality
2025-12-16 14:30:30,012 | INFO | Completed successfully
```

**Лог ошибок (`errors.log`, опционально):**
- Только ERROR и CRITICAL уровни
- Stack traces
- Диагностическая информация

### 2. Метаданные (metadata.json)
**Что включать:**
```json
{
  "run_id": "run_20251216_143000",
  "timestamp_start": "2025-12-16T14:30:00",
  "timestamp_end": "2025-12-16T14:35:30",
  "duration_seconds": 330,
  "command": "python 03_src/001_cli/main.py input.pdf",
  "arguments": {
    "input_file": "input.pdf",
    "limit_pages": 10
  },
  "environment": {
    "python_version": "3.10.5",
    "os": "Linux",
    "hostname": "dev-machine"
  },
  "versions": {
    "pipeline": "1.2.0",
    "triage": "0.4.0",
    "extraction": "0.5.0"
  },
  "status": "success",
  "artifacts": {
    "data": ["04_data/output/results.json"],
    "logs": ["05_logs/run_20251216_143000/run.log"]
  }
}
```

### 3. Usage статистика (usage.json)
**Для отслеживания использования внешних API:**
```json
{
  "run_id": "run_20251216_143000",
  "api_calls": [
    {
      "timestamp": "2025-12-16T14:30:05",
      "api": "gemini",
      "endpoint": "/v1beta/models/gemini-2.5-flash:generateContent",
      "model": "gemini-2.5-flash",
      "tokens": {
        "prompt": 1250,
        "completion": 850,
        "total": 2100
      },
      "duration_ms": 2340,
      "status": "success"
    },
    {
      "timestamp": "2025-12-16T14:30:10",
      "api": "gemini",
      "model": "gemini-2.5-flash",
      "tokens": {
        "prompt": 1100,
        "completion": 920,
        "total": 2020
      },
      "duration_ms": 2100,
      "status": "success"
    }
  ],
  "summary": {
    "total_calls": 2,
    "total_tokens": 4120,
    "total_duration_ms": 4440,
    "success_count": 2,
    "error_count": 0
  }
}
```

### 4. Диагностические дампы (опционально)
- Дампы проблемных ответов API
- Скриншоты ошибок
- Промежуточные состояния для отладки

**Пример структуры:**
```
05_logs/run_20251216_143000/
├── run.log
├── metadata.json
├── usage.json
├── errors.log
└── dumps/
    ├── api_response_error_001.json
    └── api_response_error_002.json
```

## Что НЕ хранится

- **Результаты обработки данных** → `04_data/`
- **Промежуточные данные** → `04_data/`
- **Исходный код** → `03_src/`
- **Большие файлы** (> 10 MB в логах — признак проблемы)

## Правила

### 1. Не смешивать логи разработки и рабочие логи
- Для ручных заметок использовать `00_docs/`
- В `05_logs/` только автоматически генерируемые логи

### 2. Ссылки на логи в отчетах
- При анализе проблем в `02_tasks/` прикладывать ссылки на конкретный лог
- **Пример:** "См. лог `05_logs/run_20251216_143000/run.log`"

### 3. Формат timestamp
- **Обязательный формат:** `YYYYMMDD_HHMMSS`
- **Пример:** `20251216_143000` = 16 декабря 2025, 14:30:00
- Использовать 24-часовой формат времени

### 4. Уровни логирования
- **DEBUG** — детальная информация для отладки
- **INFO** — общая информация о ходе выполнения
- **WARNING** — предупреждения о потенциальных проблемах
- **ERROR** — ошибки, не прерывающие выполнение
- **CRITICAL** — критические ошибки, прерывающие выполнение

## Очистка старых логов

### Периодическая очистка
```bash
#!/bin/bash
# clean_old_logs.sh

# Удалить логи старше 90 дней
find 05_logs/run_* -type d -mtime +90 -exec rm -rf {} +

# Или архивировать
find 05_logs/run_* -type d -mtime +30 -exec tar -czf {}.tar.gz {} \; -exec rm -rf {} +
```

### Что сохранять
- Логи важных production прогонов
- Логи с ошибками (для анализа)
- Последние N логов (например, 50)

### Что можно удалять
- Успешные логи старше N дней
- Тестовые прогоны
- Дублирующиеся логи

## Git и контроль версий

### .gitignore
```
# Не коммитить логи
05_logs/*
!05_logs/README.md
!05_logs/examples/          # Примеры для документации (опционально)
```

### Исключения
- Примеры логов для документации (маленькие файлы)
- Этот README.md

## Примеры кода

### Python — настройка логирования
```python
import logging
from datetime import datetime
from pathlib import Path

def setup_logging(run_dir: Path):
    """Настройка логирования для запуска."""
    log_file = run_dir / "run.log"

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s | %(levelname)s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
        handlers=[
            logging.FileHandler(log_file, encoding="utf-8"),
            logging.StreamHandler()  # Также в консоль
        ]
    )

    return logging.getLogger(__name__)

# Использование
timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
run_dir = Path(f"05_logs/run_{timestamp}")
run_dir.mkdir(parents=True, exist_ok=True)

logger = setup_logging(run_dir)
logger.info("Starting processing...")
```

### Python — запись метаданных
```python
import json
from datetime import datetime
from pathlib import Path

def save_metadata(run_dir: Path, metadata: dict):
    """Сохранение метаданных запуска."""
    metadata_file = run_dir / "metadata.json"
    with metadata_file.open("w", encoding="utf-8") as f:
        json.dump(metadata, f, ensure_ascii=False, indent=2)

# Использование
metadata = {
    "run_id": f"run_{timestamp}",
    "timestamp_start": datetime.now().isoformat(),
    "command": " ".join(sys.argv),
    "status": "running"
}
save_metadata(run_dir, metadata)
```

### Python — запись usage
```python
import json
from pathlib import Path

class UsageTracker:
    def __init__(self, run_dir: Path):
        self.usage_file = run_dir / "usage.json"
        self.calls = []

    def add_call(self, api: str, model: str, tokens: dict, duration_ms: int):
        """Добавить запись о вызове API."""
        self.calls.append({
            "timestamp": datetime.now().isoformat(),
            "api": api,
            "model": model,
            "tokens": tokens,
            "duration_ms": duration_ms,
            "status": "success"
        })

    def save(self):
        """Сохранить usage в файл."""
        usage_data = {
            "run_id": self.run_id,
            "api_calls": self.calls,
            "summary": {
                "total_calls": len(self.calls),
                "total_tokens": sum(c["tokens"]["total"] for c in self.calls),
                "total_duration_ms": sum(c["duration_ms"] for c in self.calls)
            }
        }
        with self.usage_file.open("w", encoding="utf-8") as f:
            json.dump(usage_data, f, ensure_ascii=False, indent=2)

# Использование
tracker = UsageTracker(run_dir)
tracker.add_call(
    api="gemini",
    model="gemini-2.5-flash",
    tokens={"prompt": 1250, "completion": 850, "total": 2100},
    duration_ms=2340
)
tracker.save()
```

## Анализ логов

### Поиск ошибок
```bash
# Найти все ошибки в логах
grep -r "ERROR\|CRITICAL" 05_logs/run_*/run.log

# Найти логи с определенным паттерном
grep -r "timeout" 05_logs/run_*/run.log
```

### Статистика по usage
```bash
# Суммарное количество токенов за все прогоны
jq -r '.summary.total_tokens' 05_logs/run_*/usage.json | \
  awk '{sum+=$1} END {print "Total tokens:", sum}'
```

## Мониторинг (опционально)

Для production систем рассмотреть:
- Централизованное логирование (ELK Stack, Splunk)
- Алерты на критические ошибки
- Дашборды с метриками usage
- Ротация логов по размеру/времени
