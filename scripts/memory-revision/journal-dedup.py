#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Убрать из журнала исходов дубли одного прохода.

Повод: правка 04.09 переносила не только почтовые пункты, и возрастные пункты попадали в список
дважды. Журнал за проход 04.09 15:25 получил 25 строк вместо 13. Пока они там, доля «без исхода»
до и после правки несравнима — а это единственный ряд, по которому видно вырождение хода.

🛑 Дубль — строка, совпадающая ЦЕЛИКОМ, вместе с исходом. Ключ без исхода схлопнул бы записи,
где у одного пункта в одну минуту стоят разные исходы (такие в журнале есть) — а это не дубль,
а отдельное явление, которое надо разбирать, а не стирать.

    journal-dedup.py <journal.tsv> [--apply]
"""
import io
import shutil
import sys
from pathlib import Path

path = Path(sys.argv[1])
apply = "--apply" in sys.argv
lines = io.open(str(path), encoding="utf-8").read().splitlines()

# 🛑 Чистим ТОЛЬКО названный проход (--stamp="ГГГГ-ММ-ДД ЧЧ:ММ"). Дубли есть и в старых отметках,
# но их причина другая и неизвестная; трогать чужие строки задним числом — менять ряд, по которому
# судят о вырождении хода.
only = ""
for a in sys.argv[2:]:
    if a.startswith("--stamp="):
        only = a.split("=", 1)[1]

seen, out, dropped = set(), [], []
for ln in lines:
    if only and not ln.startswith(only):
        out.append(ln)
        continue
    key = ln   # строка целиком: исход входит в ключ
    if key in seen:
        dropped.append(ln)
        continue
    seen.add(key)
    out.append(ln)

print("строк было %d, дублей %d, останется %d" % (len(lines), len(dropped), len(out)))
for ln in dropped[:5]:
    print("   убрать: %s" % ln[:110])
if len(dropped) > 5:
    print("   … ещё %d" % (len(dropped) - 5))

if not apply:
    print("\nэто показ; чтобы применить — тот же вызов с --apply")
    raise SystemExit(0)
if not dropped:
    raise SystemExit(0)
shutil.copy(str(path), str(path) + ".bak")
io.open(str(path), "w", encoding="utf-8", newline="\n").write("\n".join(out) + "\n")
print("применено, прежний файл рядом с суффиксом .bak")
