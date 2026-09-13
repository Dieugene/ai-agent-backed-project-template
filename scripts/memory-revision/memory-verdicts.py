#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Вердикты по пунктам списка актуализации: считает МАШИНА, а не роль в свёртке.

Зачем вынесено наружу (решение владельца 01.09, довод оппонента):

  • **вердикт сохраняется файлом.** Позванный из свёртки помощник отдаёт вердикт в контекст роли,
    где тот и умирает при сжатии. Значит ни «доля согласий без правки», ни «доля пойманных
    подсадных» посчитать не из чего — а без этих двух рядов механику нечем остановить, если она
    выродится в обряд;
  • **вердикт можно НЕ пересчитывать.** Он стареет только вместе с записью. На замеренном прогоне
    16 пунктов из 20 были повторами прошлого раза — их вердикты берутся готовыми;
  • **ожидание уходит с дороги роли.** Изнутри свёртки помощник отвечает 1–4 минуты на исходе
    контекста; здесь это время машины, а не роли;
  • **дешевле — но только вместе с кешем.** Замер 01.09 на ЛЁГКОМ пункте: изнутри сессии ~83 500
    токенов, снаружи 16 380 — экономия на постоянной части, которую субагент наследует от сессии
    роли (каскад CLAUDE.md, весь набор инструментов, инструкции MCP). Поэтому запуск идёт из
    ПУСТОГО каталога: любой CLAUDE.md выше по дереву снова притащит каскад и съест выигрыш.
    ⛔ «Снаружи в 5 раз дешевле» как общее правило ОТМЕНЕНО тем же замером: на пунктах из писем
    (открываются письмо и три-четыре записи) вышло 83 016 и 107 287 токенов — столько же, сколько
    изнутри. Экономит не вынос сам по себе, а вынос ВМЕСТЕ с кешем по отпечатку: пересчитываются
    только изменившиеся пункты, на замеренном прогоне это 4 пункта из 20.

Роль после этого не читает вердикты первой: сначала называет свой исход, потом открывает файл
вердиктов и закрывает расхождения. Иначе чужой ответ якорит — соглашаешься, не заметив.

    memory-verdicts.py --list <файл списка> --dir <память> [--jobs 4] [--limit N] [--dry-run]
