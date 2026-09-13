# -*- coding: utf-8 -*-
"""Поддельный движок для проб: отвечает на задание помощника, не выходя в сеть и не тратя денег.

Кладётся пробой в свой каталог и подставляется в PATH под именем `claude`. Задание приходит на
stdin, ответ — одним JSON на stdout, как у настоящего движка.

⚠️ Если рядом лежит файл `<этот файл>.mode`, заглушка отвечает НЕразбираемым текстом: так
проверяется, что ошибка без пометки «фатально» не сходит за удачный расчёт.
"""
import json
import os
import sys

# Метка, которой задание помечает пункты; ответ обязан её повторить, иначе вердикт не разложится.
MARK = "ПУНКТ-КЛЮЧ:"

# 🛑 Читаем БАЙТАМИ и декодируем UTF-8: задание приходит в UTF-8, а `sys.stdin.read()` на Windows
# разобрал бы его кодировкой консоли (cp1251) — метка пунктов не совпала бы, заглушка ответила бы
# запасным ключом, и проба краснела бы на исправном коде. Ровно та же грабля, что и на выводе.
prompt = sys.stdin.buffer.read().decode("utf-8", "replace")

if os.path.exists(__file__ + ".mode"):
    sys.stdout.write("this is not json at all")
    raise SystemExit(0)

keys = []
for line in prompt.splitlines():
    t = line.strip()
    if t.startswith(MARK):
        k = t.split(MARK, 1)[1].strip().strip("`")
        if k and k not in keys:
            keys.append(k)

parts = []
for k in (keys or ["x"]):
    parts.append("%s %s" % (MARK, k))
    parts.append("ВЕРДИКТ: подтверждено")
    parts.append("ОБОСНОВАНИЕ: заглушка пробы, движок не звался")
    parts.append("ЧЕМ ПРОВЕРЯЕТСЯ: в текстах")
    parts.append("")

out = json.dumps({"result": "\n".join(parts), "is_error": False, "total_cost_usd": 0.0,
                  "num_turns": 1, "usage": {"output_tokens": 1}}, ensure_ascii=False)
# 🛑 Пишем БАЙТАМИ в UTF-8: инструмент читает вывод движка как UTF-8, а `sys.stdout.write` на
# Windows отдал бы кодировку консоли (cp1251) — метка пунктов доехала бы искажённой, ответ не
# разложился по ключам, и проба краснела бы на исправном коде. Заглушка обязана говорить на том же
# языке, что и настоящий движок.
sys.stdout.buffer.write(out.encode("utf-8"))
