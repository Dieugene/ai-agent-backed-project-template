#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Закрыть пункты списка актуализации одной операцией.

Зачем. Замер 04.09 показал, где свёртка тратит шаги: роль вписывает исход и ставит метку проверки
ПОШТУЧНО, а каждая такая правка идёт двумя ходами («написать патч» + «запустить»), потому что
правки с экранированием нельзя гнать через оболочку. У ведущего вышло 46 ходов против 3-6 весной,
и каждый ход тащит весь накопленный разговор: цена прогона выросла со 136 тыс. токенов до 1,41 млн.

Роль пишет ОДИН файл исходов и делает ОДИН запуск. По строке на пункт, четыре поля:

    П1 | подтверждено | открыл запись, строка про диагностику на месте | руками — только диагностика
    П2 | заменил | число отменено владельцем 30.08, внёс в реестр | порог 15% берём из
    П7 | перенесено | нужен прогон на боевом, сейчас не проверить

🛑 ЧЕТВЁРТОЕ ПОЛЕ — ДОСЛОВНАЯ ЦИТАТА из записи, и она обязательна для закрывающих исходов.
Без неё «подтверждено» стоит ноль: канон требует назвать свою строку, которой помощник не
цитировал, и до сих пор это не проверялось ничем. Здесь проверяется машиной: цитата ищется в теле
записи, а если рядом лежит файл вердиктов помощника — ещё и сверяется с его цитатами, чтобы
согласие не сводилось к повторению чужого. Не нашлась — исход не записывается и метка не ставится.

Разделитель — вертикальная черта, но разбор идёт на четыре поля максимум: черта живёт и внутри
цитат («| grep -q» врёт под pipefail), поэтому хвост остаётся хвостом, а не режется дальше.

Что делает:
  1. вписывает исход в свой пункт списка;
  2. по закрывающим исходам ставит `checked:` — вызовом mark_checked.mark(), одной реализацией;
  3. говорит вслух: пункты без исхода, «подтверждено» без основания или без цитаты, дубли,
     нераспознанные строки, исходы не из словаря. Есть замечания — код возврата 1.

🛑 Ничего не решает за роль: исходы придумывает она, инструмент только записывает и проверяет форму.

    python memory-close.py --list <список.md> --outcomes <исходы.txt> --dir <каталог памяти>
    python memory-close.py ... --dry-run     # показать, не трогая файлов
