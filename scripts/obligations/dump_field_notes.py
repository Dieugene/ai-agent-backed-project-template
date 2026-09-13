# -*- coding: utf-8 -*-
"""Выгрузка материала первого живого прогона механики обязательств (пул pool-stand).

    python3 dump_field_notes.py --bus <шина> --out <файл.md>

Пишет ИСХОДНЫЕ данные: реестр обязательств полями как есть, дословные формулировки, замеры
темпа. Нужен, чтобы эталонные формулировки полей строились на данных, а не на воспоминании
о них: разговор, в котором это наблюдалось, до следующей сессии не доживёт.
"""

from __future__ import annotations

import argparse
import datetime
import glob
import os
import re
from collections import Counter

HDR = re.compile(r"^\|\s*(From|To|Opens|CloseWhen|About|Closes|Outcome)\s*\|\s*(.*?)\s*\|\s*$")
SUBJ = re.compile(r"^#\s+(.+?)\s*$")
SERVICE = ("pool-monitor", "system", "migration", "pool-controller")


def read_head(path: str):
    h, in_table, subj = {}, False, ""
    with open(path, encoding="utf-8", errors="replace") as f:
        for i, line in enumerate(f):
            if i > 40:
                break
            line = line.rstrip("\n")
            if not subj:
                ms = SUBJ.match(line)
                if ms:
                    subj = ms.group(1)
                    continue
            if line.startswith("|"):
                in_table = True
            elif in_table:
                break
            m = HDR.match(line)
            if m:
                h[m.group(1)] = m.group(2).replace("\\|", "|")
    return subj, h


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    msgs = []
    for p in glob.glob(os.path.join(args.bus, "*", "*", "*.md")) + \
            glob.glob(os.path.join(args.bus, "archive", "*.md")):
        subj, h = read_head(p)
        try:
            ts = int(os.path.basename(p).split("-")[0])
        except ValueError:
            continue
        msgs.append((ts, os.path.getsize(p), subj, h))
    msgs.sort()

    opens, counts, outcome, vol = {}, Counter(), {}, Counter()
    for ts, sz, subj, h in msgs:
        for field in ("Opens", "About", "Closes"):
            k = h.get(field)
            if not k:
                continue
            counts[k] += 1
            vol[k] += sz
            if field == "Opens" and k not in opens:
                opens[k] = (subj, h, ts)
            if field == "Closes":
                outcome[k] = h.get("Outcome", "(поле пустое)")

    role = [m for m in msgs if m[3].get("From") not in SERVICE]
    withf = [m for m in role if any(m[3].get(f) for f in ("Opens", "About", "Closes"))]
    total_kb = sum(m[1] for m in msgs) / 1024
    top_key = max(counts, key=lambda k: counts[k]) if counts else None

    L = []
    A = L.append
    A("# Первый живой прогон механики обязательств — пул `pool-stand`, 30.08.2026")
    A("")
    A("Снято %s (время сервера). Это ИСХОДНЫЕ данные, на которых строятся эталонные"
      % datetime.datetime.now().strftime("%d.%m %H:%M"))
    A("формулировки полей `Expect` и `CloseWhen`. Выводы отделены от данных и стоят в конце.")
    A("")
    A("## Замеры")
    A("")
    A("| Что | Значение |")
    A("|---|---|")
    A("| писем всего, включая служебные | %d |" % len(msgs))
    A("| писем ролей | %d |" % len(role))
    A("| из них несут поле обязательства | %d |" % len(withf))
    A("| ролевых писем БЕЗ полей | %d |" % (len(role) - len(withf)))
    A("| суммарный объём | %.0f КБ |" % total_kb)
    A("| средний размер письма | %.1f КБ |" % (total_kb / max(len(msgs), 1)))
    A("| обязательств открыто | %d |" % len(opens))
    A("| из них закрыто | %d |" % len(outcome))
    if top_key:
        A("| писем под самым нагруженным ключом | %d (%.0f%% объёма всей переписки) |"
          % (counts[top_key], 100 * vol[top_key] / max(total_kb * 1024, 1)))
    A("")
    A("## Реестр: поля как есть, формулировки дословные")
    A("")
    for k in sorted(opens, key=lambda x: -counts[x]):
        subj, h, ts = opens[k]
        A("### `%s` — писем %d, %.0f КБ" % (k, counts[k], vol[k] / 1024))
        A("")
        A("- **From:** `%s` · **To:** `%s`" % (h.get("From", "?"), h.get("To", "?")))
        A("- **Тема письма-открытия** (полем НЕ является, взята из первой строки): %s" % subj)
        A("- **CloseWhen:** %s" % h.get("CloseWhen", "(пусто)"))
        A("- **Outcome:** %s" % outcome.get(k, "— не закрыто"))
        A("")

    with open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(L) + "\n")
    print("записано: %s (%d знаков, обязательств %d)" % (args.out, len("\n".join(L)), len(opens)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
