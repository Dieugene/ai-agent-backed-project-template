# -*- coding: utf-8 -*-
"""Замер переписки пула по механике обязательств. Читает, ничего не меняет.

    python3 measure_oblig.py --bus <шина> [--split <ts_ms>] [--names этап1,этап2]

Зачем: сравнивать этапы работы числами, а не впечатлением, и одним и тем же способом —
иначе разница между этапами неотличима от разницы между двумя ручными подсчётами.

Определения (от них зависит каждое число ниже, поэтому они здесь, а не в голове):
  письмо           — файл вида <ts>-<hash>.from-<кто>.<сорт>[.<...>].md в ящике шины
                     (<ящик>/new, <ящик>/cur) или в archive/. Один <ts>-<hash> — одно
                     письмо: переезд new -> cur -> archive это переименование, но если
                     копия всё же встретится, берётся та, у которой шапка полнее.
  письмо роли      — отправитель не служебный (SERVICE); отправитель берётся ИЗ ИМЕНИ
                     ФАЙЛА: оно есть всегда, а шапка может не разобраться.
  поле обязательства — Opens / About / Closes в шапке.
  ключ             — значение любого из этих трёх полей; в одном письме один и тот же
                     ключ считается ОДИН раз, даже если стоит в двух полях.
  зонтик           — ключ, под которым больше всего писем.
  закрыл ждущий    — отправитель письма с Closes совпадает с отправителем письма с Opens
                     того же ключа. Ждущий — тот, кто открыл: он же и принимает.

⚠️ Жизненный цикл обязательства НЕ режется границей этапов: `opens`/`closes` собираются
по всей шине один раз, иначе обязательство, открытое до границы и закрытое после, дало бы
«не закрыто» в раннем этапе и «закрыл посторонний» в позднем — оба смещения в одну сторону.
Границей режутся только ПИСЬМА.

⚠️ Поле `Thread` здесь НЕ метрика: в этой шине ответ заводит собственный тред, поэтому
«писем на тред» всегда около единицы и ничего не измеряет. Длину переписки меряем по
ключу обязательства.
"""

from __future__ import annotations

import argparse
import glob
import os
import re

MACHINE_OPENERS = {"dispatcher", "pool-monitor", "bridge", "antiflood", "controller"}
import sys
from collections import Counter

HDR = re.compile(r"^\|\s*(From|To|Date|Thread|Opens|Expect|CloseWhen|About|Closes|Outcome)\s*\|\s*(.*?)\s*\|\s*$")
SUBJ = re.compile(r"^#\s+(.+?)\s*$")
FROM_IN_NAME = re.compile(r"\.from-([^.]+)\.")
KIND_IN_NAME = re.compile(r"\.from-[^.]+\.([^.]+)")
SERVICE = ("pool-monitor", "pool-controller", "system", "migration", "flood", "oblig")


def esc(s):
    """Значение в ячейку markdown-таблицы: своя палка разъехала бы таблицу у читателя."""
    return str(s).replace("|", "\\|")


def is_service(sender):
    return any((sender or "").startswith(s) for s in SERVICE)


def read_head(path):
    """Тема (первый заголовок) и поля шапки. Читаем 41 строку: таблица шапки всегда
    в начале. Перенос строки внутри шапки разбор не обрывает — проверено на корпусе,
    но дешевле дочитать до конца окна, чем полагаться на это."""
    h, subj = {}, ""
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
            m = HDR.match(line)
            if m:
                h[m.group(1)] = m.group(2).replace("\\|", "|")
    return subj, h


