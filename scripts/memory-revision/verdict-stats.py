# -*- coding: utf-8 -*-
"""Сводка по расчётам вердиктов и свёрткам: до и после выкатки разовой модели.
Аргументы: --cut ГГГГ-ММ-ДДTЧЧ:ММ  каталоги .revision ...
"""
import json, sys, os, glob, collections, io
cut = sys.argv[1]
dirs = sys.argv[2:]
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

def fmt(n):
    return "{:,}".format(int(n)).replace(",", " ")

for d in dirs:
    print("=" * 70)
    print("КАТАЛОГ", d)
    for f in sorted(glob.glob(os.path.join(d, "verdicts-*.json"))):
        role = os.path.basename(f)[len("verdicts-"):-5]
        try:
            data = json.load(io.open(f, encoding="utf-8"))
        except Exception as e:
            print("  ", role, "нечитаем:", e)
            continue
        if not isinstance(data, dict):
            print("  ", role, "не словарь")
            continue
        before, after = [], []
        for k, v in data.items():
            if not isinstance(v, dict):
                continue
            at = str(v.get("at", ""))
            (after if at >= cut else before).append((k, v))
        def summ(lst):
            n = len(lst)
            tok = sum(float(v.get("tokens") or 0) for _, v in lst)
            sec = sum(float(v.get("seconds") or 0) for _, v in lst)
            turns = [v.get("turns") for _, v in lst if v.get("turns") is not None]
            return n, tok, sec, turns
        nb, tb, sb, trb = summ(before)
        na, ta, sa, tra = summ(after)
        print("  роль %-18s всего %4d | до: %4d пунктов, %s ток., ходов на пункт %s | после: %4d пунктов, %s ток., ходов %s" % (
            role, nb + na, nb, fmt(tb), (sorted(set(trb))[:6] if trb else "-"),
            na, fmt(ta), (sorted(set(tra)) if tra else "-")))
        # группировка «после» по моменту расчёта (пакет = одно at)
        groups = collections.defaultdict(list)
        for k, v in after:
            groups[str(v.get("at", ""))[:16]].append(v)
        for at, vs in sorted(groups.items()):
            tok = sum(float(v.get("tokens") or 0) for v in vs)
            sec = max(float(v.get("seconds") or 0) for v in vs)
            turns = sorted(set(v.get("turns") for v in vs))
            verd = collections.Counter(str(v.get("verdict", ""))[:14] for v in vs)
            print("      пакет %s: пунктов %d, токенов %s, ходов %s, с %.0f, вердикты %s" % (
                at, len(vs), fmt(tok), turns, sec, dict(verd)))
    j = os.path.join(d, "journal.tsv")
    if os.path.isfile(j):
        rows = [l.rstrip("\n").split("\t") for l in io.open(j, encoding="utf-8", errors="replace")]
        rows = [r for r in rows if len(r) >= 5 and r[0] >= cut.replace("T", " ")]
        by = collections.defaultdict(collections.Counter)
        for r in rows:
            by[(r[0][:16], r[1])][r[4]] += 1
        print("  журнал закрытий после среза:")
        for (when, role), c in sorted(by.items()):
            print("      %s %-18s %s" % (when, role, dict(c)))
