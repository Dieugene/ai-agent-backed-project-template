"""Общий движок remote-bridge: Telegram <-> живая Claude-сессия (удалённый пульт).

ОДНА копия кода на весь workspace (<workspace-root>\\.launcher\\pool-bus\\remote-bridge\\),
по образцу pool.ps1. Инстанс НЕ задаётся расположением кода — он задаётся окружением
(REMOTE_BRIDGE_PROJECT_DIR / POOL_BUS_ROOT) или аргументом --project-dir. Инстанс-раскладка:
    <project>/secrets/bot.token
    <project>/secrets/bridge-config.json
    <project>/secrets/.env              (OPENAI_API_KEY для STT)
    <project>/pool.manifest.json        (только mode=pool)
    <data>/inbox|outbox|media|state|bridge-logs   (<data> = <project>/03_data или cfg.data_dir)

Модель доверия: гард — allowlist-of-one по числовому user_id владельца, поэтому его
сообщения = его распоряжения цели (обратно team-live). Сам модуль текст не
интерпретирует и никогда не печатает токен (URL Bot API содержит токен — все сетевые
исключения санитизируются).
"""

from __future__ import annotations

import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Общий bus-CLI (для резервного wake-note в pool-режиме).
POOL_PS1 = Path(r"<workspace-root>\.launcher\pool-bus\pool.ps1")

MAX_TEXT_CHARS = 16 * 1024          # анти-DoS журнала (граница доверия)
MAX_FILE_BYTES = 20 * 1024 * 1024   # лимит getFile Bot API
# «Токен задан» = ^\d+:[A-Za-z0-9_-]{20,}$ . Не матчит -> считаем не заданным.
TOKEN_RE = re.compile(r"^\d+:[A-Za-z0-9_-]{20,}$")

CONFIG_DEFAULTS = {
    "mode": "pool",             # pool | solo
    "allowed_user_id": 0,       # числовой TG user_id владельца; 0/нет -> TOFU по первому ЛС
    "allowed_chats": [],        # доп. chat_id для send_message (личка владельца разрешена всегда)
    "default_target": None,     # pool: дефолт текущей цели (иначе lead манифеста); solo: фикс. цель (обязательна)
    "data_dir": None,           # solo: корень рантайм-данных; null -> <project>/03_data
    "stt": {"provider": "none"},  # none | openai | faster_whisper
    "wake_debounce_s": 60,      # дебаунс резервного wake-note (pool)
}

# --- Пути инстанса. Set by init_instance(); None до вызова. Тесты переопределяют напрямую.
PROJECT_DIR = None
DATA = None
SECRETS = None
BUS_ROOT = None
MANIFEST_PATH = None
INBOX_DIR = None
OUTBOX_DIR = None
MEDIA_DIR = None
STATE_DIR = None
LOG_DIR = None
CONFIG_PATH = None
TOKEN_PATH = None
ENV_PATH = None


class TokenNotSet(Exception):
    """Токен не задан/пуст/не проходит формат. Сообщение НЕ содержит значение токена."""


class BridgeApiError(Exception):
    """Ошибка Bot API. Сообщение гарантированно не содержит токен."""

    def __init__(self, method: str, status: int | None, description: str):
        self.method = method
        self.status = status
        self.description = description
        super().__init__(f"api {method}: status={status} {description}")


# ----------------------------------------------------------- резолвинг инстанса

def resolve_project_dir(project_dir: str | None = None) -> Path:
    """--project-dir > REMOTE_BRIDGE_PROJECT_DIR > POOL_BUS_ROOT/.. ."""
    if project_dir:
        return Path(project_dir).resolve()
    env = os.environ.get("REMOTE_BRIDGE_PROJECT_DIR")
    if env:
        return Path(env).resolve()
    bus = os.environ.get("POOL_BUS_ROOT")
    if bus:
        return Path(bus).resolve().parent  # <project>/.bus -> <project>
    raise RuntimeError(
        "cannot resolve project dir: pass --project-dir or set "
        "REMOTE_BRIDGE_PROJECT_DIR / POOL_BUS_ROOT")


