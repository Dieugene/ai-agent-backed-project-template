#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Мутационная проверка поля Expect: вырезаем правило — должна покраснеть СВОЯ проверка.

Зелёный прогон сам по себе ничего не доказывает: проба могла ничего не проверять. Здесь по
одной калечится копия движка, и сверяется, что упал именно тот пункт, который это правило
сторожит, — а не «хоть что-нибудь упало».

🛑 Каждая мутация живёт в СВОЁМ временном каталоге и прогоняется ПОСЛЕДОВАТЕЛЬНО: два прогона
на одном файле дают ложные падения (проверено на прошлой правке — восемь штук).

    python3 mutate_expect.py --engine <pool.ps1> --module <shop_oblig.py> --probe <probe_expect.py>
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

# (имя мутации, файл: engine|module, что заменить, на что, какая проверка обязана упасть)
MUTATIONS = [
    ("строка Expect не пишется в шапку", "engine",
     '  if ($script:Expect)    { $rows += "| Expect | "    + (Format-HeaderValue $script:Expect)    + " |`n" }\n',
     '',
     "строка Expect есть в шапке"),

    ("значение Expect не санитизируется", "engine",
     '(Format-HeaderValue $script:Expect)',
     '($script:Expect)',
     "вертикальная черта экранирована"),

    ("expect не читается из индекса", "engine",
     "        expect     = Get-JsonProp $b 'expect'\n",
     "        expect     = ''\n",
     "свод печатает ожидание первой строкой"),

    ("длинные значения не обрезаются", "engine",
     "(Clip-Text $head 160)",
     "$head",
     "длинное значение обрезано"),

    ("потолок свода вернулся к семи", "engine",
     "if ($shown -ge 5) { break }",
     "if ($shown -ge 7) { break }",
     "потолок свода — пять записей"),

    ("вторая строка печатается без проверки", "engine",
     'if ($b.expect -and $b.close_when) { Write-Output ("       closed when: {0}"',
     'if ($true) { Write-Output ("       closed when: {0}"',
     "пустой признак не печатается голой строкой"),

    ("справка снова обрезается на 49 строках", "engine",
     "Get-Content $PSCommandPath -TotalCount 52",
     "Get-Content $PSCommandPath -TotalCount 49",
     "справка доезжает до конца шапки"),

    ("разбор шапки не знает Expect", "module",
     "(From|To|Opens|Expect|CloseWhen|About|Closes|Outcome)",
     "(From|To|Opens|CloseWhen|About|Closes|Outcome)",
     "поле expect попало в индекс"),
]


def failed_checks(text: str):
    return {line.split("FAIL:", 1)[1].strip()
            for line in text.splitlines() if "FAIL:" in line}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--module", required=True)
    ap.add_argument("--probe", required=True)
    a = ap.parse_args()

    bad = 0
    for name, target, old, new, expect_fail in MUTATIONS:
        work = Path(tempfile.mkdtemp(prefix="mutate-"))
        eng = work / "pool.ps1"
        mod = work / "shop_oblig.py"
        shutil.copy2(a.engine, eng)
        shutil.copy2(a.module, mod)
        victim = eng if target == "engine" else mod
        text = victim.read_text(encoding="utf-8")
        if text.count(old) != 1:
            print("  ?? %-42s якорь мутации не уникален (%d) — мутация не поставлена"
                  % (name, text.count(old)))
            bad += 1
            continue
        victim.write_text(text.replace(old, new, 1), encoding="utf-8")

        p = subprocess.run([sys.executable, a.probe, "--engine", str(eng), "--module", str(mod)],
                           capture_output=True, text=True, encoding="utf-8")
        fails = failed_checks(p.stdout or "")
        if expect_fail in fails:
            extra = len(fails) - 1
            tail = (" (+%d других)" % extra) if extra else ""
            print("  ok %-42s -> покраснело: %s%s" % (name, expect_fail, tail))
        else:
            print("  ХУЖЕ %-40s -> ожидалось падение «%s», упало: %s"
                  % (name, expect_fail, ", ".join(sorted(fails)) or "ничего"))
            bad += 1
        shutil.rmtree(work, ignore_errors=True)

    print("\n=== мутаций: %d, не поймано: %d ===" % (len(MUTATIONS), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