"""
import argparse
import importlib.util
import io
import os
import re
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent

# 🛑 Заголовок пункта ловим ЛЮБОЙ, а не только «файл в обратных кавычках»: сборщик печатает ещё
# почтовые пункты («### П1. Пришло: <тема>», «Сказал человек (X)») и слабые пункты со знаком `~`
# перед номером. Прежний образец их не видел — и, что хуже, не считал в остатке: роль получала
# «осталось без исхода: 0» на списке, где половина пунктов даже не разобрана (разбор оппонента).
ITEM_RE = re.compile(r"^###\s+(?:~\s*)?(П\d+)\.\s*(.*)$", re.M)
RECORD_RE = re.compile(r"`([^`]+\.md)`")
# 🛑 Внешний пункт (письмо соседа, слово человека) называет записи не в заголовке, а в теле —
# строками «в памяти об этом же: `имя:строка`» (без расширения). До 05.09 закрыватель видел запись
# только в заголовке и отказывал внешним пунктам в обе стороны («пункт не называет записи» с
# цитатой, «нет цитаты» без неё) — штатный путь для целого класса пунктов был закрыт. Нашёл
# ведущий на своей свёртке, воспроизвёл я на своём списке.
REF_RE = re.compile(r"`([A-Za-z0-9_\-]+?)(?:\.md)?(?::\d+)?`")
# Явное имя записи в четвёртом поле — «имя.md: цитата» — для пункта, у которого записей в теле нет
# вовсе (например, исход «заменил» с записью знания в НОВЫЙ файл).
EXPLICIT_RE = re.compile(r"^\s*([A-Za-z0-9_\-]+\.md)\s*:\s*(.+)$", re.S)
OUTCOME_RE = re.compile(r"^- \*\*исход:\*\*(.*)$", re.M)
PLANT_MARK = "утверждение под проверку"      # так подписана подсадная позиция (plant.py)
# 🛑 Защита «был ли помощник» — по штампу расчёта `.verdicts-stamp-<роль>.json` рядом со списком
# (пишут memory-audit.ps1 при запуске и memory-verdicts.py на каждом выходе). Режимы:
#   advise — сказать вслух, записать в журнал `.close-gate-<роль>.log`, исходы ВПИСАТЬ;
#   strict — отказать (исходы не записывать), пока расчёт идёт или его не запускали.
# Первый цикл идёт в advise: канон и закрыватель ложатся на живые роли обеих машин сразу, и ошибка
# в штампе стоила бы каждой роли её свёртки (оппонент 07.09). На strict переключать после того, как
# число «отказал бы» по журналу объяснено. Флаг --gate перекрывает константу (пробы).
GATE_MODE = "advise"

# Основание — признак ссылки на источник, а не вежливое слово.
# ⚠️ ОСНОВЫ слов, а не словоформы: боевой прогон 05.09 отверг девять честных оснований подряд
# («проверено», «сверил», «применял») только потому, что в словаре лежала другая форма. Проверка
# формы, отвергающая существо, хуже отсутствия проверки — роль начнёт подгонять слова под словарь.
GROUNDS = ("перв", "наблюд", "свер", "открыл", "строк", "прогон", "замер", "видел", "провер",
           "по файлу", "цитат", "примен", "сравн", "измер",
           # добавлено 05.09 по отвергнутым честным основаниям ведущего («принял довод помощника,
           # сверил шапку с телом») и моим («внёс в реестр», «исполнено»)
           "сопост", "слич", "довод", "исполн", "внёс", "внесл", "снял", "запис")
CLOSING = ("подтверждено", "заменил")
QUOTE_MIN = 12          # короче — не цитата, а обрывок, который найдётся в любом тексте


def load_sibling(name, attr):
    """Взять функцию/константу из соседнего модуля. Нет модуля — работаем без неё, но вслух."""
    p = HERE / name
    if not p.is_file():
        return None
    try:
        spec = importlib.util.spec_from_file_location(name.replace("-", "_")[:-3], str(p))
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return getattr(mod, attr, None)
    except Exception:
        return None


# 🛑 Словарь исходов и простановка метки берутся у соседей, а не переписываются здесь. Вторая
# реализация метки уже расходилась с первой (корневой `checked:` против метки внутри metadata),
# а свой список исходов разъехался бы со сборщиком журнала: он нормализует по своему кортежу, и
# всё, что мимо, уходит в журнал как ПУСТО — при том что роль считала пункт закрытым.
VALID_OUTCOMES = load_sibling("memory-revision.py", "VALID_OUTCOMES") or (
    "подтверждено", "заменил", "верны при условии", "спорит", "спросить владельца",
    "ложная тревога", "перенесено")
mark_checked = load_sibling("mark_checked.py", "mark")
stamp_read = load_sibling("memory-verdicts.py", "stamp_read")
stamp_state = load_sibling("memory-verdicts.py", "stamp_state")
# Третий читатель штампа: без этого свёртка с непокрытым отказом проходила у закрывателя как
# «помощник был» — два канала предупреждали, а журнал гейта молчал.
uncovered_failure = load_sibling("memory-verdicts.py", "uncovered_failure")


def gate_problems(lst, mem, outcomes):
    """[(вес, текст)]: вес 'stop' — в strict отказ; 'note' — сказать и пустить.
    Помощника у роли нет вовсе (модуля рядом нет) — защиты нет, закрыватель работает как раньше:
    отсутствие штампа тогда неотличимо от «роль забыла», и роль без помощника закрыватель терять
    не должна (оппонент 07.09, п.16)."""
    if not (HERE / "memory-verdicts.py").is_file() or not stamp_read or not stamp_state:
        return []
    lst = Path(lst)
    role = Path(mem).name
    st = stamp_read(lst.parent / (".verdicts-stamp-%s.json" % role))
    out = []
    if not st:
        out.append(("stop", "расчёт вердиктов в эту свёртку не запускался (штампа рядом со списком нет) — "
                            "первая строка канона `pool handoff`; закрываешь без помощника, скажи это в отчёте"))
    else:
        state, why = stamp_state(st)
        if state == "running":
            out.append(("stop", "расчёт вердиктов ещё идёт (с %s, %s) — дождись командой "
                                "`memory-verdicts.py --wait --dir <память>` и закрывай после"
                        % (st.get("started"), st.get("phase"))))
        elif state != "done":
            out.append(("note", "помощника не было: %s — закрываешь без него, скажи это в отчёте" % (why or state)))
        if uncovered_failure:
            u = uncovered_failure(st)
            if u:
                out.append(("note", "%s — по этим пунктам вердиктов могло не быть; скажи это в "
                                    "отчёте владельцу" % u))
        try:
            if st.get("list") and Path(st["list"]).resolve() != lst.resolve():
                out.append(("stop", "штамп относится к списку %s, а закрывается %s — подмена списка"
                            % (st["list"], lst)))
        except OSError:
            pass
    try:
        if lst.stat().st_mtime > Path(outcomes).stat().st_mtime:
            out.append(("stop", "список изменён ПОЗЖЕ файла исходов — пересобран? номера пунктов могли съехать; "
                                "сверь номера по свежему списку и перезапиши файл исходов"))
    except OSError:
        pass
    return out


def read(p):
    """Читаем БАЙТ-В-БАЙТ (newline=''): иначе запись с CRLF после правки станет LF целиком, и
    проверка «заменил» увидит сотни убранных строк там, где убрано ноль (разбор оппонента)."""
    try:
        return io.open(p, encoding="utf-8", errors="replace", newline="").read()
    except OSError:
        return ""


def write_atomic(p, text):
    p = Path(p)
    tmp = p.with_suffix(p.suffix + ".tmp")
    io.open(tmp, "w", encoding="utf-8", newline="").write(text)
    os.replace(str(tmp), str(p))


def parse_outcomes(path):
    """Файл исходов -> ({'П1': (исход, основание, цитата)}, замечания)."""
    out, notes = {}, []
    for raw in io.open(path, encoding="utf-8", errors="replace"):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        # ⚠️ Максимум ЧЕТЫРЕ поля: дальше не режем — вертикальная черта живёт внутри цитат.
        parts = [x.strip() for x in line.split("|", 3)]
        if len(parts) < 2 or not re.match(r"^П\d+$", parts[0]):
            notes.append("НЕ РАЗОБРАНА строка: %s" % line[:70])
            continue
        key, verdict = parts[0], parts[1]
        why = parts[2] if len(parts) > 2 else ""
        quote = parts[3] if len(parts) > 3 else ""
        if key in out:
            notes.append("%s: строка встречается дважды, беру последнюю" % key)
        if not any(verdict.lower().startswith(v) for v in VALID_OUTCOMES):
            notes.append("%s: исход «%s» не из словаря — сборщик запишет его как ПУСТО"
                         % (key, verdict[:30]))
        # 🛑 Черта внутри ОСНОВАНИЯ сдвигает поля: цитатой становится хвост основания, а настоящая
        # цитата уезжает за четвёртое поле и не ищется. Признак не строгий, но назвать его дешевле,
        # чем искать причину «цитата не нашлась» руками (находка ведущего 05.09).
        elif len(parts) == 4 and "|" in quote and quote.count("|") >= 1 and len(why) < 12:
            notes.append("%s: похоже, черта «|» стоит внутри основания — поля сдвинулись; "
                         "внутри полей черту не ставить" % key)
        out[key] = (verdict, why, quote)
    return out, notes


def items_of(text):
    """[(ключ, файл записи или '', заголовок, начало, конец, записи-кандидаты из тела)] по всему
    списку. Кандидаты собираются только у пунктов без записи в заголовке (внешний вход)."""
    marks = [(m.group(1), m.group(2), m.start()) for m in ITEM_RE.finditer(text)]
    res = []
    for i, (key, title, start) in enumerate(marks):
        end = marks[i + 1][2] if i + 1 < len(marks) else len(text)
        rec = RECORD_RE.search(title)
        cands = []
        if not rec:
            for m in REF_RE.finditer(text[start:end]):
                n = m.group(1) + ".md"
                if n not in cands:
                    cands.append(n)
        res.append((key, rec.group(1) if rec else "", title, start, end, cands))
    return res


def flatten(text):
    """Схлопнуть пробелы и снять разметку: в записях фраза почти всегда несёт `**`, `` ` `` или
    подчёркивание внутри, и роль, копируя её глазами, разметку не воспроизводит. Боевой прогон
    05.09: цитата «обвязка кладёт туда коммит на каждый проход» не нашлась только потому, что в
    файле она записана как «обвязка кладёт туда **коммит на каждый проход**»."""
    return " ".join(re.sub(r"[*`_~]+", "", text).split())


