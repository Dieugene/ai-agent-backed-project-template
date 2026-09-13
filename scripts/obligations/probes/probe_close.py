#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пробы тихого закрытия, правки формулировки и работы в закрытый ключ.

    python3 probe_close.py [--keep]

Гоняется на ВРЕМЕННОЙ шине в /tmp — боевые пулы не трогаются ни одной проверкой.
Каждая проба проверяет ОДНО утверждение и печатает своё имя: зелёный список без имён
ничего не доказывает, а по имени видно, какая именно проверка покраснела при мутации.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

PWSH = "pwsh"
HERE = os.path.dirname(os.path.abspath(__file__))
POOL = os.path.join(HERE, "..", "..", "pool.ps1")      # относительно каталога проб: scripts/pool.ps1
OBLIG = os.path.join(HERE, "..", "shop_oblig.py")      # scripts/obligations/shop_oblig.py
MSG_RE = re.compile(r"^\d{13}-[0-9a-f]{10}\.from-[^.]+\.[^.]+?(\.\d+\.\d+)?\.md$")

ok, bad = 0, []


def check(name, cond, detail=""):
    global ok
    if cond:
        ok += 1
        print("  PASS  %s" % name)
    else:
        bad.append(name)
        print("  FAIL  %s %s" % (name, detail))


def pool(bus, *args, expect_fail=False):
    r = subprocess.run([PWSH, "-NoProfile", "-File", POOL] + list(args) + ["-BusRoot", bus],
                       capture_output=True, text=True)
    if not expect_fail and r.returncode != 0:
        print("     !! pool %s -> rc=%d %s" % (" ".join(args[:3]), r.returncode, r.stderr[:300]))
    return r


def sweep(bus, rebuild=False):
    a = ["python3", OBLIG, "--bus", bus]
    if rebuild:
        a.append("--rebuild")
    subprocess.run(a, capture_output=True, text=True)
    with open(os.path.join(bus, ".obligations", "index.json"), encoding="utf-8") as f:
        return json.load(f)


def keys(lst):
    return {o["key"]: o for o in lst}


def main():
    bus = tempfile.mkdtemp(prefix="probe-close-")
    try:
        run(bus)
    finally:
        if "--keep" in sys.argv:
            print("шина оставлена: %s" % bus)
        else:
            shutil.rmtree(bus, ignore_errors=True)
    print("\nИТОГ: %d прошло, %d упало %s" % (ok, len(bad), bad if bad else ""))
    return 1 if bad else 0


