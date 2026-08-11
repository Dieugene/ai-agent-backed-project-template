"""remote-bridge: Telegram <-> живая Claude-сессия в режиме УДАЛЁННОГО ПУЛЬТА.

Пишет ТОЛЬКО доверенный владелец в личку (модель доверия инвертирована vs <pool-a>,
где ~15 недоверенных людей в группе). Гард = один числовой user_id (allowlist-of-one),
с TOFU (первое ЛС фиксирует владельца). Каждое сообщение владельца будит цель.

Запуск: python bridge.py [--project-dir <path>]  (обычно через run-bridge.ps1).
Exit codes: 0 — штатно (Ctrl+C); 1 — нештатный сбой (runner перезапустит);
2 — фатально, НЕ перезапускать (второй поллер 409 / живой lock / pool без манифеста).
Токен «не задан» -> движок ЖДЁТ (лог+backoff), НЕ падает и НЕ спамит.

Модель доверия: гард пропускает только владельца, поэтому его сообщения — РАСПОРЯЖЕНИЯ
цели (не «недоверенный ввод», как в <pool-a>). Сам движок текст не интерпретирует —
не eval'ит и не подставляет в shell/пути/SQL: это свойство транспорта, а не цензура
владельца. ПОСЛАБЛЕНИЕ в парсинге: закрытый словарь управляющих входов (слэш-команды +
callback_data), но ТОЛЬКО от аутентифицированного владельца и ТОЛЬКО по точному
совпадению; любой несовпавший текст едет цели нетронутым.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import bridgelib as B

EXIT_FATAL = 2
POLL_TIMEOUT_S = 50
LOCK_STALE_S = 120

COMMANDS = ("/switch", "/start")  # закрытый словарь управляющих слэш-команд (/start — глотаем, см. process_updates)

SERVICE_FIELDS = (
    "new_chat_members", "left_chat_member", "new_chat_title", "new_chat_photo",
    "pinned_message", "group_chat_created", "message_auto_delete_timer_changed",
)

# Оверрайдимо тестами; иначе берётся из B.STATE_DIR в рантайме.
SENTINEL_LOCK = None

log = logging.getLogger("remote-bridge")


def _state(name: str) -> Path:
    return B.STATE_DIR / name


# ---------------------------------------------------------------- логирование

def setup_logging() -> None:
    B.LOG_DIR.mkdir(parents=True, exist_ok=True)
    handler = logging.FileHandler(
        B.LOG_DIR / f"bridge-{B.today()}.log", encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    console = logging.StreamHandler(sys.stderr)
    console.setFormatter(handler.formatter)
    logging.basicConfig(level=logging.INFO, handlers=[handler, console])


# ---------------------------------------------------------------------- lock

def acquire_lock() -> None:
    lock_path = _state("bridge.lock")
    lock = B.read_json(lock_path, None)
    if lock and lock.get("pid") != os.getpid() \
            and time.time() - lock.get("ts", 0) < LOCK_STALE_S:
        if B.pid_alive(lock.get("pid", -1)):
            log.error("another bridge holds fresh lock (pid=%s) - exiting", lock.get("pid"))
            sys.exit(EXIT_FATAL)
        log.warning("lock pid=%s is dead (fresh ts) - taking over", lock.get("pid"))
    heartbeat()


def heartbeat() -> None:
    B.write_json(_state("bridge.lock"), {"pid": os.getpid(), "ts": time.time()})


# ---------------------------------------------------------------- манифест/цели

def manifest_roles(manifest: dict | None) -> list[dict]:
    if not manifest:
        return []
    return [r for r in (manifest.get("roles") or []) if r.get("owner")]


def role_title(manifest: dict | None, owner: str) -> str | None:
    for r in manifest_roles(manifest):
        if r.get("owner") == owner:
            return r.get("title") or owner
    return None


def target_owners(cfg: dict, manifest: dict | None) -> set[str]:
    """Валидные цели (закрытый словарь для callback_data)."""
    if manifest:
        return {r["owner"] for r in manifest_roles(manifest)}
    dt = cfg.get("default_target")
    return {dt} if dt else set()


def default_target(cfg: dict, manifest: dict | None) -> str | None:
    """Дефолт текущей цели при первом старте: cfg.default_target -> lead -> первая роль."""
    dt = cfg.get("default_target")
    if dt:
        return dt
    if manifest:
        if manifest.get("lead"):
            return manifest["lead"]
        roles = manifest_roles(manifest)
        if roles:
            return roles[0]["owner"]
    return None


# ------------------------------------------------- закрытый словарь управляющих входов

def is_control_command(text) -> str | None:
    """Точное совпадение (не NLP): вся trim'нутая строка = /cmd или /cmd@bot, cmd в COMMANDS.
    Любой другой текст (в т.ч. '/switch now', 'hello /switch') -> None (едет цели как данные)."""
    if not isinstance(text, str):
        return None
    m = re.fullmatch(r"(/[A-Za-z][A-Za-z0-9_]*)(@[A-Za-z0-9_]+)?", text.strip())
    if not m:
        return None
    cmd = m.group(1).lower()
    return cmd if cmd in COMMANDS else None


def parse_callback_data(data, valid_owners) -> str | None:
    """callback_data = 'to:<owner>'; owner должен быть в valid_owners (закрытый словарь)."""
    if not isinstance(data, str) or not data.startswith("to:"):
        return None
    owner = data[3:]
    return owner if owner in valid_owners else None


# ----------------------------------------------------------------- нормализация

def detect_kind(msg: dict) -> str:
    if any(k in msg for k in SERVICE_FIELDS):
        return "service"
    for kind in ("voice", "photo", "document", "sticker"):
        if kind in msg:
            return kind
    if "text" in msg:
        return "text"
    return "other"


def normalize(update: dict, cfg: dict) -> dict | None:
    """update -> нормализованная запись журнала. None — не сообщение.
    Один владелец, личка: без is_privileged/wake_class группового кейса."""
    msg = update.get("message") or update.get("edited_message")
    if msg is None:
        return None
    chat = msg.get("chat", {})
    frm = msg.get("from", {})
    text = msg.get("text") or msg.get("caption")
    if isinstance(text, str) and len(text) > B.MAX_TEXT_CHARS:
        text = text[:B.MAX_TEXT_CHARS]
    document = None
    if "document" in msg:
        d = msg["document"]
        document = {
            "file_id": d.get("file_id"),
            "file_unique_id": d.get("file_unique_id"),
            "file_name": d.get("file_name"),   # оригинал — ДАННЫЕ, в пути не идёт
            "mime": d.get("mime_type"),
            "file_size": d.get("file_size"),
            "path": None,
        }
    elif "photo" in msg and (msg.get("caption") or "").strip():
        p = max(msg["photo"], key=lambda x: x.get("file_size") or 0)
        document = {
            "file_id": p.get("file_id"),
            "file_unique_id": p.get("file_unique_id"),
            "file_name": None,
            "mime": "image/jpeg",
            "file_size": p.get("file_size"),
            "path": None,
        }
    voice = None
    if "voice" in msg:
        voice = {
            "file_id": msg["voice"].get("file_id"),
            "file_unique_id": msg["voice"].get("file_unique_id"),
            "file_size": msg["voice"].get("file_size"),
            "duration_s": msg["voice"].get("duration"),
            "path": None,
            "transcript": None,
            "transcript_provider": None,
        }
    return {
        "ts": B.now_iso(),
        "tg_date": msg.get("date"),
        "update_id": update["update_id"],
        "edited": "edited_message" in update,
        "chat": {
            "id": chat.get("id"),
            "type": chat.get("type"),
            "title": chat.get("title") or None,
        },
        "from": {
            "id": frm.get("id"),
            "username": frm.get("username") or None,
            "first_name": frm.get("first_name") or None,
        },
        "message_id": msg.get("message_id"),
        "kind": detect_kind(msg),
        "text": text,
        "reply_to_message_id": (msg.get("reply_to_message") or {}).get("message_id"),
        "voice": voice,
        "document": document,
        "raw_kept": False,
    }


# ------------------------------------------------------------- файлы (media)

def safe_ext(document: dict) -> str:
    """Расширение для имени на диске. Имя файла приходит по сети, поэтому в путь его не
    пускаем (это не про недоверие к владельцу, а про то, чтобы имя не стало путём):
    берём только суффикс строго .[A-Za-z0-9]{1,8}, иначе по mime, иначе .bin.
    Оригинал имени сохраняется полем журнала и показывается цели."""
    import mimetypes
    name = document.get("file_name") or ""
    suffix = Path(name).suffix if name else ""
    if re.fullmatch(r"\.[A-Za-z0-9]{1,8}", suffix):
        return suffix.lower()
    guessed = mimetypes.guess_extension(document.get("mime") or "") or ""
    if re.fullmatch(r"\.[A-Za-z0-9]{1,8}", guessed):
        return guessed
    return ".bin"


def fetch_document(token: str, rec: dict) -> None:
    """Скачивает document/photo в media/. Имя = file_unique_id + безопасное расширение.
    Ошибка — факт в лог, движок живёт."""
    d = rec["document"]
    if (d.get("file_size") or 0) > B.MAX_FILE_BYTES:
        log.warning("document update_id=%s exceeds 20MB - skipped download", rec["update_id"])
        return
    try:
        info = B.api_call(token, "getFile", {"file_id": d["file_id"]})
        dest_dir = B.MEDIA_DIR / B.today()
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / f"{d['file_unique_id']}{safe_ext(d)}"
        B.download_file(token, info["file_path"], dest)
        d["path"] = str(dest.relative_to(B.DATA)).replace("\\", "/")
    except B.BridgeApiError as exc:
        log.warning("document download failed update_id=%s: %s", rec["update_id"], exc)


def transcribe_voice(rec: dict, cfg: dict) -> None:
    """Слот STT: транскрипт — отдельной append-записью voice_transcript."""
    if cfg.get("stt", {}).get("provider", "none") == "none":
        return
    v = rec["voice"]
    if not v.get("path"):
        return
    from stt import provider as stt_provider
    text, provider_name = stt_provider.transcribe(B.DATA / v["path"], cfg)
    if text is None:
        return
    # Метку берём ИЗ rec, а не перечитываем состояние: между записью голосового и ответом
    # STT проходят секунды, за которые владелец успевает нажать /switch — и тогда текст
    # голосового уехал бы другой роли, а исходной осталась бы пустышка «transcript=нет».
    B.journal_append(B.INBOX_DIR / f"{B.today()}.jsonl", {
        "ts": B.now_iso(),
        "update_id": rec["update_id"],
        "target": rec.get("target"),
        "kind": "voice_transcript",
        "chat": rec["chat"],
        "from": rec["from"],
        "message_id": rec["message_id"],
        "text": text[:B.MAX_TEXT_CHARS],
        "transcript_provider": provider_name,
    })
    log.info("voice transcribed update_id=%s via %s", rec["update_id"], provider_name)


def fetch_voice(token: str, rec: dict) -> None:
    """Скачивает voice в media/. Имя — только из file_unique_id. Ошибка — факт в лог."""
    v = rec["voice"]
    if (v.get("file_size") or 0) > B.MAX_FILE_BYTES:
        log.warning("voice update_id=%s exceeds 20MB - skipped download", rec["update_id"])
        return
    try:
        info = B.api_call(token, "getFile", {"file_id": v["file_id"]})
        dest_dir = B.MEDIA_DIR / B.today()
        dest_dir.mkdir(parents=True, exist_ok=True)
        dest = dest_dir / f"{v['file_unique_id']}.oga"
        B.download_file(token, info["file_path"], dest)
        v["path"] = str(dest.relative_to(B.DATA)).replace("\\", "/")
    except B.BridgeApiError as exc:
        log.warning("voice download failed update_id=%s: %s", rec["update_id"], exc)


# ----------------------------------------------------------------------- wake

def scan_unread(cursor_uid: int, cfg: dict | None = None,
                target: str | None = None) -> tuple[int, int]:
    """(count, max_update_id) непрочитанных записей основного inbox (карантин мимо),
    дедуп по update_id (voice_transcript делит update_id с оригиналом -> считается раз).

    При включённой адресной ленте считаем только адресованное ЦЕЛИ: иначе побудка
    докладывает «unread=23», а цель, прочитав, видит «новых нет», и условие догона
    `cursor >= tail_at_wake` не выполняется больше никогда — дебаунс начинает давить
    первое же сообщение после простоя, ради которого тихий старт и делался."""
    seen: set[int] = set()
    count = 0
    max_uid = cursor_uid
    for f in sorted(B.INBOX_DIR.glob("????-??-??.jsonl")):
        try:
            lines = f.read_text(encoding="utf-8").splitlines()
        except OSError:
            continue
        for line in lines:
            line = line.strip()
            if not line:
                continue
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            uid = r.get("update_id", 0)
            if uid <= cursor_uid or uid in seen:
                continue
            if not B.rec_visible_to(r, cfg or {}, target):
                continue
            seen.add(uid)
            count += 1
            if uid > max_uid:
                max_uid = uid
    return count, max_uid


def should_wake(tail: int, cursor: int, wake_state: dict,
                debounce_s: float, now: float) -> bool:
    """«Тихий старт»: первое сообщение после того, как цель догнала журнал, будит
    сразу; дебаунс давит только последующие wake-note, пока цель отстаёт.
    Идемпотентность (баг 001-b): если с прошлого wake-note НОВОГО не пришло
    (tail не сдвинулся дальше tail_at_wake), НЕ будим — иначе цель, которая по
    роли не читает сырьё (курсор не двигается), ре-нагалась бы каждые debounce_s
    бесконечно."""
    if tail <= cursor:
        return False
    if tail <= wake_state.get("tail_at_wake", 0):
        return False
    caught_up_since_wake = cursor >= wake_state.get("tail_at_wake", 0)
    if not caught_up_since_wake \
            and now - wake_state.get("last_wake_ts", 0) < debounce_s:
        return False
    return True


def sentinel_alive() -> bool:
    """Жив ли chat_sentinel в сессии цели (по pid из lock)."""
    lock = SENTINEL_LOCK or _state("chat-sentinel.lock")
    lk = B.read_json(lock, None)
    if not lk or not lk.get("pid"):
        return False
    return B.pid_alive(lk["pid"])


def maybe_wake(cfg: dict, manifest: dict | None, force: bool = False) -> None:
    """РЕЗЕРВНЫЙ канал (только pool): wake-note в .bus-ящик ТЕКУЩЕЙ цели. Первичный
    канал — chat_sentinel. В сигнал идут ТОЛЬКО числа/причина, НИКАКОГО контента."""
    if cfg.get("mode") != "pool":
        return
    # Цель резолвим ДО подсчёта: при адресной ленте и курсор, и счётчик — её собственные.
    target = B.read_current_target(default_target(cfg, manifest))
    if not target:
        return
    cursor = B.read_json(B.cursor_path(cfg, target if B.per_target_inbox(cfg) else None),
                         {}).get("last_update_id", 0)
    count, max_uid = scan_unread(cursor, cfg, target)
    if count == 0:
        return
    wake_state = B.read_json(_state("wake.json"), {})
    now = time.time()
    if not (force or should_wake(max_uid, cursor, wake_state, cfg["wake_debounce_s"], now)):
        return
    reason = "new-degraded" if force else "new"
    cmd = [
        "powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", str(B.POOL_PS1), "note",
        "-To", target, "-From", "bridge", "-Wake",
        "-Subject", f"bridge: {count} new message(s)",
        "-Body", (f"unread={count} reason={reason}. Run: python "
                  r"C:\workspace-root\.launcher\pool-bus\remote-bridge\tools\read_inbox.py"),
        "-BusRoot", str(B.BUS_ROOT),
    ]
    try:
        res = subprocess.run(cmd, capture_output=True, timeout=60)
        if res.returncode == 0:
            B.write_json(_state("wake.json"), {"last_wake_ts": now, "tail_at_wake": max_uid})
            log.info("wake-note sent to %s (%s): unread=%s", target, reason, count)
        else:
            log.warning("wake-note failed rc=%s", res.returncode)
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.warning("wake-note failed: %s", type(exc).__name__)


# ------------------------------------------------- обработка (гард/TOFU/switch/journal)

def _quarantine(upd: dict, msg: dict) -> None:
    """Не-владелец: метаданные БЕЗ контента в quarantine-журнал (не будит, не в основной)."""
    frm = msg.get("from") or {}
    chat = msg.get("chat") or {}
    B.journal_append(B.INBOX_DIR / f"quarantine-{B.today()}.jsonl", {
        "ts": B.now_iso(),
        "update_id": upd.get("update_id"),
        "from_id": frm.get("id"),
        "chat_id": chat.get("id"),
        "chat_type": chat.get("type"),
        "kind": detect_kind(msg),   # только тип, без текста/медиа
    })


def handle_switch(send, chat_id, cfg: dict, manifest: dict | None, current_target: str | None) -> None:
    """/switch: инлайн-клавиатура (pool) или ответ 'solo' (solo)."""
    if cfg.get("mode") == "solo":
        tgt = cfg.get("default_target") or current_target
        send("sendMessage", {"chat_id": chat_id,
             "text": f"Режим solo: единственная цель — {tgt}. Переключаться не на что."})
        return
    buttons = []
    for r in manifest_roles(manifest):
        owner = r["owner"]
        title = r.get("title") or owner
        mark = "✓ " if owner == current_target else ""
        buttons.append([{"text": mark + title, "callback_data": f"to:{owner}"}])
    send("sendMessage", {
        "chat_id": chat_id,
        "text": "Кому писать? Текущая цель отмечена ✓.",
        "reply_markup": {"inline_keyboard": buttons},
    })


def handle_callback(cb: dict, send, cfg: dict, owner_id, valid_owners, manifest) -> str | None:
    """Нажатие инлайн-кнопки. Гард по callback_query.from.id. Возвращает новую цель/None."""
    frm = (cb.get("from") or {}).get("id")
    cb_id = cb.get("id")
    if owner_id is None or frm != owner_id:
        log.info("callback from non-owner id ignored (no content)")   # чужой — молча игнор
        return None
    target = parse_callback_data(cb.get("data"), valid_owners)
    msg = cb.get("message") or {}
    chat_id = (msg.get("chat") or {}).get("id")
    message_id = msg.get("message_id")
    if target is None:
        try:
            send("answerCallbackQuery", {"callback_query_id": cb_id, "text": "Неизвестная цель"})
        except B.BridgeApiError:
            pass
        return None
    B.write_current_target(target)
    title = role_title(manifest, target) or target
    try:
        send("answerCallbackQuery", {"callback_query_id": cb_id})   # снять «часики»
    except B.BridgeApiError:
        pass
    if chat_id and message_id:
        try:
            send("editMessageText", {"chat_id": chat_id, "message_id": message_id,
                 "text": f"✓ Теперь пишу: {title}"})
        except B.BridgeApiError:
            pass
    log.info("target switched to %s", target)
    return target


def process_updates(token: str, cfg: dict, updates: list[dict], bot: dict,
                    manifest: dict | None, send, state: dict, mode: str) -> bool:
    """Гард/TOFU/switch/журнал. state={'owner_id','current_target'} мутабелен.
    Возвращает had_new — был ли записан хоть один data-месседж владельца."""
    valid_owners = target_owners(cfg, manifest)
    had_new = False
    for upd in updates:
        cb = upd.get("callback_query")
        if cb is not None:
            new = handle_callback(cb, send, cfg, state["owner_id"], valid_owners, manifest)
            if new:
                state["current_target"] = new
            continue
        msg = upd.get("message") or upd.get("edited_message")
        if msg is None:
            continue
        frm_id = (msg.get("from") or {}).get("id")
        chat = msg.get("chat") or {}
        # TOFU: нет владельца + ЛС -> фиксируем отправителя, подтверждаем в чат
        if state["owner_id"] is None and chat.get("type") == "private" and frm_id:
            state["owner_id"] = B.bind_owner(frm_id)
            log.info("TOFU: owner bound from first private message")
            try:
                send("sendMessage", {"chat_id": chat.get("id"),
                     "text": "Канал привязан к тебе. Дальше слушаю только твои сообщения."})
            except B.BridgeApiError as exc:
                log.warning("TOFU confirm send failed: %s", exc)
        owner_id = state["owner_id"]
        if owner_id is None or frm_id != owner_id:
            _quarantine(upd, msg)
            log.info("non-owner update quarantined (no content, no wake)")
            continue
        # владелец: управляющая команда? (закрытый словарь, точное совпадение)
        cmd = is_control_command(msg.get("text"))
        if cmd == "/switch":
            handle_switch(send, chat.get("id"), cfg, manifest, state["current_target"])
            log.info("owner /switch handled (not journaled)")
            continue
        if cmd == "/start":
            # Telegram шлёт /start при открытии бота — глотаем: не журналируем, цель не будим.
            log.info("owner /start swallowed (not journaled, no wake)")
            continue
        # data-месседж -> нормализация + media + журнал
        rec = normalize(upd, cfg)
        if rec is None:
            continue
        if rec["kind"] == "voice":
            fetch_voice(token, rec)
        if rec.get("document"):
            fetch_document(token, rec)
        # Метка адресата ставится В МОМЕНТ ПРИХОДА и потом не меняется — это и есть
        # требование владельца: /switch делит поток по времени, а не перекидывает историю.
        # Пишем всегда (в solo безвредно: читатель метку игнорирует, пока флаг выключен).
        if state.get("current_target"):
            rec["target"] = state["current_target"]
        B.journal_append(B.INBOX_DIR / f"{B.today()}.jsonl", rec)
        if rec["kind"] == "voice":
            transcribe_voice(rec, cfg)
        had_new = True
        log.info("journaled update_id=%s kind=%s", rec["update_id"], rec["kind"])
    return had_new


# ------------------------------------------------------------------ main loop

def make_sender(token: str):
    def _send(method: str, params: dict):
        return B.api_call(token, method, params)
    return _send


def wait_for_token() -> str:
    """Токен «не задан» -> ждём (лог ОДИН раз + backoff), не падаем, не спамим."""
    backoff = 5
    logged = False
    while True:
        try:
            tok = B.read_token()
            if logged:
                log.info("token now present - starting")
            return tok
        except B.TokenNotSet:
            if not logged:
                log.warning("token not set (missing/empty/format) at %s - waiting quietly; "
                            "drop a valid token to start", B.TOKEN_PATH)
                logged = True
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


def get_me_retry(token: str) -> dict:
    backoff = 2
    while True:
        try:
            return B.api_call(token, "getMe")
        except B.BridgeApiError as exc:
            if exc.status == 409:
                raise
            log.warning("getMe failed (%s), retry in %ss", exc, backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--project-dir", default=None,
                    help="Корень инстанса (иначе REMOTE_BRIDGE_PROJECT_DIR / POOL_BUS_ROOT).")
    args = ap.parse_args()
    try:
        cfg, from_file = B.init_instance(args.project_dir)
    except RuntimeError as exc:
        print(f"FATAL: {exc}", file=sys.stderr)
        return EXIT_FATAL
    setup_logging()
    if not from_file:
        log.warning("config %s missing - defaults in effect (mode=pool, TOFU on)", B.CONFIG_PATH)

    mode = cfg.get("mode", "pool")
    manifest = B.load_manifest() if mode == "pool" else None
    if mode == "pool" and manifest is None:
        log.error("mode=pool but no pool.manifest.json at %s - fatal", B.MANIFEST_PATH)
        return EXIT_FATAL

    acquire_lock()
    token = wait_for_token()

    me = get_me_retry(token)
    bot = {"id": me.get("id"), "username": me.get("username")}
    log.info("remote-bridge up as @%s (id=%s) mode=%s", me.get("username"), me.get("id"), mode)

    try:
        B.api_call(token, "setMyCommands", {"commands": [
            {"command": "switch", "description": "Выбрать агента-адресата"}]})
    except B.BridgeApiError as exc:
        log.warning("setMyCommands failed: %s", exc)

    # Дефолт текущей цели -> в state-файл (нужен гейту и wake-note).
    if B.read_current_target(None) is None:
        dt = default_target(cfg, manifest)
        if dt:
            B.write_current_target(dt)
            log.info("current target initialized: %s", dt)

    state = {"owner_id": B.read_owner_id(cfg), "current_target": B.read_current_target(None)}
    send = make_sender(token)

    if "last_wake_ts" not in B.read_json(_state("wake.json"), {}):
        B.write_json(_state("wake.json"), {"last_wake_ts": time.time(), "tail_at_wake": 0})

    offset_path = _state("offset.txt")
    offset = int(offset_path.read_text().strip()) if offset_path.exists() else 0
    backoff = 1
    while True:
        try:
            updates = B.api_call(
                token, "getUpdates",
                {"offset": offset, "timeout": POLL_TIMEOUT_S,
                 "allowed_updates": ["message", "edited_message", "callback_query"]},
                timeout=POLL_TIMEOUT_S + 15)
        except B.BridgeApiError as exc:
            if exc.status == 409:
                log.error("409 Conflict: another poller uses this token - fatal")
                return EXIT_FATAL
            log.warning("poll error (%s), retry in %ss", exc, backoff)
            time.sleep(backoff)
            backoff = min(backoff * 2, 60)
            continue
        backoff = 1
        if updates:
            state["current_target"] = B.read_current_target(state.get("current_target"))
            sentinel_ok_before = sentinel_alive() if mode == "pool" else False
            had_new = process_updates(token, cfg, updates, bot, manifest, send, state, mode)
            offset = max(u["update_id"] for u in updates) + 1
            offset_path.parent.mkdir(parents=True, exist_ok=True)
            offset_path.write_text(str(offset))
            if mode == "pool" and had_new and not sentinel_ok_before:
                log.warning("chat_sentinel down before a new message - forcing backup wake-note")
                maybe_wake(cfg, manifest, force=True)
        if mode == "pool":
            maybe_wake(cfg, manifest)
        heartbeat()
        B.write_json(_state("bridge-health.json"), {
            "last_poll_ok": B.now_iso(), "offset": offset, "pid": os.getpid(),
            "mode": mode, "current_target": B.read_current_target(None),
            "sentinel_degraded": (not sentinel_alive()) if mode == "pool" else None,
        })


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        log.info("stopped by user")
        sys.exit(0)
    except Exception:  # noqa: BLE001 — падение должно попасть в лог-файл
        log.exception("unhandled error - exiting for runner restart")
        sys.exit(1)
