#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Модуль актуализации памяти: вычисляет ЗОНУ и печатает роли список мест.

Только читает память. Отчёт кладёт ВНЕ каталога памяти (иначе аудит увидит правку каждый ход
и его коммиты потеряют смысл).

Три входа, они же три вида пунктов:

  ВНЕШНЕЕ  — что пришло роли извне за отрезок (письма с обязательством: тема + «чего жду» +
             «чем закрывается»). Для каждого входа ищутся записи о том же предмете.
  ВОЗРАСТ  — записи, давно не подтверждённые. Отсчёт от метки `checked:` в шапке, где её нет —
             от последней правки в истории. Порция ограничена: срок задаёт очередь, а не список.
  ВНУТРИ   — противоречие внутри одной записи: последняя правка только ДОБАВЛЯЛА строки, а ниже
             в том же файле лежат строки о том же предмете.

Необязательный четвёртый вход (--with-registry) — проверка по реестру отмен роли, если роль его
ведёт. 🛑 Механика на реестр НЕ опирается: слово владельца 31.08 — реестр это такая же запись
памяти, как реестр задач или решений, и подлежит актуализации наравне с прочими.

Пометка `~` ставится там, где машина не уверена, что предмет вообще общий (слабое совпадение).
Только помеченный пункт роль вправе закрыть исходом «ложная тревога» — иначе роль будет
отбрасывать неудобное своей властью.

Использование:
    memory-revision.py --dir <память> [--mail <ящик>] [--days 14] [--age-days 14]
                       [--limit 12] [--out <файл>] [--with-registry]
