#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пробы для memory-close.py — закрытия пунктов пачкой.

🛑 Список для проверки собирает НАСТОЯЩИЙ сборщик (`memory-revision.py`) на игрушечной памяти, а не
пишется здесь руками. Прежний образец был написан вручную — и все пять блокеров, найденных
оппонентом, лежали ровно за его границей: почтовый пункт, пункт со знаком `~`, подсадная позиция,
пробел в хвосте `- **исход:** `. Проба, чей вход выдуман, проверяет выдумку.

Контракт двух инструментов проверяется целиком: собрать -> закрыть -> снова собрать (harvest) ->
посмотреть журнал и проверку подсадных.

Песочница своя, настоящая память и настоящий список не трогаются.
Мутации, которые ОБЯЗАНЫ покраснеть, — под ключом --mutate.
"""
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
CLOSE = HERE / "memory-close.py"
REVISION = HERE / "memory-revision.py"
PLANT = HERE / "plant.py"

REC = """---
name: %(name)s
description: "%(desc)s"
metadata:
  node_type: memory
  type: reference
%(checked)s  modified: 2026-08-01T10:00:00.000Z
---

%(body)s
"""


def check(name, cond, detail=""):
    print(("  ОК   " if cond else "  КРАСНО ") + name + (("  — " + detail) if detail and not cond else ""))
    return bool(cond)


def run(cmd):
    r = subprocess.run([sys.executable] + [str(x) for x in cmd], capture_output=True, text=True,
                       encoding="utf-8", errors="replace")
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def sandbox(with_mail=True):
    """Игрушечная память + шина с письмом. Возвращает (каталог, память, шина, .revision)."""
    root = Path(tempfile.mkdtemp(prefix="probe-close-"))
    mem = root / "memory" / "probe-role"
    mem.mkdir(parents=True)
    old = time.time() - 40 * 86400
    bodies = {
        "feedback_one": "Владелец сказал дословно: руками этого не делают, только алгоритмом.",
        "ref_two": "Порог берём 45 из кеш-окна; число обосновано в коде, не выдумано.",
        "ref_three": "Сервер в Берлине, отметка хода московская — разница ловится суффиксом журнала.",
        # 🛑 Реестр отмен нужен НАСТОЯЩИЙ: подсадную plant.py берёт из него и требует не меньше
        # трёх позиций с маркером отмены — с одной строкой он молча отвечает «подсаживать не из
        # чего», и проверка подсадных в пробе не проверяла бы ничего.
        "reference_revoked-claims":
            "Отменённые утверждения:\n\n"
            "- «Порог редкости слова берём 15 процентов от числа записей» — отменено владельцем.\n"
            "- «Письма для сверки берём за четырнадцать суток календаря» — отменено, окно по свёртке.\n"
            "- «Доля пунктов без исхода показывает дисциплину роли» — неверен, считает пересборки.\n",
    }
    # 🛑 Корпус должен быть НЕ БЕДНЫМ: порог редкости — доля записей, и на четырёх файлах он режет
    # любое слово (слово из одной записи уже «частое»). На бедном корпусе почтовый пункт не
    # появлялся вовсе, и проба зеленела бы на списке без единого письма — мой же класс отказа.
    for i in range(10):
        bodies["ref_filler_%d" % i] = (
            "Служебная запись-наполнитель номер %d: она нужна, чтобы корпус памяти был "
            "достаточного размера и порог редкости работал как на живой роли." % i)

    for name, body in bodies.items():
        p = mem / (name + ".md")
        io.open(p, "w", encoding="utf-8", newline="").write(
            REC % {"name": name, "desc": "проба " + name, "body": body, "checked": ""})
        os.utime(p, (old, old))
    io.open(mem / "MEMORY.md", "w", encoding="utf-8", newline="").write(
        "# Память\n\n" + "".join("- [%s](%s.md) — проба\n" % (n, n) for n in bodies))

    # 🛑 Песочнице НУЖНА git-история: возраст записи сборщик берёт из метки `checked:`, а где её
    # нет — из последней правки в истории (memory-revision.ages). Без репозитория он отвечает
    # «в истории нет», отбор пуст, и любая проба зеленеет на пустом списке.
    old_iso = time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(old))
    genv = dict(os.environ,
                GIT_AUTHOR_DATE=old_iso, GIT_COMMITTER_DATE=old_iso,
                GIT_AUTHOR_NAME="probe", GIT_AUTHOR_EMAIL="probe@local",
                GIT_COMMITTER_NAME="probe", GIT_COMMITTER_EMAIL="probe@local")
    for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-qm", "проба"]):
        subprocess.run(["git"] + cmd, cwd=str(mem), env=genv, capture_output=True, text=True)

    bus = root / "bus" / "probe-role"
    (bus / "cur").mkdir(parents=True)
    if with_mail:
        io.open(bus / "cur" / "1788000000000-aaa.from-owner.note.md", "w",
                encoding="utf-8", newline="").write(
            # ⚠️ Формат — как в живой шине (заголовок + таблица Field/Value): по другому образцу
            # сборщик не находит отправителя и молча пропускает письмо, а проба зеленеет на списке
            # без почтовых пунктов — ровно там, где лежал блокер.
            # ⚠️ Слово в письме берём РЕДКОЕ и встречающееся ровно в одной записи: письмо цепляется
            # к памяти по редким словам, и на частом оно не даст пункта — раздел будет, пункта нет.
            # ⚠️ Слово-зацепку кладём в ТЕМУ: сборщик ищет совпадения по заголовку письма и полям
            # обязательств, а не по телу. С темой «часы цеха» письмо доезжало, а пункта не давало.
            "# Берлине отметка московская\n\n"
            "| Field | Value |\n|---|---|\n| From | owner |\n| To | probe-role |\n"
            "| Date | 2026-09-04T10:00:00+03:00 |\n\n"
            "Время в Берлине больше не ориентир: отметки хода считаем по московскому.\n")
    rev = root / "revision"
    rev.mkdir()
    return root, mem, bus, rev  # --mail хочет каталог РОЛИ в шине, а не корень шины


def collect(mem, bus, rev, limit=6):
    out = rev / "probe-role.md"
    code, log = run([REVISION, "--dir", mem, "--mail", bus, "--out", out, "--days", "30",
                     "--age-days", "14", "--limit", limit])
    return out, log


def close(lst, outcomes, mem, extra=()):
    f = Path(lst).parent / "outcomes.txt"
    io.open(f, "w", encoding="utf-8", newline="").write(outcomes)
    return run([CLOSE, "--list", lst, "--outcomes", f, "--dir", mem, "--date", "2026-09-04"] + list(extra))


def probes():
    ok = True
    root, mem, bus, rev = sandbox()
    lst, log = collect(mem, bus, rev)
    text = io.open(lst, encoding="utf-8").read()

    keys = re.findall(r"(?m)^###\s+(?:~\s*)?(П\d+)\.", text)
    ok &= check("сборщик дал список с пунктами", len(keys) >= 2, "пунктов: %d; %s" % (len(keys), log[:120]))
    mail_keys = [m.group(1) for m in re.finditer(r"(?m)^###\s+(?:~\s*)?(П\d+)\.\s*(.*)$", text)
                 if "Пришло" in m.group(2) or "Сказал" in m.group(2)]
    ok &= check("в списке есть почтовый пункт", bool(mail_keys),
                "заголовки: %s" % re.findall(r"(?m)^### .*", text)[:2])

    # 🛑 Главная проверка блокера: инструмент обязан ВИДЕТЬ все пункты, включая почтовые и `~`.
    code, out = close(lst, "П1 | перенесено | разберу в следующий проход\n", mem)
    m = re.search(r"вписано исходов: \d+ из (\d+) предъявленных", out)
    ok &= check("инструмент видит столько же пунктов, сколько сборщик",
                bool(m) and int(m.group(1)) == len(keys),
                "инструмент: %s, сборщик: %d" % (m.group(1) if m else "?", len(keys)))

    # Остаток считается по всем пунктам, а не по видимой части.
    m2 = re.search(r"осталось без исхода: (\d+)", out)
    ok &= check("остаток считает все незакрытые", bool(m2) and int(m2.group(1)) == len(keys) - 1,
                "остаток: %s при %d пунктах" % (m2.group(1) if m2 else "?", len(keys)))

    # Закрывающий исход требует основания И цитаты, и цитата проверяется по телу записи.
    # ⚠️ Песочница СВЕЖАЯ: в предыдущей П1 уже закрыт «перенесено», и все проверки ниже упирались
    # бы в «исход уже стоит» — то есть зеленели бы, ничего не проверив.
    rootq, memq, busq, revq = sandbox()
    lst, _ = collect(memq, busq, revq)
    mem = memq
    text = io.open(lst, encoding="utf-8").read()
    age_key, age_rec = None, None
    for mm in re.finditer(r"(?m)^###\s+(?:~\s*)?(П\d+)\.\s*`([^`]+\.md)`", text):
        if "revoked" not in mm.group(2):
            age_key, age_rec = mm.group(1), mm.group(2)
            break
    if not age_key:
        ok &= check("в списке нашёлся возрастной пункт", False, "не нашёл пункта с записью")
    else:
        code, out = close(lst, "%s | подтверждено | всё так\n" % age_key, mem)
        ok &= check("«подтверждено» без основания не записано",
                    "без основания" in out and "не записал" in out, out.strip()[:140])
        code, out = close(lst, "%s | подтверждено | открыл запись, строка на месте\n" % age_key, mem)
        ok &= check("«подтверждено» без цитаты не записано", "нет цитаты" in out, out.strip()[:140])
        code, out = close(lst, "%s | подтверждено | открыл запись | такой строки в записи нет вовсе\n"
                          % age_key, mem)
        ok &= check("выдуманная цитата не проходит", "не найдена" in out, out.strip()[:140])

        body = io.open(mem / age_rec, encoding="utf-8").read()
        real = " ".join(body.strip().splitlines()[-1].split())[:40]
        code, out = close(lst, "%s | подтверждено | открыл запись, сверил | %s\n" % (age_key, real), mem)
        ok &= check("настоящая цитата принята", "вписано исходов: 1" in out, out.strip()[:140])
        ok &= check("метка проверки поставлена",
                    "checked: 2026-09-04" in io.open(mem / age_rec, encoding="utf-8").read())
        ok &= check("исход и своя строка попали в список",
                    "Своя строка" in io.open(lst, encoding="utf-8").read())

        # 🛑 Цитата с РАЗМЕТКОЙ внутри: в записях фраза почти всегда несёт `**` или обратные
        # кавычки, и роль их не воспроизводит. Боевой прогон 05.09 отверг честную цитату именно
        # из-за звёздочек — проверка формы, отвергающая существо, хуже её отсутствия.
        marked = io.open(memq / age_rec, encoding="utf-8").read()
        io.open(memq / age_rec, "w", encoding="utf-8", newline="").write(
            marked.replace("Тело записи.", "Тело записи с **выделенной серединой** внутри."))
        code, out = close(lst, "%s | заменил | сверил с записью | "
                               "Тело записи с выделенной серединой внутри\n" % age_key, memq)
        ok &= check("цитата с разметкой в файле принимается",
                    "вписано исходов: 1" in out or "исход уже стоит" in out, out.strip()[:140])

    # 🛑 Внешний пункт (письмо): запись названа в ТЕЛЕ пункта строкой «в памяти об этом же:
    # `имя:строка`», не в заголовке. До 05.09 закрыватель отказывал таким пунктам в обе стороны —
    # с цитатой «пункт не называет записи», без цитаты «нет цитаты» (нашёл ведущий).
    rootm, memm, busm, revm = sandbox()
    lstm, _ = collect(memm, busm, revm)
    tm = io.open(lstm, encoding="utf-8").read()
    mk = None
    for mm in re.finditer(r"(?m)^###\s+(?:~\s*)?(П\d+)\.\s*(.*)$", tm):
        if "Пришло" in mm.group(2):
            mk = mm.group(1)
            break
    if not mk:
        ok &= check("внешний пункт есть в списке", False, "почтового пункта нет")
    else:
        i0 = tm.index("### " + mk + ".")
        i1 = tm.find("\n### ", i0 + 1)
        blk = tm[i0:i1 if i1 > 0 else len(tm)]
        refs = re.findall(r"`([A-Za-z0-9_\-]+?)(?:\.md)?(?::\d+)?`", blk)
        recs = [r for r in refs if (memm / (r + ".md")).is_file()]
        ok &= check("внешний пункт называет запись в теле", bool(recs), "ссылки: %s" % refs[:4])
        if recs:
            bodym = io.open(memm / (recs[0] + ".md"), encoding="utf-8").read()
            realm = " ".join(bodym.strip().splitlines()[-1].split())[:40]
            code, out = close(lstm, "%s | заменил | сверил письмо с записью | %s\n" % (mk, realm), memm)
            ok &= check("внешний пункт закрыт цитатой из записи, названной в теле",
                        "вписано исходов: 1" in out, out.strip()[:160])
            ok &= check("метка поставлена на запись из тела внешнего пункта",
                        "checked: 2026-09-04" in io.open(memm / (recs[0] + ".md"), encoding="utf-8").read())
    # Явное имя записи в четвёртом поле — «имя.md: цитата» — когда пункт записей не называет
    # (например, знание записано в новый файл).
    rootn, memn, busn, revn = sandbox()
    lstn, _ = collect(memn, busn, revn)
    tn = io.open(lstn, encoding="utf-8").read()
    mk2 = None
    for mm in re.finditer(r"(?m)^###\s+(?:~\s*)?(П\d+)\.\s*(.*)$", tn):
        if "Пришло" in mm.group(2):
            mk2 = mm.group(1)
            break
    if mk2:
        b2 = io.open(memn / "ref_two.md", encoding="utf-8").read()
        q2 = " ".join(b2.strip().splitlines()[-1].split())[:40]
        code, out = close(lstn, "%s | заменил | внёс в запись ref_two | ref_two.md: %s\n" % (mk2, q2), memn)
        ok &= check("явное «имя.md: цитата» в четвёртом поле принимается", "вписано исходов: 1" in out, out.strip()[:160])
        ok &= check("метка по явно названной записи поставлена",
                    "checked: 2026-09-04" in io.open(memn / "ref_two.md", encoding="utf-8").read())
        # основание «внёс…» — из добавленных 05.09 основ: честная формулировка не отвергается
        ok &= check("основание «внёс в запись» принято словарём основ", "без основания" not in out, out.strip()[:120])
    for d in (rootm, rootn):
        shutil.rmtree(d, ignore_errors=True)

    # Подсадная: метку ставить нельзя, иначе реестр отмен уходит из проверки навсегда.
    root2, mem2, bus2, rev2 = sandbox()
    lst2, _ = collect(mem2, bus2, rev2)
    run([PLANT, "--dir", mem2, "--list", lst2, "--n", "1"])
    t2 = io.open(lst2, encoding="utf-8").read()
    pk = None
    for mm in re.finditer(r"(?m)^###\s+(?:~\s*)?(П\d+)\.\s*(.*)$", t2):
        if "утверждение под проверку" in mm.group(2):
            pk = mm.group(1)
            hit = re.search(r"`([^`]+\.md)`", mm.group(2))
            prec = hit.group(1) if hit else ""
            break
    if not pk:
        ok &= check("подсадная позиция появилась в списке", False, "plant не подсадил")
    else:
        body = io.open(mem2 / prec, encoding="utf-8").read()
        real2 = " ".join(body.strip().splitlines()[-1].split())[:40]
        code, out = close(lst2, "%s | заменил | сверил с реестром | %s\n" % (pk, real2), mem2)
        ok &= check("на подсадной метка НЕ ставится",
                    "checked: 2026-09-04" not in io.open(mem2 / prec, encoding="utf-8").read(),
                    out.strip()[:140])

    # Контракт со сборщиком: закрытый исход доезжает до журнала как исход, а не как ПУСТО.
    jr = revq / "journal.tsv"
    collect(memq, busq, revq)
    if jr.is_file() and age_rec:
        rows = [r for r in io.open(jr, encoding="utf-8", errors="replace").read().splitlines()
                if age_rec in r]
        ok &= check("закрытый пункт доехал до журнала исходом, а не ПУСТО",
                    bool(rows) and "ПУСТО" not in rows[-1],
                    (rows[-1] if rows else "строки про %s в журнале нет" % age_rec)[:150])
    else:
        ok &= check("журнал появился после пересборки", False, "нет %s" % jr)

    # --dry-run ничего не пишет.
    root3, mem3, bus3, rev3 = sandbox()
    lst3, _ = collect(mem3, bus3, rev3)
    before = io.open(lst3, encoding="utf-8").read()
    k3 = re.search(r"(?m)^###\s+(?:~\s*)?(П\d+)\.\s*`([^`]+\.md)`", before)
    if k3:
        b3 = io.open(mem3 / k3.group(2), encoding="utf-8").read()
        q3 = " ".join(b3.strip().splitlines()[-1].split())[:40]
        close(lst3, "%s | подтверждено | открыл запись | %s\n" % (k3.group(1), q3), mem3, ("--dry-run",))
        ok &= check("при --dry-run ничего не записано",
                    io.open(lst3, encoding="utf-8").read() == before
                    and "checked: 2026-09-04" not in io.open(mem3 / k3.group(2), encoding="utf-8").read())

    # Код возврата: замечания видны обвязке, а не только человеку.
    code, out = close(lst3, "мусорная строка\n", mem3)
    ok &= check("замечания дают ненулевой код возврата", code != 0, "код: %d" % code)

    # Забытый каталог памяти — отказ, а не правдоподобный успех.
    r = subprocess.run([sys.executable, str(CLOSE), "--list", str(lst3),
                        "--outcomes", str(Path(lst3).parent / "outcomes.txt")],
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    ok &= check("без --dir инструмент не работает", r.returncode != 0, "код: %d" % r.returncode)

    for d in (root, rootq, root2, root3):
        shutil.rmtree(d, ignore_errors=True)
    # 27-30. 🛑 Защита «был ли помощник»: без штампа — предупреждение (advise) / отказ (strict);
    # штамп running с исчезнувшим процессом — «помощника не было», исходы вписаны; running с живым
    # процессом — «дождись»; список новее исходов — предупреждение; журнал защиты пополняется.
    import json as _json, re as _re
    root3, mem3, bus3, rev3 = sandbox()
    lst3, _ = collect(mem3, bus3, rev3)
    t3 = io.open(lst3, encoding="utf-8").read()
    k3 = _re.findall(r"^###\s+(?:~\s*)?(П\d+)\.", t3, _re.M)
    stp3 = Path(lst3).parent / ".verdicts-stamp-probe-role.json"
    log3 = Path(lst3).parent / ".close-gate-probe-role.log"
    if len(k3) >= 3:
        code, out = close(lst3, "%s | перенесено | нужен прогон\n" % k3[0], mem3)
        ok &= check("без штампа (advise): предупреждение про `pool handoff`, исход ВПИСАН",
                    "ЗАЩИТА" in out and "pool handoff" in out and "вписано исходов: 1" in out, out[:300])
        ok &= check("журнал защиты пополнился строкой stop", log3.is_file() and "\tstop\t" in io.open(log3, encoding="utf-8").read())
        code, out = close(lst3, "%s | перенесено | нужен прогон\n" % k3[1], mem3, extra=["--gate", "strict"])
        ok &= check("без штампа (strict): исходы НЕ записаны, код 3", code == 3 and "НЕ записаны" in out, "код %d: %s" % (code, out[:200]))
        io.open(stp3, "w", encoding="utf-8").write(_json.dumps({"role": "probe-role", "list": str(lst3), "status": "running", "pid": 999999999, "started": "x", "phase": "расчёт"}))
        code, out = close(lst3, "%s | перенесено | нужен прогон\n" % k3[1], mem3, extra=["--gate", "strict"])
        ok &= check("штамп running с исчезнувшим процессом (strict): «помощника не было», исход вписан",
                    code != 3 and "помощника не было" in out and "вписано исходов: 1" in out, "код %d: %s" % (code, out[:300]))
        io.open(stp3, "w", encoding="utf-8").write(_json.dumps({"role": "probe-role", "list": str(lst3), "status": "running", "pid": os.getpid(), "started": "x", "phase": "расчёт"}))
        code, out = close(lst3, "%s | перенесено | нужен прогон\n" % k3[2], mem3, extra=["--gate", "strict"])
        ok &= check("расчёт идёт (strict): отказ «дождись»", code == 3 and "дождись" in out, "код %d: %s" % (code, out[:300]))
        io.open(stp3, "w", encoding="utf-8").write(_json.dumps({"role": "probe-role", "list": str(lst3), "status": "done", "pid": os.getpid(), "started": "x"}))
        f3 = Path(lst3).parent / "outcomes.txt"
        io.open(f3, "w", encoding="utf-8").write("%s | перенесено | нужен прогон\n" % k3[2])
        os.utime(f3, (time.time() - 100, time.time() - 100))
        code, out = run([CLOSE, "--list", lst3, "--outcomes", f3, "--dir", mem3, "--gate", "strict"])
        ok &= check("список новее файла исходов (strict): отказ «номера могли съехать»", code == 3 and "съехать" in out, "код %d: %s" % (code, out[:300]))
        os.utime(f3, None)
        code, out = run([CLOSE, "--list", lst3, "--outcomes", f3, "--dir", mem3, "--gate", "strict"])
        ok &= check("штамп done, исходы свежие (strict): пускает", code != 3 and "вписано исходов: 1" in out, "код %d: %s" % (code, out[:300]))
    else:
        ok &= check("для проб защиты нужно ≥3 пунктов", False, "пунктов: %d" % len(k3))
    shutil.rmtree(str(root3), ignore_errors=True)
    return ok


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if "--mutate" in sys.argv:
        print("Мутации, которые ОБЯЗАНЫ покраснеть:")
        print("  1) ITEM_RE вернуть к виду с обязательной обратной кавычкой")
        print("       -> пробы «видит столько же пунктов» и «остаток считает все незакрытые»")
        print("  2) хвост исхода менять на \\s* вместо [ \\t]*   -> структура списка, остаток")
        print("  3) не проверять цитату по телу записи          -> «выдуманная цитата не проходит»")
        print("  4) ставить метку на подсадной                  -> «на подсадной метка НЕ ставится»")
        print("  5) вернуть умолчание --dir рядом со списком    -> «без --dir не работает»")
        print("  6) возвращать 0 при замечаниях                 -> «ненулевой код возврата»")
        sys.exit(0)
    print("пробы memory-close.py (список собирает настоящий сборщик)")
    good = probes()
    print("\nИТОГ: " + ("всё зелено" if good else "ЕСТЬ КРАСНОЕ"))
    sys.exit(0 if good else 1)
