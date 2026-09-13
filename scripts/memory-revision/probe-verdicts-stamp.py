# -*- coding: utf-8 -*-
"""Проба: отказ, не закрытый удачным расчётом, ВИДЕН роли — и не выдумывается там, где его нет.

Что случилось 11.09. У роли `qa-div` расчёт отказал по входу движка. Пересчёт по тому же списку
считать отказался (все пункты уже с исходами) и записал `done: считать нечего`, переписав и штамп, и
файл отчёта. Причина отказа, которую роль обязана назвать владельцу, исчезла из обоих мест — отказ
стал выглядеть работой задним числом.

🛑 Признак ПОЛОЖИТЕЛЬНЫЙ: «удачного расчёта с тех пор не было», а не «прежний штамп похож на отказ».
Зачем — случай 2: обвязка пишет штамп ДО запуска расчёта (`status=running, pid=0`), и такая запись
честно читается как `failed`; признак «похоже на отказ» зажёг бы ложную тревогу у каждой роли на
каждой свёртке.

🛑 Стенд свой: своя раскладка каталогов, своя копия списка, поддельный движок
(`probe-stub-engine.py`) в своём PATH. Настоящий движок не зовётся, денег проба не стоит; живые
списки и память только копируются.

Вызов: probe-verdicts-stamp.py [путь к memory-verdicts.py] [путь к memory-close.py]
"""
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MOD = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "memory-verdicts.py")
CLOSER = sys.argv[2] if len(sys.argv) > 2 else os.path.join(HERE, "memory-close.py")
STUB = os.path.join(HERE, "probe-stub-engine.py")
WARN = "удачного с тех пор не было"


def find_sample():
    """Живой список актуализации и память той же роли — ОБРАЗЕЦ входа для стенда.

    🛑 Список руками не сочиняем: его формат задаёт сборщик, и сочинённый образец проверял бы не то
    (этой граблей уже оплачен один разбор — см. `ref_probe-failures`, случай про рукописный вход).
    Берём копию живого: на рабочей машине — свой, на сервере — любой роли, у которой рядом есть и
    список, и каталог памяти.
    """
    import glob as _g
    roots = [r"<workspace-root>\.launcher", os.path.expanduser("<workspace-root>/.launcher")]
    roots += _g.glob(os.path.expanduser("<workspace-root>/*")) + _g.glob(os.path.expanduser("<workspace-root>/*/*"))
    for root in roots:
        rev = os.path.join(root, ".revision")
        if not os.path.isdir(rev):
            continue
        mine = os.environ.get("AGENT_OWNER") or ""
        cand = sorted(_g.glob(os.path.join(rev, "*.md")),
                      key=lambda p: (os.path.basename(p)[:-3] != mine, p))
        for lst in cand:
            role = os.path.basename(lst)[:-3]
            mem = os.path.join(root, ".memory", role)
            if os.path.isdir(mem) and "### П" in io.open(lst, encoding="utf-8", errors="replace").read():
                return lst, mem
    return "", ""


REAL_LIST, REAL_MEM = find_sample()

FAILS = []
SKIPS = []
TRASH = []

# 🛑 Проба печатает ЗАХВАЧЕННЫЙ вывод инструмента, а в нём попадаются знаки, которых нет в кодировке
# консоли Windows (эмодзи из отчётов). Без этой строки `print` роняет пробу прямо в обработчике
# отказа — и красное выглядит поломкой пробы, а не найденным дефектом: мутанты тогда «не краснеют».
try:
    sys.stdout.reconfigure(errors="replace")
except Exception:
    pass


def ok(m):
    print("  ok   %s" % m)


def bad(m):
    print("  FAIL %s" % m)
    FAILS.append(m)


def skip(m):
    print("  ПРОПУСК %s" % m)
    SKIPS.append(m)


def toolbox():
    """Копии проверяемых инструментов под КАНОНИЧЕСКИМИ именами, вместе с их соседями.

    🛑 Иначе закрыватель зовёт `load_sibling("memory-verdicts.py", …)` и берёт функцию у ОРИГИНАЛА,
    лежащего рядом: правленого соседа он не увидит, и случай про закрыватель проверил бы старый код.
    """
    d = tempfile.mkdtemp(prefix="tools-")
    TRASH.append(d)
    for f in os.listdir(HERE):
        if f.endswith(".py") and not f.startswith(("probe-", "cand-")):
            shutil.copy2(os.path.join(HERE, f), os.path.join(d, f))
    shutil.copy2(MOD, os.path.join(d, "memory-verdicts.py"))
    if os.path.isfile(CLOSER):
        shutil.copy2(CLOSER, os.path.join(d, "memory-close.py"))
    return os.path.join(d, "memory-verdicts.py"), os.path.join(d, "memory-close.py")


