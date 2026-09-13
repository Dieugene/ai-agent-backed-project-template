#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сбор обязательств с шины пула — § 4 спецификации `pool-bus/spec-obligations.md`.

    python3 shop_oblig.py --bus <шина> [--rebuild] [--verbose]
    python3 shop_oblig.py --all [--rebuild]

Что делает: читает ШАПКИ писем (тело не открывается) и ведёт индекс
`<шина>/.obligations/index.json` — кто что открыл, что привязано, что закрыто и с каким исходом.

🛑 Индекс — КЭШ поверх писем, а не хранилище. Ничего, чего нет в письмах, он не держит;
`--rebuild` собирает его заново по всему архиву — это штатная операция, а не восстановление
после аварии. Отсюда же следует, что потеря индекса ничего не стоит.

🛑 На этом шаге модуль НИЧЕГО НЕ ОТПРАВЛЯЕТ. Кривые ключи и коллизии копятся в разделе `bad`;
адресные письма автору — следующий шаг, после обкатки сбора.

⚠️ Имя файла с подчёркиванием (не `shop-oblig.py`, как соседи) — намеренно: модуль импортируется
из `shop-flood.py`, а имя с дефисом импортировать нельзя.

⚠️ Шапку разбираем СВОИМ разбором, а не общим `header()` антифлуда: у того ранний выход по трём
ключам, и до строк обязательств он не доходит вовсе. Трогать его — риск для живого антифлуда,
поэтому здесь свой, с остановкой на конце таблицы.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import datetime, timedelta, timezone

MSK = timezone(timedelta(hours=3))          # цех живёт по Москве, машина — по Берлину
KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,63}$")
MSG_RE = re.compile(r"^(?P<id>\d{13}-[0-9a-f]{10})\.from-(?P<from>[^.]+)\.(?P<kind>[^.]+?)"
                    r"(\.\d+\.\d+)?\.md$")
HDR_RE = re.compile(r"^\|\s*(From|FromPool|To|Opens|Expect|CloseWhen|About|Amends|Closes|Outcome)\s*\|\s*(.*?)\s*\|\s*$")

KEEP_CLOSED = 200      # закрытые держим хвостом: они нужны для свода за окно, не вечно
KEEP_BAD = 100
MAX_HEAD_LINES = 40


def now_msk_iso() -> str:
    return datetime.now(MSK).isoformat(timespec="seconds")


def head(path: str) -> dict:
    """Шапка письма. Тело не читается: разбор кончается на первой строке после таблицы.

    ⚠️ Без этой остановки источником полей стало бы ТЕЛО: письма в шине сплошь содержат
    markdown-таблицы, и строка `| About | … |` в тексте подделала бы привязку.
    """
    h = {}
    in_table = False
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > MAX_HEAD_LINES:
                    break
                line = line.rstrip("\n")
                if line.startswith("|"):
                    in_table = True
                elif in_table:
                    break
                m = HDR_RE.match(line)
                if m:
                    # Обратная замена ровно одна: движок экранирует только вертикальную черту.
                    h[m.group(1)] = m.group(2).replace("\\|", "|")
    except OSError:
        pass
    return h


def letters(bus: str):
    """Все письма шины: ящики (new/cur) + общий архив. Возвращает (id, path, from, kind)."""
    out = []
    try:
        entries = list(os.scandir(bus))
    except OSError:
        return out
    for d in entries:
        if not d.is_dir() or d.name.startswith("."):
            continue
        subs = [d.path] if d.name == "archive" else [os.path.join(d.path, s)
                                                     for s in ("new", "cur")]
        for sub in subs:
            try:
                with os.scandir(sub) as it:
                    for f in it:
                        m = MSG_RE.match(f.name)
                        if m and f.is_file():
                            out.append((m.group("id"), f.path, m.group("from"), m.group("kind")))
            except OSError:
                continue
    out.sort(key=lambda r: r[0])
    return out


def empty_index() -> dict:
    return {"generated_at": now_msk_iso(), "cursor": "", "open": [], "closed": [], "bad": []}