def _set_data_dirs(data_root: Path) -> None:
    global DATA, INBOX_DIR, OUTBOX_DIR, MEDIA_DIR, STATE_DIR, LOG_DIR
    DATA = data_root
    INBOX_DIR = DATA / "inbox"
    OUTBOX_DIR = DATA / "outbox"
    MEDIA_DIR = DATA / "media"
    STATE_DIR = DATA / "state"
    LOG_DIR = DATA / "bridge-logs"


def init_instance(project_dir: str | None = None) -> tuple[dict, bool]:
    """Резолвит инстанс, выставляет глобальные пути, грузит конфиг (для data_dir).
    Возвращает (cfg, from_file)."""
    global PROJECT_DIR, SECRETS, BUS_ROOT, MANIFEST_PATH, CONFIG_PATH, TOKEN_PATH, ENV_PATH
    PROJECT_DIR = resolve_project_dir(project_dir)
    SECRETS = PROJECT_DIR / "secrets"
    BUS_ROOT = PROJECT_DIR / ".bus"
    MANIFEST_PATH = PROJECT_DIR / "pool.manifest.json"
    CONFIG_PATH = SECRETS / "bridge-config.json"
    TOKEN_PATH = SECRETS / "bot.token"
    ENV_PATH = SECRETS / ".env"
    cfg, from_file = load_config()
    data_dir = cfg.get("data_dir")
    _set_data_dirs(Path(data_dir).resolve() if data_dir else PROJECT_DIR / "03_data")
    return cfg, from_file


def load_config() -> tuple[dict, bool]:
    """(config, from_file). Нет файла -> дефолты (mode=pool, TOFU включён)."""
    cfg = json.loads(json.dumps(CONFIG_DEFAULTS))  # deep copy
    if CONFIG_PATH and CONFIG_PATH.exists():
        user_cfg = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        cfg.update(user_cfg)
        return cfg, True
    return cfg, False


def load_manifest() -> dict | None:
    """pool.manifest.json инстанса или None (нет файла)."""
    if not MANIFEST_PATH or not MANIFEST_PATH.exists():
        return None
    return json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))


# -------------------------------------------------------------------- токен

def read_token() -> str:
    """Токен ВНУТРИ процесса. Никогда не в argv/логах/выводе. 'Не задан' =
    файла нет / пусто после trim / не матчит TOKEN_RE -> TokenNotSet (без значения)."""
    if not TOKEN_PATH or not TOKEN_PATH.exists():
        raise TokenNotSet("token file missing")
    token = TOKEN_PATH.read_text(encoding="utf-8").strip()
    if not token:
        raise TokenNotSet("token file empty after trim")
    if not TOKEN_RE.match(token):
        raise TokenNotSet("token file does not match expected format")
    return token


# --------------------------------------------------------- владелец / цель (state)

def owner_state_path() -> Path | None:
    return (STATE_DIR / "owner.json") if STATE_DIR else None


def current_target_path() -> Path | None:
    return (STATE_DIR / "current-target.txt") if STATE_DIR else None


def read_owner_id(cfg: dict) -> int | None:
    """Числовой id владельца: cfg.allowed_user_id (>0) главнее; иначе TOFU-state; иначе None."""
    cid = cfg.get("allowed_user_id") or 0
    if cid:
        return int(cid)
    st = read_json(owner_state_path(), None) if owner_state_path() else None
    if st and st.get("user_id"):
        return int(st["user_id"])
    return None


def bind_owner(user_id: int) -> int:
    """TOFU: зафиксировать владельца в state-файле. Возвращает id."""
    write_json(owner_state_path(), {"user_id": int(user_id), "bound_ts": now_iso()})
    return int(user_id)


def read_current_target(default=None):
    p = current_target_path()
    if p and p.exists():
        try:
            t = p.read_text(encoding="utf-8").strip()
        except OSError:
            return default
        if t:
            return t
    return default


