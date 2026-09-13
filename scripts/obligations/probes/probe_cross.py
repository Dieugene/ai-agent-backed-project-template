#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Пробы сводки обязательств по чужим шинам.

    python3 probe_cross.py [--keep]

Строит два ВРЕМЕННЫХ пула со своими шинами и манифестами, гоняет обходчик с `--all` по ним
и проверяет, что попало в `cross.json` и что напечатал `mine`. Боевые пулы не трогаются.

Главная проверяемая опасность — тёзки: `lead` живёт в каждом пуле, и обязательство чужого
`lead` не должно попасть в свод своего.
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

ok, bad = 0, []


def check(name, cond, detail=""):
    global ok
    if cond:
        ok += 1
        print("  PASS  %s" % name)
    else:
        bad.append(name)
        print("  FAIL  %s %s" % (name, detail))


def pool(bus, *args, home=None):
    """`home` — домашняя шина ОТПРАВИТЕЛЯ: движок берёт её из окружения роли и по ней
    проставляет в шапку имя своего пула. Так письмо из чужого пула само себя называет."""
    env = dict(os.environ)
    if home:
        env["POOL_BUS_ROOT"] = home
    else:
        env.pop("POOL_BUS_ROOT", None)
    return subprocess.run([PWSH, "-NoProfile", "-File", POOL] + list(args) + ["-BusRoot", bus],
                          capture_output=True, text=True, env=env)


def make_pool(root, name, roles):
    d = os.path.join(root, name)
    bus = os.path.join(d, ".bus")
    os.makedirs(bus, exist_ok=True)
    with open(os.path.join(d, "pool.manifest.json"), "w", encoding="utf-8") as f:
        json.dump({"slug": name, "roles": roles}, f)
    for r in roles:                       # ящик = каталог роли; его наличие и есть «своя шина»
        os.makedirs(os.path.join(bus, r, "new"), exist_ok=True)
        os.makedirs(os.path.join(bus, r, "cur"), exist_ok=True)
    return bus


def sweep_all(root):
    subprocess.run(["python3", OBLIG, "--all", "--root", root], capture_output=True, text=True)