def load_index(bus: str) -> dict:
    p = os.path.join(bus, ".obligations", "index.json")
    try:
        with open(p, encoding="utf-8") as f:
            ix = json.load(f)
        if not isinstance(ix, dict):
            raise ValueError("индекс не словарь")
        for k, default in (("cursor", ""), ("open", []), ("closed", []), ("bad", [])):
            ix.setdefault(k, default)
        if not isinstance(ix["open"], list) or not isinstance(ix["closed"], list) \
                or not isinstance(ix["bad"], list) or not isinstance(ix["cursor"], str):
            raise ValueError("индекс испорчен")
        return ix
    except Exception:
        return empty_index()      # испорченный кэш = собрать заново, а не упасть


def save_index(bus: str, ix: dict) -> None:
    d = os.path.join(bus, ".obligations")
    os.makedirs(d, exist_ok=True)
    p = os.path.join(d, "index.json")
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(ix, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, p)            # читатель (`pool mine`) никогда не видит половину файла


def ts_of(mid: str) -> str:
    try:
        ms = int(mid.split("-", 1)[0])
        return datetime.fromtimestamp(ms / 1000, MSK).isoformat(timespec="seconds")
    except Exception:
        return ""


def note_bad(ix: dict, key: str, who: str, reason: str, mid: str) -> None:
    ix["bad"].append({"key": key[:80], "from": who, "reason": reason, "msg": mid,
                      "ts": ts_of(mid)})
    del ix["bad"][:-KEEP_BAD]


def apply_letter(ix: dict, mid: str, sender: str, h: dict) -> bool:
    """Применяет одно письмо к индексу. -> было ли изменение."""
    changed = False
    frm = h.get("From") or sender
    to = h.get("To") or ""
    by_key = {o["key"]: o for o in ix["open"]}

    opens = h.get("Opens")
    if opens:
        if not KEY_RE.match(opens):
            note_bad(ix, opens, frm, "ключ не по форме (латиница, цифры, дефис)", mid)
        elif opens in by_key:
            note_bad(ix, opens, frm, "ключ уже открыт", mid)
        else:
            ix["open"].append({"key": opens, "from": frm, "to": to,
                               # Пул отправителя, если письмо пришло из чужого пула. Пусто —
                               # значит открывали внутри этой же шины, и роль ищется здесь.
                               "from_pool": h.get("FromPool", ""),
                               "expect": h.get("Expect", ""),
                               "close_when": h.get("CloseWhen", ""),
                               "opened": ts_of(mid), "opened_msg": mid, "letters": 0})
        changed = True

    about = h.get("About")
    if about:
        if about in by_key:
            by_key[about]["letters"] = by_key[about].get("letters", 0) + 1
        else:
            # Работа, пришедшая в УЖЕ ЗАКРЫТЫЙ ключ, — не кривая привязка, а отдельный случай:
            # у lead пула pool-stand после закрытия пришло исправление, без которого в документ
            # уехал бы факт, неверный на шесть дней. Подавлять такое нельзя, значит надо
            # называть своим именем и считать — иначе оно теряется в общей куче кривых ключей.
            closed_all = ix.get("closed") or []
            closed_rec = next((c for c in closed_all
                               if isinstance(c, dict) and c.get("key") == about), None)
            if closed_rec is not None:
                closed_rec["after_close"] = closed_rec.get("after_close", 0) + 1
                closed_rec["after_close_last"] = mid
                note_bad(ix, about, frm, "работа в ЗАКРЫТЫЙ ключ (закрыт %s)"
                         % (closed_rec.get("closed") or "?"), mid)
            else:
                note_bad(ix, about, frm, "привязка к неизвестному ключу", mid)
        changed = True

    amends = h.get("Amends")
    if amends:
        # Правку формулировки вносит ТОЛЬКО открывший: иначе один участник переписывал бы
        # условие, по которому принимает другой. Движок этого не проверяет — проверка здесь,
        # где виден весь реестр.
        rec = by_key.get(amends)
        if rec is None:
            note_bad(ix, amends, frm, "правка неизвестного или уже закрытого ключа", mid)
        elif rec.get("from") != frm:
            note_bad(ix, amends, frm, "правку внёс не открывший (открыл %s)" % rec.get("from"), mid)
        else:
            if h.get("Expect"):
                rec["expect"] = h["Expect"]
            if h.get("CloseWhen"):
                rec["close_when"] = h["CloseWhen"]
            rec["amended"] = ts_of(mid)
            rec["amended_msg"] = mid
        changed = True

    closes = h.get("Closes")
    if closes:
        outcome = (h.get("Outcome") or "").strip().lower()
        if outcome not in ("fulfilled", "withdrawn"):
            note_bad(ix, closes, frm, "исход не назван или неизвестен: %r" % outcome[:20], mid)
        if closes in by_key:
            rec = by_key[closes]
            ix["open"] = [o for o in ix["open"] if o["key"] != closes]
            rec.update({"outcome": outcome or "unknown", "closed": ts_of(mid),
                        "closed_msg": mid, "closed_by": frm})
            ix["closed"].append(rec)
            del ix["closed"][:-KEEP_CLOSED]
        else:
            note_bad(ix, closes, frm, "закрытие неизвестного или уже закрытого ключа", mid)
        changed = True

    return changed


