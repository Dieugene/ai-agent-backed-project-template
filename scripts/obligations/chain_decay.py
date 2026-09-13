#!/usr/bin/env python3
"""Затухают ли письменные обмены сами — мера владельца 13.09.

Обмен (цепочка) = письма под одним ключом обязательства (Opens/About/Closes), а без него — под одним
Thread. Считаются РОЛЕВЫЕ письма (служебные отправители исключены). По каждой цепочке из ≥2 писем:
длина, число календарных дней, «нарастает» = в какой-то из последующих дней писем больше, чем в первый.
Сравнение до/после границы внедрения (split в мс).

    python3 chain_decay.py <шина> <split_ms> [<шина> ...]
"""
import os, re, sys, datetime, statistics
from collections import defaultdict

MACHINE = {"antiflood", "bridge", "controller", "dispatcher", "pool-monitor", "migration", "obhodchik",
           "obligations", "system", "vahta", "watch", "sentinel"}

def parse(path):
    hdr = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = re.match(r"\|\s*([A-Za-z_-]+)\s*\|\s*(.*?)\s*\|\s*$", line)
                if m:
                    hdr[m.group(1)] = m.group(2)
                elif hdr and not line.startswith("|"):
                    break
    except OSError:
        return None
    return hdr

def role_letters(bus):
    out = []
    for root, _, files in os.walk(bus):
        if os.sep + ".watch" in root or os.sep + ".ledger" in root:
            continue
        for fn in files:
            m = re.match(r"(\d{13})-", fn)
            if not m or not fn.endswith(".md"):
                continue
            h = parse(os.path.join(root, fn))
            if not h:
                continue
            frm = (h.get("From") or "").strip().lower()
            if not frm or frm in MACHINE or frm.startswith("pool-"):
                continue
            key = h.get("Opens") or h.get("About") or h.get("Closes")
            key = ("ob:" + key.strip()) if key and key.strip() and key.strip() not in ("-", "—") else None
            if not key:
                th = (h.get("Thread") or h.get("In-Reply-To") or "").strip()
                key = ("th:" + th) if th and th not in ("-", "—") else "one:" + fn
            out.append((int(m.group(1)), key, frm, fn))
    return out

def chains(letters):
    by = defaultdict(list)
    for ts, key, frm, fn in letters:
        by[key].append(ts)
    return {k: sorted(v) for k, v in by.items()}

def stats(ch, label):
    multi = {k: v for k, v in ch.items() if len(v) >= 2}
    if not multi:
        print("  %s: цепочек из ≥2 писем нет" % label); return
    lens = [len(v) for v in multi.values()]
    growing = 0; longlived = 0; heavy = 0
    for v in multi.values():
        days = defaultdict(int)
        for ts in v:
            d = datetime.datetime.utcfromtimestamp(ts / 1000).date()
            days[d] += 1
        first = min(days); seq = [days[d] for d in sorted(days)]
        if any(c > days[first] for c in seq[1:]):
            growing += 1
        if len(days) > 3:
            longlived += 1
        if len(v) >= 5:
            heavy += 1
    n = len(multi)
    print("  %s: цепочек %d | длина: средняя %.1f, медиана %d, p90 %d, макс %d | нарастают %d (%d%%) | дольше 3 дней %d (%d%%) | ≥5 писем %d (%d%%)"
          % (label, n, statistics.mean(lens), statistics.median(lens),
             sorted(lens)[int(0.9 * (n - 1))], max(lens),
             growing, 100 * growing // n, longlived, 100 * longlived // n, heavy, 100 * heavy // n))
    top = sorted(multi.items(), key=lambda kv: -len(kv[1]))[:4]
    for k, v in top:
        days = len({datetime.datetime.utcfromtimestamp(t / 1000).date() for t in v})
        print("      %-48s %3d писем, %d дн." % (k[:48], len(v), days))

def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    split = int(sys.argv[2])
    for bus in [sys.argv[1]] + sys.argv[3:]:
        letters = role_letters(bus)
        before = [l for l in letters if l[0] < split]
        after = [l for l in letters if l[0] >= split]
        print("%s — ролевых писем до %d / после %d" % (bus, len(before), len(after)))
        stats(chains(before), "ДО   ")
        stats(chains(after), "ПОСЛЕ")
        ob = sum(1 for l in after if l[1].startswith("ob:")); th = sum(1 for l in after if l[1].startswith("th:"))
        print("  после: под ключом обязательства %d, только под тредом %d, одиночных %d" % (ob, th, len(after) - ob - th))

if __name__ == "__main__":
    main()