def write_current_target(owner: str) -> None:
    """Владелец state текущей цели — движок. Пишем атомарно (retry на PermissionError)."""
    p = current_target_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    tmp = p.with_suffix(".tmp")
    tmp.write_text(owner, encoding="utf-8")
    for _ in range(5):
        try:
            tmp.replace(p)
            return
        except PermissionError:
            time.sleep(0.1)
    tmp.unlink(missing_ok=True)
    p.write_text(owner, encoding="utf-8")


# ------------------------------------------------------------------ сеть Bot API

def _sanitize_net_error(method: str, exc: Exception) -> BridgeApiError:
    """Никогда не включать str(exc) целиком — URL содержит токен."""
    if isinstance(exc, urllib.error.HTTPError):
        try:
            body = json.loads(exc.read().decode("utf-8", "replace"))
            desc = str(body.get("description", ""))[:300]
        except Exception:
            desc = "<unreadable body>"
        return BridgeApiError(method, exc.code, desc)
    if isinstance(exc, urllib.error.URLError):
        return BridgeApiError(method, None, f"network: {type(exc.reason).__name__}")
    return BridgeApiError(method, None, f"{type(exc).__name__}")


def api_call(token: str, method: str, params: dict | None = None,
             timeout: float = 30.0) -> dict:
    """POST JSON к Bot API. Возвращает result. Универсально: sendMessage (в т.ч. с
    reply_markup), answerCallbackQuery, editMessageText, setMyCommands, getUpdates,
    getMe, getFile — любой метод. Исключения — без токена."""
    url = f"https://api.telegram.org/bot{token}/{method}"
    payload = json.dumps(params or {}).encode("utf-8")
    req = urllib.request.Request(
        url, data=payload, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except Exception as exc:  # noqa: BLE001 — санитизация токена важнее
        raise _sanitize_net_error(method, exc) from None
    if not body.get("ok"):
        raise BridgeApiError(method, None, str(body.get("description", ""))[:300])
    return body["result"]


def download_file(token: str, file_path: str, dest: Path,
                  timeout: float = 120.0) -> None:
    """Скачивает файл Bot API в dest (атомарно через .part)."""
    url = f"https://api.telegram.org/file/bot{token}/{urllib.parse.quote(file_path)}"
    part = dest.with_suffix(dest.suffix + ".part")
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            part.write_bytes(resp.read())
    except Exception as exc:  # noqa: BLE001
        part.unlink(missing_ok=True)
        raise _sanitize_net_error("download_file", exc) from None
    part.replace(dest)


# ------------------------------------------------------------------ журнал/утилиты

def journal_append(path: Path, record: dict) -> None:
    """Одна строка JSONL, UTF-8, append-only. Контент — только внутри JSON-строк."""
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(record, ensure_ascii=False) + "\n"
    with path.open("a", encoding="utf-8", newline="\n") as f:
        f.write(line)


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%S%z")


def today() -> str:
    return time.strftime("%Y-%m-%d")


def read_json(path: Path | None, default):
    if not path or not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return default


def write_json(path: Path, value) -> None:
    """Атомарная запись через .tmp+replace. На Windows replace() даёт PermissionError,
    если файл параллельно открыт читателем (health/lock имеют внешних читателей) —
    ретраим, в крайнем случае пишем напрямую."""
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(value, ensure_ascii=False, indent=1)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    for _ in range(5):
        try:
            tmp.replace(path)
            return
        except PermissionError:
            time.sleep(0.1)
    tmp.unlink(missing_ok=True)
    path.write_text(text, encoding="utf-8")  # не атомарно, но лучше падения


def pid_alive(pid: int) -> bool:
    """Жив ли процесс (Windows). Свежий ts мёртвого процесса не должен блокировать
    перезапуск/захват lock'а."""
    import ctypes
    PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
    STILL_ACTIVE = 259
    kernel32 = ctypes.windll.kernel32
    handle = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, int(pid))
    if not handle:
        return False
    code = ctypes.c_ulong()
    ok = kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
    kernel32.CloseHandle(handle)
    return bool(ok) and code.value == STILL_ACTIVE