"""
import argparse
import calendar
import hashlib
import io
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

HUB_MARKS = ("session_state", "memory.md")
WORD = re.compile(r"[А-Яа-яЁёA-Za-z][А-Яа-яЁёA-Za-z\-]{4,}")
QUOTED = re.compile("[«“\"]([^«»“”\"]{12,400})[»”\"]")
CHECKED = re.compile(r"^\s*checked:\s*([0-9]{4}-[0-9]{2}-[0-9]{2})", re.M)

STOP = set("""
это этот эта эти того тому теми тем так там тогда тоже только очень если чтобы потому поэтому
когда который которая которые которого котором какой какая какие каких какого более менее
может можно нужно надо должен должна должно будет были было есть быть свой своя свои своего
через после перед между около самое самый сама сами один одна одно два три все всех всего
владелец владельца владельцу слово слова словом роль роли ролей запись записи записей
память памяти работа работы работе делать сделать делаю сделал значит просто ещё уже нет да
письмо письма письмом пула пулу пуле роли роль
""".split())

RECONCILE = ["не путать", "оба верны", "обе верны", "и то и другое", "раньше было",
             "ранее считалось", "не следует смешивать", "оба утверждения"]


def read(p):
    try:
        return io.open(p, encoding="utf-8", errors="replace").read()
    except Exception:
        return ""


def stem(w):
    return w.lower()[:6]


def is_hub(name):
    low = name.lower()
    return any(m in low for m in HUB_MARKS)


def git(mem, *args):
    r = subprocess.run(["git", "-C", str(mem)] + list(args),
                       capture_output=True, text=True, encoding="utf-8", errors="replace")
    return r.stdout or ""


def corpus_freq(texts):
    freq = {}
    for t in texts:
        for w in set(stem(x) for x in WORD.findall(t)):
            freq[w] = freq.get(w, 0) + 1
    return freq


# 🛑 Оба условия нужны вместе — замер 04.09 на четырёх корпусах (см. шапку правки в истории):
# доля одна теряет сигнал на маленькой памяти, абсолютное число одно пропускает шум на большой.
MAX_RECORDS = 5


def key_terms(phrase, freq, total, want=3, max_df=0.15, max_n=MAX_RECORDS):
    seen, terms = set(), []
    for w in WORD.findall(phrase):
        s = stem(w)
        if s in STOP or w.lower() in STOP or s in seen:
            continue
        seen.add(s)
        terms.append((freq.get(s, 0), s, w))
    terms.sort()
    if not terms:
        return []
    rarest = terms[0][0]
    # Слово должно быть редким И по доле корпуса, И по абсолютному числу записей: у роли со 143
    # записями 15 % — это 21 запись, и предметное слово («bridge») проходило как редкое.
    if rarest > max_df * max(total, 1) or rarest > max_n:
        return []
    return [(s, w) for _, s, w in terms[:want]]


# ── вход 1: пришедшее извне ──────────────────────────────────────────────────────────────
def last_pass_stamp(out_path, role):
    """Когда список собирали в прошлый раз. Нет отметки — свёртка первая, окно календарное."""
    if not out_path:
        return 0.0
    p = Path(out_path).parent / (".last-pass-" + role)
    try:
        v = float(io.open(str(p), encoding="utf-8").read().strip())
    except (OSError, ValueError):
        return 0.0
    # 🛑 Отметка из будущего выключила бы почтовый вход НАСОВСЕМ и молча: все письма старше её.
    # Часы на этой машине уже прыгали вперёд (замер: +154 с). `float()` вдобавок принимает inf и
    # nan — с ними любое сравнение даёт «письмо старое». Не доверяем, откатываемся на календарь.
    if not (0 < v <= time.time()):
        print("ВНИМАНИЕ: отметка прошлого прохода негодная (%r) — беру календарное окно." % v)
        return 0.0
    return v


def write_pass_stamp(out_path, role, when):
    """🛑 Двигаем отметку ТОЛЬКО когда список записан в файл: пересборка ради проверки (печать
    в stdout) окно не сдвигает, иначе проверочный прогон съел бы письма у настоящего прохода.

    🛑 `when` — время НАЧАЛА прохода, не конца. Почта сканируется в начале, а запись файла идёт
    после разбора истории памяти; письмо, пришедшее в этот промежуток, не попало бы ни в текущий
    список, ни в следующий. Найдено оппонированием 04.09."""
    p = Path(out_path).parent / (".last-pass-" + role)
    io.open(str(p), "w", encoding="utf-8", newline="\n").write("%d\n" % int(when))


# Виды записей моста, которые сообщениями не являются: служебные события чата, реакции и
# ЩЕЛЧКИ. 🛑 `poll_answer` — ответ кнопкой в викторине тренажёра: у ассистента их 708 из 817
# записей за неделю, и каждый становился пунктом «сказал человек: вариант 2» с вердиктом
# помощника (768 пунктов, 5,6 млн токенов за день, поймано владельцем 06.09). Слова человека —
# только текст и расшифровка голоса.
INBOX_SKIP = ("service", "reaction", "reaction_count", "poll_answer", "callback_query",
              "callback", "chat_member", "my_chat_member", "chat_join_request")
# Метка отменённой пометки переноса — одна на сборщик и помощника (он читает её отсюда).
SECOND_CARRY_MARK = "перенесён повторно"


def is_message(rec):
    """Запись ленты — слова человека? Мост ставит `wake: False` у всего, что не сообщение
    (реакции, ответы кнопкой) — это положительный признак, список видов — страховка."""
    if rec.get("wake") is False:
        return False
    if rec.get("kind") in INBOX_SKIP:
        return False
    return bool((rec.get("text") or "").strip())


def inbox_inputs(inbox_dir, days, since=0.0, target=""):
    """Сообщения ЛЮДЕЙ из хранилища моста за то же окно, что и письма.

    Мост складывает их в `<каталог>/<ГГГГ-ММ-ДД>.jsonl`, по записи на сообщение. Нас интересует
    текст, отправитель и время; медиа и служебные события — нет.
    """
    box = Path(inbox_dir)
    if not box.is_dir():
        return []
    cutoff = since if since else time.time() - days * 86400
    out = []
    for f in sorted(box.glob("*.jsonl")):
        if f.name.startswith("quarantine"):
            continue
        try:
            if f.stat().st_mtime < cutoff:
                continue
        except OSError:
            continue
        for line in io.open(str(f), encoding="utf-8", errors="replace"):
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if not is_message(rec):
                continue
            # 🛑 Общий мост обслуживает несколько пулов: у записи стоит адрес вида
            # «pool-B-3/lead». Чужую переписку роли не показываем; запись без адреса —
            # мост принадлежит пулу, берём. Замер 04.09: у общего моста адрес есть у всех записей.
            addr = (rec.get("target") or "").strip()
            if addr and addr != target:
                continue
            text = (rec.get("text") or "").strip()
            if not text:
                continue
            when = rec.get("tg_date") or 0
            if not when:
                try:
                    when = time.mktime(time.strptime((rec.get("ts") or "")[:19], "%Y-%m-%dT%H:%M:%S"))
                except (ValueError, TypeError):
                    when = f.stat().st_mtime
            if when < cutoff:
                continue
            frm = rec.get("from") or {}
            who = frm.get("username") or frm.get("first_name") or "человек"
            mid = str(rec.get("message_id") or rec.get("update_id") or int(when))
            out.append((mid, who, " ".join(text.split())[:400], str(f), float(when)))
    return out


# Строка машинной ноты: одни пары «ключ=значение», за которыми может идти команда запуска.
MACHINE_LINE = re.compile(r"^\s*(?:[\w-]+=[^\s=]+[\s.,;]*)+(?:(?:Run|Запусти|Запустить)\s*:.*)?$", re.I)
RUN_ONLY = re.compile(r"^\s*(?:Run|Запусти|Запустить)\s*[:.]", re.I)


def is_machine_note(text):
    """Письмо порождено программой, а не ролью: в теле только счётчики и команда.

    🛑 Замер на 1776 письмах (`pool-A/operator`, 04.09): правило поймало 807 писем и ровно
    шесть уникальных заголовков — все ноты моста; ложных срабатываний ноль. Отправитель и тип
    письма для этого не годятся: ноты шлёт обычная роль, а тип `note-wake` носят и живые письма.
    """
    parts = re.split(r"^\|\s*Thread\s*\|[^\n]*\n", text, flags=re.M)
    body = parts[-1] if len(parts) > 1 else text
    lines = [ln for ln in body.splitlines() if ln.strip() and not ln.startswith("|")]
    if not lines:
        return True
    return all(MACHINE_LINE.match(ln) or RUN_ONLY.match(ln) for ln in lines)


SRC_RE = re.compile(r"^- источник целиком: `([^`]+)`", re.M)
REF_RE = re.compile(r"^- от: `([^`]*)`, (письмо|сообщение) `([^`]+)`", re.M)


def carry_stale(chunk, role):
    """Почему перенесённый пункт сегодня не был бы создан: '' — переносить, иначе причина.

    🛑 Перенос копировал пункт из прошлого списка как есть: машинные ноты моста и щелчки,
    которые сборщик уже отсеивает, продолжали ездить по спискам, пока роль не закроет их
    руками — у оператора pool-A по 36–63 «ложной тревоги» на проход (06.09). Источник
    открывается заново и прогоняется через те же правила, что и свежий вход. Источник не
    найден — переносим: терять пункт хуже, чем показать лишний.
    """
    ms, mr = SRC_RE.search(chunk), REF_RE.search(chunk)
    if not ms or not mr:
        return ""
    src, frm, kind, mid = Path(ms.group(1)), mr.group(1), mr.group(2), mr.group(3)
    try:
        if kind == "сообщение":
            if src.suffix != ".jsonl" or not src.is_file():
                return ""
            # 🛑 На один id мост пишет НЕСКОЛЬКО записей: у голосового первая без текста, вторая —
            # расшифровка. Решаем по всем совпавшим, а не по первой: иначе пункт из голосового
            # владельца снимался бы как «запись без текста» (нашёл оппонент 06.09).
            found = []
            for line in io.open(str(src), encoding="utf-8", errors="replace"):
                line = line.strip()
                if not line.startswith("{") or mid not in line:
                    continue
                try:
                    rec = json.loads(line)
                except ValueError:
                    continue
                if mid in (str(rec.get("message_id")), str(rec.get("update_id"))):
                    found.append(rec)
            if not found or any(is_message(r) for r in found):
                return ""
            kinds = sorted(set(str(r.get("kind")) for r in found))
            if any(r.get("wake") is False or r.get("kind") in INBOX_SKIP for r in found):
                return "щелчок или служебная запись моста (%s)" % ", ".join(kinds)
            return "запись без текста"
        if src.suffix != ".md" or not src.is_file():
            return ""
        text = read(src)
        if not text.strip():
            return ""            # не прочиталось — переносим, а не снимаем
        if is_machine_note(text):
            return "машинная нота"
        m = re.search(r"^\|\s*From\s*\|\s*([^|]+)\|", text[:1200], re.M)
        mp = re.search(r"^\|\s*FromPool\s*\|\s*([^|]+)\|", text[:1200], re.M)
        if m and m.group(1).strip() == role and not mp:
            return "собственное эхо"
    except OSError:
        return ""
    return ""


def ext_closed_path(out_path, role):
    return Path(out_path).parent / (".ext-closed-" + role)


def read_ext_closed(out_path, role):
    """Внешние пункты, когда-либо закрытые ролью: ключ -> время закрытия. Порция отступает окном
    назад, и без этой памяти закрытое предъявлялось бы снова. Письмо, обновлённое ПОСЛЕ закрытия,
    закрытым не считается — это прежнее правило «предъявлялся ранее, исход был»."""
    out = {}
    if not out_path:
        return out
    try:
        for l in io.open(str(ext_closed_path(out_path, role)), encoding="utf-8"):
            k, _, ts = l.strip().partition("\t")
            if k:
                try:
                    out[k] = max(out.get(k, 0.0), float(ts or 0))
                except ValueError:
                    out[k] = out.get(k, 0.0)
    except OSError:
        pass
    return out


def add_ext_closed(out_path, role, keys, when, keep_days=14.0):
    """Файл переписывается целиком: без дублей и без записей старше `keep_days` — дальше
    календарного окна первой свёртки отметка не отступает, так что старые записи бесполезны."""
    if not out_path:
        return
    have = read_ext_closed(out_path, role)
    for k in keys:
        if have.get(k, -1.0) < when:
            have[k] = when
    floor = time.time() - keep_days * 86400
    rows = sorted((k, ts) for k, ts in have.items() if ts >= floor)
    p = ext_closed_path(out_path, role)
    if rows or p.exists():
        io.open(str(p), "w", encoding="utf-8", newline="\n").write(
            "".join("%s\t%d\n" % (k, int(ts)) for k, ts in rows))


def mail_when(text):
    """Время письма из строки `| Date | … |` шапки (ISO со смещением) — 0, если не разобрать.
    mtime файла — запасной путь: обслуживание шины и перенос в архив его поднимают, и старая
    переписка вставала бы в голову порции (нашёл оппонент 06.09)."""
    m = re.search(r"^\|\s*Date\s*\|\s*([^|]+)\|", text[:1200], re.M)
    if not m:
        return 0.0
    v = m.group(1).strip()
    try:
        base = calendar.timegm(time.strptime(v[:19], "%Y-%m-%dT%H:%M:%S"))
    except ValueError:
        return 0.0
    z = re.search(r"([+-])(\d\d):?(\d\d)$", v)
    if z:
        off = (int(z.group(2)) * 3600 + int(z.group(3)) * 60) * (1 if z.group(1) == "+" else -1)
        return float(base - off)
    return float(base) if v.endswith("Z") else float(time.mktime(time.strptime(v[:19], "%Y-%m-%dT%H:%M:%S")))


def mail_inputs(mailbox, days, since=0.0):
    box = Path(mailbox)
    role = box.name
    # 🛑 Окно задаёт РАБОТА роли, а не календарь (слово владельца 04.09). Письма разбираются
    # по мере прихода, поэтому к свёртке всё пришедшее уже прочитано; сверять с памятью надо
    # ровно то, что случилось с прошлого раза. Календарный срок остаётся для первой свёртки.
    cutoff = since if since else time.time() - days * 86400
    fields = ("Expect", "CloseWhen", "About", "Opens", "Closes")
    out = []
    places = [(box / "new", False), (box / "cur", False), (box.parent / "archive", True)]
    for d, filter_to in places:
        if not d.is_dir():
            continue
        for f in sorted(d.glob("*.md")):
            try:
                if f.stat().st_mtime < cutoff:
                    continue
            except OSError:
                continue
            text = read(f)
            if filter_to:
                m = re.search(r"^\|\s*To\s*\|\s*([^|]+)\|", text[:1200], re.M)
                if not m or m.group(1).strip() != role:
                    continue
            m = re.search(r"^\|\s*From\s*\|\s*([^|]+)\|", text[:1200], re.M)
            frm = m.group(1).strip() if m else ""
            mp = re.search(r"^\|\s*FromPool\s*\|\s*([^|]+)\|", text[:1200], re.M)
            from_pool = mp.group(1).strip() if mp else ""
            # 🛑 Своё письмо — по ПАРЕ «роль + пул», а не по имени роли: в pool-B роль во всех пулах
            # называется lead, и отсев по одному имени выбрасывал письма соседей как собственное
            # эхо (лид product 06.09: 41 письмо из 70). Строку FromPool шина ставит только письму,
            # ушедшему в ЧУЖУЮ шину (pool.ps1), поэтому своё = то же имя И FromPool пуст.
            own = frm == role and not from_pool
            if frm in ("", "bridge", "sweeper", "shop") or own or frm.startswith("pool-"):
                continue
            # 🛑 Машинные уведомления письмами не считаются (слово владельца 04.09). Отсев по
            # отправителю их не ловит: их шлёт обычная роль. Смотрим на тело.
            if is_machine_note(text):
                continue
            parts = []
            h = re.search(r"^#\s+(.+)$", text, re.M)
            if h:
                parts.append(h.group(1).strip())
            for fld in fields:
                mm = re.search(r"^\|\s*%s\s*\|\s*([^|]+)\|" % fld, text, re.M)
                if mm and mm.group(1).strip() not in ("", "-"):
                    parts.append(mm.group(1).strip())
            if parts:
                # 🛑 Путь к письму, а не только его id: пункт читает не только роль, но и субагент
                # с чистым контекстом — по одному id он источник не откроет и вынесет вердикт
                # по пересказу. Найдено пробой 01.09.
                out.append((f.name.split(".")[0], frm, " · ".join(parts), str(f),
                            mail_when(text) or float(f.stat().st_mtime)))
    return out


# ── вход 2: возраст ──────────────────────────────────────────────────────────────────────
def last_touch(mem):
    """Дата последней правки КАЖДОГО файла — одним проходом по логу.

    🛑 Раньше здесь был `git log -1` на каждый файл: на памяти в 150 записей это 150 запусков
    процесса и 7 секунд на Windows. Модуль зовётся из обвязки перед сжатием у всех ролей —
    такая цена там неприемлема. Один проход даёт то же самое за доли секунды.
    """
    out = {}
    ts = None
    for line in git(mem, "log", "--pretty=format:@%ct", "--name-only").splitlines():
        s = line.strip()
        if s.startswith("@"):
            try:
                ts = int(s[1:])
            except ValueError:
                ts = None
        elif s and ts and s not in out:
            out[s] = ts                  # лог идёт от свежего к старому — первое вхождение и есть последнее
    return out


def ages(mem, files):
    """Возраст в сутках: от метки checked:, где её нет — от последней правки в истории."""
    now = time.time()
    touched = last_touch(mem)
    out = []
    for f in files:
        text = read(f)
        m = CHECKED.search(text[:800])
        if m:
            try:
                ts = time.mktime(time.strptime(m.group(1), "%Y-%m-%d"))
                out.append((f, (now - ts) / 86400.0, "по метке проверки"))
                continue
            except ValueError:
                pass
        ts = touched.get(f.name)
        if ts:
            out.append((f, (now - ts) / 86400.0, "по последней правке"))
        else:
            out.append((f, None, "в истории нет"))
    return out


# ── вход 3: противоречие внутри записи ───────────────────────────────────────────────────
def inside_record(mem, f, freq, total):
    """Последняя правка только добавляла — а ниже в файле лежат строки о том же предмете."""
    diff = git(mem, "log", "-1", "-p", "--unified=0", "--", f.name)
    if not diff:
        return None
    added, removed = [], 0
    for line in diff.splitlines():
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            added.append(line[1:].strip())
        elif line.startswith("-"):
            removed += 1
    if removed or not added:
        return None                      # были убранные строки — это замена, а не наращивание
    text = read(f)
    lines = text.splitlines()
    added_set = set(a for a in added if len(a) > 30)
    if not added_set:
        return None
    body = " ".join(a for a in added_set)
    terms = key_terms(body, freq, total)
    if len(terms) < 2:
        return None
    hits = []
    for i, line in enumerate(lines, 1):
        low = line.lower()
        if line.strip() in added_set:
            continue                     # это и есть свежая правка
        if all(s in low for s, _ in terms):
            hits.append((i, line.strip()))
    if not hits:
        return None
    return terms, hits


ITEM_RE = re.compile(r"^###\s+(~\s*)?П\d+\.\s*(.+?)\s*$", re.M)
OUTCOME_RE = re.compile(r"^- \*\*исход:\*\*\s*(.*)$", re.M)
# Пометки прошлых проходов внутри блока пункта — при переносе отсекаются все три вида:
#   🔴 **предъявлялся в прошлый раз и остался БЕЗ ИСХОДА.**   (со звёздочками)
#   🔴 **перенесён с прошлого прохода** …                      (со звёздочками)
#   ⚠️ предъявлялся ранее, исход был: `X`.                     (БЕЗ звёздочек)
OLD_MARK_RE = re.compile(r"^\s*(🔴|⚠️)\s*(?:\*\*)?(предъявлялся|перенесён)")
VALID_OUTCOMES = ("подтверждено", "заменил", "верны при условии", "спорит",
                  "спросить владельца", "ложная тревога", "перенесено")


def item_key(title, chunk=""):
    """Устойчивый ключ пункта — чтобы «предъявлялся в прошлый раз» не терялось молча.

    🛑 Раньше ключом был заголовок с отрезанным хвостом в скобках: скобку отрезали ради пунктов
    возраста, у которых в конце меняется «(28 сут…)». Но у внешних пунктов заголовок — ТЕМА ПИСЬМА,
    и она сплошь и рядом кончается скобкой сама («…(md5 внутри)», «…(ответа не нужно)»). Такой
    пункт сохранялся обрезанным, а сверялся целым — и каждый проход выглядел новым, сколько бы раз
    его ни игнорировали. Найдено оппонированием 01.09, подтверждено на живом списке.

    Поэтому ключ берётся не из заголовка, а из того, чем пункт адресуется на самом деле:
    id письма для внешнего входа, имя файла записи для возраста. Заголовок — только запасной путь.
    """
    # 🛑 Сначала адресная строка «- от: …, письмо|сообщение `id`»: свободный поиск по блоку
    # цеплял «письмо `X`» из цитат записей памяти и подменял ключ (нашёл оппонент 06.09).
    m = re.search(r"^- от: `[^`]*`, (письмо|сообщение) `([^`]+)`", chunk, re.M)
    if m:
        return ("mail:" if m.group(1) == "письмо" else "msg:") + m.group(2)
    m = re.search(r"письмо `([^`]+)`", chunk)
    if m:
        return "mail:" + m.group(1)
    m = re.search(r"сообщение `([^`]+)`", chunk)
    if m:
        return "msg:" + m.group(1)
    # ⚠️ Порядок проверок несущий: один и тот же файл попадает и в возраст, и во «внутри записи»,
    # и по имени файла эти два пункта неразличимы. Сначала более узкий признак.
    m = re.match(r"`([^`]+\.md)`:\s*последняя правка", title)
    if m:
        return "in:" + m.group(1)
    m = re.match(r"`([^`]+\.md)`", title)
    if m:
        return "age:" + m.group(1)
    return re.sub(r"\s*\([^)]*\)\s*$", "", title).strip()


def verdicts_of(out_path, role):
    """Вердикты помощника по ключам пунктов: {ключ: слово вердикта}."""
    p = Path(out_path).parent / ("verdicts-%s.json" % role)
    try:
        data = json.loads(read(p))
    except (OSError, ValueError):
        return {}
    out = {}
    for key, rec in (data.items() if isinstance(data, dict) else []):
        text = (rec or {}).get("verdict") or ""
        m = re.search(r"ВЕРДИКТ:\s*([^\n]+)", text)
        word = (m.group(1) if m else text).strip().lower()
        for v in VALID_OUTCOMES:
            if word.startswith(v):
                out[key] = v
                break
    return out


def agreement(role_outcome, helper_outcome):
    """Согласилась ли роль с помощником. Пустой исход или отсутствие вердикта — не спор."""
    if not role_outcome or not helper_outcome:
        return "без вердикта"
    return "согласие" if role_outcome == helper_outcome else "расхождение"


def harvest(out_path, role, mem=None, keep_days=14.0):
    """Снять исходы с ПРЕДЫДУЩЕГО списка перед тем, как переписать его.

    🛑 Без этого «перенесено» не оставляет следа нигде: файл перезаписывается целиком, и второй
    проход не отличит перенесённый пункт от нового. Журнал лежит рядом со списком — вне памяти.
    """
    p = Path(out_path)
    if not p.exists():
        return {}, [], []
    text = read(p)
    items = []
    blocks = {}
    parts = re.split(r"^###\s+", text, flags=re.M)[1:]
    for chunk in parts:
        head = chunk.splitlines()[0].strip()
        m = re.match(r"(~\s*)?П\d+\.\s*(.+)$", head)
        title = (m.group(2) if m else head).strip()
        key = item_key(title, chunk)
        om = OUTCOME_RE.search(chunk)
        outcome = (om.group(1).strip() if om else "").lower()
        norm = ""
        for v in VALID_OUTCOMES:
            if outcome.startswith(v):
                norm = v
                break
        items.append((key, title, norm, outcome))
        # 🛑 Блок пункта режем по границе раздела: split по «###» отдаёт всё до следующего
        # пункта, включая заголовок следующего раздела и строку итога. При переносе этот хвост
        # печатался снова, и список получал второй комплект разделов. Поймано прогоном на живом.
        body_lines = []
        for ln in chunk.rstrip().splitlines():
            if ln.startswith(("## ", "_итог", "---", "ВСЕГО ПУНКТОВ")):
                break
            body_lines.append(ln)
        blocks[key] = "\n".join(body_lines).rstrip()

    # 🛑 Журнал дописывается ТОЛЬКО когда список действительно менялся. Пересборка идёт и по
    # требованию скила («список старше суток»), и просто ради проверки — а harvest дописывал строку
    # на каждый пункт при каждом запуске. Доля «ПУСТО» тогда растёт от числа пересборок, а не от
    # поведения роли, и ряд, по которому судят о вырождении, врёт. Найдено оппонированием 01.09;
    # на своём журнале — по 3 записи на пункт за 2 прогона.
    journal = p.parent / "journal.tsv"
    stampfile = p.parent / (".journal-stamp-" + role)
    fingerprint = hashlib.md5(
        "\n".join("%s\t%s" % (k, n) for k, _, n, _ in items).encode("utf-8")).hexdigest()
    seen = ""
    try:
        seen = io.open(stampfile, encoding="utf-8").read().strip()
    except OSError:
        pass
    if fingerprint != seen:
        stamp = time.strftime("%Y-%m-%d %H:%M")
        # 🛑 Список, в котором нет ни одного исхода, роль не разбирала — его сожгла пересборка
        # (скил велит пересобрать список старше суток). Записывать по нему «ПУСТО» значит
        # обвинять роль в отказе за минуту до того, как она эти пункты закроет. Нашёл ведущий
        # 04.09; на моих данных 44 предмета имели «ПУСТО» и настоящий исход в один и тот же день.
        touched = any(n for _, _, n, _ in items)
        blank = "ПУСТО" if touched else "пересобран"
        # 🛑 Пятая колонка — согласие роли с помощником. Без неё «доля согласий» не считалась
        # ниоткуда: вердикт лежит в файле, исход в списке, а свести их было некому.
        helper = verdicts_of(p, role)
        lines = ["%s\t%s\t%s\t%s\t%s" % (stamp, role, n or blank, t[:160],
                                          agreement(n, helper.get(k)))
                 for k, t, n, _ in items]
        if lines:
            with io.open(journal, "a", encoding="utf-8", newline="\n") as fh:
                fh.write("\n".join(lines) + "\n")
        io.open(stampfile, "w", encoding="utf-8", newline="\n").write(fingerprint + "\n")

    # 🛑 Признак исхода «заменил» из § 5 канона: замена — это УБРАННЫЕ строки в записи-носителе.
    # Без проверки роль пишет «заменил», ничего не тронув, и пункт уходит закрытым. Смотрим историю
    # записи с момента, когда список был создан: если убранных строк нет, исход сомнителен.
    if mem:
        since = int(p.stat().st_mtime)
        for key, title, norm, _ in items:
            if norm != "заменил" or not key.startswith(("age:", "in:")):
                continue
            # Подсадная закрывается отказом от чужого вердикта, а не правкой записи: требовать
            # от неё убранных строк — ложная тревога, а к красному, которое ничего не значит,
            # роль привыкает и перестаёт читать вывод.
            if "утверждение под проверку" in title:
                continue
            name = key.split(":", 1)[1]
            # 🛑 Смотрим И историю, И рабочий каталог: роль закрывает исходы в свёртке, а коммит
            # памяти идёт ПОЗЖЕ — по одной истории признак кричал бы на каждой честной замене.
            diff = (git(mem, "log", "--since=@%d" % since, "-p", "--unified=0", "--", name)
                    + git(mem, "diff", "HEAD", "--unified=0", "--", name))
            removed = [l for l in diff.splitlines()
                       if l.startswith("-") and not l.startswith("---")]
            if not removed:
                print("ВНИМАНИЕ: исход «заменил» у `%s`, но в записи ничего не убрано —"
                      " замена не состоялась или сделана вне истории." % name)

    # 🛑 «подтверждено» без основания — исход, который канон не признаёт: «рядом с исходом
    # назови, чем подтверждено: по первоисточнику, наблюдением, сверкой с файлом». Голое слово
    # ставится за секунду и потому первым сползает в отписку; у «заменил» проверка была, у этого
    # не было никакой.
    bare = []
    for key, title, norm, raw in items:
        if norm != "подтверждено":
            continue
        rest = raw[len("подтверждено"):].strip(" .,;—-–:")
        if len(rest) < 12:
            bare.append(title)
    if bare:
        print("ВНИМАНИЕ: исход «подтверждено» без основания у %d пунктов (канон требует назвать,"
              " чем подтверждено — первоисточник, наблюдение, сверка с файлом): %s"
              % (len(bare), "; ".join(t[:60] for t in bare[:4])
                 + (" и др." if len(bare) > 4 else "")))

    carried = {k: (n or "ПУСТО") for k, _, n, _ in items}
    unclosed = [t for _, t, n, _ in items if n in ("", "перенесено")]
    # 🛑 Закрытый внешний пункт помним отдельно от списка: порция сдвигает окно назад, и без
    # этой памяти уже разобранное письмо предъявлялось бы снова через проход.
    # Время закрытия — последняя запись прошлого списка: позже неё роль исходов не вписывала.
    try:
        closed_at = p.stat().st_mtime
    except OSError:
        closed_at = time.time()
    add_ext_closed(out_path, role,
                   [k for k, _, n, _ in items
                    if k.startswith(("mail:", "msg:")) and n and n != "перенесено"],
                   closed_at, keep_days)
    # 🛑 Пункт без исхода переносим ЦЕЛИКОМ, а не одним упоминанием в счётчике: с окном по
    # свёртке письмо в новый отбор уже не попадёт, и пункт исчез бы молча. Найдено
    # оппонированием 04.09.
    # 🛑 Переносим ТОЛЬКО почтовые пункты. Возраст и «внутри записи» собираются из памяти
    # заново каждый проход и потеряться не могут — их перенос давал вторую копию того же пункта,
    # а исход, вписанный в одну копию, для другой оставался пустым: пункт становился
    # незакрываемым. Поймано оппонированием 04.09 на живом списке (25 пунктов вместо 13).
    carry, seen_keys = [], set()
    for k, _, n, _ in items:
        if not k.startswith(("mail:", "msg:")) or n not in ("", "перенесено"):
            continue
        if k not in blocks or k in seen_keys:
            continue
        seen_keys.add(k)   # один пункт — один перенос, даже если прошлый список задвоился
        carry.append((k, blocks[k]))

    # 🛑 Пересборка ПОСРЕДИ работы стирает исходы, которых роль не успела вписать в файл: она их
    # уже сделала — правки в памяти есть, — но журнал запишет «ПУСТО», и работа станет невидимой.
    # Признак событийный, не по часам: память тронута ПОЗЖЕ, чем создан список, а исхода нет
    # ни одного. Поймано на себе 01.09.
    if mem and items and not any(n for _, _, n, _ in items):
        try:
            newest = max((f.stat().st_mtime for f in Path(mem).glob("*.md")), default=0)
            if newest > p.stat().st_mtime:
                print("ВНИМАНИЕ: прошлый список уходит без единого исхода, а память после него"
                      " правилась. Исход существует только в файле списка — впиши исходы туда"
                      " ДО пересборки, иначе сделанное не попадёт в журнал.")
        except OSError:
            pass

    return carried, unclosed, carry


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", required=True)
    ap.add_argument("--mail")
    ap.add_argument("--inbox", help="каталог моста с сообщениями людей (<дата>.jsonl)")
    ap.add_argument("--inbox-target", default="",
                    help="адрес роли в общем мосте, например pool-B-3/lead")
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--age-days", type=float, default=14.0)
    ap.add_argument("--limit", type=int, default=12, help="сколько пунктов ВОЗРАСТА брать за раз")
    ap.add_argument("--ext-limit", type=int, default=12,
                    help="сколько пунктов ВНЕШНЕГО входа брать за раз (свежие первыми)")
    ap.add_argument("--out", help="файл отчёта; по умолчанию печать в stdout")
    ap.add_argument("--with-registry", action="store_true")
    ap.add_argument("--journal", help="напечатать сводку по журналу исходов и выйти")
    args = ap.parse_args()
    # Время НАЧАЛА прохода: им помечается окно, чтобы письмо, пришедшее во время сборки,
    # не провалилось между текущим списком и следующим.
    started = time.time()

    if args.journal:
        # Измеритель вырождения: доля исходов по видам. Порогов НЕ ставим — печатаем ряд,
        # человек смотрит, не превратилось ли предъявление в обряд.
        # «пересобран» — не исход роли, а след пересборки: в доле отказов не участвует,
        # но печатается отдельной строкой, чтобы было видно, сколько списков сгорело впустую.
        jp = Path(args.journal)
        if not jp.exists():
            print("журнала нет: %s" % jp)
            return 2
        rows = [ln.split("\t") for ln in read(jp).splitlines() if ln.strip()]
        rows = [r for r in rows if len(r) >= 4]

        # 🛑 Проход, в котором НЕТ НИ ОДНОГО непустого исхода, — это пересборка, сжёгшая ещё не
        # разобранный список, а не отказ роли разбирать. До правки 04.09 такие строки писались
        # словом «ПУСТО» и завышали долю отказов в разы (у меня 44 предмета имели «ПУСТО» и
        # настоящий исход в один день). Старые строки НЕ переписываем — фильтруем при чтении:
        # журнал есть наблюдение, а не витрина, и переписанный ряд перестаёт быть измерением.
        passes = {}
        for r in rows:
            passes.setdefault((r[0], r[1]), []).append(r[2])
        # «пересобран» — не исход роли, а наша же пометка о сгоревшем списке: в проверку «был ли в
        # проходе хоть один настоящий исход» она входить не должна, иначе проход из одних
        # «пересобран» считается разобранным (поймано проверкой своих правок 04.09).
        burned = set(k for k, outs in passes.items()
                     if not any(o and o not in ("ПУСТО", "пересобран") for o in outs))

        by_role, burned_by_role = {}, {}
        for r in rows:
            if (r[0], r[1]) in burned and r[2] in ("", "ПУСТО", "пересобран"):
                burned_by_role[r[1]] = burned_by_role.get(r[1], 0) + 1
                continue
            by_role.setdefault(r[1], []).append(r[2])

        print("СВОДКА ЖУРНАЛА ИСХОДОВ: %s" % jp)
        for role_name, outs in sorted(by_role.items()):
            tot = len(outs)
            if not tot:
                continue
            print("\n%s — пунктов предъявлено: %d" % (role_name, tot))
            counts = {}
            for o in outs:
                counts[o] = counts.get(o, 0) + 1
            for k, v in sorted(counts.items(), key=lambda x: -x[1]):
                print("   %-20s %4d  (%.0f%%)" % (k, v, 100.0 * v / tot))
            burnt = burned_by_role.get(role_name, 0)
            if burnt:
                print("   %-20s %4d  — не в счёте: список сгорел на пересборке, роль его не видела"
                      % ("(пересобран)", burnt))
            agree = sum(1 for r in rows if r[1] == role_name and len(r) > 4 and r[4] == "согласие")
            differ = sum(1 for r in rows if r[1] == role_name and len(r) > 4 and r[4] == "расхождение")
            if agree + differ:
                print("   согласий с помощником: %d, расхождений: %d (%.0f%% расхождений)"
                      % (agree, differ, 100.0 * differ / (agree + differ)))
                print("   ⚠️ порога здесь нет: ноль расхождений так же подозрителен, как сто —"
                      " роль, которая никогда не спорит, перестала читать.")
            empty = counts.get("ПУСТО", 0)
            fake = counts.get("ложная тревога", 0)
            print("   ⚠️ без исхода: %.0f%%; «ложная тревога»: %.0f%% — ряд смотреть во времени,"
                  " порога здесь нет" % (100.0 * empty / tot, 100.0 * fake / tot))
            if burnt:
                print("   ⚠️ хвост ряда ДО 04.09 несопоставим с новым: там пересборки писались"
                      " словом «ПУСТО» и попадали в долю отказов.")
        return 0

    mem = Path(args.dir)
    if not mem.is_dir():
        print("нет каталога: %s" % mem)
        return 2
    role = mem.name

    files, closed = [], 0
    for f in sorted(mem.glob("*.md")):
        if f.name == "MEMORY.md":
            continue
        if "ЗАКРЫТО" in read(f)[:600]:
            closed += 1
            continue
        files.append(f)
    texts = {f.stem: read(f) for f in files}
    freq = corpus_freq(texts.values())
    total = len(files)

    carried, unclosed, carry = ({}, [], [])
    if args.out:
        carried, unclosed, carry = harvest(args.out, role, mem, float(args.days))

    def mark(title):
        """Пункт уже предъявлялся — сказать это прямо: иначе перенос неотличим от нового."""
        was = carried.get(title)
        if not was:
            return ""
        if was == "ПУСТО":
            return "  🔴 **предъявлялся в прошлый раз и остался БЕЗ ИСХОДА.**\n"
        if was == "перенесено":
            return "  🔴 **перенесён с прошлого прохода** — второй перенос требует причины.\n"
        return "  ⚠️ предъявлялся ранее, исход был: `%s`.\n" % was

    L = []
    add = L.append
    n = 0

    add("# Актуализация памяти: что предъявлено роли `%s`" % role)
    add("")
    add("Составлено машиной, только чтением. Записей в отборе: %d (закрытых пропущено: %d)."
        % (total, closed))
    add("")
    add("🛑 **По каждому пункту назови исход. Молчание исходом не является.**")
    add("Исходы: `подтверждено` · `заменил` · `верны при условии` · `спорит — отложено` ·"
        " `спросить владельца` · `ложная тревога`. Отложил пункт — пиши `перенесено`"
        " **и причину**: перенос не должен выглядеть подтверждением, а второй перенос подряд"
        " машина покажет отдельно.")
    add("🛑 **`подтверждено` ставится только после того, как ты ОТКРЫЛ запись** — строка"
        " `description:` в пункте это фильтр, а не содержание. Рядом с исходом назови, чем"
        " подтверждено: «по первоисточнику», «наблюдал сам», «сверено с <файл>». Без этого"
        " исход не считается.")
    add("⚠️ Закрыв пункт исходом `подтверждено` или `заменил`, поставь `checked: ГГГГ-ММ-ДД`"
        " в шапке **той записи, которую проверял** (не всех перечисленных рядом) — от этой метки"
        " считается следующий срок, а не от правки файла.")
    add("⚠️ Исход `ложная тревога` допустим ТОЛЬКО для пунктов со знаком `~`. У пунктов из"
        " раздела «давно не подтверждалось» тревоги нет вовсе: машина измерила дату, а не нашла"
        " противоречие, — такой пункт закрывается подтверждением или заменой, отбросить его"
        " нечем.")
    add("⚠️ Исход `верны при условии` законен, только если условие назвал источник или оно видно"
        " в фактах. Условие, придуманное ради выживания обоих утверждений, — это примирение.")
    add("")
    if unclosed:
        add("🔴 **С прошлого прохода осталось без исхода или перенесено: %d пунктов** — они ниже"
            " помечены." % len(unclosed))
        add("")

    # ── ВНЕШНЕЕ ─────────────────────────────────────────────────────────────────────────
    ext_n = 0
    # ── ПЕРЕНЕСЁННЫЕ: пункты, по которым решения так и не назвали ───────────────────────
    carried_keys = set()
    dropped = []
    if carry:
        kept = []
        for key, chunk in carry:
            why = carry_stale(chunk, role)
            (dropped if why else kept).append((key, why) if why else (key, chunk))
        carry = kept
    if dropped:
        add("_снято сегодняшним отсевом, не перенесено: %d — %s_"
            % (len(dropped), "; ".join("`%s` (%s)" % (k, w) for k, w in dropped[:20])
               + (" …" if len(dropped) > 20 else "")))
        add("")
    if carry:
        add("## Осталось с прошлого раза — решения не было (%d)" % len(carry))
        add("")
        add("Эти пункты переносятся независимо от срока письма: пока по пункту не сказан исход,"
            " он не закрыт. Второй перенос подряд требует причины.")
        add("")
        for key, chunk in carry:
            n += 1
            carried_keys.add(key)
            lines = chunk.splitlines()
            head = re.sub(r"^(~\s*)?П\d+\.\s*", "", lines[0].strip())
            weak = "~ " if lines[0].strip().startswith("~") else ""
            add("### %sП%d. %s" % (weak, n, head))
            was = carried.get(key, "ПУСТО")
            # Пункт уже нёс пометку переноса — значит, переносится второй раз подряд.
            again = any(OLD_MARK_RE.match(ln) and "перенесён" in ln for ln in lines[1:])
            add("  🔴 **%s: в прошлый раз %s.**"
                % (SECOND_CARRY_MARK + " (второй раз подряд)" if again else "перенесён",
                   "исхода не было" if was == "ПУСТО" else "стоял `%s`" % was))
            for line in lines[1:]:
                # Три вида прошлых пометок, и звёздочки есть только у двух: «⚠️ предъявлялся ранее,
                # исход был: …» идёт без них. Прежний `\*\*?` требовал минимум одну звёздочку и
                # пропускал эту строку в перенос — пункт печатал рядом «исхода не было» и «исход был:
                # подтверждено». Нашёл lead pool-B-2 04.09 (обязательство revision-carry-stale-mark).
                if OLD_MARK_RE.match(line):
                    continue
                # 🛑 Строку исхода приводим к каноническому виду: rstrip() блока срезал у неё
                # хвостовой пробел, и перенесённый пункт переставал совпадать с обычным —
                # роль вписывает исход в одну форму, а искать пришлось бы две. Поймано пробой.
                # 🛑 Любую строку исхода — в пустую, не только пустую: «перенесено — жду ответа»
                # уезжало в новый список дословно, harvest читал его как исход каждый проход, и
                # пункт становился вечным без «ПУСТО» и без вердикта (нашёл оппонент 06.09).
                if re.match(r"^- \*\*исход:\*\*", line):
                    add("- **исход:** ")
                    continue
                add(line)
            add("")
        add("_итог: перенесённых пунктов — %d_" % len(carry))
        add("")

    if args.mail or args.inbox:
        since = last_pass_stamp(args.out, role)
        # 🛑 Отметка и список — два куска одного состояния. Списка нет, а отметка есть: перенос
        # взять неоткуда, и всё незакрытое исчезло бы молча вместе с письмами старше отметки.
        if since and (not args.out or not Path(args.out).exists()):
            print("ВНИМАНИЕ: отметка есть, а прошлого списка нет — беру календарное окно,"
                  " иначе незакрытое пропадёт без следа.")
            since = 0.0
        # 🛑 Канал не важен, важно содержание (слово владельца 04.09): письма ролей и сообщения
        # людей идут одним потоком. Служебное сюда не попадает по устройству — побудки сторожа и
        # команды контроллера не лежат ни в почте, ни в хранилище моста.
        inputs = [(m, f, t, p, "письмо", w) for m, f, t, p, w in
                  (mail_inputs(args.mail, args.days, since) if args.mail else [])]
        inputs += [(m, f, t, p, "сообщение", w) for m, f, t, p, w in
                   (inbox_inputs(args.inbox, args.days, since, args.inbox_target)
                    if args.inbox else [])]
        # 🛑 Свежие первыми: порция (`--ext-limit`) берёт верх списка, остаток не теряется —
        # отметка прохода отступает к самому старому невошедшему, и следующий проход начнёт с
        # него. Потоп из сотен записей (викторины ассистента) иначе шёл в список целиком.
        inputs.sort(key=lambda x: -x[5])
        closed_ext = read_ext_closed(args.out, role)
        ext_cut, ext_over = 0.0, 0
        n_msg = sum(1 for x in inputs if x[4] == "сообщение")
        whence = "писем %d, сообщений людей %d" % (len(inputs) - n_msg, n_msg)
        if since:
            add("## Пришло извне с прошлой свёртки, %s (%s)"
                % (time.strftime("%d.%m %H:%M", time.localtime(since)), whence))
        else:
            add("## Пришло извне за %d сут — свёртка первая (%s)" % (args.days, whence))
        add("")
        for mid, frm, subj, mpath, kind, when in inputs:
            terms = key_terms(subj, freq, total)
            if len(terms) < 2:
                continue
            hits = []
            for name, text in texts.items():
                if is_hub(name):
                    continue
                low = text.lower()
                if not all(s in low for s, _ in terms):
                    continue
                rare = terms[0][0]
                for i, line in enumerate(text.splitlines(), 1):
                    if rare in line.lower():
                        hits.append((name, i, line.strip()))
                        break
            if not hits:
                continue
            marker = "письмо" if kind == "письмо" else "сообщение"
            ikey = item_key(subj[:200], "%s `%s`" % (marker, mid))
            if ikey in carried_keys:
                continue  # уже показан выше как перенесённый — второй раз не предъявляем
            if ikey in closed_ext and when <= closed_ext[ikey]:
                continue  # закрыт и с тех пор не менялся: окно отступило назад, повторять нечего
            if ext_n >= args.ext_limit:
                ext_over += 1
                ext_cut = when if not ext_cut else min(ext_cut, when)
                continue
            n += 1
            ext_n += 1
            weak = "~ " if len(terms) < 3 else ""
            title = "Пришло: %s" % subj[:200] if kind == "письмо" else \
                    "Сказал человек (%s): %s" % (frm, subj[:200])
            add("### %sП%d. %s" % (weak, n, title))
            m_line = mark(("mail:" if kind == "письмо" else "msg:") + mid)
            if m_line:
                add(m_line.rstrip("\n"))
            add("- от: `%s`, %s `%s`" % (frm, marker, mid))
            add("- источник целиком: `%s`" % mpath)
            add("- опознано по словам: %s" % ", ".join(w for _, w in terms))
            add("- в памяти об этом же:")
            for name, i, line in hits[:6]:
                add("  - `%s:%d` — %s" % (name, i, line[:180]))
            if len(hits) > 6:
                add("  - … ещё %d мест" % (len(hits) - 6))
            add("- **исход:** ")
            add("")
        add("_итог: пунктов из внешнего входа — %d%s_"
            % (ext_n, (" (за порцией осталось %d — следующий проход начнёт с них)" % ext_over)
               if ext_over else ""))
        add("")

    # ── ВОЗРАСТ ─────────────────────────────────────────────────────────────────────────
    all_ages = ages(mem, files)
    # 🛑 Положительный признак вместо молчания: запись вне истории в вектор «вперёд» не попадёт
    # НИКОГДА, и без этой строки «возраст ничего не нашёл» неотличимо от «возраст не считается».
    untracked = [f.name for f, a, _ in all_ages if a is None]
    aged = [(f, a, how) for f, a, how in all_ages if a is not None and a > args.age_days]
    aged.sort(key=lambda x: -x[1])
    add("## Давно не подтверждалось (старше %.0f сут: %d; берём %d)"
        % (args.age_days, len(aged), min(len(aged), args.limit)))
    add("")
    add("Срок задаёт очередь, а не список: остальные придут следующими проходами.")
    if untracked:
        add("")
        add("⚠️ **Возраст НЕ СЧИТАЕТСЯ для %d записей — их нет в истории версий:** %s."
            % (len(untracked), ", ".join("`%s`" % u for u in untracked[:8])
               + (" и др." if len(untracked) > 8 else "")))
        add("Пока они не зафиксированы, в этот раздел они не попадут никогда.")
    add("")
    for f, a, how in aged[:args.limit]:
        n += 1
        first = ""
        for line in read(f).splitlines():
            if line.startswith("description:"):
                first = line[12:].strip().strip('"')
                break
        title = "`%s` — давно не подтверждалось" % f.name
        add("### П%d. %s (%.0f сут, %s)" % (n, title, a, how))
        m_line = mark("age:" + f.name)
        if m_line:
            add(m_line.rstrip("\n"))
        if first:
            add("- о чём: %s (это ФИЛЬТР, а не содержание — открой запись)" % first[:200])
        add("- **исход:** ")
        add("")
    add("_итог: пунктов из возраста — %d (в очереди ещё %d)_"
        % (min(len(aged), args.limit), max(0, len(aged) - args.limit)))
    add("")

    # ── ВНУТРИ ЗАПИСИ ───────────────────────────────────────────────────────────────────
    add("## Противоречие внутри записи: правка только добавляла, старое осталось")
    add("")
    ins_n = 0
    # 🛑 Проверяем только записи, правленные В ПОСЛЕДНЕМ коммите: вход по смыслу про свежую правку,
    # а `git log -p` на каждый файл корпуса стоил бы столько же, сколько весь остальной разбор.
    recent = set(x.strip() for x in git(mem, "show", "--name-only", "--pretty=format:").splitlines()
                 if x.strip().endswith(".md"))
    for f in files:
        if f.name not in recent:
            continue
        r = inside_record(mem, f, freq, total)
        if not r:
            continue
        terms, hits = r
        n += 1
        ins_n += 1
        title = "`%s`: последняя правка только добавляла" % f.name
        add("### ~ П%d. %s" % (n, title))
        m_line = mark("in:" + f.name)
        if m_line:
            add(m_line.rstrip("\n"))
        add("- опознано по словам: %s" % ", ".join(w for _, w in terms))
        add("- ниже в этом же файле о том же:")
        for i, line in hits[:4]:
            add("  - строка %d — %s" % (i, line[:180]))
        add("- **исход:** ")
        add("")
    add("_итог: пунктов изнутри записей — %d_" % ins_n)
    add("")

    # 🛑 Обороты сшивания вынесены в ОТДЕЛЬНЫЙ раздел и НЕ считаются пунктами наравне: на здоровом
    # корпусе они почти все законные (замер на памяти SS: 17 из 17). Поданные вперемешку с
    # настоящими пунктами, они приучают пролистывать весь список.
    add("## Слабые сигналы (не пункты): обороты, которыми противоречие сшивают")
    add("")
    add("Отвечать по ним не обязательно. Смотреть стоит, если рядом шла работа: на здоровой памяти"
        " эти обороты почти всегда законны.")
    add("")
    marker_seen = 0
    for name, text in sorted(texts.items()):
        if is_hub(name) or marker_seen >= args.limit:
            continue
        for i, line in enumerate(text.splitlines(), 1):
            low = line.lower()
            for marker in RECONCILE:
                if marker in low:
                    if marker_seen >= args.limit:
                        break
                    marker_seen += 1
                    add("- ~ `%s:%d` «%s» — %s" % (name, i, marker, line.strip()[:150]))
                    break
    add("")
    add("_слабых сигналов показано: %d_" % marker_seen)
    add("")
    add("---")
    add("ВСЕГО ПУНКТОВ: %d" % n)

    body = "\n".join(L) + "\n"
    if args.out:
        out = Path(args.out)
        out.parent.mkdir(parents=True, exist_ok=True)
        # 🛑 Пишем через временный файл: обрыв посреди записи уничтожал предыдущий список,
        # а в нём живут вписанные ролью исходы и весь перенос. os.replace атомарен и на Windows.
        tmp_out = out.with_suffix(out.suffix + ".tmp")
        io.open(tmp_out, "w", encoding="utf-8", newline="").write(body)
        os.replace(str(tmp_out), str(out))
        if args.mail or args.inbox:
            # Порция обрезала вход — отметка отступает к самому старому невошедшему.
            write_pass_stamp(args.out, role, min(started, ext_cut - 1) if ext_cut else started)
        print("REVISION: places=%d file=%s" % (n, out))
    else:
        print(body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
