#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Темп переписки пула до и после внедрения механики обязательств.

Мера успеха по слову владельца — «сокращение переписки при той же работе». «Та же работа» машинно
не измеряется, поэтому здесь считается только левая половина: писем в сутки. Число само по себе
вывода не даёт — его читают вместе с тем, чем пул занимался в эти дни.

    python3 measure_tempo.py <шина> <split_ms>

Считаются РОЛЕВЫЕ письма (служебные отправители и события реестра исключены) — тем же способом,
каким их считает сторож замера, иначе числа несравнимы.
"""
import collections
import datetime
import glob
import os
import re
import sys

MSG = re.compile(r"^(\d{13})-[0-9a-f]{10}\.from-([^.]+)\.([^.]+?)(\.\d+\.\d+)?\.md$")
SERVICE = ("pool-monitor", "pool-controller", "system", "migration", "bridge")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    bus, split = sys.argv[1], int(sys.argv[2])
    seen = set()
    before, after = collections.Counter(), collections.Counter()
    paths = (glob.glob(os.path.join(bus, "*", "new", "*.md")) +
             glob.glob(os.path.join(bus, "*", "cur", "*.md")) +
             glob.glob(os.path.join(bus, "archive", "*.md")))
    for p in paths:
        m = MSG.match(os.path.basename(p))
        if not m:
            continue
        mid = m.group(1)
        if mid in seen:
            continue
        seen.add(mid)
        if m.group(3) == "event" or m.group(2).startswith(SERVICE):
            continue
        day = datetime.datetime.fromtimestamp(int(mid) / 1000).strftime("%Y-%m-%d")
        (after if int(mid) >= split else before)[day] += 1

    for name, c in (("ДО внедрения", before), ("ПОСЛЕ внедрения", after)):
        if not c:
            print("%s — нет данных" % name)
            continue
        tot, days = sum(c.values()), len(c)
        print("%s: писем %d за %d суток = %.1f в сутки" % (name, tot, days, tot / days))
        rows = sorted(c.items())
        print("   по дням (последние 8): %s" % dict(rows[-8:]))
        # Последние сутки среза обычно неполные — печатаем отдельно, чтобы среднее не вводило
        # в заблуждение.
        print("   первый день среза: %s=%d, последний: %s=%d"
              % (rows[0][0], rows[0][1], rows[-1][0], rows[-1][1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
