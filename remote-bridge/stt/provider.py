"""Слот STT-провайдеров. Выбор — конфиг stt.provider.

none           — транскрипция выключена (дефолт).
openai         — gpt-4o-mini-transcribe; ключ из <project>/secrets/.env (OPENAI_API_KEY).
faster_whisper — локальный фолбэк (реализация — когда понадобится офлайн).

Нет ключа / провайдер none -> transcribe() возвращает None, движок не падает.
Ключ НИКОГДА не печатается.
"""

from __future__ import annotations

import json
import sys
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bridgelib as B  # noqa: E402

OPENAI_MODEL = "gpt-4o-mini-transcribe"


def _read_env_key(name: str) -> str | None:
    """key=value парсер <project>/secrets/.env. Значение не печатать никогда."""
    env_path = B.ENV_PATH
    if not env_path or not env_path.exists():
        return None
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line.startswith(f"{name}=") and not line.startswith("#"):
            value = line.split("=", 1)[1].strip().strip('"').strip("'")
            return value or None
    return None


def transcribe(path: Path, cfg: dict, language: str = "ru") -> tuple[str | None, str | None]:
    """-> (текст | None, имя_провайдера | None). Ошибки глотаются в None."""
    provider = cfg.get("stt", {}).get("provider", "none")
    if provider == "openai":
        try:
            text = _openai_transcribe(path, language)
            return text, f"openai:{OPENAI_MODEL}"
        except Exception:  # noqa: BLE001 — STT не должен ронять движок
            return None, None
    if provider == "faster_whisper":
        return None, None  # локальный faster-whisper — когда понадобится офлайн
    return None, None


def _openai_transcribe(path: Path, language: str) -> str | None:
    key = _read_env_key("OPENAI_API_KEY")
    if not key:
        return None
    boundary = uuid.uuid4().hex
    ogg = path.read_bytes()

    def part(name: str, value: str) -> bytes:
        return (f"--{boundary}\r\nContent-Disposition: form-data; "
                f'name="{name}"\r\n\r\n{value}\r\n').encode()

    body = (
        part("model", OPENAI_MODEL) + part("language", language)
        + (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
           f"filename=\"voice.ogg\"\r\nContent-Type: audio/ogg\r\n\r\n").encode()
        + ogg + f"\r\n--{boundary}--\r\n".encode()
    )
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/transcriptions", data=body,
        headers={"Authorization": f"Bearer {key}",
                 "Content-Type": f"multipart/form-data; boundary={boundary}"})
    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8")).get("text")