def collect(bus):
    """Все письма шины, по одному экземпляру на id."""
    b = glob.escape(bus)
    paths = (glob.glob(os.path.join(b, "*", "new", "*.md")) +
             glob.glob(os.path.join(b, "*", "cur", "*.md")) +
             glob.glob(os.path.join(b, "new", "*.md")) +
             glob.glob(os.path.join(b, "cur", "*.md")) +
             glob.glob(os.path.join(b, "archive", "*.md")) +
             glob.glob(os.path.join(b, "archive", "*", "*.md")))
    seen, dup, skipped = {}, 0, 0
    for p in sorted(set(paths)):
        base = os.path.basename(p)
        mid = base.split(".")[0]
        try:
            ts = int(mid.split("-")[0])
            size = os.path.getsize(p)
            subj, h = read_head(p)
        except (ValueError, OSError):
            skipped += 1
            continue
        mf = FROM_IN_NAME.search(base)
        sender = mf.group(1) if mf else h.get("From", "")
        mk = KIND_IN_NAME.search(base)
        kind = mk.group(1) if mk else ""
        rec = (ts, size, subj, h, base, sender, kind)
        if mid in seen:
            dup += 1
            # детерминированный выбор: полнее шапка, при равенстве — больший файл
            if (len(h), size) <= (len(seen[mid][3]), seen[mid][1]):
                continue
        seen[mid] = rec
    return sorted(seen.values(), key=lambda r: (r[0], r[4])), dup, skipped


def registry(msgs):
    """Реестр обязательств по ВСЕЙ шине: кто открыл, чем, кто закрыл."""
    opens, closes = {}, {}
    for ts, sz, subj, h, base, sender, kind in msgs:
        k = h.get("Opens")
        if k and k not in opens:
            opens[k] = (sender, h.get("Expect", ""), h.get("CloseWhen", ""), subj)
        k = h.get("Closes")
        if k and k not in closes:
            closes[k] = (sender, h.get("Outcome", ""))
    return opens, closes


