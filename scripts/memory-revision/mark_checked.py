#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Поставить метку `checked:` в шапке записи памяти.

Штатный шаг закрытия пункта списка актуализации: закрыл исходом `подтверждено` или `заменил` —
метка обязана появиться, от неё считается следующий срок (а не от правки файла: правка по другому
поводу иначе молча отодвигала бы проверку).

🛑 Руками этого не делают. Метка живёт ВНУТРИ блока `metadata:` с отступом в два пробела; поставленная
на уровень корня, она читается как чужое поле и не находится ни сборщиком, ни проверкой.

    python mark_checked.py --dir <каталог памяти> [--date ГГГГ-ММ-ДД] запись1 запись2 ...

Имя записи — с расширением или без. Печатает по строке на файл; несуществующее имя — ошибка, а не
молчание: пропущенная метка возвращает пункт в список на следующем же проходе.
"""
import argparse
import io
import re
import sys
import time
from pathlib import Path


def mark(path, date):
    text = io.open(path, encoding="utf-8").read()
    fm = re.match(r"(?s)^---\r?\n(.*?)\r?\n---\r?\n", text)
    if not fm:
        return "НЕТ ШАПКИ (метку ставить некуда)"
    head = fm.group(1)
    if re.search(r"^\s+checked:", head, re.M):
        new_head = re.sub(r"^(\s+)checked:.*$", r"\g<1>checked: " + date, head, count=1, flags=re.M)
        what = "обновлена"
    else:
        # Цепляемся за `modified:` — он есть у всех записей, которые движок когда-либо трогал.
        # Нет и его: кладём последней строкой блока metadata, сохранив её отступ.
        m = re.search(r"^(\s+)modified:.*$", head, re.M)
        if m:
            new_head = head[:m.end()] + "\n%schecked: %s" % (m.group(1), date) + head[m.end():]
        else:
            m2 = re.search(r"^(\s+)\S+:.*$(?![\s\S]*^\s+\S+:)", head, re.M)
            if not m2:
                return "НЕТ БЛОКА metadata (метку ставить некуда)"
            new_head = head[:m2.end()] + "\n%schecked: %s" % (m2.group(1), date) + head[m2.end():]
        what = "поставлена"
    out = text[:fm.start(1)] + new_head + text[fm.end(1):]
    tmp = str(path) + ".tmp-checked"
    io.open(tmp, "w", encoding="utf-8", newline="").write(out)
    Path(tmp).replace(path)
    return "%s: %s" % (what, date)


def main():
    # Тот же приём, что в memory-revision.py: без него кириллица в отчёте о правке приходит
    # кракозябрами, и роль не видит, что именно сделано.
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--date", default=time.strftime("%Y-%m-%d"))
    ap.add_argument("names", nargs="+")
    args = ap.parse_args()

    mem = Path(args.dir)
    bad = 0
    for name in args.names:
        p = mem / (name if name.endswith(".md") else name + ".md")
        if not p.is_file():
            print("НЕТ ФАЙЛА: %s" % p)
            bad += 1
            continue
        print("%-42s %s" % (p.name, mark(p, args.date)))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
