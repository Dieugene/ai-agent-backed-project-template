#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# Замер доли ПОКЛОНОВ в переписке ролей. Мотивация владельца 29.08: «упразднить ситуации,
# когда агенты кланяются друг другу через "понял", "принял", "ack" — каждый такой поклон
# порождает ход, и иногда порождает дополнительный ответный поклон и прочее эхо».
#
# Поклон = письмо без нового содержания: только подтверждение получения и/или вежливость.
#
# Редакция 2 — после разбора оппонентом первой. Что исправлено (важно для доверия к числу):
#   1. Симметрия: и подтверждение, и содержание ищутся в ТЕМЕ+ТЕЛЕ (было: ack по теме и телу,
#      содержание только по телу — гарантированный перекос вверх).
#   2. Словарь подтверждений почищен: «хорошо/отлично/ясно/ок» ловили обычную координацию
#      и техстатусы («getMe OK»). Слабые слова засчитываются, ТОЛЬКО если стоят в начале тела.
#   3. Тело отрезается по КОНЦУ ШАПКИ (подряд идущие |-строки от «| Field | Value |»),
#      а не по последней |-строке в окне: таблица внутри тела ампутировала письмо.
#   4. Заголовки внутри тела больше не выбрасываются — с ними уходило содержание (20% писем).
#   5. Веерная рассылка (одно письмо N адресатам = N файлов с разными id) схлопывается
#      в одну отправку: иначе содержательная рассылка размывает долю вниз.
#   6. Все ряды печатаются на ОДНОМ пороге, порог подписан.
#   7. Выборки для ручной проверки бьют по опасным классам, а не по «серединке».
#   8. У эха печатается знаменатель: часть ответов не имеет ссылки на родителя.
#   9. Контрольные счётчики разбора: без шапки, пустое тело, таблица в теле.
# В вывод идут ТОЛЬКО агрегаты и id писем; тела не печатаются и не сохраняются.
import re, os, sys, random, hashlib
from datetime import datetime

BUS = sys.argv[1] if len(sys.argv) > 1 else "<workspace-root>/pool-A/.bus"
SYSTEM_SENDERS = {"system", "pool-monitor", "migration", "pool-controller", "bridge"}
KIND_RE = re.compile(r"\.(coord|note-wake|note|task|reply)\.")
MAIN = 25          # основной порог длины тела для «поклона», в словах
SHOW = [12, 25, 40]

# --- подтверждение получения --------------------------------------------------------------
ACK_STRONG = [
    ("prinyato",  re.compile(r"\bпринят[оаы]?\b|\bпринял[аи]?\b", re.I)),
    ("ponyal",    re.compile(r"\bпонял[аи]?\b", re.I)),
    ("ack",       re.compile(r"\back\b|\backed\b|подтверждаю получение", re.I)),
    ("spasibo",   re.compile(r"\bспасибо\b|\bблагодарю\b", re.I)),
    ("uchtu",     re.compile(r"\bучт[уё]\b|\bуч[её]л\b", re.I)),
    ("soglasen",  re.compile(r"\bсогласен\b|\bдоговорились\b|\bне возражаю\b", re.I)),
]
# слабые: засчитываются ТОЛЬКО в начале тела (иначе ловят техстатус и обычную речь)
ACK_WEAK_HEAD = re.compile(
    r"^\W{0,3}(ок|ok|okay|добро|хорошо|отлично|супер|ясно|понятно|есть)\b", re.I)