def run(bus):
    # --- подготовка: открываем обязательство обычным письмом
    pool(bus, "send", "-From", "lead", "-To", "worker", "-Subject", "задание",
         "-Body", "тело", "-Opens", "zadacha-odin",
         "-Expect", "Требуется первая формулировка", "-CloseWhen", "признак первый")
    ix = sweep(bus)
    check("подготовка: обязательство открыто письмом", "zadacha-odin" in keys(ix["open"]))

    # --- 1. amend от открывшего меняет обе формулировки
    pool(bus, "amend", "-Owner", "lead", "-Key", "zadacha-odin",
         "-Expect", "Требуется ИСПРАВЛЕННАЯ формулировка", "-CloseWhen", "признак ИСПРАВЛЕННЫЙ")
    ix = sweep(bus)
    rec = keys(ix["open"]).get("zadacha-odin", {})
    check("amend: правка от открывшего меняет Expect",
          rec.get("expect") == "Требуется ИСПРАВЛЕННАЯ формулировка", rec.get("expect", ""))
    check("amend: правка от открывшего меняет CloseWhen",
          rec.get("close_when") == "признак ИСПРАВЛЕННЫЙ", rec.get("close_when", ""))
    check("amend: на записи остаётся след правки", bool(rec.get("amended")))

    # --- 2. amend событием НЕ попадает ни в чей ящик
    inbox_files = []
    for who in ("lead", "worker"):
        for sub in ("new", "cur"):
            d = os.path.join(bus, who, sub)
            if os.path.isdir(d):
                inbox_files += os.listdir(d)
    check("amend: ящики не тронуты (0 писем сверх исходного)", len(inbox_files) == 1,
          str(inbox_files))
    arch = os.listdir(os.path.join(bus, "archive"))
    check("amend: событие лежит в archive", len(arch) == 1, str(arch))
    check("amend: имя события разбирается обходчиком", all(MSG_RE.match(a) for a in arch), str(arch))

    # --- 3. amend от чужого не проходит и назван своей причиной
    pool(bus, "amend", "-Owner", "worker", "-Key", "zadacha-odin",
         "-Expect", "Требуется ЧУЖАЯ подмена")
    ix = sweep(bus)
    rec = keys(ix["open"]).get("zadacha-odin", {})
    check("amend: чужая правка НЕ применена",
          rec.get("expect") == "Требуется ИСПРАВЛЕННАЯ формулировка", rec.get("expect", ""))
    check("amend: чужая правка названа своей причиной",
          any("не открывший" in b.get("reason", "") for b in ix["bad"]),
          str([b.get("reason") for b in ix["bad"]]))

    # --- 4. close закрывает без письма
    pool(bus, "close", "-Owner", "lead", "-Key", "zadacha-odin", "-Body", "принято")
    ix = sweep(bus)
    check("close: ключ ушёл из открытых", "zadacha-odin" not in keys(ix["open"]))
    closed = keys(ix["closed"]).get("zadacha-odin", {})
    check("close: исход по умолчанию fulfilled", closed.get("outcome") == "fulfilled",
          closed.get("outcome", ""))
    check("close: закрывший записан", closed.get("closed_by") == "lead", closed.get("closed_by", ""))
    inbox_files = []
    for who in ("lead", "worker"):
        for sub in ("new", "cur"):
            d = os.path.join(bus, who, sub)
            if os.path.isdir(d):
                inbox_files += os.listdir(d)
    check("close: ничей ящик не пополнился", len(inbox_files) == 1, str(inbox_files))

    # --- 5. работа в закрытый ключ отличается от кривой привязки
    pool(bus, "send", "-From", "worker", "-To", "lead", "-Subject", "поправка после закрытия",
         "-Body", "т", "-About", "zadacha-odin")
    pool(bus, "send", "-From", "worker", "-To", "lead", "-Subject", "привязка в никуда",
         "-Body", "т", "-About", "takogo-kljucha-net")
    ix = sweep(bus)
    reasons = [b.get("reason", "") for b in ix["bad"]]
    check("закрытый ключ: работа после закрытия названа отдельно",
          any("ЗАКРЫТЫЙ ключ" in r for r in reasons), str(reasons))
    check("неизвестный ключ: причина осталась прежней",
          any("неизвестному ключу" in r for r in reasons), str(reasons))
    closed = keys(ix["closed"]).get("zadacha-odin", {})
    check("закрытый ключ: счётчик работы после закрытия", closed.get("after_close") == 1,
          str(closed.get("after_close")))

    # --- 6. rebuild воспроизводит тот же результат (событие живёт в переписке, не в кэше)
    ix2 = sweep(bus, rebuild=True)
    closed2 = keys(ix2["closed"]).get("zadacha-odin", {})
    check("rebuild: закрытие переживает пересборку индекса",
          closed2.get("outcome") == "fulfilled" and closed2.get("closed_by") == "lead")
    check("rebuild: правка формулировки переживает пересборку",
          closed2.get("expect") == "Требуется ИСПРАВЛЕННАЯ формулировка", closed2.get("expect", ""))

    # --- 7. отказы: без ключа и без формулировок
    r = pool(bus, "close", "-Owner", "lead", expect_fail=True)
    check("close без -Key отказывает", r.returncode != 0)
    r = pool(bus, "amend", "-Owner", "lead", "-Key", "zadacha-odin", expect_fail=True)
    check("amend без формулировок отказывает", r.returncode != 0)

    # --- 8. обычное письмо не несёт строку Amends
    pool(bus, "send", "-From", "lead", "-To", "worker", "-Subject", "обычное", "-Body", "т")
    latest = sorted(os.listdir(os.path.join(bus, "worker", "new")))[-1]
    txt = open(os.path.join(bus, "worker", "new", latest), encoding="utf-8").read()
    check("обычное письмо БЕЗ строки Amends", "| Amends |" not in txt)

    # --- 9. mine не падает и печатает свод
    r = pool(bus, "mine", "-Owner", "lead")
    check("mine работает на индексе с новыми полями", r.returncode == 0, r.stderr[:200])

    # --- 10. справка знает про новые команды и не обрезана
    r = pool(bus, "help")
    lines = r.stdout.split("\n")
    check("help: строка про close есть", any("pool.ps1 close" in l for l in lines))
    check("help: строка про amend есть", any("pool.ps1 amend" in l for l in lines))
    # Длина справки задана числом строк: занизишь — хвост молча отрежется. Сторожим КОНЕЦ блока,
    # и маркер обязан встречаться в справке ровно один раз: «note -Wake» стоял ещё и в середине,
    # поэтому проверка проходила даже на обрезанной справке — мутация это и вскрыла.
    check("help: справка доходит до конца блока (не обрезана числом)",
          any("exactly like a task" in l for l in lines), repr(lines[-3:]))


if __name__ == "__main__":
    sys.exit(main())
