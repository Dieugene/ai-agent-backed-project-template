# -*- coding: utf-8 -*-
"""chat_sentinel — быстрый сторож чата для сессии-ЦЕЛИ remote-bridge.

НЕ pool-вотчер (слово «вотчер» зарезервировано за pool.ps1 watch) — отдельный
локальный сторож: следит за inbox-журналом относительно курсора и будит сессию
за ~2 сек. Первичный канал побудки (резерв — pool wake-note, только в pool-режиме).

ЦЕЛЕ-ЗАВИСИМ: срабатывает только если AGENT_OWNER == текущая цель моста
(state/current-target.txt). Не-цель не будится (чужую сессию не трогаем).
В solo-режиме единственная цель == solo-сессия, поэтому проверка всегда проходит.

Взводится ТОЛЬКО из сессии-цели, фоновой Bash-задачей (run_in_background):

    python D:\\_workspace\\.launcher\\pool-bus\\remote-bridge\\tools\\chat_sentinel.py

Срабатывание: печатает СЧЁТЧИК новых записей (контент в вывод не попадает никогда)
и завершается — завершение фоновой задачи будит сессию. После пробуждения:
(1) read_inbox, (2) перевзвести сторож той же командой, (3) работать.

КАК ЧИТАТЬ ВЫВОД ПРИ ПОБУДКЕ (замерено 2026-07-28, не гипотеза):

    ПУСТО                    — задачу снял ХАРНЕСС. Он делает это произвольно,
                               таймаута нет (наблюдались 2.8 / 9.3 / 73 / 117 /
                               337 мин). Сообщений НЕ приходило, ничего не
                               сломано: перевзвести и работать дальше.
    CHAT SENTINEL fired      — сообщения есть, дальше по шагам в самом выводе.
    CHAT SENTINEL superseded — уже работает более новый сторож. НЕ перевзводить.
    CHAT SENTINEL ERROR      — чинить по тексту ошибки, затем перевзвести.

Почему пусто, а не «я жив»: буфер stdout при убийстве процесса теряется целиком
(проверено опытом), поэтому строка, напечатанная при взводе, до агента НЕ доедет.
Пустота — единственный надёжный признак убийства, и однозначна она ровно потому,
что все ОСТАЛЬНЫЕ исходы говорят о себе вслух.

Взводить фоновую задачу С ОПИСАНИЕМ (`description` Bash-тула попадает в текст
побудки ДОСЛОВНО и при убийстве остаётся единственным, что дойдёт до агента):

    chat sentinel idle-wait: EMPTY output = harness stopped it, nothing arrived,
    just re-arm; any printed line says what to do

Синглтон «новейший побеждает»: свежий запуск перехватывает lock по pid;
вытесненный экземпляр выходит кодом 3 и ГОВОРИТ об этом. Молчать он не может:
завершение фоновой задачи будит сессию в любом случае, а молчание делало
вытеснение неотличимым от снятия харнессом — агент перевзводил сторож, убивая
живого, и цикл не кончался.
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
CFG: dict = {}   # конфиг инстанса; нужен pending_count для фильтра адресной ленты
POLL_S = 2
EXIT_SUPERSEDED = 3

RE_ARM = (r"python C:\workspace-root\.launcher\pool-bus\remote-bridge\tools\chat_sentinel.py")
READ = (r"python C:\workspace-root\.launcher\pool-bus\remote-bridge\tools\read_inbox.py")
# Описание фоновой задачи ДОСЛОВНО попадает в текст побудки; при убийстве харнессом
# stdout теряется, и эта строка остаётся ЕДИНСТВЕННЫМ, что доедет до агента. Печатаем
# её вместе с командой перевзвода, чтобы предписание распространялось само.
RE_ARM_DESC = ("chat sentinel idle-wait: EMPTY output = harness stopped it, nothing "
               "arrived, just re-arm; any printed line says what to do")


def pending_count() -> int:
    """Непрочитанные записи основного inbox (карантин мимо). Читаем ТОЛЬКО метаданные
    (update_id), не контент; дедуп по update_id.

    При включённой адресной ленте считаем ТОЛЬКО свои: иначе счётчик и читатель
    расфазируются — «unread=23», а `read_inbox` отвечает «новых нет», и монитор повторяет
    объявление каждые REPEAT_S, жгя лимиты."""
    cursor = B.read_json(CURSOR_PATH, {}).get("last_update_id", 0)
    owner = B.reader_owner()
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
            if not B.rec_visible_to(r, CFG, owner):
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


def shutdown_quiet() -> bool:
    """True, если роль сейчас гасится: в шине лежит её intent-метка.

    Под меткой сторож МОЛЧИТ — то же правило, что у вотчера шины (`Test-ShutdownQuiet` в pool.ps1).
    Требование владельца: с момента начала гашения ничего не вбрасывать, пока идёт handoff.
    Метку ставит контроллер ПОСЛЕ отправки задачи завершения и снимает перед убийством; если гашение
    прервали, метку чистит запуск пула. Сам мост ходит мимо шины, но сторож живёт ВНУТРИ роли и знает
    оба нужных значения из её окружения, поэтому здесь фильтр возможен, а в мосту — нет.
    Нет любого из значений (не pool-режим) -> не фильтруем: одиночному мосту карантин неоткуда взять.
    """
    owner = os.environ.get("AGENT_OWNER")
    bus = os.environ.get("POOL_BUS_ROOT")
    if not owner or not bus:
        return False
    try:
        return (Path(bus) / ".control" / f"shutdown-intent-{owner}").exists()
    except OSError:
        return False


def main() -> int:
    B.write_json(LOCK_PATH, {"pid": os.getpid(), "ts": time.time()})
    while True:
        # Вытеснение — только если в lock ЧИТАЕМО стоит ЧУЖОЙ pid.
        lock = B.read_json(LOCK_PATH, None)
        if lock and lock.get("pid") not in (None, os.getpid()):
            # ГОВОРИМ, а не молчим. Прежнее молчание не спасало от побудки (завершение
            # фоновой задачи будит сессию в любом случае), зато делало вытеснение
            # неотличимым от снятия харнессом: агент видел пустоту, перевзводил сторож,
            # убивал живого — и цикл не кончался.
            print("CHAT SENTINEL superseded: a newer sentinel already holds the lock. "
                  "NO messages arrived. Do NOT re-arm.", flush=True)
            return EXIT_SUPERSEDED
        # Карантин гашения: пока стоит метка, не читаем и не печатаем — печать здесь и есть побудка.
        if shutdown_quiet():
            time.sleep(POLL_S)
            continue
        if is_current_target():
            n = pending_count()
            if n > 0:
                print(f"CHAT SENTINEL fired: {n} new message(s) from the owner in inbox.")
                print(f"STEP 1 - read: {READ}")
                print(f"STEP 2 - re-arm sentinel (background Bash task): {RE_ARM}")
                print(f"         with description: {RE_ARM_DESC}")
                print("STEP 3 - handle the message(s), then idle.")
                return 0
        time.sleep(POLL_S)


def run() -> int:
    """Никогда не умирать молча: любая ошибка печатается (будит сессию с диагностикой)."""
    try:
        cfg, _ = B.init_instance()
        global CURSOR_PATH, LOCK_PATH, CFG
        CFG = cfg
        # Путь курсора — ТОЛЬКО через общий хелпер: при адресной ленте он свой у каждой роли,
        # и разъехавшиеся счётчик со читателем дают либо вечное «непрочитано», либо слепоту.
        CURSOR_PATH = B.cursor_path(cfg, B.reader_owner())
        LOCK_PATH = B.STATE_DIR / "chat-sentinel.lock"
        return main()
    except Exception as exc:  # noqa: BLE001
        # Печатаем и ТИП, и ТЕКСТ ошибки: сообщения путей/конфига токен-безопасны
        # (токен живёт только в API-вызовах bridge.py, не на этом пути). Голый
        # "re-arm me" маскировал корень (напр. отсутствие REMOTE_BRIDGE_PROJECT_DIR).
        print(f"CHAT SENTINEL ERROR: {type(exc).__name__}: {exc} -- fix, then re-arm")
        return 1


if __name__ == "__main__":
    sys.exit(run())
