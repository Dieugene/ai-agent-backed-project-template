"""Раскладка переписки шины после внедрения механики обязательств: по ролям и по закрытиям.
Только чтение. python3 oblig_breakdown.py <bus> <split_ms>"""
import collections
import io
import os
import re
import sys

bus, split = sys.argv[1], int(sys.argv[2])
HDR = re.compile(r"^\|\s*([A-Za-z]+)\s*\|\s*(.*?)\s*\|\s*$")
SERVICE = {"pool-monitor", "bridge", "pool-delivery", "controller", "shop", "antiflood", "shop-flood"}


def parse(path):
    hdr = {}
    with io.open(path, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    intable = False
    for ln in lines[:60]:
        m = HDR.match(ln)
        if m:
            k, v = m.group(1), m.group(2)
            if k in ("Field", "---"):
                intable = True
                continue
            if k[0].isupper():
                hdr[k] = v
        elif intable and ln.strip() == "":
            break
    return hdr


letters = []
for root, dirs, files in os.walk(bus):
    dirs[:] = [d for d in dirs if not d.startswith(".")]
    for fn in files:
        if not fn.endswith(".md"):
            continue
        m = re.match(r"^(\d{13})-", fn)
        if not m or int(m.group(1)) < split:
            continue
        kind = "note" if ".note." in fn else ("reply" if ".reply." in fn else "task")
        hdr = parse(os.path.join(root, fn))
        hdr["_path"] = os.path.join(root, fn)
        frm = hdr.get("From", "?")
        # Одно письмо лежит в нескольких копиях (new/cur/archive с суффиксами) — считаем по id один раз.
        if any(x[1].startswith(m.group(1)) and x[3] == frm for x in letters):
            continue
        letters.append((int(m.group(1)), fn, kind, frm, hdr))

role_letters = [x for x in letters if x[3] not in SERVICE]
print("писем после среза:", len(letters), "ролевых:", len(role_letters))

by_role = collections.defaultdict(lambda: collections.Counter())
for ts, fn, kind, frm, h in role_letters:
    c = by_role[frm]
    c["всего"] += 1
    c[kind] += 1
    if any(k in h for k in ("Opens", "About", "Closes")):
        c["с полем"] += 1
    if "Opens" in h:
        c["открыл"] += 1
    if "Closes" in h:
        c["закрыл письмом"] += 1
print("\n## По ролям (письма после внедрения)")
print("| роль | всего | задач | ответов | заметок | с полем | % с полем | открыл | закрыл письмом |")
print("|---|---|---|---|---|---|---|---|---|")
for r, c in sorted(by_role.items(), key=lambda kv: -kv[1]["всего"]):
    t = c["всего"]
    print(f"| {r} | {t} | {c['task']} | {c['reply']} | {c['note']} | {c['с полем']} | {100*c['с полем']//t if t else 0}% | {c['открыл']} | {c['закрыл письмом']} |")

# Обязательства: кто открыл, кто закрыл (письмом или событием), исход.
opens = {}
closes = collections.defaultdict(list)
for ts, fn, kind, frm, h in letters:
    if "Opens" in h:
        opens[h["Opens"]] = (frm, h.get("To", "?"), ts)
    if "Closes" in h:
        closes[h["Closes"]].append((frm, h.get("Outcome", "?"), "письмо"))
# события close в archive/.obligations? — читаем каталог событий, если есть
ev_dir = os.path.join(bus, "archive")
for fn in os.listdir(ev_dir) if os.path.isdir(ev_dir) else []:
    if ".close." in fn or fn.startswith("close-") or ".event." in fn:
        h = parse(os.path.join(ev_dir, fn))
        if "Closes" in h:
            closes[h["Closes"]].append((h.get("From", "?"), h.get("Outcome", "?"), "событие"))

print("\n## Закрытия: кто закрыл относительно открывшего")
waiter = executor = other = 0
exec_list = []
for key, (opener, to, ts) in opens.items():
    for closer, outcome, how in closes.get(key, []):
        if closer == opener:
            waiter += 1
        elif closer == to:
            executor += 1
            exec_list.append((key, opener, to, outcome, how))
        else:
            other += 1
            exec_list.append((key, opener, closer + " (третий)", outcome, how))
print("закрыл ждущий:", waiter, "| закрыл исполнитель:", executor, "| закрыл третий:", other)
print("\n### Закрытые не ждущим")
print("| ключ | открыл | закрыл | исход | как |")
print("|---|---|---|---|---|")
for k, o, c, oc, how in exec_list:
    print(f"| `{k}` | {o} | {c} | {oc[:60]} | {how} |")

print("\n## Исходы")
oc = collections.Counter(o for lst in closes.values() for _, o, _ in lst)
for k, v in oc.most_common(8):
    print(f"- {k[:70]}: {v}")

print("\n## Письма без полей — темы (первые 25, чтобы понять класс)")
n = 0
for ts, fn, kind, frm, h in sorted(role_letters, key=lambda x: -x[0]):
    if any(k in h for k in ("Opens", "About", "Closes")):
        continue
    subj = h.get("Subject", "")
    if not subj:
        with io.open(h["_path"], encoding="utf-8", errors="replace") as f:
            first = f.readline().strip("# \n")
        subj = first
    print(f"- {kind:5} {frm:12} {subj[:90]}")
    n += 1
    if n >= 25:
        break
