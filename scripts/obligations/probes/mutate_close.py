#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Мутационная проверка правки: вырезаем по одному правилу и смотрим, краснеет ли ИМЕННО та
проверка, которая это правило сторожит.

    python3 mutate_close.py

Зелёный прогон проб сам по себе не доказывает ничего: он одинаков и когда правило работает,
и когда проверка его не касается. Поэтому каждая мутация названа вместе с ожидаемой жертвой —
если жертва не покраснела, проверка пустая, и чинить надо ЕЁ, а не код.

Работает на КОПИЯХ в /tmp, боевые файлы не трогаются: пробе подсовывается копия через
переменные окружения PROBE_POOL / PROBE_OBLIG.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
POOL = os.path.join(HERE, "..", "..", "pool.ps1")      # относительно каталога проб: scripts/pool.ps1
OBLIG = os.path.join(HERE, "..", "shop_oblig.py")      # scripts/obligations/shop_oblig.py
PROBE = os.path.join(HERE, "probe_close.py")

MUTATIONS = [
    ("событие кладётся в ящик, а не в archive", POOL,
     "$final = Join-Path (Archive-Dir) ((\"{0}.from-{1}.{2}.md\") -f $id, $fromOwner, $kind)",
     "$final = Join-Path (Sub-Dir 'worker' 'new') ((\"{0}.from-{1}.{2}.md\") -f $id, $fromOwner, $kind)",
     ["amend: ящики не тронуты", "close: ничей ящик не пополнился", "amend: событие лежит в archive"]),

    ("close перестаёт требовать ключ", POOL,
     "if (-not $Key) { throw 'close requires -Key <obligation-key>' }",
     "if ($false) { throw 'close requires -Key <obligation-key>' }",
     ["close без -Key отказывает"]),

    ("amend перестаёт требовать формулировку", POOL,
     "if (-not $Expect -and -not $CloseWhen) { throw 'amend requires -Expect and/or -CloseWhen' }",
     "if ($false) { throw 'amend requires -Expect and/or -CloseWhen' }",
     ["amend без формулировок отказывает"]),

    ("строка Amends не пишется в шапку", POOL,
     'if ($script:Amends)    { $rows += "| Amends | "',
     'if ($false)            { $rows += "| Amends | "',
     ["amend: правка от открывшего меняет Expect", "amend: правка от открывшего меняет CloseWhen"]),

    ("справка обрезается прежним числом строк", POOL,
     "Get-Content $PSCommandPath -TotalCount 56",
     "Get-Content $PSCommandPath -TotalCount 52",
     ["help: справка доходит до конца блока (не обрезана числом)"]),

    ("обходчик не знает поля Amends", OBLIG,
     "(From|FromPool|To|Opens|Expect|CloseWhen|About|Amends|Closes|Outcome)",
     "(From|FromPool|To|Opens|Expect|CloseWhen|About|Closes|Outcome)",
     ["amend: правка от открывшего меняет Expect"]),

    ("правку принимают от кого угодно", OBLIG,
     'elif rec.get("from") != frm:',
     'elif False:',
     ["amend: чужая правка НЕ применена", "amend: чужая правка названа своей причиной"]),

    ("работа в закрытый ключ снова неотличима от кривой", OBLIG,
     '"работа в ЗАКРЫТЫЙ ключ (закрыт %s)"',
     '"привязка к неизвестному ключу (был закрыт %s)"',
     ["закрытый ключ: работа после закрытия названа отдельно"]),

    ("разбор не запускается на событии правки", OBLIG,
     'or h.get("Closes") or h.get("Amends"):',
     'or h.get("Closes"):',
     ["amend: правка от открывшего меняет Expect"]),

    ("счётчик работы после закрытия не растёт", OBLIG,
     'closed_rec["after_close"] = closed_rec.get("after_close", 0) + 1',
     'closed_rec["after_close"] = closed_rec.get("after_close", 0)',
     ["закрытый ключ: счётчик работы после закрытия"]),
]


def run_probe(pool_path, oblig_path):
    """Гоняем пробу на подменённых копиях. Возвращает множество ИМЁН упавших проверок."""
    src = open(PROBE, encoding="utf-8").read()
    src = re.sub(r"^POOL = .*$", "POOL = %r" % pool_path, src, count=1, flags=re.M)
    src = re.sub(r"^OBLIG = .*$", "OBLIG = %r" % oblig_path, src, count=1, flags=re.M)
    tmp_probe = os.path.join(tempfile.gettempdir(), "probe_mutant.py")
    with open(tmp_probe, "w", encoding="utf-8") as f:
        f.write(src)
    r = subprocess.run(["python3", tmp_probe], capture_output=True, text=True)
    failed = set()
    for line in r.stdout.split("\n"):
        m = re.match(r"^  FAIL  (.+?)(?:  |$)", line)
        if m:
            failed.add(m.group(1).strip())
    return failed, r.stdout


def main():
    work = tempfile.mkdtemp(prefix="mutate-close-")
    base_pool = os.path.join(work, "pool.ps1")
    base_oblig = os.path.join(work, "shop_oblig.py")
    shutil.copy2(POOL, base_pool)
    shutil.copy2(OBLIG, base_oblig)

    print("=== контроль: непорченые копии")
    failed, out = run_probe(base_pool, base_oblig)
    if failed:
        print("🛑 КОНТРОЛЬ КРАСНЫЙ — мутации ничего не докажут. Упало: %s" % sorted(failed))
        print(out[-2000:])
        return 2
    print("  контроль зелёный\n")

    bad = 0
    for name, target, old, new, victims in MUTATIONS:
        pool_p, oblig_p = base_pool, base_oblig
        mut_dir = tempfile.mkdtemp(prefix="mut-", dir=work)
        src_p = os.path.join(mut_dir, os.path.basename(target))
        text = open(target, encoding="utf-8").read()
        if text.count(old) != 1:
            print("  ПРОПУСК  %-52s якорь встречается %d раз" % (name, text.count(old)))
            bad += 1
            continue
        with open(src_p, "w", encoding="utf-8") as f:
            f.write(text.replace(old, new, 1))
        if target == POOL:
            pool_p = src_p
        else:
            oblig_p = src_p
        failed, out = run_probe(pool_p, oblig_p)
        caught = [v for v in victims if any(v in f for f in failed)]
        if caught:
            print("  ЛОВИТСЯ  %-52s -> %s" % (name, caught[0]))
        else:
            print("  🛑 НЕ ЛОВИТСЯ %-49s ожидались: %s; упало: %s"
                  % (name, victims, sorted(failed) or "ничего"))
            bad += 1

    shutil.rmtree(work, ignore_errors=True)
    print("\nмутаций %d, не поймано %d" % (len(MUTATIONS), bad))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
