# -*- coding: utf-8 -*-
"""chat_sentinel — быстрый сторож чата для сессии-ЦЕЛИ remote-bridge.

НЕ pool-вотчер (слово «вотчер» зарезервировано за pool.ps1 watch) — отдельный
локальный сторож: следит за inbox-журналом относительно курсора и будит сессию
за ~2 сек. Первичный канал побудки (резерв — pool wake-note, только в pool-режиме).

ЦЕЛЕ-ЗАВИСИМ: срабатывает только если AGENT_OWNER == текущая цель моста
(state/current-target.txt). Не-цель не будится (чужую сессию не трогаем).
В solo-режиме единственная цель == solo-сессия, поэтому проверка всегда проходит.

Взводится ТОЛЬКО из сессии-цели, фоновой Bash-задачей (run_in_background):

    python <workspace-root>\\.launcher\\pool-bus\\remote-bridge\\tools\\chat_sentinel.py

Срабатывание: печатает СЧЁТЧИК новых записей (контент в вывод не попадает никогда)
и завершается — завершение фоновой задачи будит сессию. После пробуждения:
(1) read_inbox, (2) перевзвести сторож той же командой, (3) работать.

Синглтон «новейший побеждает»: свежий запуск перехватывает lock по pid;
вытесненный экземпляр завершается молча (exit 3), не будя сессию.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridgelib as B  # noqa: E402

# Set by run(); тесты переопределяют напрямую.
CURSOR_PATH = None
LOCK_PATH = None
POLL_S = 2
EXIT_SUPERSEDED = 3

RE_ARM = (r"python <workspace-root>\.launcher\pool-bus\remote-bridge\tools\chat_sentinel.py")
READ = (r"python <workspace-root>\.launcher\pool-bus\remote-bridge\tools\read_inbox.py")


def pending_count() -> int:
    """Непрочитанные записи основного inbox (карантин мимо). Читаем ТОЛЬКО метаданные
    (update_id), не контент; дедуп по update_id."""
    cursor = B.read_json(CURSOR_PATH, {}).get("last_update_id", 0)
    seen: set[int] = set()
    count = 0
    for f in sorted(B.INBOX_DIR.glob("????-??-??.jsonl")):
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            uid = r.get("update_id", 0)
            if uid <= cursor or uid in seen:
                continue
            seen.add(uid)
            count += 1
    return count


def is_current_target() -> bool:
    """True если можно будить эту сессию: AGENT_OWNER не задан ИЛИ равен текущей цели.
    Цель нечитаема (нет state) -> не фильтруем (True), sentinel всё равно полезен."""
    owner = os.environ.get("AGENT_OWNER")
    if not owner:
        return True
    target = B.read_current_target(None)
    if target is None:
        return True
    return owner == target


def main() -> int:
    B.write_json(LOCK_PATH, {"pid": os.getpid(), "ts": time.time()})
    while True:
        # Вытеснение — только если в lock ЧИТАЕМО стоит ЧУЖОЙ pid.
        lock = B.read_json(LOCK_PATH, None)
        if lock and lock.get("pid") not in (None, os.getpid()):
            return EXIT_SUPERSEDED
        if is_current_target():
            n = pending_count()
            if n > 0:
                print(f"CHAT SENTINEL fired: {n} new message(s) from the owner in inbox.")
                print(f"STEP 1 - read: {READ}")
                print(f"STEP 2 - re-arm sentinel (background Bash task): {RE_ARM}")
                print("STEP 3 - handle the message(s), then idle.")
                return 0
        time.sleep(POLL_S)


def run() -> int:
    """Никогда не умирать молча: любая ошибка печатается (будит сессию с диагностикой)."""
    try:
        B.init_instance()
        global CURSOR_PATH, LOCK_PATH
        CURSOR_PATH = B.STATE_DIR / "target-cursor.json"
        LOCK_PATH = B.STATE_DIR / "chat-sentinel.lock"
        return main()
    except Exception as exc:  # noqa: BLE001
        print(f"CHAT SENTINEL ERROR: {type(exc).__name__} - re-arm me")
        return 1


if __name__ == "__main__":
    sys.exit(run())