# --- признаки НОВОГО содержания ------------------------------------------------------------
CONTENT = [
    ("vopros",   re.compile(r"\?")),
    ("prosba",   re.compile(r"\b(пришл[иё]\w*|сделай\w*|проверь\w*|запусти\w*|прошу|нужн\w+|"
                            r"надо|давай|подними|поставь|погаси|дай|поправь|перезапусти|"
                            r"возьми|посмотри|напиши|скажи|сообщи|уточни|подтверди|согласуй|"
                            r"закрой|внеси|оставь|убери|держи|требуется|жду от|за тобой|"
                            r"с тебя)\b", re.I)),
    ("zhdu",     re.compile(r"\bжд[уёе]\w*\b|\bждут\b|\bожидаю\b", re.I)),
    ("chislo",   re.compile(r"\d+\s*%|\d+\s*/\s*\d+|\d+\s*(шт|сек|мин|ч|мс|мб|гб|кб|"
                            r"мин\.|строк|писем|файл\w*)\b", re.I)),
    ("put-fajl", re.compile(r"\.(py|ps1|md|json|txt|log|sh|bat|tsv|yml|yaml|jsonl)\b|"
                            r"[A-Za-zА-Яа-я_][\w.-]*[\\/][A-Za-zА-Яа-я_][\w.-]*", re.I)),
    ("kod",      re.compile(r"`[^`]+`|```")),
    ("prichina", re.compile(r"\bпотому что\b|\bпричина\b|\bиз-за\b|\bно\b|\bоднако\b|"
                            r"\bне получилось\b|\bне вышло\b|\bошибк\w*\b|\bупал\w*\b|"
                            r"\bсломал\w*\b|\bнашёл\b|\bнашел\b|\bвыяснил\w*\b|"
                            r"\bоказалось\b|\bпочему\b", re.I)),
    ("spisok",   re.compile(r"(^\s*[-*+]\s+\S.*\n){2,}|(^\s*\d+[.)]\s+\S.*\n){2,}", re.M)),
]

WORD_RE = re.compile(r"[A-Za-zА-Яа-яЁё0-9][A-Za-zА-Яа-яЁё0-9-]*")
HDR_START = re.compile(r"^\|\s*Field\s*\|\s*Value\s*\|")
THREAD_RE = re.compile(r"^\|\s*Thread\s*\|\s*(\S+)\s*\|", re.M)
FROM_RE = re.compile(r"^\|\s*From\s*\|\s*(\S+)\s*\|", re.M)
TO_RE = re.compile(r"^\|\s*To\s*\|\s*(\S+)\s*\|", re.M)


def split_letter(text):
    """(тема, тело, шапка_найдена). Тело — всё после блока подряд идущих строк шапки."""
    lines = text.split("\n")
    subj = lines[0].lstrip("#").strip() if lines else ""
    start = None
    for i, ln in enumerate(lines[:20]):
        if HDR_START.match(ln):
            start = i
            break
    if start is None:
        return subj, "\n".join(lines[1:]).strip(), False
    j = start
    while j < len(lines) and lines[j].lstrip().startswith("|"):
        j += 1
    return subj, "\n".join(lines[j:]).strip(), True


def letters():
    dirs = [os.path.join(BUS, "archive")]
    for box in sorted(os.listdir(BUS)):
        p = os.path.join(BUS, box)
        if box.startswith(".") or not os.path.isdir(p) or box == "archive":
            continue
        for sub in ("new", "cur"):
            d = os.path.join(p, sub)
            if os.path.isdir(d):
                dirs.append(d)
    seen = set()
    for d in dirs:
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if not name.endswith(".md"):
                continue
            lid = name.split(".")[0]
            if lid in seen:
                continue
            seen.add(lid)
            yield lid, os.path.join(d, name), name


ctl = {"total": 0, "system": 0, "bridge": 0, "no_header": 0, "empty_body": 0,
       "table_in_body": 0, "fanout_dropped": 0}
recs = {}          # id -> запись о письме (после схлопывания рассылок)
fan_seen = {}      # (отправитель, хеш тела, минута) -> id первой копии
senders_all = {}