def pass_bus(bus: str, rebuild: bool = False, verbose: bool = False) -> dict:
    """Один проход по шине. Возвращает индекс (уже записанный)."""
    ix = empty_index() if rebuild else load_index(bus)
    cursor = ix.get("cursor", "")
    seen = 0
    for mid, path, sender, kind in letters(bus):
        if cursor and mid <= cursor:
            continue
        h = head(path)
        if h.get("Opens") or h.get("About") or h.get("Closes") or h.get("Amends"):
            apply_letter(ix, mid, sender, h)
        if mid > cursor:
            cursor = mid
        seen += 1
    ix["cursor"] = cursor
    # Штамп ставится КАЖДЫЙ проход, даже когда ничего не изменилось: по нему читатель судит,
    # жив ли сбор, и без обновления он читал бы старый список как свежий.
    ix["generated_at"] = now_msk_iso()
    save_index(bus, ix)
    if verbose:
        print("%s: новых писем %d, открыто %d, закрыто %d, кривых %d"
              % (bus, seen, len(ix["open"]), len(ix["closed"]), len(ix["bad"])))
    return ix


def bus_slug(bus: str) -> str:
    """Имя пула для показа роли. Берём из манифеста: там оно и есть имя пула. Эвристика по
    пути врёт на пулах верхнего уровня — выдаёт «workspace/pool-B» и «workspace/.launcher»,
    а роль читает ярлык как имя пула и по нему решает, куда идти закрывать."""
    d = os.path.dirname(os.path.abspath(bus))
    try:
        with open(os.path.join(d, "pool.manifest.json"), encoding="utf-8") as f:
            slug = (json.load(f) or {}).get("slug")
        if slug:
            return str(slug)
    except (OSError, ValueError):
        pass
    return os.path.basename(d) or bus


def mailbox_owners(bus: str):
    """Роли, у которых в этой шине есть ящик. Признак ящика — подкаталог `new` внутри:
    по одному лишь «каталог не с точки» в роли попали бы корневой ящик шины (`<шина>/new`,
    куда падает почта с пустым адресатом), витрины и любой служебный каталог, заведённый
    завтра."""
    out = []
    try:
        for d in os.scandir(bus):
            if (d.is_dir() and not d.name.startswith(".") and d.name != "archive"
                    and os.path.isdir(os.path.join(bus, d.name, "new"))):
                out.append(d.name)
    except OSError:
        pass
    return out