"""
import argparse
import concurrent.futures as futures
import hashlib
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

ITEM_RE = re.compile(r"^###\s+", re.M)
# 🛑 В пунктах запись называется и так, и так: `имя.md` в разделе возраста и `имя:35` (без
# расширения!) в перечне мест. Регулярка на одно только `.md` не находила НИЧЕГО — отпечаток
# считался по одному тексту пункта, то есть не замечал правок в самих записях (ради чего он и
# заведён) и зато срывался от перестановки мест. Поймано замером окна 01.09.
REC_RE = re.compile(r"`([A-Za-z0-9_\-]+?)(?:\.md)?(?::\d+)?`")
# 🛑 Без обязательных звёздочек: «⚠️ предъявлявшийся ранее, исход был: …» сборщик печатает без
# них, и эта строка доезжала до помощника (нашёл оппонент 06.09; в сборщике то же чинили 04.09).
MARK_RE = re.compile(r"^\s*[🔴⚠️]+\s*(?:\*\*)?(?:предъявлялся|перенесён).*$", re.M)
# 🛑 Только пробелы в строке, не `\s*`: тот съедал перевод строки и читал СЛЕДУЮЩУЮ строку как
# исход — последний пункт списка с пустым исходом получал «исход уже вписан» (мой список 06.09).
OUT_RE = re.compile(r"^- \*\*исход:\*\*[ \t]*(\S.*)$", re.M)
TAIL_STARTS = ("## ", "_итог", "---", "ВСЕГО ПУНКТОВ", "_слабых сигналов", "_снято сегодняшним")


def _memrev():
    import importlib.util
    src = Path(__file__).with_name("memory-revision.py")
    spec = importlib.util.spec_from_file_location("memrev", src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# Признак повторного переноса берём у сборщика: формулировка, живущая в двух местах, разошлась бы молча.
SECOND_CARRY = _memrev().SECOND_CARRY_MARK


def skip_reason(chunk):
    """Почему пункт помощнику не считать: '' — считать.

    🛑 Вердикт нужен роли ДО исхода. Пункт с уже вписанным исходом закрыт — вердикт по нему
    никто не прочтёт. Пункт, перенесённый второй раз подряд, роль решать не стала — вердикт
    ей не помог в первый раз и не поможет во второй, а стоит он столько же (у ассистента
    768 таких пунктов, 5,6 млн токенов за день; поймано владельцем 06.09).
    """
    if OUT_RE.search(chunk):
        return "исход уже вписан"
    if SECOND_CARRY in chunk:
        return "второй перенос подряд"
    return ""


def read(p):
    try:
        return io.open(p, encoding="utf-8", errors="replace").read()
    except Exception:
        return ""


def md5(s):
    return hashlib.md5(s.encode("utf-8", "replace")).hexdigest()


def pid_alive(pid):
    """Жив ли процесс. На Windows — через OpenProcess, а НЕ os.kill(pid, 0): там нулевой сигнал
    зовёт TerminateProcess и убивает того, кого проверяли."""
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    if pid <= 0:
        return False
    if os.name == "nt":
        import ctypes
        k = ctypes.windll.kernel32
        h = k.OpenProcess(0x1000, False, pid)   # PROCESS_QUERY_LIMITED_INFORMATION
        if not h:
            return False
        try:
            code = ctypes.c_ulong()
            ok = k.GetExitCodeProcess(h, ctypes.byref(code))
            return bool(ok) and code.value == 259   # STILL_ACTIVE
        finally:
            k.CloseHandle(h)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def revision_dir(mem):
    """Где лежат список, вердикты и штамп роли: тот же вывод, что у обвязки (memory-audit.ps1):
    `<корень пула>/.revision`, корень пула — на два уровня выше каталога памяти."""
    mem = Path(mem).resolve()
    return mem.parent.parent / ".revision"


def stamp_path(lst_dir, role):
    return Path(lst_dir) / (".verdicts-stamp-%s.json" % role)


def stamp_read(path):
    try:
        d = json.loads(read(path))
        return d if isinstance(d, dict) else {}
    except ValueError:
        return {}


def stamp_write(path, **fields):
    """Штамп состояния расчёта — единственное место, где роль (и закрыватель) узнают, был ли
    помощник. 🛑 Пишется на КАЖДОМ выходе, тихих выходов больше нет: молча пропущенный расчёт
    выглядел как «помощник посмотрел, сказать нечего» (ведущий 06.09, лид product 06.09)."""
    path = Path(path)
    cur = stamp_read(path)
    cur.update(fields)
    cur.setdefault("started", time.strftime("%Y-%m-%d %H:%M:%S"))
    if fields.get("status") in ("done", "skipped", "failed"):
        cur["finished"] = time.strftime("%Y-%m-%d %H:%M:%S")
    # 🛑 Отказ и пропуск запоминаются ОТДЕЛЬНОЙ меткой, а не только в `reason`: `reason` перепишет
    # следующий же прогон. Поймано 11.09 на роли `qa-div`: её расчёт отказал по входу, пересчёт
    # ничего не нашёл считать («все пункты с исходом») и записал `done, считать нечего` — причина,
    # которую роль обязана назвать владельцу, исчезла и из штампа, и из отчёта. Отказ стал
    # выглядеть работой задним числом. Метка снимается не стиранием, а появлением НОВОЙ удачи.
    if fields.get("status") in ("skipped", "failed"):
        cur["last_fail"] = {"at": cur["finished"],
                            "reason": fields.get("reason") or cur.get("reason") or ""}
    tmp = path.with_suffix(".tmp")
    io.open(tmp, "w", encoding="utf-8", newline="\n").write(json.dumps(cur, ensure_ascii=False, indent=1))
    os.replace(str(tmp), str(path))
    return cur


def stamp_state(st):
    """Состояние по штампу для читателей: running с мёртвым pid — это failed."""
    status = st.get("status", "")
    if status == "running" and not pid_alive(st.get("pid")):
        return "failed", "процесс расчёта исчез (pid %s), штамп не закрыт" % st.get("pid")
    return status, st.get("reason", "")


def uncovered_failure(st):
    """Отказ, НЕ закрытый удачным расчётом: фраза для роли или пустая строка.

    🛑 Признак ПОЛОЖИТЕЛЬНЫЙ — считается от метки последней удачи (`last_ok`), а не от того,
    похож ли прежний штамп на отказ. Обвязка пишет штамп ДО запуска расчёта
    (`memory-audit.ps1`: `status=running, pid=0`), и `stamp_state` честно читает такую запись как
    `failed`; признак «прежний штамп failed» давал бы ложную тревогу на КАЖДОЙ свёртке у каждой
    роли — ровно то, что владелец запретил ([[feedback_no-false-alarms]]).

    Второе следствие того же выбора: пропуск по памяти, таймаут и потерянные ответы тоже остаются
    видимыми — вердиктов они не дали, значит удачи не было, значит признак горит.

    Зовут его ТРОЕ: отчёт роли, команда ожидания и закрыватель. Одна функция на всех — иначе
    каналы расходятся, и расхождение ловится не устройством, а дисциплиной.
    """
    f = st.get("last_fail") or {}
    at = f.get("at") or ""
    if not at:
        return ""
    ok = st.get("last_ok") or ""
    if ok and ok >= at:          # обе метки — «ГГГГ-ММ-ДД ЧЧ:ММ:СС», сравнение строк законно
        return ""
    return ("расчёт %s вердиктов НЕ дал (%s), а удачного с тех пор не было"
            % (at, f.get("reason") or "причина не записана"))


def load_item_key():
    """Ключ пункта берём из самого сборщика, а не переписываем: правило, живущее в двух местах,
    расходится молча. Имя файла с дефисом обычным импортом не берётся."""
    import importlib.util
    src = Path(__file__).with_name("memory-revision.py")
    spec = importlib.util.spec_from_file_location("memrev", src)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.item_key


def parse_items(list_path):
    """Разобрать список на пункты: ключ, заголовок, блок целиком."""
    item_key = load_item_key()
    text = read(list_path)
    out = []
    for chunk in ITEM_RE.split(text)[1:]:
        # Блок пункта — до первой служебной строки (итог раздела, следующий раздел, слабые
        # сигналы): иначе последний пункт тащит в задание весь хвост списка.
        kept = []
        for ln in chunk.splitlines():
            if kept and ln.startswith(TAIL_STARTS):
                break
            kept.append(ln)
        chunk = "\n".join(kept)
        head = chunk.splitlines()[0].strip()
        m = re.match(r"(~\s*)?П\d+\.\s*(.+)$", head)
        title = (m.group(2) if m else head).strip()
        key = item_key(title, chunk)
        skip = skip_reason(chunk)
        block = "### " + chunk.rstrip()
        # 🛑 Строку «предъявлялся ранее, исход был…» помощнику не показываем: она якорит его на
        # прошлом вердикте, а нужен свежий взгляд. Роли в её списке она остаётся.
        block = MARK_RE.sub("", block)
        out.append({"key": key, "title": title, "block": block, "skip": skip})
    return out


def select_todo(items, cache, mem):
    """Кого считать: не из кеша, не закрытые, не перенесённые второй раз."""
    todo, kept, skipped = [], 0, {}
    for it in items:
        if it.get("skip"):
            skipped[it["skip"]] = skipped.get(it["skip"], 0) + 1
            continue
        it["fp"] = fingerprint(it, mem)
        old = cache.get(it["key"])
        if old and old.get("fp") == it["fp"] and old.get("verdict"):
            kept += 1
        else:
            todo.append(it)
    return todo, kept, skipped


def fingerprint(item, mem):
    """Отпечаток = сам пункт + содержимое КАЖДОЙ записи, которую он называет.

    Правка любой из них делает старый вердикт недействительным; всё остальное — нет.
    """
    # Отпечаток строим из того, от чего вердикт РЕАЛЬНО зависит: кто пункт (ключ) и что написано
    # в записях, о которых он говорит. Текст самого пункта в отпечаток не берём: там живут номер,
    # число суток, пометки о прошлых предъявлениях и порядок найденных мест — всё это меняется
    # само собой и вердикта не отменяет.
    parts = [item["key"]]
    names = set()
    for raw in REC_RE.findall(item["block"]):
        p = Path(mem) / (raw if raw.endswith(".md") else raw + ".md")
        if p.is_file():
            names.add(p.name)
    for name in sorted(names):
        parts.append(name + ":" + md5(read(Path(mem) / name)))
    if not names:
        # Пункт ни на одну запись не ссылается (бывает у внешних) — тогда держимся за его текст,
        # очищенный от переменной части.
        parts.append(md5(re.sub(r"^###\s+~?\s*П\d+\.", "###", item["block"])))
    return md5("\n".join(parts))


def claude_exe():
    """Полный путь к движку.

    🛑 На Windows `claude` в PATH — это shell-скрипт без расширения; `subprocess` без оболочки его
    не находит и падает «не удаётся найти указанный файл». Берём `claude.cmd`, а на Linux — просто
    первый найденный, включая `~/.local/bin`, который в неинтерактивном ssh в PATH не попадает.
    """
    import shutil
    for name in (["claude.cmd", "claude"] if os.name == "nt" else ["claude"]):
        p = shutil.which(name)
        if p:
            return p
    local = Path.home() / ".local" / "bin" / "claude"
    return str(local) if local.exists() else "claude"


# Разбор строки токена. 🛑 Правило живёт в ДВУХ местах поневоле: у запускателя на PowerShell
# (`pool-bus/pool-account.ps1`, `Read-AccountToken`) и здесь. Расходиться им нельзя — счёт идёт
# на деньги владельца, — поэтому случаи сверяются пробой с самотестом запускателя
# (`probe-verdicts-token.py`), а не пересказом: BOM, ПОСЛЕДНЕЕ присваивание, парные кавычки,
# пустое значение и подстановка.
TOKEN_LINE_RE = re.compile(r"(?m)^[ \t]*(?:export[ \t]+)?CLAUDE_CODE_OAUTH_TOKEN[ \t]*=(.*)$")


def account_tokens_dir():
    """Хранилище токенов аккаунтов. `POOL_TOKENS_DIR` переопределяет — им живут самотесты."""
    d = os.environ.get("POOL_TOKENS_DIR")
    if d:
        return Path(d)
    base = os.environ.get("USERPROFILE") or os.environ.get("HOME") or str(Path.home())
    return Path(base) / ".config" / "agents" / "tokens"


def account_names():
    """Заведённые аккаунты — файлы `<имя>.env` в хранилище. Значения не читаются."""
    try:
        return sorted(p.name[:-4] for p in account_tokens_dir().glob("*.env") if p.is_file())
    except OSError:
        return []


def show_account(name):
    """Имя в сообщении об отказе — вместе с кодами знаков: невидимый ведущий знак консоль рисует
    пробелом, и отказ читается как «лишний пробел». У запускателя это стоило двух ложных следов."""
    return "«%s» (коды: %s)" % (name, " ".join("%04X" % ord(c) for c in name))


def read_token_file(path):
    """(значение, причина отказа) — тем же разбором, что у запускателя.

    ⚠️ Берётся ПОСЛЕДНЕЕ присваивание: так же поступает запускатель, и роль с помощником иначе
    уехали бы на разные токены из одного файла. Пустое значение и значение с подстановкой —
    отказ, а не «тихо пусто»: у запускателя на оба есть именные проверки в самотесте.
    """
    try:
        raw = io.open(str(path), encoding="utf-8", errors="replace").read()
    except OSError as e:
        return "", "файл токена не читается (%s): %s" % (e.__class__.__name__, path)
    raw = raw.lstrip(u"\ufeff")  # BOM иначе прилипнет к имени переменной, и совпадения не будет
    found = TOKEN_LINE_RE.findall(raw)
    if not found:
        return "", "в файле нет CLAUDE_CODE_OAUTH_TOKEN: %s" % path
    v = found[-1].strip()
    if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
        v = v[1:-1]
    v = v.strip()
    if not v:
        return "", "значение токена пусто: %s" % path
    if re.search(r"[$`]", v):
        return "", "в значении есть подстановка, разбирать не берусь: %s" % path
    return v, ""


def engine_token():
    """Вход движка для безголового вызова — ТОТ ЖЕ токен, что назначен пулу, на который работает роль.

    🛑 Оплачено боевым (сервер): роли живут под `CLAUDE_CODE_OAUTH_TOKEN`, а расчёт вердиктов звал
    движок без этой переменной — и получал «Not logged in» при нулевом расходе. Механика не
    отработала на сервере ни разу с выката, хотя локально была зелёной.

    🛑 Оплачено боевым (локально, 11.09): **движок НЕ отдаёт свой токен дочерним процессам.**
    Запускатель ставит рядом две переменные — `POOL_ACCOUNT` и токен аккаунта, — но до инструментов
    роли доезжает только первая (проверено в живой сессии). Значит расчёт ехал на интерактивном
    логине и падал вместе с ним: «OAuth session expired and could not be refreshed» (роль
    `dev-div`; накануне тот же расчёт прошёл — логин был ещё жив, и разницы не было видно).

    🛑 **Назначение пула сильнее унаследованной переменной.** Запускатель первым делом
    РАЗМИНИРУЕТ `CLAUDE_CODE_OAUTH_TOKEN` («иначе тихо уводит роль на чужой аккаунт мимо всего
    назначения»), и здесь тот же порядок: назван аккаунт — берём его токен, а переменную не
    смотрим вовсе. Иначе назначение пикером ничего не решало бы.

    🛑 **Молчаливый откат на ЧУЖОЙ токен запрещён.** Аккаунт назначен, а его токен не прочитан —
    возвращаем пусто (движок войдёт сам) и называем причину; уходить на общий файл окружения
    нельзя: на сервере там лежит токен другого аккаунта, и расчёт молча пошёл бы с чужого счёта.
    Серверная обёртка на том же входе роль вовсе не поднимает.

    Порядок: аккаунт пула → (если не назначен) переменная → общий файл окружения → пусто.
    Возвращает (значение, откуда); при пустом значении второй элемент — ПРИЧИНА, а не источник.
    ⚠️ Значение НИКОГДА не печатается и не уходит в argv — только в окружение дочернего процесса.
    """
    # ⚠️ Снимаем ТОЛЬКО транспортный мусор (метку порядка байтов, перевод строки), но НЕ
    # пробелы: запускатель имя с пробелом отвергает, и подрезать его здесь значило бы завести
    # третье поведение — роль ушла бы на логин, а помощник на токен пула.
    acc = (os.environ.get("POOL_ACCOUNT") or "").strip(u"\ufeff\r\n")
    if acc:
        # ⚠️ Имя — ЧАСТЬ ПУТИ, поэтому оно не проверяется шаблоном, а СВЕРЯЕТСЯ С ЗАВЕДЁННЫМИ:
        # тогда ни `..`, ни имена устройств Windows в путь не попадут вовсе. `CON` прошёл бы
        # белый список и повесил фоновый расчёт внутри общего замка машины — встали бы свёртки
        # всех ролей, и каждая показывала бы «считается».
        if acc in account_names():
            v, why = read_token_file(account_tokens_dir() / (acc + ".env"))
            if v:
                return v, "аккаунта пула «%s»" % acc
            return "", "аккаунт пула назначен, но токен не прочитан — %s" % why
        return "", ("аккаунт пула %s не заведён в хранилище %s"
                    % (show_account(acc), account_tokens_dir()))
    t = (os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") or "").strip()
    if t:
        return t, "окружения"
    path = os.environ.get("SHOP_AGENT_ENV") or str(Path.home() / ".config" / "agents" / "env")
    v, why = read_token_file(path)
    if v:
        return v, path
    return "", "аккаунт пулу не назначен, переменной нет, %s" % why


# 🛑 РАЗОВАЯ МОДЕЛЬ (слово владельца 06.09: помощник работает «разово на каком-то объёме
# материала»). Раньше в задание клался СРЕЗ записи (3000 знаков или 12 строк вокруг места), а
# инструкция велела «открыть запись целиком инструментом Read» — то есть срез был дублем, а
# помощник дочитывал файлы ходами, и каждый ход оплачивал весь накопленный разговор: пакет
# летописца pool-A 06.09 — 16 пунктов, 67 ходов, 9,3 млн токенов перечитывания за один вызов.
# Теперь всё, что нужно, лежит в задании ОДИН раз и целиком: каждая названная запись, каждое
# письмо-источник. Инструментов у помощника нет — один ход, цена = размер задания единожды.
REC_NAME_RE = re.compile(r"`([A-Za-z0-9_\-]+?)(?:\.md)?(?::\d+)?`")
SRC_RE = re.compile(r"источник целиком: `([^`]+)`")
_READ_CACHE = {}


def _read_cached(p):
    key = str(p)
    if key not in _READ_CACHE:
        try:
            _READ_CACHE[key] = io.open(key, encoding="utf-8", errors="replace").read()
        except OSError:
            _READ_CACHE[key] = ""
    return _READ_CACHE[key]


def records_for(group, mem):
    """{имя файла: текст} — каждая запись, названная хотя бы в одном пункте, ОДИН раз, целиком."""
    out = {}
    for it in group:
        for m in REC_NAME_RE.finditer(it["block"]):
            name = m.group(1)
            fname = name if name.endswith(".md") else name + ".md"
            if fname in out:
                continue
            p = Path(mem) / fname
            if p.is_file():
                text = _read_cached(p)
                if text:
                    out[fname] = text
    return out


def sources_for(group):
    """{путь: текст} писем шины (.md) — целиком, один раз.

    🛑 Записи ленты моста (.jsonl) НЕ даются: сырой чат помощнику нельзя (граница доверия, слово
    architect pool-A 03.09). Выдержка сообщения уже стоит в самом пункте — её и хватает.
    """
    out = {}
    for it in group:
        for m in SRC_RE.finditer(it["block"]):
            p = Path(m.group(1))
            if p.suffix != ".md" or str(p) in out or not p.is_file():
                continue
            text = _read_cached(p)
            if text:
                out[str(p)] = text
    return out


def numbered(text):
    """Строки с номерами: цитата в ответе называет `файл:строка`, и сверка идёт по этим номерам."""
    return "\n".join("%5d| %s" % (i + 1, ln) for i, ln in enumerate(text.splitlines()))


def build_prompt(group, mem):
    """Задание пакета: пункты, затем записи памяти (каждая один раз, целиком, с номерами строк),
    затем письма-источники. Возвращает (текст, записи, письма)."""
    recs = records_for(group, mem)
    srcs = sources_for(group)
    L = [(
        "Тебе дают пункты списка актуализации одной роли — они пришли за один отрезок её работы и\n"
        "связаны между собой: одно письмо может отменять другое, а третье закрывать вопрос из\n"
        "второго. Смотри их вместе, а не по отдельности.\n\n"
        "🛑 ВСЁ, ЧТО ТЕБЕ НУЖНО, ЛЕЖИТ НИЖЕ: записи памяти целиком с номерами строк и письма-источники\n"
        "целиком. Инструментов у тебя нет, на диск идти некуда — цитируй по данному тексту.\n\n"
        "🛑 ОТВЕТ — ПЕРЕЧНЕМ. По каждому пункту начинай блок строкой «%s <ключ пункта>» и дальше\n"
        "отвечай по формату (ВЕРДИКТ, ПРОЧИТАНО, ЦИТАТЫ, ОБОСНОВАНИЕ, ЧЕМ ПРОВЕРЯЕТСЯ, РОЛИ ДЕЛАТЬ,\n"
        "УВЕРЕННОСТЬ). Пропускать пункты нельзя: пункт без блока будет считаться несделанным.\n\n"
        "Каталог памяти роли: %s\n" % (KEY_MARK, mem)), "## ПУНКТЫ\n"]
    for it in group:
        L.append("%s %s\n\n%s\n" % (KEY_MARK, it["key"], it["block"]))
    L.append("## ЗАПИСИ ПАМЯТИ — целиком, с номерами строк (это всё, что есть)\n")
    for name, text in recs.items():
        L.append("### Запись `%s` (%d строк)\n\n%s\n" % (name, len(text.splitlines()), numbered(text)))
    if srcs:
        L.append("## ПИСЬМА-ИСТОЧНИКИ — целиком\n")
        for path, text in srcs.items():
            L.append("### Письмо `%s`\n\n%s\n" % (Path(path).name, text))
    return "\n".join(L), recs, srcs


def ask(item, mem, workdir, timeout=300, token=""):
    """Один пункт — тот же путь, что и пакет: устройство одно."""
    return ask_batch([item], mem, workdir, timeout=timeout, token=token)[item["key"]]


# Переменные, по которым Stop-хуки узнают роль пула. Дочернему движку они не нужны и вредны
# (см. оговорку в call_engine). Список короткий намеренно: гасим ровно то, на чём гейтятся хуки,
# а не всё подряд — движку нужны и HOME, и PATH, и вход по токену.
POOL_ROLE_VARS = ("POOL_WATCHER", "AGENT_OWNER", "POOL_BUS_ROOT")
NO_TOOLS = ("Read", "Grep", "Glob", "Bash", "Edit", "Write", "MultiEdit", "NotebookEdit",
            "WebFetch", "WebSearch", "Agent", "Task")


def engine_project_dir(workdir):
    """Каталог, который движок заводит под стенограммы вызовов из `workdir`: путь с заменой всего,
    кроме букв и цифр, на дефис (`/tmp/verdicts-x` -> `-tmp-verdicts-x`)."""
    slug = re.sub(r"[^A-Za-z0-9]", "-", str(Path(workdir).resolve()))
    return Path.home() / ".claude" / "projects" / slug


def cleanup_engine_project(workdir):
    """Убрать стенограммы помощника: на сервере их накопилось 74 каталога на 249 МБ (06.09).
    Удаляем только каталог, где нет ничего, кроме стенограмм."""
    p = engine_project_dir(workdir)
    try:
        if p.is_dir() and all(f.suffix == ".jsonl" or f.is_dir() for f in p.iterdir()):
            shutil.rmtree(str(p), ignore_errors=True)
    except OSError:
        pass


def call_engine(prompt, dirs, workdir, timeout=300, token=""):
    """Один вызов движка. Общий для поштучного и пакетного разбора — оговорки внутри
    касаются обоих, и держать их в двух копиях нельзя."""
    cmd = [claude_exe(), "-p", "--agent", "memory-verdict", "--output-format", "json"]
    # 🛑 Инструментов помощнику НЕ даём: всё, что нужно, лежит в задании. С инструментами он
    # дочитывал файлы ходами, и каждый ход оплачивал весь разговор (см. RECORDS выше).
    cmd += ["--disallowedTools"] + list(NO_TOOLS)
    for d in dirs:
        cmd += ["--add-dir", d]
    env = os.environ.copy()
    # 🛑 Переменные роли дочернему движку НЕ отдаём. С ними Stop-хуки принимают помощника за саму
    # роль и требуют от него взвести вотчер шины, чего он сделать не может: ход уходит в спор с
    # хуком, пакетный ответ теряется и пункты считаются заново поштучно. Хуже расхода — помощник
    # пишет в состояние чужой роли (снимает ей арм-гейт, кладёт ноту в ящик, сбивает офсет
    # детектора). Оба хука сами себя выключают без этих переменных, поэтому лечение здесь:
    # ничего не отключаем в настройках, просто не представляемся ролью.
    for var in POOL_ROLE_VARS:
        env.pop(var, None)
    if token:
        env["CLAUDE_CODE_OAUTH_TOKEN"] = token
    t0 = time.time()
    try:
        r = subprocess.run(cmd, cwd=workdir, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout,
                           input=prompt, env=env)
    except subprocess.TimeoutExpired:
        return {"error": "таймаут %d с" % timeout, "seconds": timeout}
    out = r.stdout or ""
    i = out.find("{")
    if i < 0:
        return {"error": "ответ не разобран: %s" % (out[:200] or r.stderr[:200]), "seconds": time.time() - t0}
    try:
        d = json.loads(out[i:])
    except ValueError as e:
        return {"error": "json: %s" % e, "seconds": time.time() - t0}
    # 🛑 Отказ движка приходит НЕ ошибкой процесса, а обычным ответом: код возврата 0,
    # `subtype: success`, а внутри `is_error: true`, `terminal_reason: api_error` и
    # `result: "Not logged in · Please run /login"` при нулевом расходе. Без этой проверки текст
    # отказа ложился в кеш КАК ВЕРДИКТ и больше не пересчитывался — отпечаток-то не менялся.
    # Оплачено боевым: на сервере механика не отработала ни разу с выката, 206 пунктов у семи
    # ролей, и роли получали файл, выглядевший заполненным. Отказ выглядел как работа.
    res_text = d.get("result", "") or ""
    if d.get("is_error") or d.get("terminal_reason") == "api_error":
        kind = "auth" if re.search(r"not logged in|please run /login|invalid api key|/login",
                                   res_text, re.I) else "api"
        return {"error": "движок отказал (%s): %s" % (d.get("terminal_reason") or "is_error",
                                                      res_text[:160]),
                "fatal": kind, "seconds": round(time.time() - t0, 1)}
    u = d.get("usage", {})
    return {
        "verdict": res_text,
        "cost": d.get("total_cost_usd", 0.0),
        "tokens": (u.get("cache_creation_input_tokens", 0) + u.get("cache_read_input_tokens", 0)
                   + u.get("output_tokens", 0)),
        # Число ходов помощника — по разбору architect (03.09): «токены» здесь включают
        # `cache_read`, то есть ПЕРЕЧИТЫВАНИЕ одного контекста на каждом ходу, и потому растут
        # со временем работы, а не с объёмом прочитанного. Его улика: два пункта дали 4226 и
        # 4277 токенов в секунду — совпадение с точностью 1,2 %. ⇒ разброс цены (140–490 тыс.
        # на сервере против 83–107 тыс. локально) объясняется, скорее всего, числом ходов, а не
        # средой. Кладём поле в кеш, чтобы это можно было проверить сравнением, а не спором.
        # ⚠️ Честная мера расхода тут доллары, а не токены: у architect вышло ~$0,35 на пункт.
        "turns": d.get("num_turns", 0),
        "seconds": round(time.time() - t0, 1),
    }


# Предел ЗАДАНИЯ в знаках — от окна модели, а не от числа пунктов: окно помощника около 200 тыс.
# токенов, заданию отдаём половину (~100 тыс. токенов ≈ 400 тыс. знаков), остальное — ответ и
# запас. Задание считается целиком: пункты + записи (каждая один раз) + письма.
BATCH_CHARS = 400000
KEY_MARK = "ПУНКТ-КЛЮЧ:"


def batches(items, mem=None):
    """Разбить пункты на пакеты по размеру задания. Без `mem` (пробы) — по размеру блоков."""
    def size_of(group):
        if mem:
            return len(build_prompt(group, mem)[0])
        return sum(len(x["block"]) for x in group)
    group = []
    for it in items:
        if group and size_of(group + [it]) > BATCH_CHARS:
            yield group
            group = [it]
        else:
            group.append(it)
    if group:
        yield group


def split_answer(text):
    """Разложить ответ пакета по ключам пунктов."""
    out = {}
    cur = None
    buf = []
    for line in (text or "").splitlines():
        if line.strip().startswith(KEY_MARK):
            if cur:
                out[cur] = "\n".join(buf).strip()
            cur = line.split(KEY_MARK, 1)[1].strip().strip("`")
            buf = []
            continue
        if cur:
            buf.append(line)
    if cur:
        out[cur] = "\n".join(buf).strip()
    return out


def ask_batch(group, mem, workdir, timeout=900, token=""):
    """Один вызов на пакет: одно задание, один ход. Возвращает {ключ: результат}."""
    prompt, _, _ = build_prompt(group, mem)
    res = call_engine(prompt, [], workdir, timeout=timeout, token=token)
    if res.get("error"):
        return dict((it["key"], dict(res)) for it in group)

    parts = split_answer(res.get("verdict", ""))
    out = {}
    share = max(1, len(group))
    for it in group:
        text = parts.get(it["key"], "")
        if not text:
            out[it["key"]] = {"missing": True}
            continue
        # Расход пакета делится между пунктами поровну — и токены, и секунды, и стоимость:
        # раньше секунды приписывались каждому пункту целиком, и «часы» в сводках врали.
        out[it["key"]] = {"verdict": text,
                          "tokens": res.get("tokens", 0) // share,
                          "turns": res.get("turns", 0),
                          "seconds": round(float(res.get("seconds", 0.0)) / share, 1),
                          "cost": float(res.get("cost", 0.0)) / share}
    return out


def verdict_line(text, field):
    m = re.search(r"^%s:\s*(.+)$" % field, text, re.M)
    return m.group(1).strip() if m else ""


# Цена одного вызова движка, замер 04.09 на сервере цеха: 239–247 МиБ RSS на процесс.
CALL_MIB = 245
# Запас, который оставляем машине: ниже него не начинаем вовсе.
RESERVE_MIB = 400


def mem_available_mib():
    """Сколько памяти реально доступно. Нет /proc/meminfo (не Linux) — считаем, что вдоволь."""
    try:
        for line in io.open("/proc/meminfo", encoding="utf-8"):
            if line.startswith("MemAvailable:"):
                return int(line.split()[1]) // 1024
    except (OSError, ValueError, IndexError):
        pass
    return 10 ** 6


def jobs_by_memory(asked):
    """Столько потоков, сколько влезает по памяти. 0 — не начинать вовсе."""
    free = mem_available_mib()
    room = (free - RESERVE_MIB) // CALL_MIB
    if room < 1:
        return 0, free
    return max(1, min(asked, room)), free


MACHINE_LOCK = "memory-verdicts.machine.lock"


def machine_lock_path():
    return Path(tempfile.gettempdir()) / MACHINE_LOCK


def _try_lock(path):
    """Взять замок атомарно: файл с pid создаётся рядом и ПРИВЯЗЫВАЕТСЯ жёсткой ссылкой — ссылка
    на занятое имя не встаёт, а содержимое замка полно с первой же миллисекунды (у «создал каталог,
    потом записал pid» есть окно, где замок есть, а pid в нём нет)."""
    tmp = path.with_name("%s.%d.tmp" % (path.name, os.getpid()))
    try:
        io.open(tmp, "w", encoding="utf-8").write(str(os.getpid()))
        try:
            os.link(str(tmp), str(path))
            return True
        except FileExistsError:
            return False
        except OSError:
            # Нет жёстких ссылок — запасной путь: эксклюзивное создание + запись.
            try:
                fd = os.open(str(path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except FileExistsError:
                return False
            with os.fdopen(fd, "w", encoding="utf-8") as f:
                f.write(str(os.getpid()))
            return True
    finally:
        try:
            os.unlink(str(tmp))
        except OSError:
            pass


def take_machine_lock(wait=True, on_wait=None, poll_s=3.0):
    """Общий замок на машину: расчёт вердиктов идёт по одному.

    🛑 Замок по роли не спасает: две роли, свернувшиеся одновременно, дают два прохода.
    🛑 Занят живым процессом — ЖДЁМ очереди (слово владельца 07.09: «если я сворачиваю сразу
    несколько агентов… отработает только один? Какое-то странное решение»). Пропуск был тихим:
    свёртка ведущего 06.09 прошла без помощника, и никто этого не увидел.
    Держателя судим по pid, а не по возрасту: возраст при опросе превращался бы в кражу замка
    каскадом (ждущий сносит живой замок долгого прохода, потом его самого сносит первый).
    """
    path = machine_lock_path()
    said = False
    while True:
        if _try_lock(path):
            return path
        holder = read(path).strip()
        if not pid_alive(holder):
            try:
                os.unlink(str(path))
            except OSError:
                pass
            continue
        if not wait:
            return None
        if on_wait and not said:
            on_wait(holder)
            said = True
        time.sleep(poll_s)


def release_machine_lock(path):
    """Снять ТОЛЬКО свой замок: чужой (уже перехваченный после нашей смерти) не трогать."""
    try:
        if read(path).strip() == str(os.getpid()):
            os.unlink(str(path))
    except OSError:
        pass


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", help="файл списка актуализации (не нужен при --wait/--status)")
    ap.add_argument("--dir", required=True, help="каталог памяти роли")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--limit", type=int, default=0, help="0 — все пункты списка")
    ap.add_argument("--dry-run", action="store_true", help="только сказать, что пересчиталось бы")
    ap.add_argument("--lock", help="каталог-замок: снять его, когда проход закончен")
    ap.add_argument("--wait", action="store_true",
                    help="роль на шаге «вердикт открывать вторым»: дождаться расчёта и напечатать вердикты")
    ap.add_argument("--status", action="store_true", help="одной строкой: в каком состоянии расчёт")
    args = ap.parse_args()
    if args.wait or args.status:
        return wait_for(Path(args.dir), block=args.wait)
    if not args.list:
        ap.error("--list обязателен для расчёта")
    try:
        return run(args)
    finally:
        # 🛑 Замок снимает тот, кто работу закончил. Обвязка ставит его перед запуском и ждать
        # фоновый проход не может; без этой строки замок держался бы до протухания по времени,
        # и следующая свёртка расчёта не запустила бы вовсе.
        if args.lock:
            import shutil
            shutil.rmtree(args.lock, ignore_errors=True)


def run(args):
    lst = Path(args.list)
    mem = Path(args.dir).resolve()
    stamp = stamp_path(lst.parent, mem.name)
    if not args.dry_run:
        stamp_write(stamp, role=mem.name, list=str(lst), pid=os.getpid(), status="running",
                    phase="старт", reason="")

    def waiting(holder):
        print("ВЕРДИКТЫ: на машине считается другая роль (pid %s) — жду очереди." % holder)
        if not args.dry_run:
            stamp_write(stamp, phase="очередь за pid %s" % holder)

    machine_lock = take_machine_lock(wait=True, on_wait=waiting)
    if not args.dry_run:
        stamp_write(stamp, phase="расчёт")
    try:
        return _run(args, stamp if not args.dry_run else None)
    except Exception as e:  # noqa: BLE001 — любой отказ обязан дойти до штампа, иначе он тихий
        if not args.dry_run:
            stamp_write(stamp, status="failed", reason="исключение: %s: %s" % (type(e).__name__, e))
        raise
    finally:
        release_machine_lock(machine_lock)


def wait_for(mem, block, out=None):
    """Шаг канона «вердикт открывать вторым». Отвечает по штампу: готово — печатает вердикты;
    считается живым процессом — ждёт (событие, не порог; предел даёт таймаут инструмента роли);
    штампа нет / не считался — причина и «разбирай сам», код не ноль. Ничего не запускает:
    третьей точки запуска нет, запуск — `pool handoff` в начале свёртки."""
    out = out or sys.stdout

    def say(*a):
        print(*a, file=out)

    mem = Path(mem).resolve()
    rd = revision_dir(mem)
    st_path = stamp_path(rd, mem.name)
    out_path = rd / ("verdicts-%s.md" % mem.name)
    said = False
    while True:
        st = stamp_read(st_path)
        if not st:
            say("ВЕРДИКТЫ: расчёт в эту свёртку не запускался (штампа %s нет) — "
                  "первым шагом свёртки идёт `pool handoff`; разбирай пункты сам и скажи это в отчёте."
                  % st_path.name)
            return 5
        state, reason = stamp_state(st)
        if state == "running":
            if not block:
                say("ВЕРДИКТЫ: считается с %s (%s), pid %s" % (st.get("started"), st.get("phase"), st.get("pid")))
                return 1
            if not said:
                say("ВЕРДИКТЫ: считается с %s (%s) — жду готовности…" % (st.get("started"), st.get("phase")))
                said = True
            time.sleep(2)
            continue
        if state == "done":
            say("ВЕРДИКТЫ: готовы (%s; посчитано %s, из кеша %s, не считалось %s; список %s)"
                  % (st.get("finished"), st.get("computed"), st.get("kept"),
                     sum((st.get("skipped") or {}).values()) if isinstance(st.get("skipped"), dict) else "?",
                     st.get("list")))
            u = uncovered_failure(st)
            if u:
                say("⚠️ НО %s — скажи это в отчёте владельцу." % u)
            if not block:
                return 0
            say("список мог пополниться подсадной — перечитай его, если читал до готовности.")
            say("=" * 60)
            out.write(read(out_path) or "(файла вердиктов нет: %s)\n" % out_path)
            return 0
        say("ВЕРДИКТЫ: не считались — %s (%s). Разбирай пункты сам и скажи это в отчёте: "
              "молча пропущенный ход выглядит выполненным." % (reason or state, st.get("finished") or st.get("started")))
        return 4


def _run(args, stamp=None):

    lst = Path(args.list)
    mem = Path(args.dir).resolve()
    role = mem.name

    def note(**fields):
        if stamp:
            stamp_write(stamp, **fields)

    if not lst.is_file():
        print("нет списка: %s" % lst)
        note(status="failed", reason="нет списка %s" % lst)
        return 2

    cache_path = lst.parent / ("verdicts-%s.json" % role)
    out_path = lst.parent / ("verdicts-%s.md" % role)
    try:
        cache = json.loads(read(cache_path)) if cache_path.exists() else {}
    except ValueError:
        cache = {}

    items = parse_items(lst)
    if args.limit:
        items = items[:args.limit]

    todo, kept, skipped = select_todo(items, cache, mem)

    print("пунктов: %d; из кеша: %d; считать: %d%s"
          % (len(items), kept, len(todo),
             ("; не считаю: " + ", ".join("%s — %d" % kv for kv in sorted(skipped.items())))
             if skipped else ""))
    note(items=len(items), kept=kept, skipped=skipped, computed=0)
    # Читаем штамп ПО ПУТИ, а не через переданный хэндл: в `--dry-run` хэндла нет, а отчёт в ветке
    # «считать нечего» всё равно пишется — иначе отчёт и `--status` разошлись бы между собой.
    warn = uncovered_failure(stamp_read(stamp_path(lst.parent, mem.name)))
    if args.dry_run or not todo:
        if not todo:
            write_report(items, cache, out_path, role, warn=warn)
            note(status="done", reason="считать нечего: все пункты из кеша или с исходом")
        return 0

    workdir = tempfile.mkdtemp(prefix="verdicts-")
    done = 0
    # ⚠️ `done` считает ОБРАБОТАННЫЕ пункты — он растёт и на ошибке, и на потерянном ответе
    # (инкремент стоит первой строкой `absorb`). Метку удачи ставим по `landed` — по числу
    # вердиктов, реально легших в кеш, иначе таймаут снимал бы предупреждение об отказе.
    landed = 0
    fatal = ""
    token, token_why = engine_token()
    # 🛑 След обязателен: печать уходит в скрытую консоль фонового процесса и её не видит никто,
    # поэтому источник кладём в ШТАМП — его читают `--status` и отчёт. Без этого на вопрос «каким
    # токеном посчитано» ответить нечем, а он и есть предмет назначения аккаунта пулу.
    token_src = ("из %s" % token_why if token
                 else ("вход движку не найден: %s" % token_why if token_why
                       else "вход берёт сам движок: источников нет"))
    print("вход движка: %s" % token_src)
    note(engine_entry=token_src)
    jobs, free_mib = jobs_by_memory(args.jobs)
    if jobs == 0:
        print("ВЕРДИКТЫ: не начинаю — свободной памяти %d МиБ, это меньше запаса %d МиБ."
              % (free_mib, RESERVE_MIB))
        # 🛑 Файл вердиктов тоже перезаписать: иначе роль прочтёт прошлый как свежий.
        write_report(items, cache, out_path, role, "на машине мало памяти (%d МиБ свободно)" % free_mib,
                     warn=warn)
        note(status="skipped", reason="мало памяти: свободно %d МиБ, запас %d" % (free_mib, RESERVE_MIB))
        return 0
    if jobs < args.jobs:
        print("ВЕРДИКТЫ: потоков %d вместо %d — свободно %d МиБ, вызов стоит ~%d МиБ."
              % (jobs, args.jobs, free_mib, CALL_MIB))
    # 🛑 Считаем ПАКЕТАМИ: постоянная часть контекста помощника (41 тыс. токенов по замеру 04.09)
    # платится раз на группу, а не раз на пункт. И, что важнее денег, помощник видит пункты одного
    # отрезка вместе — иначе он не заметит, что одно письмо отменяет другое. Слово владельца 04.09.
    groups = list(batches(todo, mem))
    print("пакетов: %d (пунктов в них: %s)" % (len(groups), ", ".join(str(len(g)) for g in groups)))

    def absorb(it, res):
        """Разложить результат по пункту: в кеш, в счётчик, в вывод."""
        nonlocal done, fatal, landed
        done += 1
        if res.get("missing"):
            return False
        if res.get("error"):
            print("  [%d/%d] %s — ОШИБКА: %s" % (done, len(todo), it["key"], res["error"]))
            # 🛑 Отказ движка одинаков для всех пунктов: гнать остальные вызовы бессмысленно
            # и небесплатно. Останавливаемся на первом и говорим об этом вслух — молчаливо
            # выключенная проверка неотличима от работающей.
            if res.get("fatal") and not fatal:
                fatal = res["error"]
            return True
        landed += 1
        cache[it["key"]] = {
            "fp": it["fp"], "title": it["title"], "verdict": res["verdict"],
            "cost": res.get("cost", 0.0), "tokens": res.get("tokens", 0),
            "seconds": res.get("seconds", 0), "turns": res.get("turns", 0),
            "at": time.strftime("%Y-%m-%d %H:%M"),
        }
        print("  [%d/%d] %s — %s (%s токенов, %s с)"
              % (done, len(todo), it["key"],
                 verdict_line(res["verdict"], "ВЕРДИКТ") or "?",
                 res.get("tokens", 0), res.get("seconds", 0)))
        return True

    missed = []
    with futures.ThreadPoolExecutor(max_workers=jobs) as ex:
        fut = {ex.submit(ask_batch, g, mem, workdir, token=token): g for g in groups}
        for f in futures.as_completed(fut):
            g = fut[f]
            results = f.result()
            for it in g:
                if not absorb(it, results.get(it["key"], {"missing": True})):
                    missed.append(it)
            if fatal:
                for other in fut:
                    other.cancel()
                break

    # 🛑 Пакет не должен молча терять пункт: чего нет в ответе — досчитываем поштучно.
    if missed and not fatal:
        print("в ответе пакета не оказалось пунктов: %d — досчитываю по одному" % len(missed))
        done -= len(missed)
        with futures.ThreadPoolExecutor(max_workers=jobs) as ex:
            fut2 = {ex.submit(ask, it, mem, workdir, token=token): it for it in missed}
            for f in futures.as_completed(fut2):
                absorb(fut2[f], f.result())
                if fatal:
                    for other in fut2:
                        other.cancel()
                    break

    io.open(cache_path, "w", encoding="utf-8", newline="\n").write(
        json.dumps(cache, ensure_ascii=False, indent=1))
    # Предупреждение в ИТОГОВЫЙ отчёт идёт только если вердиктов так и не легло: иначе отказ
    # уже закрыт этим самым прогоном, и пугать роль нечем.
    write_report(items, cache, out_path, role, fatal, token_src=token_src,
                 warn=("" if landed else warn))
    if landed:
        # Метка удачи — единственное, что снимает предупреждение. Ставим ПОСЛЕ отчёта: в самом
        # отчёте предупреждение ещё уместно, если отказ был до этого прогона.
        note(last_ok=time.strftime("%Y-%m-%d %H:%M:%S"), last_ok_n=landed)
    # Стенограммы вызовов и пустой рабочий каталог больше не нужны.
    cleanup_engine_project(workdir)
    shutil.rmtree(workdir, ignore_errors=True)

    # 🛑 Подсадная ставится ПОСЛЕДНИМ шагом — после того, как файл вердиктов написан. Иначе
    # расчёт затирает подложный вердикт настоящим и проверка против штамповки не работает вовсе
    # (поймано сверкой 04.09: подсадка 17:31, пересчёт 17:32, роль увидела правильный вердикт).
    if not fatal:
        plant = Path(__file__).with_name("plant.py")
        if plant.is_file():
            try:
                subprocess.run([sys.executable, str(plant), "--dir", str(mem),
                                "--list", str(lst), "--n", "1"],
                               capture_output=True, timeout=60)
            except (OSError, subprocess.SubprocessError):
                pass

    spent = sum(cache[i["key"]]["cost"] for i in todo if i["key"] in cache)
    toks = sum(cache[i["key"]]["tokens"] for i in todo if i["key"] in cache)
    if fatal:
        print("VERDICTS: РАСЧЁТ ОСТАНОВЛЕН — %s" % fatal)
        print("  посчитано до остановки: %d из %d; файл: %s" % (done - 1, len(todo), out_path))
        note(status="failed", reason="движок: %s" % fatal, computed=max(done - 1, 0))
        return 3
    print("VERDICTS: считано=%d из_кеша=%d токенов=%d файл=%s"
          % (len(todo), kept, toks, out_path))
    print("  стоимость пересчёта: %.2f USD" % spent)
    note(status="done", reason="", computed=len(todo), tokens=toks,
         missing=len([i for i in todo if i["key"] not in cache]))
    return 0


def write_report(items, cache, out_path, role, fatal="", token_src="", warn=""):
    """Файл вердиктов для роли — рядом со списком, вне памяти."""
    if fatal:
        # Роль обязана увидеть, что помощника не было, — иначе она примет пустой файл за
        # «спорного нет» и решит, что ход отработал.
        io.open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join([
            "# Вердикты помощника — РАСЧЁТ НЕ ВЫПОЛНЕН (роль `%s`)" % role, "",
            "🛑 **Помощник не отвечал: %s**" % fatal, "",
            "Это не «спорного нет» и не «всё подтверждено». Вердиктов НЕТ ни по одному пункту —",
            "разбирай список сам, как без механики, и скажи об этом в отчёте владельцу:",
            "молча пропущенный ход выглядит выполненным.", "",
            "Чинить не тебе: расчёт зовёт обвязка `<supervisor-role>`, ему это видно.",
            "", "_%s._" % (token_src or "вход движка не назван"),
        ] + ([
            "", "⚠️ **И до этого:** %s." % warn,
        ] if warn else []) + [
            "", "_проверено %s, пунктов в списке: %d_" % (time.strftime("%Y-%m-%d %H:%M"), len(items)),
        ]) + "\n")
        return
    L = ["# Вердикты помощника по списку актуализации — роль `%s`" % role, "",
         "🛑 **Открывать ПОСЛЕ того, как назвал свой исход по пункту.** Прочитав чужой ответ первым,"
         " соглашаешься с ним незаметно для себя — ради этого порядка вердикты и лежат отдельно"
         " от списка.", "",
         "Вердикт готовит помощник на слабой модели: он видит только тексты, на машины не ходит,"
         " истории правок не знает. Он ловит противоречия, а не ложь.", "",
         "_Был ли расчёт и чем кончился — в штампе `.verdicts-stamp-%s.json` рядом; читать его"
         " командой `memory-verdicts.py --status --dir <память>`._" % role,
         ("_%s._" % token_src if token_src else ""), ""]
    if warn:
        L += ["⚠️ **Вердиктов у части пунктов может не быть:** %s. Скажи это в отчёте владельцу —"
              " молча пропущенный ход выглядит выполненным." % warn, ""]
    for it in items:
        rec = cache.get(it["key"])
        L.append("## %s" % it["title"])
        if not rec and it.get("skip"):
            L.append("")
            L.append("_не считался: %s_" % it["skip"])
            L.append("")
            continue
        if not rec:
            L.append("")
            L.append("_вердикта нет: не считался или вызов не удался_")
            L.append("")
            continue
        # 🛑 Полностью печатаем ТОЛЬКО спорное. Вердикт «подтверждено» — это «противоречий в текстах
        # не нашёл»; роль всё равно обязана проверить сама и назвать свою строку, так что полный
        # текст ей там не нужен, а стоит он места в окне. Замер 01.09: 20 вердиктов целиком — 2,1 %
        # окна, то есть свёртка удваивалась. Сжатая форма даёт около 0,2 %.
        v = rec["verdict"].strip()
        line = verdict_line(v, "ВЕРДИКТ").lower()
        L.append("")
        if line.startswith("подтверждено"):
            # Длину режем: помощник пишет «чем проверяется» абзацем, а роли нужно понять одно —
            # хватает ли текстов или идти смотреть в жизни. Подробности лежат в json.
            how = (verdict_line(v, "ЧЕМ ПРОВЕРЯЕТСЯ") or "")
            if len(how) > 220:
                how = how[:217].rstrip() + "…"
            L.append("**подтверждено** — противоречий в текстах не нашёл. %s" % how)
            L.append("")
            L.append("_полный текст: `verdicts-%s.json`, ключ `%s`_" % (role, it["key"]))
        else:
            L.append("_посчитан %s, %s токенов_" % (rec.get("at", "?"), rec.get("tokens", "?")))
            L.append("")
            L.append("```")
            L.append(v)
            L.append("```")
        L.append("")
    io.open(out_path, "w", encoding="utf-8", newline="\n").write("\n".join(L) + "\n")


if __name__ == "__main__":
    sys.exit(main())
