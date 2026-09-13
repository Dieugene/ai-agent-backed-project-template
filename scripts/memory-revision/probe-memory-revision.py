#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пробы к сборщику списка актуализации: окно по свёртке и перенос пунктов без исхода.

Повод (владелец, 04.09): «Просто берите все, что пришло с предыдущей свёртки, и все. Если свёртка
выполняется впервые - ок, берите диапазон 2 недели.»
Второе (оппонент, 04.09): при окне по свёртке пункт без исхода выпадает молча, а счётчик
«осталось без исхода» продолжает его считать.

🛑 Каждое правило проверяется ИЗОЛИРОВАННО. Первая версия проб этого не делала: перенос
незакрытых маскировал окно (старое письмо всё равно оказывалось в списке, только другим разделом),
и мутация «окно снова календарное» проходила незамеченной.

  python probe-memory-revision.py           # прогон
  python probe-memory-revision.py --mutate  # что обязано покраснеть при вырезании правила
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
SCRIPT = HERE / "memory-revision.py"
ROLE = "testrole"

# Выдуманные слова: редкие в памяти (порог 15% записей) и не стоп-слова.
# ⚠️ В теме письма должны стоять ТОЛЬКО слова, которые есть в записи: слово, которого в памяти нет
# вовсе, имеет частоту 0, становится самым редким и требуется в записи — совпадений не будет.
W1, W2, W3 = "зюзюка", "пляпа", "мырглик"
SUBJ = "%s %s %s" % (W1, W2, W3)


def build(tmp, mail_ages_days):
    """Каталог памяти (10 записей; имя каталога = имя роли) и шина с письмами заданного возраста."""
    mem = tmp / ROLE
    mem.mkdir(parents=True)
    for i in range(9):
        io.open(mem / ("ref_fon%d.md" % i), "w", encoding="utf-8").write(
            "---\nname: ref_fon%d\ndescription: \"фоновая запись %d\"\n---\n\nБез ключевых слов.\n"
            % (i, i))
    io.open(mem / "ref_target.md", "w", encoding="utf-8").write(
        "---\nname: ref_target\ndescription: \"запись про %s\"\n---\n\n"
        "Здесь написано про %s и про %s, а также %s.\n" % (W1, W1, W2, W3))

    # 🛑 Без git-истории возраст записей не считается вовсе: все они уходят в «нет в истории»,
    # раздел возраста пуст, и две трети входов сборщика пробами не покрываются. Именно поэтому
    # дефект с двойными пунктами возраста прошёл мимо проб и вылез на живом списке.
    env = dict(os.environ, GIT_AUTHOR_DATE="2026-08-01T10:00:00", GIT_COMMITTER_DATE="2026-08-01T10:00:00",
               GIT_AUTHOR_NAME="probe", GIT_AUTHOR_EMAIL="probe@local",
               GIT_COMMITTER_NAME="probe", GIT_COMMITTER_EMAIL="probe@local")
    for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "проба"]):
        subprocess.run(["git", "-C", str(mem)] + cmd, capture_output=True, env=env)

    bus = tmp / "bus"
    (bus / ROLE / "new").mkdir(parents=True)
    (bus / "archive").mkdir(parents=True)
    for name, age_days in mail_ages_days:
        p = bus / ROLE / "new" / ("%s.from-lead.note.md" % name)
        io.open(p, "w", encoding="utf-8").write(
            "# %s\n\n| Field | Value |\n|---|---|\n| From | lead |\n| To | %s |\n\nтело\n" % (SUBJ, ROLE))
        when = time.time() - age_days * 86400
        os.utime(str(p), (when, when))
    return mem, bus


def run(mem, bus, out=None, days=14, inbox=None, extra=None):
    cmd = [sys.executable, "-X", "utf8", str(SCRIPT), "--dir", str(mem),
           "--mail", str(bus / ROLE), "--days", str(days)]
    if inbox:
        cmd += ["--inbox", str(inbox)]
    if extra:
        cmd += list(extra)
    if out:
        cmd += ["--out", str(out)]
    r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    if out and not Path(out).exists():
        raise SystemExit("сборщик не создал файл.\nstdout: %s\nstderr: %s"
                         % (r.stdout[-800:], r.stderr[-1500:]))
    return (io.open(out, encoding="utf-8").read() if out else r.stdout), r


def section(body, title):
    """Тело раздела `## <title>…` до следующего раздела."""
    for part in re.split(r"^## ", body, flags=re.M):
        if part.startswith(title):
            return part
    return ""


def close_all(out):
    """Вписать исход во все пункты — как это делает роль."""
    text = io.open(out, encoding="utf-8").read()
    io.open(out, "w", encoding="utf-8", newline="").write(
        text.replace("- **исход:** \n", "- **исход:** подтверждено\n"))


def check(name, cond, detail=""):
    print(("  ОК   " if cond else "  КРАСНО ") + name + (("  — " + detail) if detail and not cond else ""))
    return bool(cond)