def write_cross(buses, collected: dict) -> None:
    """Для каждой шины — обязательства её ролей, живущие в ДРУГИХ шинах.

    Пишется в `.obligations/cross.json` той шины, где у роли есть ящик: движку не нужно
    знать ни путей соседей, ни того, сколько их. Файл — кэш поверх чужих индексов, как и
    сам индекс: потеря ничего не стоит, следующий проход соберёт заново.
    """
    homes = {}                                   # роль -> [шины, где у неё ящик]
    for bus in buses:
        for role in mailbox_owners(bus):
            homes.setdefault(role, []).append(bus)
    ambiguous = sorted(r for r, hs in homes.items() if len(hs) > 1)
    if ambiguous:
        print("cross: имена в нескольких шинах (%s) — по ним сводка идёт только из писем "
              "с полем FromPool; безадресные пропускаются" % ", ".join(ambiguous),
              file=sys.stderr)

    # ⚠️ Раскладка строится по ВСЕМ шинам, а не только по тем, чей проход удался: иначе шина,
    # на которой обходчик упал, вечно хранила бы старую сводку, и роль читала бы закрытое
    # месяц назад как открытое.
    by_slug = {}
    for b in buses:
        by_slug.setdefault(bus_slug(b), b)

    rows_by_bus = {bus: {} for bus in buses}
    for bus, ix in collected.items():
        slug = bus_slug(bus)
        boxes_here = set(mailbox_owners(bus))
        for o in ix.get("open") or []:
            if not isinstance(o, dict):
                continue
            for role in (o.get("from"), o.get("to")):
                if not role:
                    continue
                # Адрес отправителя квалифицирован — этого достаточно: письмо само называет
                # свой пул, и однофамилец в этой шине больше ничего не решает.
                fp = o.get("from_pool") if role == o.get("from") else ""
                if fp and fp in by_slug and by_slug[fp] != bus:
                    where = [by_slug[fp]]
                else:
                    if role in boxes_here:
                        continue                  # ящик в этой же шине — видно обычным сводом
                    # Безадресное письмо: прежнее правило — кладём только тем, у кого ящик
                    # ровно один на весь цех. Ложная строка дороже пропущенной: роль пошла бы
                    # закрывать чужое.
                    where = homes.get(role, [])
                if len(where) != 1:
                    continue
                row = dict(o)
                row["bus"] = slug
                rows_by_bus[where[0]].setdefault(role, []).append(row)

    for bus, by_role in rows_by_bus.items():
        d = os.path.join(bus, ".obligations")
        if not os.path.isdir(d):
            continue          # реестра тут нет — чужой каталог не заводим: он достался бы
                              # нашему пользователю, и обходчик самого пула потерял бы запись
        for role in by_role:
            by_role[role].sort(key=lambda r: (r.get("bus", ""), r.get("key", "")))
        try:
            p = os.path.join(d, "cross.json")
            # pid в имени: обход ходит раз в минуту и может в минуту не уложиться; два
            # одновременных прохода писали бы в один временный файл и склеили бы мусор.
            tmp = "%s.tmp.%d" % (p, os.getpid())
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump({"generated_at": now_msk_iso(), "roles": by_role}, f,
                          ensure_ascii=False)
                f.flush()
                os.fsync(f.fileno())
            os.chmod(tmp, 0o644)                  # читателю — роли — файл должен быть доступен
            os.replace(tmp, p)
        except OSError:
            continue                              # одна недоступная шина не роняет обход


SENDER = "pool-monitor"          # тот же отправитель, что у антифлуда: для роли это обвязка
MAX_LINES = 5                    # больше пяти замечаний в одном письме роль не прочтёт
MAX_FAILS = 3                    # столько раз пробуем достучаться, дальше запись закрываем
KEEP_SEEN = 2000
SEND_TIMEOUT_S = 20


def pool_cli():
    # переопределяется ради пробы: боевую отправку иначе не проверить, не разбудив живую роль
    return os.environ.get("POOL_CLI") or os.path.join(
        os.path.expanduser("~"), ".local", "bin", "pool")


def _fp(b) -> str:
    """Отпечаток замечания. Через формат, а не сложением: `msg` может прийти числом,
    и сложение строки с числом уронило бы весь фоновый обход."""
    return "%s|%s" % (b.get("msg"), b.get("reason", ""))