for lid, path, name in letters():
    ctl["total"] += 1
    m = KIND_RE.search(name)
    kind = m.group(1) if m else "?"
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        continue
    fm = FROM_RE.search(text)
    frm = fm.group(1) if fm else ""
    tm_to = TO_RE.search(text)
    to = tm_to.group(1) if tm_to else ""
    subj, body, had_hdr = split_letter(text)
    if not had_hdr:
        ctl["no_header"] += 1
    if frm in SYSTEM_SENDERS:
        ctl["system"] += 1
        continue
    if re.search(r"#\s*bridge:", subj, re.I) or re.match(r"^\s*Run:\s*python", body):
        ctl["bridge"] += 1
        continue
    senders_all[frm] = senders_all.get(frm, 0) + 1
    if not body.strip():
        ctl["empty_body"] += 1
    if len(re.findall(r"^\s*\|", body, re.M)) >= 2:
        ctl["table_in_body"] += 1

    # схлопывание веерной рассылки: тот же отправитель, то же тело, та же минута
    try:
        minute = int(lid) // 60000
    except ValueError:
        minute = 0
    key = (frm, hashlib.md5(body.strip().encode("utf-8", "replace")).hexdigest(), minute)
    if key in fan_seen:
        ctl["fanout_dropped"] += 1
        recs[fan_seen[key]]["copies"] += 1
        continue
    fan_seen[key] = lid

    full = subj + "\n" + body
    nwords = len(WORD_RE.findall(body))
    ack_names = [an for an, rx in ACK_STRONG if rx.search(full)]
    ack_head = bool(ACK_WEAK_HEAD.match(body.strip()))
    reasons = [cn for cn, rx in CONTENT if rx.search(full)]
    ack_only_subject = bool(ack_names) and not any(rx.search(body) for _, rx in ACK_STRONG)

    tmm = THREAD_RE.search(text)
    parent = tmm.group(1) if tmm and tmm.group(1) != lid else None

    recs[lid] = {"id": lid, "from": frm, "to": to, "kind": kind, "words": nwords,
                 "ack": bool(ack_names) or ack_head, "ack_names": ack_names,
                 "ack_head_only": ack_head and not ack_names,
                 "ack_only_subject": ack_only_subject,
                 "reasons": reasons, "parent": parent, "copies": 1}

# --- классификация --------------------------------------------------------------------------
role = len(recs)
bow_by_thr = {t: [] for t in SHOW}
ack_total = [r for r in recs.values() if r["ack"]]
ack_no_content = [r for r in ack_total if not r["reasons"]]
long_forgiven = [r for r in ack_no_content if r["words"] > SHOW[-1]]
content_reasons = {}
for r in ack_total:
    for c in r["reasons"]:
        content_reasons[c] = content_reasons.get(c, 0) + 1
for r in ack_no_content:
    for t in SHOW:
        if r["words"] <= t:
            bow_by_thr[t].append(r)

bows = {r["id"] for r in bow_by_thr[MAIN]}
by_sender_bow, by_kind_bow = {}, {}
for r in bow_by_thr[MAIN]:
    by_sender_bow[r["from"]] = by_sender_bow.get(r["from"], 0) + 1
    by_kind_bow[r["kind"]] = by_kind_bow.get(r["kind"], 0) + 1

# --- эхо: поклон в ответ на поклон, другим отправителем ---------------------------------------
with_parent = [r for r in recs.values() if r["parent"]]
parent_known = [r for r in with_parent if r["parent"] in recs]
echo = [r for r in parent_known
        if r["id"] in bows and r["parent"] in bows and r["from"] != recs[r["parent"]]["from"]]

# --- ходы: сколько побудок стоит переписка ----------------------------------------------------
deliveries = sum(r["copies"] for r in recs.values())
bow_deliveries = sum(r["copies"] for r in bow_by_thr[MAIN])

random.seed(20260829)
def ids(lst, n=10):
    return [r["id"] for r in random.sample(lst, min(n, len(lst)))]

print(f"ЗАМЕР ДОЛИ ПОКЛОНОВ (ред. 2, после разбора оппонентом) — "
      f"{datetime.now().strftime('%Y-%m-%d %H:%M')} — шина {BUS}")
print(f"файлов просмотрено: {ctl['total']}; системных: {ctl['system']}; мостовых побудок: {ctl['bridge']}; "
      f"копий веерных рассылок схлопнуто: {ctl['fanout_dropped']}")
print(f"РОЛЕВЫХ ОТПРАВОК (знаменатель): {role}; доставок адресатам (ходов): {deliveries}")
print("")
print(f"ПОКЛОН = подтверждение + НИ ОДНОГО признака содержания. Основной порог: тело <= {MAIN} слов.")
for t in SHOW:
    n = len(bow_by_thr[t])
    print(f"  тело <= {t:>2} слов: {n:>4} — {100*n/max(1,role):.1f}% отправок")
