#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Проба поля Expect («Требуется») — форма письма, свод в mine, сбор в индекс.

    python3 probe_expect.py --engine <pool.ps1> --module <shop_oblig.py>

Пишет только во временный каталог. Боевые шины не трогает.
🛑 Ни одного обращения к возможному отсутствию через index/split: проба, падающая исключением,
краснеет не своей проверкой, и мутация выглядит пойманной, когда поймано совсем другое.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

PWSH = "pwsh"
FAILED = []
PASSED = []


def check(name: str, ok: bool, evidence: str = "") -> None:
    (PASSED if ok else FAILED).append(name)
    print(("PASS  " if ok else "FAIL  ") + name)
    if not ok and evidence:
        print("      " + evidence.replace("\n", "\n      ")[:600])


def run(engine: str, *args: str):
    p = subprocess.run([PWSH, "-NoProfile", "-File", engine, *args],
                       capture_output=True, text=True, encoding="utf-8")
    return p.returncode, (p.stdout or ""), (p.stderr or "")


def header_of(path: Path) -> str:
    text = path.read_text(encoding="utf-8")
    out, in_table = [], False
    for line in text.splitlines():
        if line.startswith("|"):
            in_table = True
            out.append(line)
        elif in_table:
            break
    return "\n".join(out)


def only_letter(bus: Path, owner: str) -> Path:
    files = sorted(Path(bus, owner, "new").glob("*.md"))
    return files[-1] if files else Path(bus, "нет-письма")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--engine", required=True)
    ap.add_argument("--module", required=True)
    a = ap.parse_args()
    engine = a.engine

    tmp = Path(tempfile.mkdtemp(prefix="probe-expect-"))
    bus = tmp / "bus"
    for role in ("lead", "records"):
        for sub in ("new", "cur", "tmp"):
            (bus / role / sub).mkdir(parents=True, exist_ok=True)
    (bus / "archive").mkdir(parents=True, exist_ok=True)

    EXPECT = "Требуется корпус утверждений памяти оператора — вход для встречной проверки"
    CLOSE = "корпус прислан, названо число прочитанных записей из 136, у каждого путь к источнику"

    # --- 1. форма письма ----------------------------------------------------
    rc, out, err = run(engine, "send", "-To", "records", "-From", "lead",
                       "-Subject", "проба", "-Body", "тело",
                       "-Opens", "korpus", "-Expect", EXPECT, "-CloseWhen", CLOSE,
                       "-BusRoot", str(bus))
    check("отправка с -Expect не падает", rc == 0, err)
    hdr = header_of(only_letter(bus, "records"))
    check("строка Expect есть в шапке", ("| Expect |" in hdr) and (EXPECT in hdr), hdr)

    pos_o = hdr.find("| Opens |")
    pos_e = hdr.find("| Expect |")
    pos_c = hdr.find("| CloseWhen |")
    check("порядок полей: Opens, Expect, CloseWhen",
          pos_o >= 0 and pos_e > pos_o and pos_c > pos_e, hdr)

    # --- 2. санитизация -----------------------------------------------------
    rc, out, err = run(engine, "send", "-To", "records", "-From", "lead",
                       "-Subject", "проба2", "-Body", "тело",
                       "-Opens", "truba", "-Expect", "требуется A | B и\nвторая строка",
                       "-CloseWhen", "событие", "-BusRoot", str(bus))
    hdr2 = header_of(only_letter(bus, "records"))
    line_e = ""
    for line in hdr2.splitlines():
        if line.startswith("| Expect |"):
            line_e = line
    check("вертикальная черта экранирована", "\\|" in line_e, line_e)
    check("перевод строки схлопнут в пробел",
          ("вторая строка" in line_e) and (line_e.count("|") >= 2) and ("\n" not in line_e), line_e)

    # --- 3. сбор в индекс ---------------------------------------------------
    sys.path.insert(0, os.path.dirname(os.path.abspath(a.module)))
    import importlib.util
    spec = importlib.util.spec_from_file_location("shop_oblig_probe", a.module)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.pass_bus(str(bus))
    ix_path = bus / ".obligations" / "index.json"
    ix = json.loads(ix_path.read_text(encoding="utf-8")) if ix_path.exists() else {}
    rows = [r for r in ix.get("open", []) if r.get("key") == "korpus"]
    check("обходчик собрал обязательство", len(rows) == 1, json.dumps(ix, ensure_ascii=False)[:400])
    check("поле expect попало в индекс",
          len(rows) == 1 and EXPECT in rows[0].get("expect", ""),
          json.dumps(rows, ensure_ascii=False)[:400])

    # --- 4. свод в mine -----------------------------------------------------
    def write_index(records):
        ix_path.parent.mkdir(parents=True, exist_ok=True)
        ix_path.write_text(json.dumps({"generated_at": "2026-08-30T15:00:00+03:00",
                                       "open": records}, ensure_ascii=False), encoding="utf-8")

    write_index([{"key": "korpus", "from": "lead", "to": "records",
                  "expect": EXPECT, "close_when": CLOSE}])
    rc, out, err = run(engine, "mine", "-Owner", "lead", "-BusRoot", str(bus))
    check("свод печатает ожидание первой строкой", EXPECT[:40] in out, out[-500:])
    check("свод печатает признак второй строкой", "closed when:" in out and CLOSE[:30] in out, out[-500:])

    write_index([{"key": "starye", "from": "lead", "to": "records", "close_when": CLOSE}])
    rc, out, err = run(engine, "mine", "-Owner", "lead", "-BusRoot", str(bus))
    check("старая запись без expect печатается одной строкой",
          (CLOSE[:30] in out) and ("closed when:" not in out), out[-500:])

    write_index([{"key": "bezpriznaka", "from": "lead", "to": "records", "expect": EXPECT}])
    rc, out, err = run(engine, "mine", "-Owner", "lead", "-BusRoot", str(bus))
    check("пустой признак не печатается голой строкой", "closed when:" not in out, out[-500:])

    long_expect = "Т" * 400
    write_index([{"key": "dlinnoe", "from": "lead", "to": "records",
                  "expect": long_expect, "close_when": CLOSE}])
    rc, out, err = run(engine, "mine", "-Owner", "lead", "-BusRoot", str(bus))
    longest = max((len(l) for l in out.splitlines() if l.startswith("   ! ")), default=0)
    check("длинное значение обрезано", 0 < longest < 260, "самая длинная строка: %d" % longest)

    write_index([{"key": "m%d" % i, "from": "lead", "to": "records",
                  "expect": "требуется %d" % i, "close_when": "событие %d" % i} for i in range(9)])
    rc, out, err = run(engine, "mine", "-Owner", "lead", "-BusRoot", str(bus))
    check("потолок свода — пять записей",
          out.count("   ! ") == 5 and "(+4 more)" in out, out[-600:])

    # --- 5. справка ---------------------------------------------------------
    rc, out, err = run(engine, "help")
    check("справка называет -Expect", "-Expect" in out, out[:400])
    check("справка доезжает до конца шапки", "also wakes an idle watcher" in out, out[-300:])

    print("\n=== ИТОГО: %d PASS, %d FAIL ===" % (len(PASSED), len(FAILED)))
    for name in FAILED:
        print("  FAIL: " + name)
    return 1 if FAILED else 0


if __name__ == "__main__":
    raise SystemExit(main())
