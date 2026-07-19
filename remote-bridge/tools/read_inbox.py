# -*- coding: utf-8 -*-
"""Выдаёт цели новые сообщения владельца из журнала и двигает курсор.

    python read_inbox.py [--project-dir <path>] [--peek] [--max N]

--peek — показать без сдвига курсора. Карантин (quarantine-*.jsonl) не читается.
Курсор позиционный (файл+строка): переживает append-only дописывания транскриптов.

Модель доверия ОБРАТНА модели группового чата: сюда попадает только то, что прошло гард моста по
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


def collect_new(cursor: dict, limit: int | None):
    files = sorted(B.INBOX_DIR.glob("????-??-??.jsonl"))
    cur_file, cur_line = cursor.get("file", ""), cursor.get("line", 0)
    out, new_cursor = [], dict(cursor)
    prev_update_id = None
    for f in files:
        if f.name < cur_file:
            continue
        start = cur_line if f.name == cur_file else 0
        with f.open(encoding="utf-8") as fh:
            lines = fh.readlines()
        for idx in range(start, len(lines)):
            line = lines[idx].strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
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
                return out, new_cursor
        new_cursor = {"file": f.name, "line": len(lines),
                      "last_update_id": new_cursor.get("last_update_id", 0)}
    return out, new_cursor


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
    B.init_instance(args.project_dir)
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")

    cursor_path = B.STATE_DIR / "target-cursor.json"
    cursor = B.read_json(cursor_path, {"file": "", "line": 0, "last_update_id": 0})
    records, new_cursor = collect_new(cursor, args.max)
    if not records:
        print("Новых сообщений нет.")
        return 0

    print(BANNER_TOP)
    print(f"Сообщений: {len(records)}\n")
    for rec in records:
        print(fmt(rec))
        print()
    print(BANNER_BOTTOM)
    if not args.peek:
        B.write_json(cursor_path, new_cursor)
        print(f"(курсор сдвинут: {new_cursor['file']}:{new_cursor['line']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