print(f"  ходов, потраченных на поклоны (с копиями рассылок): {bow_deliveries} "
      f"({100*bow_deliveries/max(1,deliveries):.1f}% всех доставок)")
print("")
print(f"писем с подтверждением где-либо: {len(ack_total)} ({100*len(ack_total)/max(1,role):.1f}%) "
      f"— ⚠️ это НЕ поклоны, у большинства есть содержание")
print(f"  из них без единого признака содержания: {len(ack_no_content)}")
print(f"  из них помиловано длиной (>{SHOW[-1]} слов): {len(long_forgiven)}")
print(f"почему письмо с подтверждением НЕ поклон: {dict(sorted(content_reasons.items(), key=lambda x: -x[1]))}")
print("")
print(f"ЭХО (поклон в ответ на поклон, другой отправитель): {len(echo)}")
print(f"  знаменатель: ответов со ссылкой на родителя {len(with_parent)}, "
      f"из них родитель найден в корпусе {len(parent_known)}")
print(f"  ⚠️ часть ответов ссылки на родителя не несёт — эхо СНИЗУ, не полное")
print("")
print(f"поклоны по отправителям (порог {MAIN}): {dict(sorted(by_sender_bow.items(), key=lambda x: -x[1]))}")
print(f"всего отправок по отправителям: {dict(sorted(senders_all.items(), key=lambda x: -x[1]))}")
print(f"поклоны по видам писем (порог {MAIN}): {dict(sorted(by_kind_bow.items(), key=lambda x: -x[1]))}")
hist = {"0-8": 0, "9-15": 0, "16-25": 0, "26-40": 0, "41-100": 0, "101+": 0}
for r in recs.values():
    w = r["words"]
    k = ("0-8" if w <= 8 else "9-15" if w <= 15 else "16-25" if w <= 25
         else "26-40" if w <= 40 else "41-100" if w <= 100 else "101+")
    hist[k] += 1
short = sorted(recs.values(), key=lambda r: r["words"])[:12]
print(f"длина ТЕЛА ролевых отправок, слов: {hist}")
print(f"  писем короче {MAIN} слов всего: {hist['0-8']+hist['9-15']+hist['16-25']} "
      f"({100*(hist['0-8']+hist['9-15']+hist['16-25'])/max(1,role):.1f}%) — "
      f"если их почти нет, поклонам просто негде быть")
print(f"контроль разбора: {ctl}")
print("самые короткие письма корпуса (id, слов, подтверждение, признаки содержания):")
for r in short:
    print(f"   {r['id']}  {r['words']:>3} сл.  ack={r['ack']}  {r['reasons']}")
print("")
print("=== ВЫБОРКИ ДЛЯ РУЧНОЙ ПРОВЕРКИ (бьют по опасным классам) ===")
band = [r for r in bow_by_thr[40] if 26 <= r["words"] <= 40]
print(f"1. поклоны длиной 26-40 слов (вне основного порога, самый спорный класс), всего {len(band)}:",
      ids(band))
only_subj = [r for r in bow_by_thr[MAIN] if r["ack_only_subject"]]
print(f"2. поклоны, где подтверждение ТОЛЬКО в теме, всего {len(only_subj)}:", ids(only_subj))
weak = [r for r in bow_by_thr[MAIN] if r["ack_head_only"]]
print(f"3. поклоны по слабому слову в начале тела (ок/хорошо/ясно...), всего {len(weak)}:", ids(weak))
print(f"4. помилованные длиной (подтверждение, содержания нет, но длинные), всего {len(long_forgiven)}:",
      ids(long_forgiven))
for c in ("vopros", "chislo", "spisok", "kod"):
    lst = [r for r in ack_total if c in r["reasons"] and r["words"] <= MAIN]
    print(f"5. короткие письма с подтверждением, спасённые признаком '{c}', всего {len(lst)}:", ids(lst, 5))
print(f"6. случайные поклоны основного порога, всего {len(bow_by_thr[MAIN])}:", ids(bow_by_thr[MAIN]))