def quote_ok(mem, record, quote):
    """Цитата обязана находиться в теле записи. Пробелы схлопываем: перенос строки в файле не
    должен мешать роли скопировать фразу."""
    if not record:
        return False, ("пункт не называет записи — назови её сам в четвёртом поле: «имя.md: цитата»")
    body = read(Path(mem) / record)
    if not body:
        return False, "записи %s нет на диске" % record
    if flatten(quote) not in flatten(body):
        return False, "цитата в записи %s не найдена" % record
    return True, ""


def helper_quotes(list_path, role_hint=""):
    """Цитаты помощника из его отчёта — чтобы согласие не сводилось к повторению чужого."""
    d = Path(list_path).parent
    name = "verdicts-%s.md" % (role_hint or Path(list_path).stem)
    return read(d / name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", dest="lst", required=True)
    ap.add_argument("--outcomes", required=True)
    # 🛑 Каталог памяти ОБЯЗАТЕЛЕН: у списка и памяти нет общего корня, а умолчание «рядом со
    # списком» давало правдоподобный успех — исходы записаны, метки не поставлены ни одной.
    ap.add_argument("--dir", dest="mem", required=True)
    ap.add_argument("--date", default=time.strftime("%Y-%m-%d"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--gate", choices=("advise", "strict"), default=GATE_MODE,
                    help="защита «был ли помощник»: advise — предупредить, strict — отказать")
    args = ap.parse_args()

    text = read(args.lst)
    if not text:
        print("нет списка: %s" % args.lst)
        return 2
    mem = Path(args.mem)
    if not mem.is_dir():
        print("нет каталога памяти: %s" % mem)
        return 2

    outcomes, notes = parse_outcomes(args.outcomes)
    if not outcomes:
        print("исходов не найдено — ничего не делаю")
        for n in notes:
            print("   ⚠️ " + n)
        return 2

    gate = gate_problems(args.lst, mem, args.outcomes)
    if gate:
        stops = [t for w, t in gate if w == "stop"]
        print("ЗАЩИТА «был ли помощник»%s:" % (" (пока только предупреждает)" if args.gate == "advise" else ""))
        for w, t in gate:
            print("   %s %s" % ("⛔" if w == "stop" else "ℹ️", t))
        # Журнал — ряд для решения о strict: сколько закрытий защита отказала бы и почему.
        try:
            log = Path(args.lst).parent / (".close-gate-%s.log" % mem.name)
            with io.open(log, "a", encoding="utf-8", newline="\n") as f:
                for w, t in gate:
                    f.write("%s\t%s\t%s\t%s\n" % (time.strftime("%Y-%m-%d %H:%M"), args.gate, w, t))
        except OSError:
            pass
        if stops and args.gate == "strict" and not args.dry_run:
            print("исходы НЕ записаны: защита в режиме strict")
            return 3

    items = items_of(text)
    known = dict((k, (rec, title)) for k, rec, title, _, _, _ in items)
    helper = helper_quotes(args.lst, mem.name)

    written, to_mark = 0, []
    # Идём с конца: вставки не сдвигают позиции ещё не обработанных блоков.
    for key, rec, title, start, end, cands in reversed(items):
        if key not in outcomes:
            continue
        verdict, why, quote = outcomes[key]
        block = text[start:end]
        m = OUTCOME_RE.search(block)
        if not m:
            notes.append("%s: в пункте нет строки исхода" % key)
            continue
        if m.group(1).strip():
            notes.append("%s: исход уже стоит, не трогаю" % key)
            continue

        closing = any(verdict.lower().startswith(v) for v in CLOSING)
        if closing:
            if not any(g in why.lower() for g in GROUNDS):
                notes.append("%s: «%s» без основания — назови, чем подтверждено; не записал"
                             % (key, verdict))
                continue
            if len(quote) < QUOTE_MIN:
                notes.append("%s: нет цитаты из записи (нужно четвёртое поле) — не записал" % key)
                continue
            # Запись названа явно в четвёртом поле («имя.md: цитата») — она и проверяется, и метится.
            em = EXPLICIT_RE.match(quote)
            if em:
                rec, quote = em.group(1), em.group(2).strip()
            # Внешний пункт: записи названы в теле — берём ту, где цитата нашлась; ни в одной —
            # отказ с перечнем, а не «цитировать нечего».
            if not rec and cands:
                found = None
                for c in cands:
                    if quote_ok(mem, c, quote)[0]:
                        found = c
                        break
                if not found:
                    notes.append("%s: цитата не найдена ни в одной из записей, названных в пункте (%s) — не записал"
                                 % (key, ", ".join(cands[:5])))
                    continue
                rec = found
            good, why_not = quote_ok(mem, rec, quote)
            if not good:
                notes.append("%s: %s — не записал" % (key, why_not))
                continue
            if quote and flatten(quote) in flatten(helper):
                notes.append("%s: эту строку уже цитировал помощник — нужна СВОЯ; не записал" % key)
                continue
        elif verdict.lower().startswith("перенесено") and not why:
            notes.append("%s: «перенесено» без причины — канон требует назвать её; не записал" % key)
            continue

        line = "- **исход:** " + verdict + ((" — " + why) if why else "")
        if closing and quote:
            line += ". Своя строка: «%s»" % quote
        # ⚠️ Хвост [ \t]*, а НЕ \s*: жадный пробельный класс съедает перенос и приклеивает исход к
        # следующему заголовку — 14 пунктов выглядели как 3 и разбор ломался молча (30.08).
        text = text[:start] + block[:m.start()] + line + block[m.end():] + text[end:]
        written += 1
        # 🛑 Метку ставим ТОЛЬКО по записанному сейчас исходу — и не подсадной позиции: она
        # предъявляется из реестра отмен, а метка вывела бы этот реестр из проверки на 14 суток,
        # то есть навсегда (подсадная берётся оттуда каждый проход).
        if closing and rec and PLANT_MARK not in title:
            to_mark.append((key, rec))

    for key in outcomes:
        if key not in known:
            notes.append("%s: такого пункта в списке нет" % key)

    marked = []
    for key, rec in to_mark:
        p = mem / rec
        if not p.is_file():
            notes.append("%s: записи %s нет — метка не поставлена" % (key, rec))
            continue
        if args.dry_run:
            marked.append("%s -> %s (проба, не писал)" % (key, rec))
        elif mark_checked:
            marked.append("%s -> %s (%s)" % (key, rec, mark_checked(str(p), args.date)))
        else:
            notes.append("%s: mark_checked.py рядом нет — метку поставь сам" % key)

    if written and not args.dry_run:
        # ⚠️ Пишем список ТОЛЬКО при настоящей правке: его время изменения читают проверка
        # «список старше суток» и окно сверки «заменил», и холостой прогон сдвигал бы оба.
        write_atomic(args.lst, text)

    left = []
    for k, _, _, s, e, _ in items_of(text):
        mm = OUTCOME_RE.search(text[s:e])
        if mm and not mm.group(1).strip():
            left.append(k)

    print("%sвписано исходов: %d из %d предъявленных пунктов"
          % ("[проба] " if args.dry_run else "", written, len(items)))
    if marked:
        print("метки проверки:")
        for line in marked:
            print("   " + line)
    if notes:
        print("замечания:")
        for line in notes:
            print("   ⚠️ " + line)
    print("осталось без исхода: %d%s" % (len(left), (" (" + ", ".join(left) + ")") if left else ""))
    return 1 if notes else 0


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    sys.exit(main())
