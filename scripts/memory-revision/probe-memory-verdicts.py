#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пробы к memory-verdicts.py: разбор пакетом, замок на машину, счёт потоков по памяти.

Движок здесь не зовётся: проверяется всё, что вокруг него, — группировка пунктов, разбор ответа
по ключам, добор потерянного, защита памяти. Сам вызов проверяется живым прогоном.

  python probe-memory-verdicts.py            # прогон
  python probe-memory-verdicts.py --mutate   # что обязано покраснеть
"""
import importlib.util
import io
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("mv", str(HERE / "memory-verdicts.py"))
mv = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mv)


def check(name, cond, detail=""):
    print(("  ОК   " if cond else "  КРАСНО ") + name + (("  — " + detail) if detail and not cond else ""))
    return bool(cond)


def item(key, size):
    return {"key": key, "title": key, "block": "### П1. " + ("x" * size)}


def probes():
    ok = True

    # 1. Пункты режутся на группы по объёму, а не по числу.
    small = [item("k%d" % i, 1000) for i in range(5)]
    groups = list(mv.batches(small))
    ok &= check("мелкие пункты идут одним пакетом", len(groups) == 1,
                "групп: %d" % len(groups))

    # ⚠️ Размер задаём числом, а не долей от BATCH_CHARS: проба, вычисляющая свой вход из
    # мутируемой константы, мутацию этой константы не заметит (поймано мутационным прогоном).
    big = [item("b%d" % i, 250000) for i in range(4)]
    groups = list(mv.batches(big))
    ok &= check("крупные пункты режутся на несколько пакетов", len(groups) >= 2,
                "групп: %d" % len(groups))
    ok &= check("ни один пункт при делении не потерян",
                sum(len(g) for g in groups) == len(big),
                "в группах: %d из %d" % (sum(len(g) for g in groups), len(big)))

    # 2. Ответ пакета раскладывается по ключам.
    answer = ("%s mail:abc\nВЕРДИКТ: подтверждено\nОБОСНОВАНИЕ: раз\n\n"
              "%s age:file.md\nВЕРДИКТ: заменил\nОБОСНОВАНИЕ: два\n") % (mv.KEY_MARK, mv.KEY_MARK)
    parts = mv.split_answer(answer)
    ok &= check("ответ пакета разложен по ключам",
                set(parts) == {"mail:abc", "age:file.md"}
                and "подтверждено" in parts["mail:abc"] and "заменил" in parts["age:file.md"],
                "ключи: %s" % sorted(parts))

    # 3. 🛑 Пункт, которого в ответе нет, помечается потерянным — иначе пакет молча съедает пункты.
    parts = mv.split_answer("%s mail:abc\nВЕРДИКТ: подтверждено\n" % mv.KEY_MARK)
    ok &= check("пункта без блока в ответе нет — он будет досчитан отдельно",
                "age:file.md" not in parts, "ключи: %s" % sorted(parts))

    # 4. Счёт потоков по свободной памяти.
    real = mv.mem_available_mib
    try:
        mv.mem_available_mib = lambda: 5000
        ok &= check("при обилии памяти берётся запрошенное число потоков",
                    mv.jobs_by_memory(3)[0] == 3, "получил %s" % (mv.jobs_by_memory(3),))
        mv.mem_available_mib = lambda: 900
        ok &= check("при 900 МиБ потоков меньше запрошенного",
                    mv.jobs_by_memory(3)[0] == 2, "получил %s" % (mv.jobs_by_memory(3),))
        mv.mem_available_mib = lambda: 300
        ok &= check("при памяти ниже запаса расчёт не начинается",
                    mv.jobs_by_memory(3)[0] == 0, "получил %s" % (mv.jobs_by_memory(3),))
    finally:
        mv.mem_available_mib = real

    # 5. Общий замок на машину: второй проход не начинается.
    # ⚠️ Замок берём в СВОЙ каталог, а не в общий временный: на сервере там лежит замок настоящего
    # прохода, и проба падала на чужой работе, а не на своей (поймано выкаткой 04.09).
    import tempfile
    sandbox = tempfile.mkdtemp(prefix="probe-lock-")
    real_tmp = mv.tempfile.gettempdir
    mv.tempfile.gettempdir = lambda: sandbox
    lock = mv.take_machine_lock()
    second = mv.take_machine_lock(wait=False)
    ok &= check("общий замок пускает только один проход", bool(lock) and second is None,
                "первый: %s, второй: %s" % (bool(lock), second))
    ok &= check("в замке лежит pid держателя", lock and mv.read(lock).strip() == str(os.getpid()),
                "содержимое: %r" % (mv.read(lock) if lock else None))
    mv.release_machine_lock(lock)
    third = mv.take_machine_lock(wait=False)
    ok &= check("после снятия замка следующий проход проходит", third is not None)
    # 🛑 Замок мёртвого процесса забирается, живого — ждётся (очередь, а не пропуск).
    io.open(third, "w", encoding="utf-8").write("999999999")
    fourth = mv.take_machine_lock(wait=False)
    ok &= check("замок исчезнувшего процесса забирается", fourth is not None and mv.read(fourth).strip() == str(os.getpid()))
    import threading
    waited = {"holder": None}
    def free_later():
        import time as _t
        _t.sleep(1.0)
        mv.release_machine_lock(fourth)
    threading.Thread(target=free_later, daemon=True).start()
    t0 = __import__("time").monotonic()
    fifth = mv.take_machine_lock(wait=True, on_wait=lambda h: waited.__setitem__("holder", h), poll_s=0.2)
    dt = __import__("time").monotonic() - t0
    ok &= check("занятый живым процессом замок ЖДЁТСЯ и берётся после освобождения",
                fifth is not None and waited["holder"] == str(os.getpid()) and dt >= 0.9,
                "ждал %.1f с, держатель %s" % (dt, waited["holder"]))
    mv.release_machine_lock(fifth)
    mv.tempfile.gettempdir = real_tmp
    # N. Окружение помощника: переменные роли не уходят, нужное доезжает.
    # 🛑 Зачем: с POOL_WATCHER/AGENT_OWNER/POOL_BUS_ROOT оба Stop-хука принимают headless-помощника
    # за саму роль и требуют взвести вотчер, которого он не может. Замер 04.09 на холодном гейте:
    # 6 ходов и 2 блокировки против 1 хода после правки; пакетный ответ при этом терялся целиком.
    seen_env = {}

    class _Res(object):
        stdout = '{"result":"x","num_turns":1,"total_cost_usd":0,"session_id":"s"}'
        stderr = ""

    seen_cmd = []

    def _fake_run(cmd, **kw):
        seen_cmd[:] = list(cmd)
        seen_env.clear()
        seen_env.update(kw.get("env") or {})
        return _Res()

    _run, _exe = mv.subprocess.run, mv.claude_exe
    _env_backup = dict(os.environ)
    try:
        mv.subprocess.run = _fake_run
        mv.claude_exe = lambda: "claude"
        os.environ["POOL_WATCHER"] = "1"
        os.environ["AGENT_OWNER"] = "some-role"
        os.environ["POOL_BUS_ROOT"] = "/tmp/bus"
        os.environ["PROBE_KEEP_ME"] = "да"
        mv.call_engine("тест", [], str(HERE), timeout=5, token="TOK")
    finally:
        mv.subprocess.run, mv.claude_exe = _run, _exe
        os.environ.clear()
        os.environ.update(_env_backup)

    leaked = [v for v in ("POOL_WATCHER", "AGENT_OWNER", "POOL_BUS_ROOT") if v in seen_env]
    ok &= check("переменные роли не уходят помощнику", not leaked,
                "уехали: %s" % ", ".join(leaked))
    # ⚠️ Парная проверка: без неё предыдущая зеленеет и тогда, когда окружение вычищено ЦЕЛИКОМ.
    ok &= check("нужное окружение доезжает до помощника",
                seen_env.get("CLAUDE_CODE_OAUTH_TOKEN") == "TOK"
                and seen_env.get("PROBE_KEEP_ME") == "да",
                "токен=%s посторонняя=%s" % (seen_env.get("CLAUDE_CODE_OAUTH_TOKEN"),
                                             seen_env.get("PROBE_KEEP_ME")))

    shutil.rmtree(sandbox, ignore_errors=True)
    # 6. 🛑 Помощник не считает закрытые пункты и второй перенос подряд: вердикт нужен роли
    # ДО исхода, а по пункту, который она дважды не стала решать, он не помогает.
    tmp6 = Path(tempfile.mkdtemp(prefix="probe-verd6-"))
    try:
        lst = tmp6 / "list.md"
        io.open(lst, "w", encoding="utf-8").write(
            "# список\n\n"
            "### П1. Пришло: обычный\n- от: `lead`, письмо `1`\n- **исход:** \n\n"
            "### П2. Пришло: закрытый\n- от: `lead`, письмо `2`\n- **исход:** подтверждено, открыл\n\n"
            "### П3. Пришло: дважды перенесён\n  🔴 **%s (второй раз подряд): в прошлый раз исхода не было.**\n" % mv.SECOND_CARRY +
            "- от: `lead`, письмо `3`\n- **исход:** \n\n"
            "### П4. Пришло: перенесён впервые\n  🔴 **перенесён: в прошлый раз исхода не было.**\n"
            "- от: `lead`, письмо `4`\n- **исход:** \n\n")
        items6 = mv.parse_items(lst)
        reasons = [it["skip"] for it in items6]
        ok &= check("разбор помечает закрытый и второй перенос, остальные — считать",
                    reasons == ["", "исход уже вписан", "второй перенос подряд", ""],
                    "причины: %s" % reasons)
        todo6, kept6, skipped6 = mv.select_todo(items6, {}, str(tmp6))
        # 7. 🛑 Пометка «⚠️ предъявлялся ранее, исход был: …» печатается сборщиком БЕЗ звёздочек и
        # тоже не должна доезжать до помощника: она якорит его на прошлом вердикте.
        lst7 = tmp6 / "list7.md"
        io.open(lst7, "w", encoding="utf-8").write(
            "# список\n\n### П1. Пришло: снова\n  ⚠️ предъявлялся ранее, исход был: `подтверждено`.\n"
            "- от: `lead`, письмо `7`\n- **исход:** \n\n")
        items7 = mv.parse_items(lst7)
        ok &= check("пометка «предъявлялся ранее» без звёздочек помощнику не показывается",
                    items7 and "предъявлялся" not in items7[0]["block"],
                    "блок: %r" % (items7[0]["block"][:160] if items7 else None))
        ok &= check("в расчёт идут только обычный и первый перенос",
                    [it["key"] for it in todo6] == [items6[0]["key"], items6[3]["key"]]
                    and skipped6 == {"исход уже вписан": 1, "второй перенос подряд": 1},
                    "todo: %s, skipped: %s" % ([it["key"] for it in todo6], skipped6))
    finally:
        shutil.rmtree(str(tmp6), ignore_errors=True)
    # 8. 🛑 РАЗОВАЯ МОДЕЛЬ: в задании каждая запись один раз и целиком, письмо-источник целиком,
    # запись ленты моста (.jsonl) — не даётся.
    tmp8 = Path(tempfile.mkdtemp(prefix="probe-verd8-"))
    try:
        mem8 = tmp8 / "mem"; mem8.mkdir()
        io.open(mem8 / "ref_a.md", "w", encoding="utf-8").write("---\nname: ref_a\n---\n\n" + "\n".join("строка a%d" % i for i in range(40)) + "\n")
        io.open(mem8 / "ref_b.md", "w", encoding="utf-8").write("---\nname: ref_b\n---\n\nтело b\n")
        mail = tmp8 / "1.from-lead.note.md"; io.open(mail, "w", encoding="utf-8").write("# письмо\n\nТЕЛО-ПИСЬМА\n")
        lenta = tmp8 / "2026-09-06.jsonl"; io.open(lenta, "w", encoding="utf-8").write('{"text":"СЫРОЙ-ЧАТ"}\n')
        g8 = [
            {"key": "mail:1", "title": "t1", "block": "### П1. t1\n- источник целиком: `%s`\n- `ref_a:3` — x\n- `ref_b:1` — y\n" % mail},
            {"key": "msg:2", "title": "t2", "block": "### П2. t2\n- источник целиком: `%s`\n- `ref_a:9` — z\n" % lenta},
            {"key": "age:ref_a.md", "title": "`ref_a.md` — давно", "block": "### П3. `ref_a.md` — давно\n"},
        ]
        prompt8, recs8, srcs8 = mv.build_prompt(g8, str(mem8))
        ok &= check("каждая запись в задании один раз, целиком, с номерами строк",
                    set(recs8) == {"ref_a.md", "ref_b.md"} and prompt8.count("### Запись `ref_a.md`") == 1
                    and "   40| строка a35" in prompt8, "записи: %s" % sorted(recs8))
        ok &= check("письмо-источник дано целиком, лента моста — нет",
                    "ТЕЛО-ПИСЬМА" in prompt8 and "СЫРОЙ-ЧАТ" not in prompt8 and list(srcs8) == [str(mail)],
                    "письма: %s" % list(srcs8))
        # 9. Расход пакета делится между пунктами: секунды и стоимость тоже.
        real_ce = mv.call_engine
        mv.call_engine = lambda *a, **k: {"verdict": "%s mail:1\nВЕРДИКТ: подтверждено\n%s msg:2\nВЕРДИКТ: заменил\n%s age:ref_a.md\nВЕРДИКТ: подтверждено\n" % (mv.KEY_MARK, mv.KEY_MARK, mv.KEY_MARK),
                                          "tokens": 3000, "seconds": 30.0, "cost": 0.3, "turns": 1}
        try:
            r9 = mv.ask_batch(g8, str(mem8), str(tmp8))
        finally:
            mv.call_engine = real_ce
        ok &= check("токены, секунды и стоимость пакета поделены между пунктами",
                    r9["mail:1"]["tokens"] == 1000 and r9["mail:1"]["seconds"] == 10.0 and abs(r9["mail:1"]["cost"] - 0.1) < 1e-9,
                    "получил: %s" % r9["mail:1"])
        # 10. Движок зовётся без инструментов и без --add-dir.
        real_run, real_exe = mv.subprocess.run, mv.claude_exe
        got = {}
        class _R(object):
            stdout = '{"result":"x","num_turns":1,"total_cost_usd":0,"session_id":"s"}'; stderr = ""
        def _fr(cmd, **kw):
            got["cmd"] = list(cmd); return _R()
        try:
            mv.subprocess.run = _fr; mv.claude_exe = lambda: "claude"
            mv.call_engine("тест", [], str(tmp8), timeout=5, token="TOK")
        finally:
            mv.subprocess.run, mv.claude_exe = real_run, real_exe
        cmd10 = got.get("cmd", [])
        ok &= check("помощник зовётся без инструментов и без --add-dir",
                    "--disallowedTools" in cmd10 and "Read" in cmd10 and "--add-dir" not in cmd10,
                    "cmd: %s" % cmd10[:12])
    finally:
        shutil.rmtree(str(tmp8), ignore_errors=True)
    # 11. 🛑 Последний пункт списка: пустой исход остаётся пустым (следующая строка — не исход),
    # хвост файла (итоги, слабые сигналы) в блок не попадает.
    tmp11 = Path(tempfile.mkdtemp(prefix="probe-verd11-"))
    try:
        lst11 = tmp11 / "list.md"
        io.open(lst11, "w", encoding="utf-8").write(
            "# список\n\n### П1. Пришло: первый\n- от: `lead`, письмо `11`\n- **исход:** \n\n"
            "### П2. Пришло: последний\n- от: `lead`, письмо `12`\n- **исход:** \n_итог: пунктов из внешнего входа — 2_\n\n"
            "## Слабые сигналы (не пункты)\n- ~ `ref_x:3` «не путать» — текст\n\nВСЕГО ПУНКТОВ: 2\n")
        items11 = mv.parse_items(lst11)
        ok &= check("пустой исход последнего пункта не читается как вписанный",
                    [it["skip"] for it in items11] == ["", ""], "причины: %s" % [it["skip"] for it in items11])
        ok &= check("пустой исход перед непустой строкой блока — не исход (регекс не глотает перевод строки)",
                    mv.skip_reason("### П9. x" + chr(10) + "- **исход:** " + chr(10) + "- в памяти об этом же:" + chr(10)) == "",
                    "skip: %r" % mv.skip_reason("### П9. x" + chr(10) + "- **исход:** " + chr(10) + "- в памяти об этом же:" + chr(10)))
        ok &= check("хвост списка (итог, слабые сигналы) в блок последнего пункта не попадает",
                    "_итог" not in items11[-1]["block"] and "Слабые" not in items11[-1]["block"]
                    and "ВСЕГО" not in items11[-1]["block"], "блок: %r" % items11[-1]["block"][-120:])
    finally:
        shutil.rmtree(str(tmp11), ignore_errors=True)
    # 12. 🛑 Штамп на КАЖДОМ выходе расчёта: нет списка, считать нечего, мало памяти, отказ движка,
    # исключение. Тихих выходов нет — иначе роль читает прошлый файл вердиктов как свежий.
    import argparse, json as _json
    tmp12 = Path(tempfile.mkdtemp(prefix="probe-verd12-"))
    sandbox12 = tempfile.mkdtemp(prefix="probe-lock12-")
    real_tmp12 = mv.tempfile.gettempdir
    mv.tempfile.gettempdir = lambda: sandbox12
    try:
        pool = tmp12 / "pool"; memd = pool / ".memory" / "r"; rev = pool / ".revision"
        memd.mkdir(parents=True); rev.mkdir()
        io.open(memd / "ref_x.md", "w", encoding="utf-8").write("---\nname: ref_x\n---\n\nстрока один\n")
        lst = rev / "r.md"
        def args_for(**kw):
            a = argparse.Namespace(list=str(lst), dir=str(memd), jobs=1, limit=0, dry_run=False, lock=None)
            for k, v in kw.items():
                setattr(a, k, v)
            return a
        stp = mv.stamp_path(rev, "r")
        # а) нет списка
        rc = mv.run(args_for())
        st = mv.stamp_read(stp)
        ok &= check("нет списка -> штамп failed с причиной", rc == 2 and st.get("status") == "failed" and "нет списка" in st.get("reason", ""), str(st))
        # б) считать нечего (все пункты с исходом)
        io.open(lst, "w", encoding="utf-8").write("# список\n\n### П1. `ref_x.md` — давно\n- **исход:** подтверждено\n\n---\nВСЕГО ПУНКТОВ: 1\n")
        rc = mv.run(args_for())
        st = mv.stamp_read(stp)
        ok &= check("считать нечего -> штамп done, computed=0", rc == 0 and st.get("status") == "done" and st.get("computed") == 0, str(st))
        ok &= check("файл вердиктов указывает на штамп", ".verdicts-stamp-r.json" in mv.read(rev / "verdicts-r.md"))
        # в) мало памяти
        io.open(lst, "w", encoding="utf-8").write("# список\n\n### П1. `ref_x.md` — давно\n- **исход:** \n\n---\nВСЕГО ПУНКТОВ: 1\n")
        real_mem = mv.mem_available_mib
        mv.mem_available_mib = lambda: 10
        rc = mv.run(args_for())
        mv.mem_available_mib = real_mem
        st = mv.stamp_read(stp)
        ok &= check("мало памяти -> штамп skipped, файл вердиктов перезаписан «НЕ ВЫПОЛНЕН»",
                    rc == 0 and st.get("status") == "skipped" and "памят" in st.get("reason", "")
                    and "НЕ ВЫПОЛНЕН" in mv.read(rev / "verdicts-r.md"), str(st))
        # г) отказ движка (подменяем вызов пакета)
        real_ask = mv.ask_batch
        mv.ask_batch = lambda g, mem, wd, token=None: {it["key"]: {"error": "движок не отвечает", "fatal": True} for it in g}
        real_tok = mv.engine_token
        mv.engine_token = lambda: ("", "проба")
        rc = mv.run(args_for())
        mv.ask_batch = real_ask; mv.engine_token = real_tok
        st = mv.stamp_read(stp)
        ok &= check("отказ движка -> штамп failed с текстом отказа", rc == 3 and st.get("status") == "failed" and "движок" in st.get("reason", ""), str(st))
        # д) исключение внутри расчёта
        real_parse = mv.parse_items
        def boom(p):
            raise RuntimeError("сломалось")
        mv.parse_items = boom
        try:
            mv.run(args_for())
        except RuntimeError:
            pass
        mv.parse_items = real_parse
        st = mv.stamp_read(stp)
        ok &= check("исключение -> штамп failed", st.get("status") == "failed" and "сломалось" in st.get("reason", ""), str(st))
        # е) running с мёртвым pid читается как failed
        mv.stamp_write(stp, status="running", pid=999999999, reason="")
        state, why = mv.stamp_state(mv.stamp_read(stp))
        ok &= check("running с исчезнувшим процессом = failed", state == "failed" and "исчез" in why, "%s / %s" % (state, why))
        # ж) --wait по состояниям (без блокировки)
        def wait_out(block):
            buf = io.StringIO()
            rc = mv.wait_for(memd, block=block, out=buf)
            return rc, buf.getvalue()
        # ⚠️ В потоке с пределом: если --wait примет мёртвый pid за живой, он повиснет навсегда,
        # и проба должна покраснеть, а не зависнуть вместе с ним.
        import threading
        box = {}
        th = threading.Thread(target=lambda: box.update(zip(("rc", "out"), wait_out(True))), daemon=True)
        th.start(); th.join(5)
        ok &= check("--wait при исчезнувшем процессе: код 4 и «разбирай сам» (не виснет)",
                    not th.is_alive() and box.get("rc") == 4 and "Разбирай" in box.get("out", ""),
                    "повис" if th.is_alive() else box.get("out", "")[:160])
        mv.stamp_write(stp, status="done", pid=os.getpid(), computed=1, kept=0, skipped={})
        io.open(rev / "verdicts-r.md", "w", encoding="utf-8").write("# вердикты\nПРОБА-ТЕКСТ\n")
        rc, out = wait_out(True)
        ok &= check("--wait при done: код 0 и печатает файл вердиктов", rc == 0 and "ПРОБА-ТЕКСТ" in out, out[:160])
        mv.stamp_write(stp, status="running", pid=os.getpid())
        rc, out = wait_out(False)
        ok &= check("--status при живом расчёте: код 1, «считается»", rc == 1 and "считается" in out, out[:160])
        stp.unlink()
        rc, out = wait_out(True)
        ok &= check("--wait без штампа: код 5 и указание на `pool handoff`", rc == 5 and "pool handoff" in out, out[:160])
    finally:
        mv.tempfile.gettempdir = real_tmp12
        shutil.rmtree(str(tmp12), ignore_errors=True)
        shutil.rmtree(sandbox12, ignore_errors=True)
    return ok


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if "--mutate" in sys.argv:
        print("Мутации, которые ОБЯЗАНЫ покраснеть:")
        print("  1) BATCH_CHARS сделать бесконечным      -> проба 2 (деление на пакеты)")
        print("  2) split_answer возвращает весь текст   -> пробы 3, 4")
        print("  3) jobs_by_memory игнорирует память     -> пробы 4")
        print("  4) take_machine_lock всегда даёт замок  -> проба 5")
        print("  5) убрать цикл POOL_ROLE_VARS в call_engine -> проба про переменные роли")
        print("  6) skip_reason всегда ''                 -> проба 6")
        print("  7) MARK_RE снова требует звёздочки       -> проба 7")
        print("  8) records_for без дедупа / sources_for даёт .jsonl -> проба 8")
        print("  9) share не делит секунды                 -> проба 9")
        print(" 10) call_engine без --disallowedTools      -> проба 10")
        print(" 11) OUT_RE снова с \\s* / блок без обрезки хвоста -> проба 11")
        print(" 12) любой тихий выход без штампа / --wait без разбора состояний -> проба 12")
        sys.exit(0)
    print("пробы memory-verdicts.py")
    good = probes()
    print("\nИТОГ: " + ("всё зелено" if good else "ЕСТЬ КРАСНОЕ"))
    sys.exit(0 if good else 1)
