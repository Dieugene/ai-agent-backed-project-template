#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Замер «база до» (реформа обязательств, направление I): сколько писем шины УЖЕ называют
# условие закрытия прозой — открытия и закрытия. В вывод — ТОЛЬКО агрегаты и id писем;
# тела не печатаются и не сохраняются. Дата замера печатается всегда.
import re, os, sys, random
from datetime import datetime

BUS = sys.argv[1] if len(sys.argv) > 1 else "<workspace-root>/pool-A/.bus"
SYSTEM_SENDERS = {"system", "pool-monitor", "migration", "pool-controller", "bridge"}

MARKERS = [
    ("zhdu",          re.compile(r"\bжд[уё]м?\b", re.I)),
    ("dai-znat",      re.compile(r"дай(те)? знать|отпишись|отпишитесь", re.I)),
    ("podtverdi",     re.compile(r"\bподтверди(те)?\b", re.I)),
    ("skazhi-kogda",  re.compile(r"(скажи|напиши|сообщи)(те)?,? когда", re.I)),
    ("po-gotovnosti", re.compile(r"по готовности", re.I)),
    ("prishli",       re.compile(r"\bпришли(те)?\b (мне |в ответ |сюда )?", re.I)),
    ("nuzhno-ot",     re.compile(r"нужн[оа] от (тебя|вас)|жду от (тебя|вас)", re.I)),
    ("s-tebya",       re.compile(r"\bс тебя\b|\bза тобой\b", re.I)),
    ("srok-vremya",   re.compile(r"\b(к|до) \d{1,2}[:.]\d{2}\b|сегодня до |завтра до |дедлайн", re.I)),
    ("priznak",       re.compile(r"признак(ом)? закрыт|условие закрыт", re.I)),
]
NO_REPLY = re.compile(r"не отвечай|ответ не нужен|ответа не (жду|нужн)|без ответа", re.I)
CLOSERS = [
    ("prinyato",  re.compile(r"\bпринят[оа]?\b|\bпринял\b", re.I)),
    ("snyato",    re.compile(r"\bснима[юй]\b|\bснял\b|\bотозвал\b|\bотзываю\b|можешь снимать", re.I)),
    ("zakryto",   re.compile(r"\bзакрыт[оа]\b|\bзакрыл\b|считаю закрытым", re.I)),
    ("sdelano",   re.compile(r"\bсделано\b|\bготово\b|\bвыполнено\b|\bисполнено\b", re.I)),
    ("nichego-ne-vozvrashchayu", re.compile(r"ничего не возвращаю|к тебе ничего нет|вопросов к тебе нет", re.I)),
]
KIND_RE = re.compile(r"\.(coord|note-wake|note|task|reply)\.")

def letters():
    dirs = [os.path.join(BUS, "archive")]
    for box in os.listdir(BUS):
        p = os.path.join(BUS, box)
        if box.startswith(".") or not os.path.isdir(p):
            continue
        for sub in ("new", "cur"):
            d = os.path.join(p, sub)
            if os.path.isdir(d):
                dirs.append(d)
    seen = set()
    for d in dirs:
        for name in os.listdir(d):
            if not name.endswith(".md"):
                continue
            lid = name.split(".")[0]
            if lid in seen:
                continue
            seen.add(lid)
            yield lid, os.path.join(d, name), name

stats = {"total": 0, "role": 0, "bridge": 0, "system": 0,
         "hit": 0, "noreply": 0, "close": 0, "hit_or_close": 0}
by_kind, by_sender, by_marker, by_closer = {}, {}, {}, {}
hits_sample, miss_sample = [], []

for lid, path, name in letters():
    stats["total"] += 1
    m = KIND_RE.search(name)
    kind = m.group(1) if m else "?"
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        continue
    frm = ""
    fm = re.search(r"^\|\s*From\s*\|\s*(\S+)\s*\|", text, re.M)
    if fm:
        frm = fm.group(1)
    subj = text.split("\n", 1)[0]
    if frm in SYSTEM_SENDERS:
        stats["system"] += 1
        continue
    if kind == "note-wake" and re.match(r"#\s*bridge:", subj, re.I):
        stats["bridge"] += 1
        continue
    stats["role"] += 1
    by_kind[kind] = by_kind.get(kind, 0) + 1
    by_sender[frm] = by_sender.get(frm, 0) + 1
    hit_names = [mn for mn, rx in MARKERS if rx.search(text)]
    close_names = [cn for cn, rx in CLOSERS if rx.search(text)]
    if NO_REPLY.search(text):
        stats["noreply"] += 1
    if close_names:
        stats["close"] += 1
        for cn in close_names:
            by_closer[cn] = by_closer.get(cn, 0) + 1
    if hit_names or close_names:
        stats["hit_or_close"] += 1
    if hit_names:
        stats["hit"] += 1
        for mn in hit_names:
            by_marker[mn] = by_marker.get(mn, 0) + 1
        hits_sample.append(lid)
    else:
        miss_sample.append(lid)

random.seed(20260828)
print(f"ЗАМЕР 'база до' — {datetime.now().strftime('%Y-%m-%d %H:%M')} — шина {BUS}")
print(f"всего уникальных писем: {stats['total']}; системных: {stats['system']}; мостовых побудок: {stats['bridge']}")
print(f"РОЛЕВЫХ: {stats['role']}")
print(f"  с маркером прозаического ОТКРЫТИЯ (условие закрытия названо): {stats['hit']} ({100*stats['hit']/max(1,stats['role']):.1f}%)")
print(f"  с маркером ЗАКРЫТИЯ прозой (принято/снято/сделано/закрыто): {stats['close']} ({100*stats['close']/max(1,stats['role']):.1f}%)")
print(f"  открытие ИЛИ закрытие: {stats['hit_or_close']} ({100*stats['hit_or_close']/max(1,stats['role']):.1f}%)")
print(f"  с явным 'ответ не нужен': {stats['noreply']} ({100*stats['noreply']/max(1,stats['role']):.1f}%)")
print("по видам:", dict(sorted(by_kind.items(), key=lambda x: -x[1])))
print("по отправителям:", dict(sorted(by_sender.items(), key=lambda x: -x[1])))
print("по маркерам открытий:", dict(sorted(by_marker.items(), key=lambda x: -x[1])))
print("по маркерам закрытий:", dict(sorted(by_closer.items(), key=lambda x: -x[1])))
print("выборка для ручной проверки — С маркером:", random.sample(hits_sample, min(8, len(hits_sample))))
print("выборка для ручной проверки — БЕЗ маркера:", random.sample(miss_sample, min(8, len(miss_sample))))