def cross_of(bus):
    p = os.path.join(bus, ".obligations", "cross.json")
    if not os.path.exists(p):
        return None
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def main():
    root = tempfile.mkdtemp(prefix="probe-cross-")
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
    bus_a = make_pool(root, "poolA", ["lead", "coordinator"])
    bus_b = make_pool(root, "poolB", ["lead", "worker"])

    # 1. coordinator (ящик только в A) открывает обязательство в шине B
    pool(bus_b, "send", "-From", "coordinator", "-To", "worker", "-Subject", "межпуловое",
         "-Body", "т", "-Opens", "mezhpulovoe-odin",
         "-Expect", "Требуется межпуловая работа", "-CloseWhen", "признак межпулового")
    # 2. lead из A пишет в шину B — тёзка, различить нечем
    pool(bus_b, "send", "-From", "lead", "-To", "worker", "-Subject", "от тёзки",
         "-Body", "т", "-Opens", "tezka-dva",
         "-Expect", "Требуется работа от тёзки", "-CloseWhen", "признак тёзки")
    # 3. внутрипуловое обязательство в B — в cross попасть не должно вовсе
    pool(bus_b, "send", "-From", "worker", "-To", "lead", "-Subject", "внутри B",
         "-Body", "т", "-Opens", "vnutri-b",
         "-Expect", "Требуется внутреннее", "-CloseWhen", "признак внутреннего")
    sweep_all(root)

    ca = cross_of(bus_a)
    check("сводка для пула A создана", ca is not None)
    roles_a = (ca or {}).get("roles", {})
    coord = roles_a.get("coordinator", [])
    check("координатор видит своё обязательство из чужой шины", len(coord) == 1,
          str([r.get("key") for r in coord]))
    check("у строки назван пул, где она живёт",
          bool(coord and coord[0].get("bus", "").endswith("poolB")),
          str(coord[0].get("bus") if coord else None))
    check("формулировка доехала до сводки",
          bool(coord and coord[0].get("expect") == "Требуется межпуловая работа"),
          str(coord[0].get("expect") if coord else None))

    # 🛑 главное: тёзка
    lead_a = roles_a.get("lead", [])
    check("ТЁЗКА: обязательство чужого lead НЕ попало в свод lead'а пула A",
          len(lead_a) == 0, str([r.get("key") for r in lead_a]))

    cb = cross_of(bus_b)
    roles_b = (cb or {}).get("roles", {})
    check("внутрипуловое в сводку не попало",
          all("vnutri-b" != r.get("key") for rows in roles_b.values() for r in rows),
          str(roles_b))
    check("worker (ящик в B) своего же обязательства в сводке не видит",
          len(roles_b.get("worker", [])) == 0, str(roles_b.get("worker")))

    # 3б. ТЁЗКА С КВАЛИФИЦИРОВАННЫМ АДРЕСОМ: тот же `lead`, но письмо несёт имя своего пула
    pool(bus_b, "send", "-From", "lead", "-To", "worker", "-Subject", "тёзка, но с адресом",
         "-Body", "т", "-Opens", "tezka-s-adresom",
         "-Expect", "Требуется работа от тёзки с адресом", "-CloseWhen", "признак",
         home=bus_a)
    sweep_all(root)
    ca = cross_of(bus_a)
    lead_rows = (ca or {}).get("roles", {}).get("lead", [])
    keys_a = [r.get("key") for r in lead_rows]
    check("КВАЛИФИЦИРОВАННЫЙ АДРЕС: обязательство тёзки дошло до СВОЕГО пула",
          "tezka-s-adresom" in keys_a, str(keys_a))
    check("а безадресное обязательство тёзки по-прежнему не разносится",
          "tezka-dva" not in keys_a, str(keys_a))
    cb = cross_of(bus_b)
    lead_b = (cb or {}).get("roles", {}).get("lead", [])
    check("в чужой пул обязательство тёзки не попало",
          "tezka-s-adresom" not in [r.get("key") for r in lead_b], str(lead_b))
    # само поле в письме
    txt = ""
    for f in os.listdir(os.path.join(bus_b, "worker", "new")):
        t = open(os.path.join(bus_b, "worker", "new", f), encoding="utf-8").read()
        if "tezka-s-adresom" in t:
            txt = t
    check("в шапке письма стоит имя пула отправителя", "| FromPool | poolA |" in txt, txt[:400])

    # 4. свод роли печатает отдельную секцию
    r = pool(bus_a, "mine", "-Owner", "coordinator")
    check("mine не падает", r.returncode == 0, r.stderr[:200])
    check("mine печатает секцию чужих пулов", "obligations in OTHER pools" in r.stdout,
          r.stdout[-300:])
    check("mine называет пул в строке", "poolB" in r.stdout, r.stdout[-300:])

    # 5. роль без чужих обязательств секции не получает.
    # Берём `worker` из пула B: у него всё своё в своей шине. `lead` пула A для этой проверки
    # больше не годится — после сценария 3б у него законно появилось чужое обязательство.
    r = pool(bus_b, "mine", "-Owner", "worker")
    check("роль без чужих обязательств секции не видит",
          "obligations in OTHER pools" not in r.stdout, r.stdout[-200:])

    # 6. нет файла сводки — mine всё равно работает (локальная машина без обхода)
    os.remove(os.path.join(bus_a, ".obligations", "cross.json"))
    r = pool(bus_a, "mine", "-Owner", "coordinator")
    check("без файла сводки mine работает", r.returncode == 0, r.stderr[:200])
    check("без файла сводки секции нет", "obligations in OTHER pools" not in r.stdout)

    # 7. битый файл сводки не роняет подъём роли
    with open(os.path.join(bus_a, ".obligations", "cross.json"), "w", encoding="utf-8") as f:
        f.write("{это не json")
    r = pool(bus_a, "mine", "-Owner", "coordinator")
    check("битая сводка не роняет mine", r.returncode == 0, r.stderr[:200])


if __name__ == "__main__":
    sys.exit(main())