def stand(work=False, broken=False):
    """🛑 Раскладка как на боевом: каталог списка инструмент вычисляет ОТ пути памяти
    (`<корень>/.revision`, корень — на два уровня выше памяти). Иначе расчёт и команда ожидания
    смотрят в разные места, и проба краснеет на своём же стенде."""
    d = tempfile.mkdtemp(prefix="stamp-probe-")
    TRASH.append(d)
    mem = os.path.join(d, ".memory", "memstand")
    rev = os.path.join(d, ".revision")
    binp = os.path.join(d, "bin")
    for x in (mem, rev, binp):
        os.makedirs(x)

    text = io.open(REAL_LIST, encoding="utf-8").read()
    if work:
        # ⚠️ Открываем ВСЕ исходы, а не пункт по номеру: у разных ролей списки разные, и у
        # «того самого» пункта может оказаться свой пропуск (второй перенос подряд, знак ~) —
        # тогда работы не появится, и случай проверит не то. На сервере этим и покраснело.
        text = re.sub(r"- [*][*]исход:[*][*][^\n]*", "- **исход:** ", text)
    io.open(os.path.join(rev, "list.md"), "w", encoding="utf-8", newline="\n").write(text)
    for name in re.findall(r"### П\d+\.\s*`([^`]+)`", text):
        src = os.path.join(REAL_MEM, name)
        if os.path.isfile(src):
            shutil.copy2(src, os.path.join(mem, name))
    io.open(os.path.join(mem, "MEMORY.md"), "w", encoding="utf-8", newline="\n").write("# стенд\n")

    stub = os.path.join(binp, "stub.py")
    shutil.copy2(STUB, stub)
    if broken:
        io.open(stub + ".mode", "w", encoding="utf-8").write("broken")
    if os.name == "nt":
        io.open(os.path.join(binp, "claude.cmd"), "w", encoding="utf-8", newline="\r\n").write(
            '@python "%~dp0stub.py" %*\n')
    else:
        p = os.path.join(binp, "claude")
        io.open(p, "w", encoding="utf-8", newline="\n").write(
            '#!/bin/sh\nexec python3 "$(dirname "$0")/stub.py" "$@"\n')
        os.chmod(p, 0o755)
    return d, mem, rev, binp


def stamp_file(rev, mem):
    return os.path.join(rev, ".verdicts-stamp-%s.json" % os.path.basename(mem))


def report_file(rev, mem):
    return os.path.join(rev, "verdicts-%s.md" % os.path.basename(mem))


def read_stamp(rev, mem):
    try:
        return json.loads(io.open(stamp_file(rev, mem), encoding="utf-8").read())
    except Exception:
        return {}


def report(rev, mem):
    p = report_file(rev, mem)
    return io.open(p, encoding="utf-8").read() if os.path.isfile(p) else ""


def run_tool(mem, rev, binp, lst=None):
    env = dict(os.environ)
    env["PATH"] = binp + os.pathsep + env.get("PATH", "")
    cmd = [sys.executable, MOD, "--list", lst or os.path.join(rev, "list.md"),
           "--dir", mem, "--jobs", "1"]
    return subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                          errors="replace", timeout=900, env=env)


def make_real_failure(mem, rev, binp):
    """Отказ производится ИНСТРУМЕНТОМ, а не подложенным штампом: так проверяется заодно, что метку
    отказа вообще кто-то ставит."""
    run_tool(mem, rev, binp, lst=os.path.join(rev, "нет-такого-списка.md"))


