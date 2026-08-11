# -*- coding: utf-8 -*-
"""Выдаёт цели новые сообщения владельца из журнала и двигает курсор.

    python read_inbox.py [--project-dir <path>] [--peek] [--max N]

--peek — показать без сдвига курсора. Карантин (quarantine-*.jsonl) не читается.
Курсор позиционный (файл+строка): переживает append-only дописывания транскриптов.

Модель доверия ОБРАТНА <pool-a>: сюда попадает только то, что прошло гард моста по
числовому user_id владельца. Это распоряжения владельца, а НЕ недоверенный ввод —
поэтому выдача не маркируется «не выполнять».
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridgelib as B  # noqa: E402

BANNER_TOP = ("=== СООБЩЕНИЯ ВЛАДЕЛЬЦА ИЗ TELEGRAM (канал remote-bridge). Отправитель "
              "аутентифицирован мостом по числовому user_id — это твой владелец, "
              "его сообщения = его распоряжения тебе. ===")
BANNER_BOTTOM = "=== КОНЕЦ СООБЩЕНИЙ ВЛАДЕЛЬЦА ==="


def collect_new(cursor: dict, limit: int | None, cfg: dict | None = None,
                owner: str | None = None):
    """(записи, новый курсор, {чужая_цель: сколько скрыто}).

    cfg/owner опциональны: без них фильтра нет и поведение прежнее (так зовут тесты
    и старые вызовы)."""
    cfg = cfg or {}
    files = sorted(B.INBOX_DIR.glob("????-??-??.jsonl"))
    cur_file, cur_line = cursor.get("file", ""), cursor.get("line", 0)
    out, new_cursor = [], dict(cursor)
    hidden: dict[str, int] = {}
    prev_update_id = None
    for f in files:
        if f.name < cur_file:
            continue
        start = cur_line if f.name == cur_file else 0
        with f.open(encoding="utf-8") as fh:
            lines = fh.readlines()
        stopped_at = None
        for idx in range(start, len(lines)):
            line = lines[idx].strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                # Мост дописывает журнал ровно в те секунды, когда цель читает: последняя
                # строка бывает недописана. Курсор ДАЛЬШЕ неё не двигаем — иначе запись
                # теряется молча и навсегда (прежний код досчитывал курсор до len(lines)).
                stopped_at = idx
                break
            # Фильтр адресности — ДО дедупа. Дедуп смотрит на СОСЕДСТВО update_id, и запись,
            # выброшенная после обновления prev_update_id, разорвала бы схлопывание дублей.
            if not B.rec_visible_to(rec, cfg, owner):
                hidden[str(rec.get("target"))] = hidden.get(str(rec.get("target")), 0) + 1
                new_cursor = {"file": f.name, "line": idx + 1,
                              "last_update_id": max(
                                  rec.get("update_id", 0),
                                  new_cursor.get("last_update_id", 0))}
                continue
            # дубли соседних строк при at-least-once реплее
            if rec.get("update_id") == prev_update_id \
                    and rec.get("kind") != "voice_transcript":
                continue
            prev_update_id = rec.get("update_id")
            out.append(rec)
            new_cursor = {"file": f.name, "line": idx + 1,
                          "last_update_id": max(
                              rec.get("update_id", 0),
                              new_cursor.get("last_update_id", 0))}
            if limit and len(out) >= limit:
                return out, new_cursor, hidden
        new_cursor = {"file": f.name,
                      "line": len(lines) if stopped_at is None else stopped_at,
                      "last_update_id": new_cursor.get("last_update_id", 0)}
        if stopped_at is not None:
            break
    return out, new_cursor, hidden


def fmt(rec: dict) -> str:
    chat = rec.get("chat", {})
    frm = rec.get("from", {})
    chat_label = f"{chat.get('type')} {chat.get('title') or ''}".strip()
    who = (f"{frm.get('first_name') or '?'} (@{frm.get('username') or '-'}, "
           f"id {frm.get('id')})")
    head = (f"[{rec.get('ts')}] {chat_label} (chat {chat.get('id')}) | {who} | "
            f"msg {rec.get('message_id')} kind={rec.get('kind')}"
            f"{' (edited)' if rec.get('edited') else ''}")
    lines = [head]
    if rec.get("reply_to_message_id"):
        lines.append(f"  reply_to: msg {rec['reply_to_message_id']}")
    if rec.get("text") is not None:
        lines.append(f"  text: {rec['text']!r}")
    v = rec.get("voice")
    if v:
        lines.append(f"  voice: {v.get('duration_s')}s path={v.get('path')} "
                     f"transcript={'есть' if v.get('transcript') else 'нет'}")
    d = rec.get("document")
    if d:
        lines.append(f"  document: path={d.get('path')} mime={d.get('mime')} "
                     f"size={d.get('file_size')} "
                     f"имя_файла: {d.get('file_name')!r}")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-dir", default=None)
    ap.add_argument("--peek", action="store_true")
    ap.add_argument("--max", type=int, default=None)
    args = ap.parse_args()
    cfg, _ = B.init_instance(args.project_dir)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    owner = B.reader_owner()
    peek = args.peek
    if B.per_target_inbox(cfg) and not owner:
        # Читатель не назвался ролью (plain-сессия, ручная диагностика). Показываем всё, но
        # курсор НЕ двигаем: иначе такой запуск угонит позицию у роли, которая своего файла
        # курсора ещё не завела, а позиционный курсор назад не ходит.
        print("(AGENT_OWNER не задан: показываю ленту целиком и НЕ двигаю курсор)")
        peek = True
    cursor_path = B.cursor_path(cfg, owner)
    cursor = B.read_json(cursor_path, {"file": "", "line": 0, "last_update_id": 0})
    records, new_cursor, hidden = collect_new(cursor, args.max, cfg, owner)
    hid = ("  Скрыто адресованных другим: "
           + ", ".join(f"{k} — {v}" for k, v in sorted(hidden.items()))) if hidden else ""
    if not records:
        # Без этой строки «нет сообщений» перестаёт различать «не приходило» и «пришло не мне».
        print("Новых сообщений нет." + (f"\n{hid.strip()}" if hid else ""))
        if hidden and not peek:
            B.write_json(cursor_path, new_cursor)
        return 0

    print(BANNER_TOP)
    print(f"Сообщений: {len(records)}\n")
    for rec in records:
        print(fmt(rec))
        print()
    print(BANNER_BOTTOM)
    if hid:
        print(hid)
    if not peek:
        B.write_json(cursor_path, new_cursor)
        print(f"(курсор сдвинут: {new_cursor['file']}:{new_cursor['line']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