def probes():
    ok = True
    tmp = Path(tempfile.mkdtemp(prefix="probe-rev-"))
    try:
        mem, bus = build(tmp, [("1000000000001-aaa", 0.01),
                               ("1000000000002-bbb", 1.0),
                               ("1000000000003-ccc", 10.0)])
        out = tmp / "list.md"
        stamp = out.parent / (".last-pass-" + ROLE)

        # 1. Первая свёртка: отметки нет — окно календарное, видны все три письма.
        body, _ = run(mem, bus, out)
        ok &= check("первая свёртка берёт календарные 14 суток",
                    "свёртка первая" in body and len(re.findall(r"письмо `", body)) == 3,
                    "раздел: %s" % section(body, "Пришло")[:120])

        # 2. Отметка прохода поставлена.
        ok &= check("после прохода поставлена отметка времени", stamp.exists())

        # 3. 🛑 ОКНО, изолированно: все исходы вписаны, значит переносить нечего — и старые письма
        # обязаны исчезнуть из «пришло извне». Без этого шага перенос маскирует окно.
        close_all(out)
        body2, _ = run(mem, bus, out)
        ext = section(body2, "Пришло")
        ok &= check("после свёртки старые письма во «внешнее» не берутся",
                    "с прошлой свёртки" in body2 and "письмо `" not in ext,
                    "раздел: %s" % ext[:200])

        # 4. ПЕРЕНОС: письма без исхода уходят в отдельный раздел, хотя срок их давно вышел.
        mem2, bus2 = build(tmp / "b", [("2000000000001-aaa", 5.0), ("2000000000002-bbb", 6.0)])
        out2 = tmp / "b" / "list.md"
        run(mem2, bus2, out2)                      # первый проход, исходы не вписаны
        body3, _ = run(mem2, bus2, out2)           # второй проход
        carry = section(body3, "Осталось с прошлого раза")
        ok &= check("пункты без исхода перенесены целиком",
                    len(re.findall(r"письмо `", carry)) == 2 and "перенесён" in carry,
                    "раздел: %s" % carry[:200])

        # 4b. 🛑 Перенос не тащит хвост раздела. Разбор прошлого списка режет его по «###», и в
        # блок пункта попадает всё до следующего пункта — включая заголовок следующего раздела и
        # строку итога. Печатались они снова, и список получал второй комплект разделов.
        # Поймано прогоном на живом списке, пробами до того не ловилось.
        alien = [ln for ln in carry.splitlines()
                 if (ln.startswith("## ") and not ln.startswith("### "))
                 or ln.startswith("_итог: пунктов") or ln.startswith("ВСЕГО ПУНКТОВ")]
        ok &= check("перенесённый пункт не тащит заголовки чужих разделов",
                    not alien, "чужие строки: %s" % alien[:3])

        # 4c. 🛑 Прошлые пометки не едут в перенос НИ В ОДНОМ из трёх видов. Пункт, закрытый исходом
        # и предъявленный снова, получает строку «⚠️ предъявлялся ранее, исход был: …» (без звёздочек);
        # если потом он остаётся без исхода и переносится, эта строка обязана отсечься — иначе в одном
        # пункте стоят «исхода не было» и «исход был: подтверждено». Нашёл lead pool-B-2 04.09.
        mem3, bus3 = build(tmp / "c", [("2000000000003-ccc", 5.0)])
        out3 = tmp / "c" / "list.md"
        run(mem3, bus3, out3)                      # предъявлен
        close_all(out3)                            # исход вписан
        p3 = bus3 / ROLE / "new" / "2000000000003-ccc.from-lead.note.md"
        now3 = time.time()
        os.utime(str(p3), (now3, now3))
        body5, _ = run(mem3, bus3, out3)           # снова в окне -> «предъявлялся ранее, исход был»
        seen_again = "предъявлялся ранее" in body5
        body6, _ = run(mem3, bus3, out3)           # исход не вписан -> перенос
        carry3 = section(body6, "Осталось с прошлого раза")
        ok &= check("перенесённый пункт не тащит прошлую пометку «предъявлялся ранее»",
                    seen_again and "перенесён" in carry3 and "предъявлялся ранее" not in carry3,
                    "предъявлялся=%s; раздел: %s" % (seen_again, carry3[:300]))

        # 5. 🛑 ДУБЛИ, изолированно: письмо и перенесено, и снова попадает в окно (так бывает —
        # роль прочла письмо, оно уехало в архив, время файла обновилось). Показать его надо один раз.
        p = bus2 / ROLE / "new" / "2000000000001-aaa.from-lead.note.md"
        now = time.time()
        os.utime(str(p), (now, now))
        body4, _ = run(mem2, bus2, out2)
        ids = re.findall(r"письмо `([^`]+)`", body4)
        ok &= check("перенесённое письмо не показано дважды, когда снова попало в окно",
                    ids.count("2000000000001-aaa") == 1, "письма в списке: %s" % ids)

        # 6. Проверочный прогон (печать без записи файла) окно не сдвигает.
        before = io.open(stamp, encoding="utf-8").read()
        time.sleep(1.1)
        run(mem, bus, None)
        ok &= check("прогон без записи файла окно не сдвигает",
                    before == io.open(stamp, encoding="utf-8").read())

        # 8. 🛑 ОТБОР НОВОГО: письмо, пришедшее ПОСЛЕ отметки, обязано попасть во «внешнее».
        # Без этой пробы можно сдвинуть окно вперёд и обрубить почтовый вход навсегда —
        # все прочие пробы останутся зелёными, потому что проверяют только «старое не берётся».
        fresh = bus2 / ROLE / "new" / "2000000000009-new.from-lead.note.md"
        io.open(fresh, "w", encoding="utf-8").write(
            "# %s\n\n| Field | Value |\n|---|---|\n| From | lead |\n| To | %s |\n\nтело\n"
            % (SUBJ, ROLE))
        body6, _ = run(mem2, bus2, out2)
        ok &= check("письмо, пришедшее после отметки, попадает во «внешнее»",
                    "2000000000009-new" in section(body6, "Пришло"),
                    "раздел: %s" % section(body6, "Пришло")[:200])

        # 9. 🛑 ИНВАРИАНТ: один пункт — одна строка в списке. Нарушение этого дало 25 пунктов
        # вместо 13 на живом списке: переносились и почтовые, и возрастные, а исход, вписанный
        # в одну копию, для другой оставался пустым — пункт становился незакрываемым.
        # ⚠️ Считать надо КЛЮЧИ, а не заголовки: тема письма у разных писем законно совпадает
        # (и в жизни тоже — «Re: …»), а ключ пункта уникален: id письма либо имя записи.
        keys = (re.findall(r"письмо `([^`]+)`", body6)
                + re.findall(r"^### (?:~ )?П\d+\. `([^`]+)`", body6, re.M))
        dupes = [k for k in set(keys) if keys.count(k) > 1]
        ok &= check("ни один пункт не показан дважды", not dupes, "повторы: %s" % dupes[:3])

        # 10. Возраст вообще считается (иначе проба 9 проверяет пустоту).
        ok &= check("раздел возраста непустой — пункты возраста в проверке участвуют",
                    "письмо" not in section(body6, "Давно не подтверждалось")
                    and "ref_" in section(body6, "Давно не подтверждалось"),
                    "раздел: %s" % section(body6, "Давно не подтверждалось")[:200])

        # 7. Пункт, закрытый исходом, из переноса уходит.
        close_all(out2)
        body5, _ = run(mem2, bus2, out2)
        ok &= check("закрытый исходом пункт больше не переносится",
                    "письмо `" not in section(body5, "Осталось с прошлого раза"),
                    "раздел: %s" % section(body5, "Осталось с прошлого раза")[:160])
        # 10b. 🛑 Пересборка неразобранного списка не пишет «ПУСТО» в журнал. Скил велит
        # пересобрать список старше суток, и раньше пересборка записывала отказ по каждому пункту
        # за минуту до того, как роль их закроет. Нашёл ведущий 04.09: у него 6 таких предметов
        # за день, у меня 44 — доля отказов в журнале была завышена в разы.
        jr = (out2.parent / "journal.tsv")
        jtext = io.open(jr, encoding="utf-8").read() if jr.exists() else ""
        ok &= check("пересборка неразобранного списка пишет «пересобран», а не «ПУСТО»",
                    "пересобран" in jtext and "\tПУСТО\t" not in jtext,
                    "журнал: %s" % " | ".join(jtext.splitlines()[:2]))

        # 10c. 🛑 Сводка журнала не считает сгоревшие пересборки отказами — и делает это ФИЛЬТРОМ
        # ПРИ ЧТЕНИИ, не переписывая файл. Довод ведущего 04.09: журнал есть наблюдение, а не
        # витрина; переписанный задним числом ряд перестаёт отличать «так было измерено» от
        # «так мы решили считать потом».
        jfake = tmp / "j.tsv"
        io.open(jfake, "w", encoding="utf-8", newline="\n").write(
            "2026-09-01 10:00\tr\tПУСТО\t`a.md` — давно\n"          # проход без исходов —
            "2026-09-01 10:00\tr\tПУСТО\t`b.md` — давно\n"          # сгорел на пересборке
            "2026-09-01 11:00\tr\tподтверждено\t`a.md` — давно\n"   # проход с работой роли:
            "2026-09-01 11:00\tr\tПУСТО\t`b.md` — давно\n")         # тут ПУСТО настоящее
        r_j = subprocess.run([sys.executable, "-X", "utf8", str(SCRIPT), "--dir", str(mem),
                              "--journal", str(jfake)], capture_output=True, text=True,
                             encoding="utf-8", errors="replace")
        outj = r_j.stdout or ""
        ok &= check("сводка не считает сгоревшие пересборки отказами",
                    "пересобран" in outj and "без исхода: 50%" in outj,
                    "сводка: %s" % " | ".join(l.strip() for l in outj.splitlines() if l.strip())[:220])

        # 12. 🛑 СООБЩЕНИЯ ЛЮДЕЙ — во вход наравне с письмами. Замер, ради которого это сделано:
        # у pool-A/operator за четыре дня 83 сообщения от девяти человек, и ни одно не попадало
        # в список; вместо них там лежали 60 машинных счётчиков «пришло N сообщений».
        inbox = tmp / "inbox"
        inbox.mkdir(exist_ok=True)
        recs = [
            {"kind": "text", "text": "%s %s %s" % (W1, W2, W3),
             "from": {"username": "vladelec"}, "message_id": 501, "tg_date": int(time.time())},
            {"kind": "service", "text": "вошёл в группу", "from": {"username": "bot"},
             "message_id": 502, "tg_date": int(time.time())},
            {"kind": "reaction", "text": "", "from": {"username": "kto-to"},
             "message_id": 503, "tg_date": int(time.time())},
            {"kind": "text", "text": "%s %s %s" % (W1, W2, W3),
             "from": {"username": "kollega"}, "message_id": 504, "tg_date": int(time.time())},
        ]
        io.open(inbox / "2026-09-04.jsonl", "w", encoding="utf-8").write(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in recs) + "\n")
        out3 = tmp / "c-list.md"
        body8, _ = run(mem, bus, out3, inbox=inbox)
        ext8 = section(body8, "Пришло")
        ok &= check("сообщения людей становятся пунктами наравне с письмами",
                    "сообщение `501`" in ext8 and "Сказал человек (vladelec)" in ext8
                    and "сообщений людей 2" in ext8,
                    "раздел: %s" % ext8[:260])
        ok &= check("служебные записи чата (вход в группу, реакции) пунктами не становятся",
                    "`502`" not in ext8 and "`503`" not in ext8,
                    "раздел: %s" % ext8[:260])

        # 13. 🛑 Машинные уведомления письмами не считаются (слово владельца 04.09). Признак
        # измерен на 1776 письмах: тело только из пар «ключ=значение» и команды запуска — 807 писем,
        # шесть заголовков, все ноты моста, ложных срабатываний ноль.
        mem3, bus3 = build(tmp / "d", [("3000000000001-aaa", 0.01)])
        note = bus3 / ROLE / "new" / "3000000000002-note.from-builder.note-wake.md"
        # ⚠️ Заголовок у ноты берём тот же, что у живых писем: иначе она не совпадёт с памятью
        # по словам и не попадёт в список даже без отсева — проба перестанет проверять правило
        # (поймано мутационным прогоном: мутация «не отсеивать ноты» проходила незамеченной).
        io.open(note, "w", encoding="utf-8").write(
            "# %s\n\n| Field | Value |\n|---|---|\n| From | builder |\n"
            "| To | %s |\n| Thread | 3000000000002-note |\n\n"
            "direct=1 ambient=0 reason=direct. Run: python read_inbox.py\n" % (SUBJ, ROLE))
        live = bus3 / ROLE / "new" / "3000000000003-live.from-builder.note-wake.md"
        io.open(live, "w", encoding="utf-8").write(
            "# %s\n\n| Field | Value |\n|---|---|\n| From | builder |\n| To | %s |\n"
            "| Thread | 3000000000003-live |\n\nЗдесь живой текст с предложением. И ещё одно.\n"
            % (SUBJ, ROLE))
        out4 = tmp / "d" / "list.md"
        body9, _ = run(mem3, bus3, out4)
        ok &= check("машинная нота письмом не считается",
                    "3000000000002-note" not in body9,
                    "в списке: %s" % re.findall(r"письмо `([^`]+)`", body9))
        ok &= check("живое письмо от того же отправителя остаётся",
                    "3000000000003-live" in body9,
                    "в списке: %s" % re.findall(r"письмо `([^`]+)`", body9))

        # 14. 🛑 СОГЛАСИЕ С ПОМОЩНИКОМ считается машиной. Это главный измеритель вырождения
        # хода, и до 04.09 он не считался ниоткуда: вердикт лежал в файле, исход роли — в списке.
        mem4, bus4 = build(tmp / "e", [("4000000000001-aaa", 0.01), ("4000000000002-bbb", 0.02)])
        out5 = tmp / "e" / "list.md"
        run(mem4, bus4, out5)
        text5 = io.open(out5, encoding="utf-8").read()
        keys = re.findall(r"письмо `([^`]+)`", text5)
        # помощник: по первому письму «подтверждено», по второму «заменил»
        verd = {"mail:" + keys[0]: {"verdict": "ВЕРДИКТ: подтверждено\nОБОСНОВАНИЕ: раз"},
                "mail:" + keys[1]: {"verdict": "ВЕРДИКТ: заменил\nОБОСНОВАНИЕ: два"}}
        io.open(out5.parent / ("verdicts-%s.json" % ROLE), "w", encoding="utf-8").write(
            json.dumps(verd, ensure_ascii=False))
        # роль: с первым согласилась, со вторым нет
        text5 = text5.replace("- **исход:** \n", "- **исход:** подтверждено — сверено с файлом\n", 1)
        text5 = text5.replace("- **исход:** \n", "- **исход:** подтверждено — сверено с файлом\n", 1)
        io.open(out5, "w", encoding="utf-8", newline="").write(text5)
        run(mem4, bus4, out5)
        jr2 = out5.parent / "journal.tsv"
        jt = io.open(jr2, encoding="utf-8").read() if jr2.exists() else ""
        ok &= check("машина считает согласие роли с помощником",
                    "\tсогласие" in jt and "\tрасхождение" in jt,
                    "журнал: %s" % " | ".join(jt.splitlines()[-2:]))

        # 15. 🛑 ПОРОГ РЕДКОСТИ — пара условий, и они должны расходиться на большом корпусе.
        # Корпус 50 записей, слова письма встречаются в 6 из них: это 12 % — доля ПОЗВОЛЯЕТ, но
        # число записей 6 > 5. Старое правило (только доля) такое письмо пропускало; у роли со 143
        # записями именно так проходило «bridge», главное слово её работы.
        big = tmp / "f" / ROLE
        big.mkdir(parents=True)
        for i in range(50):
            has = i < 6      # слова в шести записях из пятидесяти: 12 %% — доля позволяет, а 6 > 5
            io.open(big / ("ref_b%02d.md" % i), "w", encoding="utf-8").write(
                "---\nname: ref_b%02d\ndescription: \"запись %d\"\n---\n\n%s\n"
                % (i, i, ("Тут про %s и %s." % (W1, W2)) if has else "Ничего особенного."))
        env2 = dict(os.environ, GIT_AUTHOR_DATE="2026-08-01T10:00:00",
                    GIT_COMMITTER_DATE="2026-08-01T10:00:00", GIT_AUTHOR_NAME="probe",
                    GIT_AUTHOR_EMAIL="probe@local", GIT_COMMITTER_NAME="probe",
                    GIT_COMMITTER_EMAIL="probe@local")
        for cmd in (["init", "-q"], ["add", "-A"], ["commit", "-q", "-m", "проба"]):
            subprocess.run(["git", "-C", str(big)] + cmd, capture_output=True, env=env2)
        busb = tmp / "f" / "bus"
        (busb / ROLE / "new").mkdir(parents=True)
        (busb / "archive").mkdir(parents=True)
        io.open(busb / ROLE / "new" / "5000000000001-aaa.from-lead.note.md", "w",
                encoding="utf-8").write(
            "# %s %s\n\n| Field | Value |\n|---|---|\n| From | lead |\n| To | %s |\n\n"
            "Живой текст письма с предложением. И ещё одно.\n" % (W1, W2, ROLE))
        outb = tmp / "f" / "list.md"
        bodyb, _ = run(big, busb, outb)
        ok &= check("частое в корпусе слово редким не считается, даже если доля позволяет",
                    "5000000000001-aaa" not in bodyb,
                    "в списке: %s" % re.findall(r"письмо `([^`]+)`", bodyb))

        # 16. 🛑 ОБЩИЙ МОСТ: у записи стоит адрес роли, и чужое брать нельзя. У пулов pool-B мост
        # один на несколько пулов; замер 04.09 показал в записях поле target вида
        # «pool-B-3/lead». Запись без адреса — мост пула, её берём.
        inbox2 = tmp / "inbox2"
        inbox2.mkdir(exist_ok=True)
        recs2 = [
            {"kind": "text", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 601, "tg_date": int(time.time()), "target": "мой-пул/%s" % ROLE},
            {"kind": "text", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 602, "tg_date": int(time.time()), "target": "чужой-пул/lead"},
            {"kind": "text", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 603, "tg_date": int(time.time())},
        ]
        io.open(inbox2 / "2026-09-04.jsonl", "w", encoding="utf-8").write(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in recs2) + "\n")
        out6 = tmp / "g-list.md"
        cmd6 = [sys.executable, "-X", "utf8", str(SCRIPT), "--dir", str(mem),
                "--mail", str(bus / ROLE), "--inbox", str(inbox2),
                "--inbox-target", "мой-пул/%s" % ROLE, "--out", str(out6)]
        subprocess.run(cmd6, capture_output=True, text=True, encoding="utf-8", errors="replace")
        body10 = io.open(out6, encoding="utf-8").read()
        ok &= check("из общего моста берутся только свои сообщения",
                    "сообщение `601`" in body10 and "`602`" not in body10,
                    "в списке: %s" % re.findall(r"сообщение `([^`]+)`", body10))
        ok &= check("запись без адреса берётся (мост принадлежит пулу)",
                    "сообщение `603`" in body10,
                    "в списке: %s" % re.findall(r"сообщение `([^`]+)`", body10))

        # 11. 🛑 Негодная отметка не должна молча выключать почтовый вход. Часы на машине уже
        # прыгали вперёд; отметка из будущего отсекла бы ВСЕ письма, а «входов: 0» неотличимо
        # от честного нуля. Ждём отката на календарное окно и явной строки об этом.
        io.open(stamp, "w", encoding="utf-8", newline="").write("%d\n" % int(time.time() + 86400))
        body7, r7 = run(mem, bus, out)
        ok &= check("отметка из будущего забракована, окно откатывается на календарь",
                    "негодная" in (r7.stdout or "") and "свёртка первая" in body7,
                    "вывод: %s" % (r7.stdout or "").strip()[:160])
        # 12. 🛑 Своё письмо отличается по паре роль+пул. В pool-B роль во всех пулах называется
        # lead: письмо соседа с тем же именем роли и строкой FromPool — чужое, берётся; письмо
        # с тем же именем и без FromPool — своё эхо, отсеивается.
        tmp12 = tmp / "t12"
        mem12, bus12 = build(tmp12, [])
        for name, frompool in (("1200000000001-own", ""), ("1200000000002-nbr", "other-pool")):
            p = bus12 / ROLE / "new" / ("%s.from-%s.note.md" % (name, ROLE))
            rows = "| From | %s |\n" % ROLE
            if frompool:
                rows += "| FromPool | %s |\n" % frompool
            io.open(p, "w", encoding="utf-8").write(
                "# %s\n\n| Field | Value |\n|---|---|\n%s| To | %s |\n\nтело\n" % (SUBJ, rows, ROLE))
        out12 = tmp12 / "list.md"
        body12, _ = run(mem12, bus12, out12)
        ids12 = re.findall(r"письмо `([^`]+)`", body12)
        ok &= check("письмо соседа с тем же именем роли (есть FromPool) берётся",
                    "1200000000002-nbr" in ids12, "в списке: %s" % ids12)
        ok &= check("своё эхо (то же имя, FromPool нет) отсеивается",
                    "1200000000001-own" not in ids12, "в списке: %s" % ids12)
        # 13. 🛑 Щелчок — не слова человека. Ответ кнопкой в викторине (`poll_answer`) пунктом
        # не становится; текст с теми же словами — становится.
        tmp13 = tmp / "t13"
        mem13, bus13 = build(tmp13, [])
        inbox13 = tmp13 / "inbox"
        inbox13.mkdir()
        recs13 = [
            {"kind": "poll_answer", "text": SUBJ, "from": {"username": "vladelec"},
             "update_id": 701, "message_id": None, "tg_date": int(time.time())},
            {"kind": "text", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 702, "tg_date": int(time.time())},
        ]
        io.open(inbox13 / "2026-09-06.jsonl", "w", encoding="utf-8").write(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in recs13) + "\n")
        out13 = tmp13 / "list.md"
        body13, _ = run(mem13, bus13, out13, inbox=inbox13)
        got13 = re.findall(r"сообщение `([^`]+)`", body13)
        ok &= check("ответ кнопкой в викторине пунктом не становится",
                    "701" not in got13 and "702" in got13, "в списке: %s" % got13)

        # 14. 🛑 ПОРЦИЯ: свежие первыми, остаток не теряется. Четыре письма, порция 2:
        # в списке два свежайших, строка «за порцией осталось 2», отметка отступила к самому
        # старому невошедшему; второй проход (первые два закрыты) показывает оставшиеся два и
        # НЕ показывает закрытые.
        tmp14 = tmp / "t14"
        mem14, bus14 = build(tmp14, [("1400000000001-a", 0.5), ("1400000000002-b", 1.5),
                                     ("1400000000003-c", 2.5), ("1400000000004-d", 3.5)])
        out14 = tmp14 / "list.md"
        stamp14 = out14.parent / (".last-pass-" + ROLE)
        body14, _ = run(mem14, bus14, out14, extra=["--ext-limit", "2"])
        got14 = re.findall(r"письмо `([^`]+)`", body14)
        ok &= check("порция берёт два свежайших письма",
                    got14 == ["1400000000001-a", "1400000000002-b"], "в списке: %s" % got14)
        ok &= check("остаток за порцией назван числом",
                    "за порцией осталось 2" in body14)
        st = float(io.open(stamp14, encoding="utf-8").read().strip())
        ok &= check("отметка отступила к самому старому невошедшему",
                    st < time.time() - 3.4 * 86400, "отметка: %s" % st)
        close_all(out14)
        body14b, _ = run(mem14, bus14, out14, extra=["--ext-limit", "2"])
        got14b = re.findall(r"письмо `([^`]+)`", section(body14b, "Пришло"))
        ok &= check("второй проход показывает остаток и не повторяет закрытые",
                    got14b == ["1400000000003-c", "1400000000004-d"], "в списке: %s" % got14b)
        close_all(out14)
        body14c, _ = run(mem14, bus14, out14, extra=["--ext-limit", "2"])
        got14c = re.findall(r"письмо `([^`]+)`", body14c)
        ok &= check("третий проход не предъявляет закрытое два прохода назад",
                    not got14c, "в списке: %s" % got14c)

        # 15. 🛑 ПЕРЕНОС ЧЕРЕЗ ОТСЕВ: пункт прошлого списка, чей источник сегодня отсеялся бы
        # (щелчок в ленте, машинная нота в почте), не переносится; обычный — переносится.
        tmp15 = tmp / "t15"
        mem15, bus15 = build(tmp15, [("1500000000001-live", 0.5)])
        note = bus15 / ROLE / "new" / "1500000000002-mach.from-lead.note-wake.md"
        io.open(note, "w", encoding="utf-8").write(
            "# %s\n\n| Field | Value |\n|---|---|\n| From | lead |\n| To | %s |\n"
            "| Thread | 1500000000002-mach |\n\n"
            "direct=1 ambient=0 reason=direct. Run: python read_inbox.py\n" % (SUBJ, ROLE))
        inbox15 = tmp15 / "inbox"
        inbox15.mkdir()
        io.open(inbox15 / "2026-09-06.jsonl", "w", encoding="utf-8").write(json.dumps(
            {"kind": "text", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 751, "tg_date": int(time.time())}, ensure_ascii=False) + "\n")
        out15 = tmp15 / "list.md"
        body15, _ = run(mem15, bus15, out15, inbox=inbox15)
        # подделываем прошлый список: машинная нота и щелчок стоят пунктами, как в старых
        # списках оператора pool-A; запись ленты переписываем в poll_answer
        text15 = io.open(out15, encoding="utf-8").read()
        text15 = text15.replace("_итог: пунктов из внешнего входа",
            "### П90. Пришло: %s\n- от: `lead`, письмо `1500000000002-mach`\n"
            "- источник целиком: `%s`\n- **исход:** \n\n_итог: пунктов из внешнего входа"
            % (SUBJ, note), 1)
        io.open(out15, "w", encoding="utf-8", newline="").write(text15)
        io.open(inbox15 / "2026-09-06.jsonl", "w", encoding="utf-8").write(json.dumps(
            {"kind": "poll_answer", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": None, "update_id": 751, "tg_date": None, "wake": False,
             "ts": "2026-09-06T10:00:00+0200"}, ensure_ascii=False) + "\n")
        body15b, _ = run(mem15, bus15, out15, inbox=inbox15)
        carry15 = section(body15b, "Осталось с прошлого раза")
        ok &= check("обычное письмо без исхода переносится",
                    "1500000000001-live" in carry15, "раздел: %s" % carry15[:200])
        ok &= check("машинная нота и щелчок не переносятся, снятие названо",
                    "1500000000002-mach" not in carry15 and "`751`" not in carry15
                    and "снято сегодняшним отсевом" in body15b
                    and "машинная нота" in body15b and "щелчок" in body15b,
                    "раздел: %s | снято: %s" % (carry15[:160],
                                                 re.findall(r"снято сегодняшним[^\n]*", body15b)))
        # 16. 🛑 Голосовое владельца: мост пишет ДВЕ записи с одним message_id — без текста и
        # расшифровку. Пункт создаётся, а при переносе НЕ снимается. Реакция с текстом
        # (`reaction_count`, `wake: False`) пунктом не становится.
        tmp16 = tmp / "t16"
        mem16, bus16 = build(tmp16, [])
        inbox16 = tmp16 / "inbox"
        inbox16.mkdir()
        now16 = int(time.time())
        recs16 = [
            {"kind": "voice", "text": None, "from": {"username": "vladelec"},
             "message_id": 761, "tg_date": now16},
            {"kind": "voice_transcript", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 761, "tg_date": now16},
            {"kind": "reaction_count", "text": "реакции под сообщением 5: " + SUBJ,
             "from": {"username": "vladelec"}, "message_id": 762, "tg_date": now16, "wake": False},
            {"kind": "text", "text": SUBJ, "from": {"username": "vladelec"},
             "message_id": 763, "tg_date": now16, "wake": False},
        ]
        io.open(inbox16 / "2026-09-06.jsonl", "w", encoding="utf-8").write(
            "\n".join(json.dumps(r, ensure_ascii=False) for r in recs16) + "\n")
        out16 = tmp16 / "list.md"
        body16, _ = run(mem16, bus16, out16, inbox=inbox16)
        got16 = re.findall(r"сообщение `([^`]+)`", body16)
        ok &= check("голосовое (две записи на один id) становится пунктом, реакция и wake:False — нет",
                    got16 == ["761"], "в списке: %s" % got16)
        body16b, _ = run(mem16, bus16, out16, inbox=inbox16)   # перенос
        carry16 = section(body16b, "Осталось с прошлого раза")
        ok &= check("пункт из голосового при переносе не снимается",
                    "`761`" in carry16 and "снято сегодняшним отсевом" not in body16b,
                    "раздел: %s | %s" % (carry16[:120], re.findall(r"снято[^\n]*", body16b)))

        # 17. 🛑 Нечитаемый или пропавший источник — переносим, а не снимаем.
        tmp17 = tmp / "t17"
        mem17, bus17 = build(tmp17, [("1700000000001-a", 0.5), ("1700000000002-b", 0.6)])
        out17 = tmp17 / "list.md"
        run(mem17, bus17, out17)
        pa = bus17 / ROLE / "new" / "1700000000001-a.from-lead.note.md"
        pb = bus17 / ROLE / "new" / "1700000000002-b.from-lead.note.md"
        io.open(pa, "w", encoding="utf-8").write("")          # пустой файл
        os.remove(str(pb))                                    # пропал
        body17, _ = run(mem17, bus17, out17)
        carry17 = section(body17, "Осталось с прошлого раза")
        ok &= check("пустой и пропавший источник переносятся, не снимаются",
                    "1700000000001-a" in carry17 and "1700000000002-b" in carry17
                    and "снято сегодняшним отсевом" not in body17,
                    "раздел: %s" % carry17[:200])

        # 18. 🛑 Любая строка исхода при переносе становится пустой: «перенесено — жду» не должно
        # ехать дословно. И второй перенос подряд помечается словами сборщика.
        tmp18 = tmp / "t18"
        mem18, bus18 = build(tmp18, [("1800000000001-a", 0.5)])
        out18 = tmp18 / "list.md"
        run(mem18, bus18, out18)
        t18 = io.open(out18, encoding="utf-8").read().replace(
            "- **исход:** \n", "- **исход:** перенесено — жду ответа соседа\n", 1)
        io.open(out18, "w", encoding="utf-8", newline="").write(t18)
        body18, _ = run(mem18, bus18, out18)
        carry18 = section(body18, "Осталось с прошлого раза")
        ok &= check("непустой исход «перенесено — …» при переносе становится пустой строкой",
                    "- **исход:** \n" in carry18 and "жду ответа" not in carry18
                    and "стоял `перенесено`" in carry18, "раздел: %s" % carry18[:300])
        body18b, _ = run(mem18, bus18, out18)                 # третий проход — второй перенос
        carry18b = section(body18b, "Осталось с прошлого раза")
        ok &= check("второй перенос подряд помечен «перенесён повторно»",
                    "перенесён повторно" in carry18b and "перенесён: в прошлый" not in carry18b,
                    "раздел: %s" % carry18b[:300])
        # 19. 🛑 Ключ пункта — по адресной строке «- от: …», а не по первому «письмо `…`» в блоке:
        # цитата записи памяти внутри пункта может содержать «письмо `X`» и подменяла ключ.
        import importlib.util
        spec = importlib.util.spec_from_file_location("memrev_probe", str(SCRIPT))
        memrev = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(memrev)
        chunk19 = ("П1. Пришло: тема\n- от: `lead`, письмо `1900000000001-real`\n"
                   "- в памяти об этом же:\n  - `ref_x:3` — см. письмо `9999-chuzhoe` и ответ\n")
        k19 = memrev.item_key("Пришло: тема", chunk19)
        ok &= check("ключ пункта берётся из адресной строки, а не из цитаты",
                    k19 == "mail:1900000000001-real", "ключ: %s" % k19)
        chunk19b = ("П2. Сказал человек (x): текст\n- от: `x`, сообщение `123`\n"
                    "  - `ref_y:1` — там было письмо `555`\n")
        k19b = memrev.item_key("Сказал человек (x): текст", chunk19b)
        ok &= check("ключ сообщения не подменяется письмом из цитаты",
                    k19b == "msg:123", "ключ: %s" % k19b)
    finally:
        shutil.rmtree(str(tmp), ignore_errors=True)
    return ok


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if "--mutate" in sys.argv:
        print("Мутации, которые ОБЯЗАНЫ покраснеть:")
        print("  1) окно всегда календарное                      -> проба 3")
        print("  2) убрать раздел перенесённых                   -> пробы 4, 7")
        print("  3) двигать отметку и без --out                  -> пробы 2, 6")
        print("  4) не пропускать перенесённые при сборе внешних -> проба 5")
        print("  5) сдвинуть окно вперёд (since + 86400)         -> проба 8")
        print("  6) переносить и непочтовые пункты                -> проба 9")
        print("  7) OLD_MARK_RE снова требует звёздочку (\\*\\*?)  -> проба 4c")
        print("  8) own = frm == role (без FromPool)              -> проба 12")
        print("  9) poll_answer убрать из INBOX_SKIP               -> проба 13")
        print(" 10) не отступать отметкой (ext_cut)                -> проба 14 (остаток)")
        print(" 11) не помнить закрытые (.ext-closed)              -> проба 14 (третий проход)")
        print(" 12) carry_stale всегда ''                          -> проба 15")
        print(" 13) carry_stale решает по ПЕРВОЙ записи             -> проба 16 (перенос)")
        print(" 14) is_message не смотрит wake                      -> проба 16")
        print(" 15) пустой источник = машинная нота                 -> проба 17")
        print(" 16) канонизировать только пустой исход              -> проба 18")
        print(" 17) again всегда False                              -> проба 18 (повторно)")
        print(" 18) item_key без адресной строки                    -> проба 19")
        sys.exit(0)
    print("пробы memory-revision.py")
    good = probes()
    print("\nИТОГ: " + ("всё зелено" if good else "ЕСТЬ КРАСНОЕ"))
    sys.exit(0 if good else 1)
