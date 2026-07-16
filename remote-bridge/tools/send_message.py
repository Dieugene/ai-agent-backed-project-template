"""Единственный разрешённый цели исходящий канал (граница доверия).

    python send_message.py [--project-dir <path>] --chat <chat_id> [--reply-to <mid>] --text-file <path>
    python send_message.py [--project-dir <path>] --chat <chat_id> --stdin

Токен читается внутри и не печатается. Текст — файлом/через stdin (не argv).
Куда можно слать: личка владельца (chat_id == owner user_id) ИЛИ chat_id из
allowed_chats конфига ИЛИ приватный чат, уже встречавшийся во входящем журнале.
Каждая отправка журналируется в outbox/. Rate-guard ~20 сообщений/мин.
Только sendMessage (+ sendChatAction «печатает…»).
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridgelib as B  # noqa: E402

TG_MAX = 4096
CHUNK = 4000
RATE_PER_MIN = 20


def chat_is_known_private(chat_id: int) -> bool:
    for f in sorted(B.INBOX_DIR.glob("????-??-??.jsonl")):
        with f.open(encoding="utf-8") as fh:
            for line in fh:
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if rec.get("chat", {}).get("id") == chat_id \
                        and rec["chat"].get("type") == "private":
                    return True
    return False


def chat_allowed(chat_id: int, cfg: dict, owner_id: int | None) -> bool:
    """Личка владельца (chat_id == owner id) + allowed_chats + известный приватный."""
    if chat_id in cfg.get("allowed_chats", []):
        return True
    if owner_id and chat_id == owner_id:
        return True
    return chat_is_known_private(chat_id)


def rate_exceeded() -> bool:
    path = B.OUTBOX_DIR / f"{B.today()}.jsonl"
    if not path.exists():
        return False
    cutoff = time.time() - 60
    recent = 0
    with path.open(encoding="utf-8") as fh:
        for line in fh:
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            if rec.get("unix_ts", 0) >= cutoff:
                recent += 1
    return recent >= RATE_PER_MIN


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-dir", default=None)
    ap.add_argument("--chat", type=int, required=True)
    ap.add_argument("--reply-to", type=int, default=None)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--text-file", type=Path)
    src.add_argument("--stdin", action="store_true")
    args = ap.parse_args()
    B.init_instance(args.project_dir)

    if args.stdin:
        text = sys.stdin.buffer.read().decode("utf-8")
    else:
        text = args.text_file.read_text(encoding="utf-8")
    text = text.strip()
    if not text:
        print("ERROR empty text", file=sys.stderr)
        return 1

    cfg, _ = B.load_config()
    owner_id = B.read_owner_id(cfg)
    if not chat_allowed(args.chat, cfg, owner_id):
        print(f"ERROR chat {args.chat} not in allowlist and not a known "
              f"private chat - refused", file=sys.stderr)
        return 1
    if rate_exceeded():
        print("ERROR rate limit (~20 msg/min) - try later", file=sys.stderr)
        return 1

    token = B.read_token()
    chunks = [text[i:i + CHUNK]
              for i in range(0, len(text), CHUNK)] if len(text) > TG_MAX else [text]
    for i, chunk in enumerate(chunks):
        params = {"chat_id": args.chat, "text": chunk}
        if args.reply_to and i == 0:
            params["reply_to_message_id"] = args.reply_to
        result = B.api_call(token, "sendMessage", params)
        B.journal_append(B.OUTBOX_DIR / f"{B.today()}.jsonl", {
            "ts": B.now_iso(),
            "unix_ts": time.time(),
            "chat_id": args.chat,
            "message_id": result.get("message_id"),
            "reply_to_message_id": params.get("reply_to_message_id"),
            "text": chunk,
            "initiator": "target",
        })
        print(f"OK message_id={result.get('message_id')} chat={args.chat}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except B.BridgeApiError as exc:
        print(f"ERROR {exc}", file=sys.stderr)
        sys.exit(1)