def notify_body(rows) -> str:
    """Письмо автору: что именно криво и что с этим делать. Машинный текст, короткий."""
    lines = ["По твоим письмам в шине разобрана форма обязательств. Замечания:", ""]
    for r in rows[:MAX_LINES]:
        lines.append("- ключ `%s`: %s" % (r.get("key", "?"), r.get("reason", "?")))
    if len(rows) > MAX_LINES:
        lines.append("- …и ещё %d того же рода." % (len(rows) - MAX_LINES))
    lines += [
        "",
        "Что с этим делать:",
        "- ключ не по форме — латиница, цифры и дефис, придумывает открывающий;",
        "- привязка к неизвестному ключу — обязательство не открывали либо ключ написан иначе;",
        "- работа в ЗАКРЫТЫЙ ключ — само письмо слать было правильно, но ключ закрыт рано:",
        "  открывай новое обязательство, а не дописывай в закрытое;",
        "- исход не назван — при закрытии нужен `-Outcome fulfilled` либо `withdrawn`;",
        "- правку формулировки вносит только тот, кто обязательство открыл.",
        "",
        "Правила целиком печатает скил `coordinating-on-the-pool-bus`.",
        "Отвечать на это письмо не нужно.",
    ]
    return "\n".join(lines) + "\n"


def notify_authors(bus: str, ix: dict, dry: bool = False):
    """Письма авторам по НОВЫМ записям раздела `bad`. Возвращает список (роль, сколько)."""
    cursor_path = os.path.join(bus, ".obligations", "notified.json")
    bad = [b for b in (ix.get("bad") or []) if isinstance(b, dict) and b.get("msg")]

    if not os.path.exists(cursor_path):
        # Засев: до первого включения замечания копились неделями. Рассылать их разом —
        # это письма про переписку, которую автор давно забыл, и по всем пулам сразу.
        if not dry:
            _save_state(cursor_path, [_fp(b) for b in bad], {})
        return []

    try:
        with open(cursor_path, encoding="utf-8") as f:
            state = json.load(f)
        if not isinstance(state, dict):
            raise ValueError("не словарь")
    except Exception as e:                       # noqa: BLE001
        # Молча начать «с чистого листа» нельзя: это рассылка всего заново каждую минуту.
        print("%s: notified.json нечитаем (%s) — писем не шлю" % (bus, e), file=sys.stderr)
        return []

    seen = [s for s in (state.get("seen") or []) if isinstance(s, str)]
    fails = state.get("fail") if isinstance(state.get("fail"), dict) else {}
    seen_set = set(seen)
    fresh = [b for b in bad if _fp(b) not in seen_set]
    if not fresh:
        return []

    by_role = {}
    for b in fresh:
        who = b.get("from")
        if isinstance(who, str) and who and not who.startswith(("pool-", "system", "migration")):
            by_role.setdefault(who, []).append(b)
    if not by_role:
        # Отпечатки служебных отправителей в seen не попадают никогда, поэтому без этого
        # выхода файл переписывался бы каждую минуту по каждой шине впустую.
        return []

    cli = pool_cli()
    if not dry and not os.path.exists(cli):
        print("%s: движка нет по пути %s — писем не шлю" % (bus, cli), file=sys.stderr)
        return []

    sent = []
    boxes = set(mailbox_owners(bus))
    for role, rows in sorted(by_role.items()):
        # одно письмо — один повод: две записи с тем же ключом и причиной это одна ошибка
        uniq, seen_pairs = [], set()
        for b in rows:
            pair = (b.get("key"), b.get("reason"))
            if pair not in seen_pairs:
                seen_pairs.add(pair)
                uniq.append(b)
        if dry:
            sent.append((role, len(uniq)))
            continue
        if role not in boxes:
            # Адресата в этой шине нет: имя пришло из шапки письма и может быть чужим или
            # с опечаткой. Молча закрываем записи — иначе отправка будет падать вечно.
            print("%s: адресата '%s' в шине нет, замечания закрываю без письма" % (bus, role),
                  file=sys.stderr)
            for b in rows:
                seen_set.add(_fp(b))
            seen.extend(_fp(b) for b in rows)
            _save_state(cursor_path, seen, fails)
            continue

        tmp = os.path.join(bus, ".obligations", "body-%s-%d.md" % (role, os.getpid()))
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(notify_body(uniq))
            r = subprocess.run([cli, "note", "-To", role, "-From", SENDER,
                                "-Subject", "форма обязательств: %d замечание(й)" % len(uniq),
                                "-BodyFile", tmp, "-BusRoot", bus],
                               capture_output=True, text=True, encoding="utf-8",
                               errors="replace", stdin=subprocess.DEVNULL,
                               timeout=SEND_TIMEOUT_S)
            rc, err = r.returncode, (r.stderr or "")
        except (OSError, subprocess.SubprocessError) as e:
            rc, err = 1, str(e)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass

        if rc != 0:
            n = int(fails.get(role, 0)) + 1
            print("%s: письмо %s не ушло (%d-я попытка): %s" % (bus, role, n, err[:200]),
                  file=sys.stderr)
            fails[role] = n
            if n >= MAX_FAILS:
                # Иначе одна недоставляемая запись держала бы попытку каждую минуту вечно.
                print("%s: %s недостижим %d раз, замечания закрываю" % (bus, role, n),
                      file=sys.stderr)
                for b in rows:
                    seen_set.add(_fp(b))
                    seen.append(_fp(b))
                fails.pop(role, None)
            _save_state(cursor_path, seen, fails)
            continue

        fails.pop(role, None)
        for b in rows:
            if _fp(b) not in seen_set:
                seen_set.add(_fp(b))
                seen.append(_fp(b))
        # Сохраняем ПОСЛЕ КАЖДОЙ роли: обрыв в середине цикла иначе повторил бы письма тем,
        # кому уже отправили.
        _save_state(cursor_path, seen, fails)
        sent.append((role, len(uniq)))
    return sent