def stats(msgs, label, opens_all, closes_all):
    # События (`close`/`amend`) — не письма: они никому не приходят и ничьего хода не стоят.
    # Считать их вместе с письмами значило бы, что тихое закрытие «не дало экономии»: число
    # осталось бы прежним, хотя ходов стало меньше. Поэтому отдельная строка.
    events = [m for m in msgs if m[6] == "event"]
    role = [m for m in msgs if not is_service(m[5]) and m[6] != "event"]
    withf = [m for m in role if any(m[3].get(f) for f in ("Opens", "About", "Closes"))]
    total_b = sum(m[1] for m in msgs)

    keys, key_vol = Counter(), Counter()
    for ts, sz, subj, h, base, sender, kind in msgs:
        ks = {h[f] for f in ("Opens", "About", "Closes") if h.get(f)}
        for k in ks:
            keys[k] += 1
            key_vol[k] += sz

    # обязательства, ОТКРЫТЫЕ в этом срезе
    opened_here = [m[3]["Opens"] for m in msgs if m[3].get("Opens")]
    opened_here = list(dict.fromkeys(opened_here))
    closed_here = [k for k in opened_here if k in closes_all]
    by_waiter = sum(1 for k in closed_here if closes_all[k][0] == opens_all[k][0])
    # Обязательства, открытые машинными ролями (диспетчер картотеки и подобные), закрыть может только
    # исполнитель — машина не закрывает. В норме «закрывает ждущий» они не участвуют (слово владельца 05.09).
    machine_exec = sum(1 for k in closed_here
                       if opens_all[k][0] in MACHINE_OPENERS and closes_all[k][0] != opens_all[k][0])
    human_total = len(closed_here) - machine_exec
    orphan = sorted({m[3]["Closes"] for m in msgs
                     if m[3].get("Closes") and m[3]["Closes"] not in opens_all})
    top = max(keys, key=lambda k: keys[k]) if keys else None
    expect_len = [len(opens_all[k][1]) for k in opened_here if opens_all[k][1]]
    cw_len = [len(opens_all[k][2]) for k in opened_here if opens_all[k][2]]
    heavy = {k: keys[k] for k in opened_here if keys[k] > 5}

    out = []
    A = out.append
    A("## %s" % label)
    A("")
    A("| Что | Значение |")
    A("|---|---|")
    A("| писем всего (включая служебные) | %d |" % (len(msgs) - len(events)))
    A("| событий реестра (close/amend, ходов не стоят) | %d |" % len(events))
    A("| писем ролей | %d |" % len(role))
    A("| из них с полем обязательства | %d |" % len(withf))
    A("| ролевых писем БЕЗ полей | %d (%.0f%%) |"
      % (len(role) - len(withf), 100.0 * (len(role) - len(withf)) / max(len(role), 1)))
    A("| объём | %.0f КБ |" % (total_b / 1024))
    A("| средний размер письма | %.1f КБ |" % (total_b / 1024 / max(len(msgs), 1)))
    A("| обязательств открыто | %d |" % len(opened_here))
    A("| из них закрыто | %d |" % len(closed_here))
    A("| писем на обязательство | %.1f |"
      % (sum(keys[k] for k in opened_here) / max(len(opened_here), 1)))
    A("| обязательств тяжелее пяти писем | %d |" % len(heavy))
    A("| закрыл ждущий / закрыл исполнитель | %d / %d |" % (by_waiter, len(closed_here) - by_waiter))
    A("| из закрытий исполнителем — по машинным обязательствам (%s) | %d |" % (", ".join(sorted(MACHINE_OPENERS)), machine_exec))
    A("| закрыл ждущий без машинных обязательств | %d из %d = %d%% |" % (by_waiter, human_total, (100 * by_waiter // human_total) if human_total else 0))
    if orphan:
        A("| закрытий без открытия (диагностика) | %d: %s |" % (len(orphan), esc(", ".join(orphan))))
    if top:
        A("| зонтик (самый нагруженный ключ) | `%s`: %d писем, %.0f%% объёма |"
          % (esc(top), keys[top], 100.0 * key_vol[top] / max(total_b, 1)))
    A("| открытий с полем Expect | %d из %d |" % (len(expect_len), len(opened_here)))
    A("| открытий с полем CloseWhen | %d из %d |" % (len(cw_len), len(opened_here)))
    if expect_len:
        A("| длина Expect, знаков | мин %d / сред %d / макс %d |"
          % (min(expect_len), sum(expect_len) // len(expect_len), max(expect_len)))
    if cw_len:
        A("| длина CloseWhen, знаков | мин %d / сред %d / макс %d |"
          % (min(cw_len), sum(cw_len) // len(cw_len), max(cw_len)))
    A("")
    A("### Обязательства, открытые в этом срезе")
    A("")
    for k in sorted(opened_here, key=lambda x: -keys[x]):
        who, exp, cw, subj = opens_all[k]
        if k in closes_all:
            state = "закрыл `%s` (%s)" % (closes_all[k][0], closes_all[k][1] or "исход не назван")
        else:
            state = "**НЕ ЗАКРЫТО**"
        A("- **`%s`** — открыл `%s`, писем %d, %.0f КБ, %s"
          % (esc(k), who, keys[k], key_vol[k] / 1024, state))
        A("  - Тема: %s" % esc(subj or "—"))
        A("  - Expect: %s" % esc(exp or "— (поля нет)"))
        A("  - CloseWhen: %s" % esc(cw or "— (поля нет)"))
    A("")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus", required=True)
    ap.add_argument("--split", type=int, default=None, help="граница этапов, ts в мс")
    ap.add_argument("--names", default="до границы,после границы")
    args = ap.parse_args()

    msgs, dup, skipped = collect(args.bus)
    opens_all, closes_all = registry(msgs)
    parts = args.names.split(",")
    n1 = parts[0]
    n2 = parts[1] if len(parts) > 1 else "после границы"

    print("# Замер шины %s" % args.bus)
    print("")
    print("Писем всего: %d. Копий сверх уникальных: %d. Пропущено файлов (имя или чтение): %d."
          % (len(msgs), dup, skipped))
    print("Обязательств на шине: открыто %d, закрыто %d." % (len(opens_all), len(closes_all)))
    print("")
    if args.split is not None:
        print(stats([m for m in msgs if m[0] < args.split],
                    "%s (до %d)" % (n1, args.split), opens_all, closes_all))
        print(stats([m for m in msgs if m[0] >= args.split],
                    "%s (с %d)" % (n2, args.split), opens_all, closes_all))
    else:
        print(stats(msgs, "вся шина", opens_all, closes_all))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    raise SystemExit(main())
