#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Страница-пульт для входа в цех из браузера. Слушает 127.0.0.1:7680, наружу её выставляет
реверс-прокси DevOps (пароль и https — там). Терминалы рисует ttyd на 127.0.0.1:7681 (юнит
shop-web-term.service), прокси отдаёт ему путь /term/*.

Отдаёт, и только по GET:
  /, /index.html — страница с панелями
  /pane.html     — одна панель отдельным окном браузера (короткий заголовок «пул / роль»)
  /panes.js      — общая обвязка обеих страниц
  /roster.json   — кто поднят: сессии tmux фермы и их окна, живость по pane_dead
  /outbox.json?pool= — что роли положили для владельца (`exchange/outbox`), с пометкой «от кого»
  /download?pool=&path= — забрать оттуда файл
  /health        — 200 ok
POST:
  /upload?pool=&role=&name= — файл, перетащенный на панель: уходит в `exchange/inbox/<роль>/`
                              штатным приёмником `shop/shop-deliver.py` (см. накладную у него)
  /remove?pool=&path=       — убрать забранный файл из ящика (по кнопке, не автоматически:
                              молча стирать после скачивания — верный способ потерять файл)

🛑 Файлы отдаются ПО СПИСКУ (WEB_FILES), а не «всё из каталога web/»: каталог лежит в рабочем
дереве, и любой файл, случайно оставленный рядом (черновик, копия .bak), иначе стал бы доступен
всякому, кто вошёл по паролю.

🛑 Сведения о ролях берутся ПРЯМО у tmux при каждом запросе, а не из снимка сборщика
(shop-collect.sh): странице нужен только список окон и живы ли они, а снимок собирается
секундами и тянет за собой pwsh. Это то же исключение, что у ДЕЙСТВИЙ консоли (enter.sh):
«живые вызовы tmux остались только у действий и у видов». Ничего сверх имён и pane_dead
отсюда не отдавать — иначе появится второй сборщик.

Сессии-виды (`view-*`) и стенд (`stand`) в список не попадают: вид — чья-то панель, стенд — не пул.
`shop-ops` (окна длительных операций) показывается — туда полезно заглянуть из браузера.
"""
import argparse
import io
import json
import os
import re
import subprocess
import sys
import tarfile
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
WEB = os.path.join(HERE, "web")
INDEX = os.path.join(WEB, "index.html")
WEB_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/pane.html": ("pane.html", "text/html; charset=utf-8"),
    "/panes.js": ("panes.js", "application/javascript; charset=utf-8"),
}
SOCKET = os.environ.get("SHOP_TMUX_SOCKET", "agents")
HIDDEN_SESSIONS = {"stand"}


# Разделитель полей — двоеточие: в имени СЕССИИ tmux его не бывает (заменяет на «_» при создании),
# остальные поля — числа и «@N». Имя ОКНА может содержать что угодно, поэтому оно всегда идёт
# ПОСЛЕДНИМ и берётся целиком остатком строки (split с пределом).
# ⚠️ Управляющий символ (0x1f) разделителем не годится: tmux печатает его в выводе команд как
# «\037» буквами — проверено на ферме, список из-за этого вышел пустым при зелёной пробе.
SEP = ":"


class FarmUnavailable(Exception):
    """Ферму не спросить: tmux не нашёлся, не ответил за 5 с или вернул ошибку.
    🛑 Это НЕ «пулов нет»: та же ошибка, что консоль уже покупала («неполный деплой выглядел как
    „пул погашен“»). Страница обязана печатать «ферму не спросить», а не «ни один пул не поднят»."""


def tmux(*args):
    """Вывод tmux строками. Не ответил — FarmUnavailable, а не пустой список."""
    try:
        out = subprocess.run(
            ["tmux", "-L", SOCKET, *args],
            capture_output=True, text=True, timeout=5, check=False,
        )
    except OSError as e:
        raise FarmUnavailable("tmux не запускается: %s" % e)
    except subprocess.TimeoutExpired:
        raise FarmUnavailable("tmux не ответил за 5 с")
    if out.returncode != 0:
        err = (out.stderr or "").strip().splitlines()
        # «no server running» — сервер фермы не поднят: пулов и правда нет, но сказать это надо
        # словами про сервер, а не «ни один пул не поднят».
        raise FarmUnavailable(err[0] if err else "tmux вернул код %d" % out.returncode)
    return [l for l in out.stdout.splitlines() if l]


def roster():
    """{"at", "socket", "pools": [{"name", "roles": [{"name", "index", "alive"}]}],
        "views": [{"name", "attached", "live_windows"}]} либо {"error": "..."}"""
    try:
        # Одна панель с pane_dead=0 — окно живое (на ферме remain-on-exit on: мёртвая панель
        # остаётся с трейсом, поэтому «окно есть» ещё не значит «внутри кто-то работает»).
        alive = {}
        for line in tmux("list-panes", "-a", "-F", SEP.join(["#{session_name}", "#{window_id}", "#{pane_dead}"])):
            parts = line.split(SEP)
            if len(parts) != 3:
                continue
            s, w, dead = parts
            key = (s, w)
            alive[key] = alive.get(key, False) or dead == "0"
        pools, order, views = {}, [], {}
        for line in tmux("list-windows", "-a", "-F", SEP.join(["#{session_name}", "#{window_index}", "#{window_id}", "#{session_attached}", "#{window_name}"])):
            parts = line.split(SEP, 4)
            if len(parts) != 5:
                continue
            s, idx, wid, att, name = parts
            if s in HIDDEN_SESSIONS:
                continue
            if s.startswith("view-"):
                # Вид — чья-то панель, в список пулов не идёт. Но БРОШЕННЫЙ вид с живыми окнами —
                # единственное, ради чего написана view-lib.sh (он держит роли погашенного пула),
                # и тому, у кого только браузер, его иначе не увидеть.
                v = views.setdefault(s, {"name": s, "attached": att not in ("", "0"), "live_windows": 0})
                if alive.get((s, wid), False):
                    v["live_windows"] += 1
                continue
            if s not in pools:
                pools[s] = []
                order.append(s)
            pools[s].append({"name": name, "index": int(idx) if idx.isdigit() else -1,
                             "alive": alive.get((s, wid), False)})
    except FarmUnavailable as e:
        return {"at": int(time.time()), "socket": SOCKET, "error": str(e), "pools": [], "views": []}
    return {
        "at": int(time.time()),
        "socket": SOCKET,
        "pools": [{"name": s, "roles": pools[s]} for s in order],
        "views": [views[k] for k in sorted(views) if not views[k]["attached"]],
    }


# ── приём файлов со страницы ──────────────────────────────────────────────────
# 🛑 Файл НЕ кладётся на диск отсюда. Он упаковывается в tar и отдаётся штатному приёмнику
# `shop/shop-deliver.py accept <пул>` — тому же, что возит папку с машины владельца. Иначе в цеху
# появился бы ВТОРОЙ способ укладки, со своей (наверняка более бедной) страховкой: отбор секретов,
# сохранение потеснённых экземпляров, журнал доставленного и письмо адресату живут там.
# Адрес получателя задаётся МЕСТОМ файла в архиве: `<роль>/<имя>` — файл роли, `<имя>` — общий,
# письмо лиду (правило владельца 10.09.2026).
MAX_UPLOAD = 200 * 1024 * 1024
NAME_RX = re.compile(r"^[^\x00-\x1f/\\]{1,200}$")
SLUG_RX = re.compile(r"^[a-z0-9._-]{1,64}$")


def deliver_cli():
    # ⚠️ Путь берём из окружения с дефолтом, а не «на каталог выше от себя»: копия консоли,
    # разложенная в другом месте (проба, стенд), искала бы приёмник рядом с собой и не нашла.
    base = os.environ.get("SHOP_DIR") or os.path.join(os.path.expanduser("~"), "workspace", ".launcher", "shop")
    return os.path.join(base, "shop-deliver.py")


def accept_upload(pool, role, name, body):
    """Вернуть (код ответа, текст) — текст показывается человеку прямо на странице."""
    if not SLUG_RX.match(pool or ""):
        return 400, "имя пула не по форме\n"
    if role and not SLUG_RX.match(role):
        return 400, "имя роли не по форме\n"
    # ⚠️ Имя приходит от браузера: берём только последний кусок пути и запрещаем разделители,
    # иначе «файл» вида ../../x увёл бы запись из приёмной (в архиве это тоже отсечётся, но
    # ошибку надо называть здесь и словами).
    name = os.path.basename((name or "").replace("\\", "/"))
    if not NAME_RX.match(name) or name in (".", ".."):
        return 400, "имя файла не по форме\n"
    cli = deliver_cli()
    if not os.path.exists(cli):
        return 500, "приёмника нет на месте: %s\n" % cli
    member = (role + "/" + name) if role else name
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tf:
        ti = tarfile.TarInfo("./" + member)
        ti.size = len(body)
        ti.mtime = int(time.time())
        tf.addfile(ti, io.BytesIO(body))
    try:
        r = subprocess.run([sys.executable, cli, "accept", pool], input=buf.getvalue(),
                           capture_output=True, timeout=300)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 500, "приёмник не отработал: %s\n" % str(e)[:200]
    out = (r.stdout or b"").decode("utf-8", "replace") + (r.stderr or b"").decode("utf-8", "replace")
    if r.returncode != 0:
        return 500, "приёмник отказал (код %d):\n%s" % (r.returncode, out)
    # Приёмник придерживает похожее на секреты — с браузера «доставить вместе с секретами» не
    # предлагаем: это отдельное осознанное действие, у него есть свой пункт в пульте.
    if "придержано как похожее на секреты" in out or "НЕ повезу никогда" in out:
        return 200, "принято НЕ полностью — приёмник придержал файл:\n" + out
    return 200, out


# ── обратная дорога: забрать файлы, которые роли положили для владельца ───────
# Отдаём ТОЛЬКО из `<пул>/exchange/outbox` и только обычные файлы. Путь приходит от браузера,
# поэтому проверяем не строку, а РЕЗУЛЬТАТ: куда он на самом деле указывает после разрешения
# ссылок (realpath). Строчные проверки на «..» обходятся ссылкой внутри ящика.
def pool_dir_of(slug):
    """Каталог пула по слагу — тем же обходом, что у приёмника доставки (манифест на месте)."""
    root = os.environ.get("SHOP_WORKSPACE") or os.path.join(os.path.expanduser("~"), "workspace")
    depth0 = root.count(os.sep)
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if not d.startswith(".") and d not in ("node_modules", "archive")]
        if dp.count(os.sep) - depth0 > 3:
            dn[:] = []
            continue
        if "pool.manifest.json" not in fn:
            continue
        dn[:] = []
        try:
            with open(os.path.join(dp, "pool.manifest.json"), encoding="utf-8") as f:
                m = json.load(f)
        except Exception:
            continue
        if m.get("slug") == slug:
            return dp, m
    return None, None


def outbox_of(slug):
    """(каталог outbox, роли пула) или (None, None), если пула нет."""
    pool_dir, man = pool_dir_of(slug)
    if not pool_dir:
        return None, None
    roles = set()
    for r in (man or {}).get("roles") or []:
        name = r if isinstance(r, str) else (r or {}).get("owner")
        if name:
            roles.add(str(name))
    if (man or {}).get("lead"):
        roles.add(str(man["lead"]))
    return os.path.join(pool_dir, "exchange", "outbox"), roles


def outbox_list(slug):
    box, roles = outbox_of(slug)
    if not box:
        return {"pool": slug, "error": "пул не найден", "files": []}
    if not os.path.isdir(box):
        return {"pool": slug, "files": []}
    root = os.path.realpath(box)
    out = []
    for dp, dn, fn in os.walk(box):
        for n in sorted(fn):
            full = os.path.join(dp, n)
            real = os.path.realpath(full)
            if not os.path.isfile(real) or (real != root and not real.startswith(root + os.sep)):
                continue      # ссылка наружу ящика — не показываем и не отдадим
            rel = os.path.relpath(full, box).replace(os.sep, "/")
            head = rel.split("/", 1)[0] if "/" in rel else ""
            try:
                st = os.stat(real)
            except OSError:
                continue
            out.append({"path": rel, "from": head if head in roles else "",
                        "size": st.st_size, "mtime": int(st.st_mtime)})
            if len(out) >= 500:
                break
        if len(out) >= 500:
            break
    out.sort(key=lambda x: -x["mtime"])
    return {"pool": slug, "files": out}


def outbox_file(slug, rel):
    """Полный путь к файлу в ящике или (None, причина)."""
    if not SLUG_RX.match(slug or ""):
        return None, "имя пула не по форме"
    if not rel or len(rel) > 400 or "\x00" in rel:
        return None, "путь не по форме"
    box, _ = outbox_of(slug)
    if not box or not os.path.isdir(box):
        return None, "у пула нет ящика для владельца"
    root = os.path.realpath(box)
    full = os.path.realpath(os.path.join(box, rel.replace("/", os.sep)))
    if full != root and not full.startswith(root + os.sep):
        return None, "этот путь ведёт за пределы ящика"
    if not os.path.isfile(full):
        return None, "такого файла в ящике нет"
    return full, None


class Handler(BaseHTTPRequestHandler):
    server_version = "shop-web/1"

    def log_message(self, fmt, *args):  # журнал — в journald юнита, коротко
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _send(self, code, body, ctype):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def _query(self):
        return urllib.parse.parse_qs(self.path.split("?", 1)[1] if "?" in self.path else "")

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if path == "/remove":
            q = self._query()
            full, why = outbox_file((q.get("pool") or [""])[0], (q.get("path") or [""])[0])
            if not full:
                self._send(400, why + "\n", "text/plain; charset=utf-8")
                return
            try:
                os.unlink(full)
                # Пустой подкаталог роли убираем следом — иначе ящик зарастает пустыми папками.
                d = os.path.dirname(full)
                while d and os.path.basename(d) != "outbox" and not os.listdir(d):
                    os.rmdir(d)
                    d = os.path.dirname(d)
            except OSError as e:
                self._send(500, "не убрался: %s\n" % e, "text/plain; charset=utf-8")
                return
            self._send(200, "убран\n", "text/plain; charset=utf-8")
            return
        if path != "/upload":
            self._send(404, "нет такого\n", "text/plain; charset=utf-8")
            return
        q = self._query()
        pool = (q.get("pool") or [""])[0]
        role = (q.get("role") or [""])[0]
        name = (q.get("name") or [""])[0]
        try:
            size = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            size = -1
        if size < 0 or size > MAX_UPLOAD:
            self._send(413, "файл больше %d МиБ — так не вожу\n" % (MAX_UPLOAD // 1048576),
                       "text/plain; charset=utf-8")
            return
        body = self.rfile.read(size) if size else b""
        out = accept_upload(pool, role, name, body)
        self._send(out[0], out[1], "text/plain; charset=utf-8")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in WEB_FILES:
            name, ctype = WEB_FILES[path]
            full = os.path.join(WEB, name)
            try:
                with open(full, "rb") as f:
                    self._send(200, f.read(), ctype)
            except OSError:
                self._send(500, "нет файла: %s\n" % full, "text/plain; charset=utf-8")
        elif path == "/roster.json":
            self._send(200, json.dumps(roster(), ensure_ascii=False), "application/json; charset=utf-8")
        elif path == "/outbox.json":
            slug = (self._query().get("pool") or [""])[0]
            if not SLUG_RX.match(slug or ""):
                self._send(400, "имя пула не по форме\n", "text/plain; charset=utf-8")
                return
            self._send(200, json.dumps(outbox_list(slug), ensure_ascii=False), "application/json; charset=utf-8")
        elif path == "/download":
            q = self._query()
            full, why = outbox_file((q.get("pool") or [""])[0], (q.get("path") or [""])[0])
            if not full:
                self._send(400, why + "\n", "text/plain; charset=utf-8")
                return
            try:
                with open(full, "rb") as f:
                    data = f.read()
            except OSError as e:
                self._send(500, "файл не читается: %s\n" % e, "text/plain; charset=utf-8")
                return
            name = os.path.basename(full)
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(len(data)))
            # Имя файла бывает кириллическим — только звёздочная форма его и переживает.
            self.send_header("Content-Disposition",
                             "attachment; filename*=UTF-8''" + urllib.parse.quote(name, safe=""))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
        elif path == "/desk-action":
            # Пульт цеха в браузере поднят с «--warp»: войдя в роль, он не занимает свою панель, а
            # кладёт запрос сюда и выходит. Забираем запрос ОДИН раз (файл удаляем): второй
            # читатель открыл бы те же панели повторно.
            f = os.environ.get("SHOP_ACTION_FILE") or os.path.join(os.path.expanduser("~"), ".shop", "desk-action-web")
            try:
                with open(f, encoding="utf-8") as fh:
                    line = fh.readline().rstrip("\n")
                os.unlink(f)
            except OSError:
                self._send(200, "{}", "application/json; charset=utf-8")
                return
            parts = line.split("\t")
            what = parts[0] if parts else ""
            pool = parts[1] if len(parts) > 1 else ""
            roles = [r for r in (parts[2].split() if len(parts) > 2 else []) if r and r != "-"]
            self._send(200, json.dumps({"what": what, "pool": pool, "roles": roles}, ensure_ascii=False),
                       "application/json; charset=utf-8")
        elif path == "/health":
            self._send(200, "ok\n", "text/plain; charset=utf-8")
        else:
            self._send(404, "нет такого\n", "text/plain; charset=utf-8")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=7680)
    ap.add_argument("--roster", action="store_true", help="напечатать roster.json и выйти (проба)")
    a = ap.parse_args()
    if a.roster:
        print(json.dumps(roster(), ensure_ascii=False, indent=1))
        return 0
    srv = ThreadingHTTPServer((a.bind, a.port), Handler)
    srv.daemon_threads = True
    sys.stderr.write("shop-web: слушаю %s:%d, страница %s\n" % (a.bind, a.port, INDEX))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
