#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пробы рассылки замечаний авторам. Временный пул, боевые шины не трогаются.

    python3 probe_notify.py [--keep]

Главное, что проверяется, — не «письмо ушло», а что оно НЕ уходит там, где уйти не должно:
без ключа `--notify`, на первом прогоне (засев) и повторно на те же замечания.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

PWSH = "pwsh"
HERE = os.path.dirname(os.path.abspath(__file__))
POOL = os.path.join(HERE, "..", "..", "pool.ps1")      # относительно каталога проб: scripts/pool.ps1
OBLIG = os.path.join(HERE, "..", "shop_oblig.py")      # scripts/obligations/shop_oblig.py
CLI = os.path.expanduser("~/.local/bin/pool")

ok, bad = 0, []


def check(name, cond, detail=""):
    global ok
    if cond:
        ok += 1
        print("  PASS  %s" % name)
    else:
        bad.append(name)
        print("  FAIL  %s %s" % (name, detail))


def pool(bus, *args):
    return subprocess.run([PWSH, "-NoProfile", "-File", POOL] + list(args) + ["-BusRoot", bus],
                          capture_output=True, text=True)


def sweep(root, *flags):
    r = subprocess.run(["python3", OBLIG, "--all", "--root", root] + list(flags),
                       capture_output=True, text=True)
    return r.stdout + r.stderr


def inbox(bus, role):
    d = os.path.join(bus, role, "new")
    return [f for f in os.listdir(d)] if os.path.isdir(d) else []


def main():
    root = tempfile.mkdtemp(prefix="probe-notify-")
    try:
        run(root)
    finally:
        if "--keep" in sys.argv:
            print("оставлено: %s" % root)
        else:
            shutil.rmtree(root, ignore_errors=True)
    print("\nИТОГ: %d прошло, %d упало %s" % (ok, len(bad), bad if bad else ""))
    return 1 if bad else 0


def run(root):
    d = os.path.join(root, "poolX")
    bus = os.path.join(d, ".bus")
    os.makedirs(bus, exist_ok=True)
    with open(os.path.join(d, "pool.manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"slug": "poolX", "roles": ["lead", "worker"]}, f)
    for r in ("lead", "worker"):
        os.makedirs(os.path.join(bus, r, "new"), exist_ok=True)
        os.makedirs(os.path.join(bus, r, "cur"), exist_ok=True)

    # кривой ключ: заглавные буквы формой не допускаются
    pool(bus, "send", "-From", "worker", "-To", "lead", "-Subject", "кривой ключ",
         "-Body", "т", "-Opens", "KRIVOI_Kluch", "-Expect", "Требуется что-то",
         "-CloseWhen", "признак")

    # 1. без ключа --notify не уходит ничего
    sweep(root)
    check("без --notify писем нет", len(inbox(bus, "worker")) == 0, str(inbox(bus, "worker")))
    ix = json.load(open(os.path.join(bus, ".obligations", "index.json"), encoding="utf-8"))
    check("замечание в индексе есть", len(ix.get("bad", [])) == 1, str(ix.get("bad")))

    # 2. первый прогон с --notify — засев, письма не уходят
    out = sweep(root, "--notify")
    check("первый прогон: засев, письма не ушли", len(inbox(bus, "worker")) == 0,
          str(inbox(bus, "worker")))
    check("файл отпечатков создан",
          os.path.exists(os.path.join(bus, ".obligations", "notified.json")))

    # 3. новое замечание — письмо уходит
    pool(bus, "send", "-From", "worker", "-To", "lead", "-Subject", "второй кривой",
         "-Body", "т", "-Opens", "ESHO_KRIVO", "-Expect", "Требуется", "-CloseWhen", "признак")
    sweep(root, "--notify")
    box = inbox(bus, "worker")
    check("на новое замечание письмо ушло", len(box) == 1, str(box))
    if box:
        txt = open(os.path.join(bus, "worker", "new", box[0]), encoding="utf-8").read()
        check("письмо от обвязки, а не от роли", "| From | pool-monitor |" in txt)
        check("письмо это заметка, а не задача", ".note." in box[0], box[0])
        check("в письме назван кривой ключ", "ESHO_KRIVO" in txt, txt[:200])
        check("в письме есть, что делать", "coordinating-on-the-pool-bus" in txt)

    # 4. повтора нет
    sweep(root, "--notify")
    check("повторного письма на то же замечание нет", len(inbox(bus, "worker")) == 1,
          str(inbox(bus, "worker")))

    # 5. сухой прогон ничего не отправляет
    pool(bus, "send", "-From", "worker", "-To", "lead", "-Subject", "третий кривой",
         "-Body", "т", "-Opens", "TRETIJ_KRIVO", "-Expect", "Требуется", "-CloseWhen", "признак")
    out = sweep(root, "--notify-dry")
    check("сухой прогон писем не шлёт", len(inbox(bus, "worker")) == 1, str(inbox(bus, "worker")))
    check("сухой прогон называет адресата", "worker" in out and "ушло бы" in out, out[-300:])

    # 6. пересборка индекса рассылку не запускает
    before = len(inbox(bus, "worker"))
    sweep(root, "--notify", "--rebuild")
    check("на пересборке индекса писем не шлём", len(inbox(bus, "worker")) == before,
          str(inbox(bus, "worker")))

    # 7. битый файл отпечатков не приводит к рассылке заново
    with open(os.path.join(bus, ".obligations", "notified.json"), "w", encoding="utf-8") as f:
        f.write("{это не json")
    before = len(inbox(bus, "worker"))
    out = sweep(root, "--notify")
    check("битый файл отпечатков: рассылки нет", len(inbox(bus, "worker")) == before,
          str(inbox(bus, "worker")))
    check("битый файл отпечатков: сказано в журнал", "нечитаем" in out, out[-300:])


if __name__ == "__main__":
    sys.exit(main())