def _save_state(path, seen, fails) -> bool:
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = "%s.tmp.%d" % (path, os.getpid())
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump({"seen": seen[-KEEP_SEEN:], "fail": fails}, f, ensure_ascii=False)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        return True
    except OSError as e:
        print("КУРСОР НЕ ЗАПИСАН (%s) — следующий проход ПОВТОРИТ письма" % e, file=sys.stderr)
        return False


def all_buses(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in ("_windows", "node_modules", ".git")]
        if "pool.manifest.json" in filenames:
            bus = os.path.join(dirpath, ".bus")
            if os.path.isdir(bus):
                yield bus


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--bus")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--root", default=os.path.expanduser("~/workspace"))  # корень, под которым лежат пулы (<workspace-root>)
    ap.add_argument("--rebuild", action="store_true")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--notify", action="store_true",
                    help="писать авторам о кривой форме (по умолчанию только индекс)")
    ap.add_argument("--notify-dry", action="store_true", dest="notify_dry",
                    help="показать, кому и сколько ушло бы, ничего не отправляя")
    args = ap.parse_args()

    if args.all:
        buses, collected = [], {}
        for bus in all_buses(args.root):
            buses.append(bus)
            try:
                ix = pass_bus(bus, args.rebuild, True)
                if isinstance(ix, dict):
                    collected[bus] = ix
                    # ⚠️ На пересборке НЕ шлём: `--rebuild` наполняет `bad` заново, и любая
                    # правка текста причины в разборе сделала бы все записи «новыми».
                    if (args.notify or args.notify_dry) and not args.rebuild:
                        for role, n in notify_authors(bus, ix, dry=args.notify_dry):
                            print("  -> %s: %s, замечаний %d"
                                  % (role, "ушло бы письмо" if args.notify_dry else "письмо автору", n))
            except Exception as e:                      # noqa: BLE001 — один пул не роняет обход
                print("%s: СБОЙ %s" % (bus, e), file=sys.stderr)
        try:
            write_cross(buses, collected)
        except Exception as e:                          # noqa: BLE001 — сводка не роняет сбор
            print("cross: СБОЙ %s" % e, file=sys.stderr)
        return 0
    if not args.bus:
        ap.error("нужен --bus или --all")
    pass_bus(args.bus, args.rebuild, args.verbose or True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