def main():
    global MOD, CLOSER
    print("проверяю: %s" % MOD)
    if not REAL_LIST:
        # ⚠️ Молчать нельзя: без образца входа проба ничего не проверила, и её ноль отказов
        # неотличим от успеха.
        skip("живого списка актуализации на этой машине не нашлось — стенду не из чего строиться")
        print()
        print("пропущено проверок: 1")
        print("ПРОБА НЕ ВЫПОЛНЕНА: нет образца входа")
        return 2
    print("образец входа: %s" % REAL_LIST)
    MOD, CLOSER = toolbox()

    print("== 1. отказ помнится: пустой прогон после отказа предупреждает")
    d, mem, rev, binp = stand()
    make_real_failure(mem, rev, binp)
    st = read_stamp(rev, mem)
    if (st.get("last_fail") or {}).get("at"):
        ok("отказ оставил метку: %s" % (st["last_fail"].get("reason") or "")[:50])
    else:
        bad("отказ метки не оставил: %r" % st)
    run_tool(mem, rev, binp)
    st, rep = read_stamp(rev, mem), report(rev, mem)
    if st.get("status") == "done" and (st.get("last_fail") or {}).get("at"):
        ok("пустой прогон закрылся, метка отказа цела")
    else:
        bad("метка потеряна пустым прогоном: %r" % st)
    if WARN in rep:
        ok("отчёт предупреждает роль")
    else:
        bad("отчёт молчит об отказе: %s" % rep[:300])

    print("== 2. запись ОБВЯЗКИ (running, pid 0) отказом НЕ считается")
    d, mem, rev, binp = stand()
    io.open(stamp_file(rev, mem), "w", encoding="utf-8", newline="\n").write(json.dumps({
        "role": "memstand", "list": os.path.join(rev, "list.md"), "status": "running", "pid": 0,
        "phase": "запуск обвязкой", "reason": "", "started": "2026-09-11 14:00:00",
        "launched_by": "memory-audit"}, ensure_ascii=False))
    run_tool(mem, rev, binp)
    st, rep = read_stamp(rev, mem), report(rev, mem)
    if not (st.get("last_fail") or {}).get("at"):
        ok("метка отказа не выдумана")
    else:
        bad("ЛОЖНАЯ ТРЕВОГА: запись обвязки принята за отказ (%r)" % st.get("last_fail"))
    if WARN not in rep:
        ok("отчёт не пугает")
    else:
        bad("ЛОЖНАЯ ТРЕВОГА в отчёте: %s" % rep[:200])

    print("== 3. удачный расчёт предупреждение снимает")
    d, mem, rev, binp = stand(work=True)
    make_real_failure(mem, rev, binp)
    r = run_tool(mem, rev, binp)
    st, rep = read_stamp(rev, mem), report(rev, mem)
    if st.get("last_ok") and (st.get("last_ok_n") or 0) >= 1:
        ok("метка удачи поставлена (вердиктов легло: %s)" % st.get("last_ok_n"))
    else:
        bad("метки удачи нет: %r; вывод: %s"
            % ({k: st.get(k) for k in ("last_ok", "last_ok_n", "computed")}, (r.stdout or "")[-200:]))
    if WARN not in rep:
        ok("отчёт больше не предупреждает")
    else:
        bad("предупреждение осталось после удачи")

    print("== 4. ошибка БЕЗ пометки «фатально» удачей не считается")
    d, mem, rev, binp = stand(work=True, broken=True)
    make_real_failure(mem, rev, binp)
    r = run_tool(mem, rev, binp)
    st, rep = read_stamp(rev, mem), report(rev, mem)
    if not st.get("last_ok"):
        ok("метка удачи не поставлена на неразобранном ответе")
    else:
        bad("НЕУДАЧА СОШЛА ЗА УДАЧУ: last_ok=%r, вердиктов %r"
            % (st.get("last_ok"), st.get("last_ok_n")))
    if WARN in rep:
        ok("отчёт по-прежнему предупреждает")
    else:
        bad("предупреждение снято зря; вывод: %s" % (r.stdout or "")[-200:])

    print("== 5. команда ожидания не прячет отказ за словом «готовы»")
    d, mem, rev, binp = stand()
    make_real_failure(mem, rev, binp)
    run_tool(mem, rev, binp)
    r = subprocess.run([sys.executable, MOD, "--wait", "--dir", mem], capture_output=True,
                       text=True, encoding="utf-8", errors="replace", timeout=300)
    out = (r.stdout or "") + (r.stderr or "")
    if "готовы" in out:
        ok("ожидание отвечает «готовы»")
    else:
        bad("ожидание ответило не тем: %s" % out[:200])
    # ⚠️ Ищем СВОЮ строку ожидания: тело отчёта эта команда печатает целиком, и предупреждение из
    # отчёта прошло бы за её собственное — мутант тогда не краснеет.
    if "НО расчёт" in out:
        ok("и предупреждает само, а не пересказом отчёта")
    else:
        bad("своего предупреждения нет: %s" % out[:300])

    print("== 6. закрыватель тоже видит непокрытый отказ")
    if not os.path.isfile(CLOSER):
        skip("закрывателя нет рядом (%s)" % CLOSER)
    else:
        spec = importlib.util.spec_from_file_location("closer_probe", CLOSER)
        mc = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mc)
        d, mem, rev, binp = stand()
        make_real_failure(mem, rev, binp)
        run_tool(mem, rev, binp)
        # ⚠️ Закрыватель сверяет ВРЕМЯ файла исходов со временем списка — ему нужен путь, а не
        # пустышка: на словаре он падает, и случай проверял бы падение, а не замечание.
        outs = os.path.join(d, "outcomes.txt")
        io.open(outs, "w", encoding="utf-8", newline="\n").write("П1 | перенесено | стенд\n")
        probs = mc.gate_problems(os.path.join(rev, "list.md"), mem, outs)
        texts = " | ".join(t for _, t in probs)
        if WARN in texts:
            ok("замечание закрывателя на месте")
        else:
            bad("закрыватель молчит: %s" % (texts[:200] or "(замечаний нет)"))

    for x in TRASH:
        shutil.rmtree(x, ignore_errors=True)
    print()
    if SKIPS:
        print("пропущено проверок: %d" % len(SKIPS))
    if FAILS:
        print("ПРОБА КРАСНАЯ: отказов %d" % len(FAILS))
        return 1
    print("ПРОБА ЗЕЛЁНАЯ: отказов 0")
    return 0


if __name__ == "__main__":
    sys.exit(main())
