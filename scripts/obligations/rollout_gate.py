#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сторож замера: считает накопление на боевом пуле и напоминает, когда мерить итоги.

    python3 rollout_gate.py [--check] [--force]

Зачем: замер «через несколько дней» без условия не делается никогда — забывается. Здесь условие
записано числом, проверяется машиной, и при достижении кладёт письмо супервайзору сервера.

## Откуда взяты пороги (не выдуманы — посчитаны)

**Когда мерить: 300 ролевых писем после внедрения.** Темп пула — 88 писем в сутки (4239 писем
за 48 дней, замер 31.08). Стенду хватило 35 писем, чтобы сравнение было содержательным; 300 —
почти на порядок больше, то есть случайность исключена. По времени это около трёх с половиной
суток, но условие не по времени: простаивает пул — мерить нечего, и замер честно подождёт.

**Порог 1: доля ролевых писем с полем обязательства ≥ 30%.** База «до» по этому же пулу
(приложение Б спецификации, 3013 отправок): открытие обязательства выражалось прозой в 30%
писем. Значит каждое такое письмо теперь обязано нести поле. Ниже 30% — роли не переучились.
Цель — 60%: столько писем (63%) несли обязательственный смысл хоть в каком-то виде.

**Порог 2: закрытий, поставленных ждущим, ≥ 80%.** Правило «закрывает тот, кто ждал» исключений
не имеет, поэтому мерить надо близость к сотне. На стенде ДО механики было 3 из 10 (30%),
с механикой — 4 из 4. Восемьдесят процентов = не более одного нарушения из пяти: ниже этого
норма не работает, а не «иногда нарушается».

**Порог 3: событий `close` больше нуля.** Тихое закрытие — прямой заказ владельца ради экономии
хода. Ноль событий означает, что роли продолжают закрывать письмом, и экономия не состоялась.
"""

import glob
import json
import os
import re
import subprocess
import sys

BUS = os.environ.get("ROLLOUT_GATE_BUS", "<workspace-root>/pool-A/.bus")
SINCE_MS = int(os.environ.get("ROLLOUT_GATE_SINCE_MS", "1788174549998"))          # первое письмо онбординга, 31.08.2026 ~15:09 MSK
NEED_LETTERS = 300
TO = os.environ.get("ROLLOUT_GATE_TO", "<supervisor-role>")
NOTIFY_BUS = os.environ.get("ROLLOUT_GATE_NOTIFY_BUS", "<workspace-root>/pool-B-2/.bus")   # шина, где у адресата есть ящик
STATE = os.path.expanduser("~/.shop/rollout-gate.json")
MSG_RE = re.compile(r"^(\d{13})-[0-9a-f]{10}\.from-([^.]+)\.([^.]+?)(\.\d+\.\d+)?\.md$")
SERVICE = ("pool-monitor", "pool-controller", "system", "migration")


def count_since():
    """Ролевые письма после внедрения. События реестра не письма — их не считаем."""
    n, events = 0, 0
    paths = (glob.glob(os.path.join(BUS, "*", "new", "*.md")) +
             glob.glob(os.path.join(BUS, "*", "cur", "*.md")) +
             glob.glob(os.path.join(BUS, "archive", "*.md")))
    seen = set()
    for p in paths:
        m = MSG_RE.match(os.path.basename(p))
        if not m:
            continue
        mid = m.group(1)
        if int(mid) < SINCE_MS or mid in seen:
            continue
        seen.add(mid)
        if m.group(3) == "event":
            events += 1
        elif not m.group(2).startswith(SERVICE):
            n += 1
    return n, events


def main():
    if "<" in BUS or "<" in TO or not os.path.isdir(BUS):
        print("rollout_gate: сторож привязан к конкретному внедрению - задайте ROLLOUT_GATE_BUS, ROLLOUT_GATE_TO,"
              " ROLLOUT_GATE_NOTIFY_BUS и ROLLOUT_GATE_SINCE_MS (или уберите вызов из shop-flood.py)", file=sys.stderr)
        return 2
    done = False
    try:
        with open(STATE, encoding="utf-8") as f:
            done = bool(json.load(f).get("notified"))
    except Exception:
        pass
    n, events = count_since()
    if "--check" in sys.argv:
        print("ролевых писем после внедрения: %d из %d; событий close/amend: %d; напомнено: %s"
              % (n, NEED_LETTERS, events, "да" if done else "нет"))
        return 0
    if done and "--force" not in sys.argv:
        return 0
    if n < NEED_LETTERS and "--force" not in sys.argv:
        return 0

    body = [
        "Накопилось %d ролевых писем после внедрения механики (порог %d) — пора снимать итоги."
        % (n, NEED_LETTERS),
        "",
        "Команда замера:",
        "  python3 <probes-dir>/measure_oblig.py --bus %s --split %d \\" % (BUS, SINCE_MS),
        "      --names \"До внедрения,После внедрения\"",
        "",
        "С чем сравнивать (пороги посчитаны 31.08, обоснование — в шапке rollout_gate.py):",
        "- доля ролевых писем с полем обязательства: ниже 30% — роли не переучились; цель 60%;",
        "- закрытий, поставленных ждущим: не ниже 80% без машинных обязательств (dispatcher и подобные закрыть не могут), иначе норма не работает;",
        "- событий close: больше нуля, иначе тихое закрытие не используется.",
        "",
        "Событий close/amend на этот момент: %d." % events,
        "",
        "Результат сравнить с числами стенда (приложение Б спецификации) и доложить владельцу.",
        "Отвечать на это письмо не нужно.",
    ]
    tmp = os.path.join(os.path.expanduser("~/.shop"), "rollout-gate-body.md")
    os.makedirs(os.path.dirname(tmp), exist_ok=True)
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(body) + "\n")
    cli = os.environ.get("POOL_CLI") or os.path.expanduser("~/.local/bin/pool")
    r = subprocess.run([cli, "note", "-To", TO, "-From", "pool-monitor",
                        "-Subject", "Пора замерить итоги внедрения: накопилось %d писем" % n,
                        "-BodyFile", tmp, "-BusRoot", NOTIFY_BUS],
                       capture_output=True, text=True, encoding="utf-8", errors="replace",
                       stdin=subprocess.DEVNULL, timeout=20)
    if r.returncode != 0:
        print("напоминание не ушло: %s" % (r.stderr or "")[:200], file=sys.stderr)
        return 1
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    with open(STATE, "w", encoding="utf-8") as f:
        json.dump({"notified": True, "letters": n, "events": events}, f, ensure_ascii=False)
    print("напоминание отправлено: писем %d, событий %d" % (n, events))
    return 0


if __name__ == "__main__":
    sys.exit(main())
