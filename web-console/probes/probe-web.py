#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Сквозная проба входа из браузера: страница → список → ttyd → web-entry.sh → enter.sh → вид.

Ходит по ЖИВЫМ службам (7680/7681) и живой ферме, но только смотрит: клавиш в окно роли не шлёт
(⚠️ enter.sh сам через 2 и 5 с после подключения стирает строку ввода роли, если в ней опознан
мусор терминала — это его штатное поведение, у пробы оно не отключается), размер терминала берёт
равным текущему окну роли, чтобы не переразмерить его. Самое дорогое, что проверяется:
  - вид смотрит на ТО ЖЕ окно, что окно роли в сессии пула (не застава, не чужое поколение);
  - после обрыва соединения вид убран в пределах полутора секунд и процесс входа вышел
    (вид держит окна живыми: брошенный вид = роли, которых не погасить);
  - текущее окно сессии пула НЕ сдвинулось (инвариант консоли: вид не уводит рабочую сессию).

  probe-web.py [--page http://127.0.0.1:7680] [--term http://127.0.0.1:7681/term] --pool <пул> --role <роль>

Websocket-клиент здесь свой, на сокетах: сторонних библиотек у python3 фермы нет, а протокол ttyd
прост — первый кадр от клиента: JSON {AuthToken, columns, rows}; от сервера — двоичные кадры с
первым байтом-командой ('0' = вывод терминала).

Чего проба НЕ видит (сказано, чтобы зелёное не читалось шире, чем оно есть): всё, что выше
прокси DevOps (пароль, Origin, префикс /term, заголовки против iframe, fail2ban), обрезку экрана
при разных размерах клиентов, мусор от мыши в строке ввода, поведение страницы в браузере.
"""
import argparse
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SOCKET = os.environ.get("SHOP_TMUX_SOCKET", "agents")
FAILS = []


def ok(name, cond, detail=""):
    print(("  ok   " if cond else "  FAIL ") + name + (("  — " + detail) if detail else ""))
    if not cond:
        FAILS.append(name)
    return cond


def tmux(*args):
    r = subprocess.run(["tmux", "-L", SOCKET, *args], capture_output=True, text=True, timeout=5, check=False)
    return r.stdout.splitlines() if r.returncode == 0 else []


def views():
    return set(l for l in tmux("list-sessions", "-F", "#{session_name}") if l.startswith("view-"))


def display(target, fmt):
    out = tmux("display", "-p", "-t", target, fmt)
    return out[0] if out else ""


def entry_procs(pool, role):
    """pid процессов enter.sh на эту роль (pgrep сам себя не считает; python в списке не окажется —
    его командная строка слов enter.sh не содержит)."""
    r = subprocess.run(["pgrep", "-f", "enter.sh %s %s$" % (pool, role)], capture_output=True, text=True)
    return set(r.stdout.split())


def http_get(url, timeout=5):
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return r.status, r.headers.get("Content-Type", ""), r.read()


class WS:
    """Минимальный websocket-клиент: рукопожатие, маскированные кадры, чтение с таймаутом."""

    def __init__(self, url, subprotocol="tty", origin=None):
        u = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((u.hostname, u.port or 80), timeout=5)
        path = u.path + ("?" + u.query if u.query else "")
        key = base64.b64encode(os.urandom(16)).decode()
        host = "%s:%d" % (u.hostname, u.port or 80)
        origin = origin or ("http://" + host)
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: %s\r\n"
               "Origin: %s\r\n\r\n") % (path, host, key, subprotocol, origin)
        self.sock.sendall(req.encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.sock.recv(4096)
            if not chunk:
                break
            head += chunk
        self.status = head.split(b"\r\n", 1)[0].decode(errors="replace")
        self.buf = head.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in head else b""
        if " 101 " not in self.status:
            raise RuntimeError("рукопожатие: " + self.status)

    def send(self, payload, opcode=1):
        if isinstance(payload, str):
            payload = payload.encode()
        mask = os.urandom(4)
        n = len(payload)
        hdr = bytes([0x80 | opcode])
        if n < 126:
            hdr += bytes([0x80 | n])
        elif n < 65536:
            hdr += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            hdr += bytes([0x80 | 127]) + struct.pack(">Q", n)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(hdr + mask + masked)

    def _need(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.time()
            if left <= 0:
                return False
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return False
            if not chunk:
                return False
            self.buf += chunk
        return True

    def recv(self, timeout=2.0):
        """(opcode, payload) или None по таймауту/закрытию."""
        deadline = time.time() + timeout
        if not self._need(2, deadline):
            return None
        b0, b1 = self.buf[0], self.buf[1]
        opcode = b0 & 0x0F
        masked = b1 & 0x80
        n = b1 & 0x7F
        off = 2
        if n == 126:
            if not self._need(4, deadline):
                return None
            n = struct.unpack(">H", self.buf[2:4])[0]; off = 4
        elif n == 127:
            if not self._need(10, deadline):
                return None
            n = struct.unpack(">Q", self.buf[2:10])[0]; off = 10
        if masked:
            off += 4
        if not self._need(off + n, deadline):
            return None
        payload = self.buf[off:off + n]
        self.buf = self.buf[off + n:]
        return opcode, payload

    def close(self):
        try:
            self.send(struct.pack(">H", 1000), opcode=8)
            self.sock.settimeout(1)
            try:
                self.sock.recv(4096)
            except Exception:
                pass
        finally:
            self.sock.close()


def open_terminal(term, args, seconds=4.0, cols=140, rows=40):
    """Открыть терминал ttyd с аргументами входа, собрать вывод за seconds. Возвращает (текст, ws).

    🛑 Отвечаем на запрос позиции курсора (`ESC [ 6 n`): в браузере на него отвечает сам xterm.js,
    а без ответа приложение ЖДЁТ молча. Ровно на этом проба показывала «пульт не нарисовался» при
    исправном пульте: fzf спрашивал позицию и висел, за 25 секунд приходило 46 знаков служебных
    последовательностей. Признак «мало вывода» тут ничего не значил — врал не пульт, а проба.
    """
    qs = "&".join("arg=" + urllib.parse.quote(a, safe="") for a in args)
    ws = WS(term + "/ws?" + qs)
    ws.send(json.dumps({"AuthToken": "", "columns": cols, "rows": rows}))
    out = b""
    end = time.time() + seconds
    while time.time() < end:
        fr = ws.recv(timeout=max(0.1, end - time.time()))
        if fr is None:
            continue
        op, payload = fr
        if op == 8:
            break
        if op == 9:
            # 🛑 Отвечаем на ping. ttyd поднят с -P 10 и рвёт молчащего клиента: на длинных
            # открытиях (25-45 с — столько собирается снимок для пульта) соединение закрывалось
            # ПОСЕРЕДИНЕ, вывод уже был собран, а процесс пульта к моменту проверки убит. Проба
            # показывала «пульта нет» при исправном пульте — врал клиент пробы, а не цех.
            ws.send(payload, opcode=10)
            continue
        if op in (1, 2) and payload[:1] == b"0":
            chunk = payload[1:]
            out += chunk
            if b"\x1b[6n" in chunk:
                ws.send(b"0" + b"\x1b[1;1R")   # '0' — кадр ввода в протоколе ttyd
    return out.decode("utf-8", errors="replace"), ws


def wait_gone(pred, limit=1.5, step=0.1):
    """Сколько секунд прошло до того, как pred() стал истинным; None — не дождались."""
    t0 = time.time()
    while time.time() - t0 < limit:
        if pred():
            return round(time.time() - t0, 2)
        time.sleep(step)
    return None


REFUSALS = ("не по форме", "не поднята", "не поднят", "не найден", "Неизвестный вход", "Не сказано",
            "Нет рабочей библиотеки", "Не удалось открыть вид", "не выбралось", "не то же, что в пуле",
            "Не удалось подключиться", "погашен")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--page", default="http://127.0.0.1:7680")
    ap.add_argument("--term", default="http://127.0.0.1:7681/term")
    ap.add_argument("--pool", required=True)
    ap.add_argument("--role", required=True)
    a = ap.parse_args()
    page, term = a.page.rstrip("/"), a.term.rstrip("/")
    target = "=%s:=%s" % (a.pool, a.role)

    print("1. страница")
    st, ct, body = http_get(page + "/health")
    ok("/health отвечает", st == 200 and body.strip() == b"ok")
    st, ct, body = http_get(page + "/")
    ok("/ отдаёт страницу", st == 200 and "text/html" in ct and b"<title>" in body and b"roster.json" in body)
    st, ct, body = http_get(page + "/panes.js")
    ok("/panes.js отдаётся", st == 200 and "javascript" in ct and b"dressFrame" in body)
    st, ct, body = http_get(page + "/pane.html")
    ok("/pane.html отдаётся", st == 200 and "text/html" in ct and b"panes.js" in body)
    st, ct, body = http_get(page + "/roster.json")
    ros = json.loads(body.decode())
    ok("/roster.json без ошибки фермы", st == 200 and not ros.get("error"), str(ros.get("error", "")))
    ok("в списке есть пулы", isinstance(ros.get("pools"), list) and len(ros["pools"]) > 0, "пулов: %d" % len(ros.get("pools", [])))
    pool = next((p for p in ros["pools"] if p["name"] == a.pool), None)
    ok("в списке есть пул %s с ролью %s" % (a.pool, a.role),
       pool is not None and any(r["name"] == a.role for r in pool["roles"]))
    ok("в списке нет видов и стенда", not any(p["name"].startswith("view-") or p["name"] == "stand" for p in ros["pools"]))
    ok("поле views есть", isinstance(ros.get("views"), list), "брошенных видов сейчас: %d" % len(ros.get("views", [])))
    for p in ("/nothing-here", "/web-serve.py", "/../web-serve.py", "/index.html.bak"):
        try:
            http_get(page + p)
            ok("чужой путь %s — 404" % p, False, "ответил 200")
        except urllib.error.HTTPError as e:
            ok("чужой путь %s — 404" % p, e.code == 404, "код %d" % e.code)

    print("2. ttyd")
    st, ct, body = http_get(term + "/")
    ok("/term/ отдаёт клиент ttyd", st == 200 and "text/html" in ct)
    st, ct, body = http_get(term + "/token")
    ok("/term/token — JSON", st == 200 and b"token" in body)

    print("3. вход в роль %s/%s" % (a.pool, a.role))
    size = display(target, "#{window_width} #{window_height}").split()
    cols, rows = (int(size[0]), int(size[1])) if len(size) == 2 else (140, 40)
    ok("размер окна роли прочитан", len(size) == 2, "%dx%d" % (cols, rows))
    role_wid = display(target, "#{window_id}")
    before_views, before_win, before_procs = views(), display("=%s:" % a.pool, "#{window_id}"), entry_procs(a.pool, a.role)
    ok("окно роли и текущее окно пула читаются", bool(role_wid) and bool(before_win), "%s / %s" % (role_wid, before_win))
    text, ws = open_terminal(term, ["role", a.pool, a.role], cols=cols, rows=rows)
    new_views = views() - before_views
    new_procs = entry_procs(a.pool, a.role) - before_procs
    # Процессов может быть два: сам enter.sh и его фоновая подоболочка уборки строки ввода
    # (та же командная строка) — важно, что появились и что ВСЕ потом ушли.
    ok("процесс входа enter.sh появился", len(new_procs) >= 1, " ".join(new_procs) or "нет")
    ok("вид на роль открылся", any(v.startswith("view-%s-" % a.role) for v in new_views), " ".join(new_views) or "новых видов нет")
    view = next((v for v in new_views if v.startswith("view-%s-" % a.role)), "")
    view_wid = display("=%s:" % view, "#{window_id}") if view else ""
    ok("вид смотрит на ТО ЖЕ окно, что окно роли в пуле", bool(view_wid) and view_wid == role_wid, "%s / %s" % (view_wid, role_wid))
    ok("экран роли пришёл (есть вывод)", len(text) > 50, "%d знаков" % len(text))
    ok("ни одной заставы входа в выводе", not any(r in text for r in REFUSALS))
    ok("текущее окно сессии пула не сдвинулось", display("=%s:" % a.pool, "#{window_id}") == before_win)
    ok("к виду подключён клиент", display("=%s:" % view, "#{session_attached}") == "1" if view else False)
    ws.close()
    dt = wait_gone(lambda: not (views() & new_views))
    ok("после обрыва соединения вид убран за ≤1.5 с", dt is not None, "%s с" % dt if dt is not None else "остался: " + " ".join(views() & new_views))
    dt2 = wait_gone(lambda: not (entry_procs(a.pool, a.role) & new_procs))
    ok("процесс входа вышел за ≤1.5 с", dt2 is not None, "%s с" % dt2 if dt2 is not None else "жив: " + " ".join(entry_procs(a.pool, a.role) & new_procs))

    print("4. отказы входа (ничего не открывается, видов и процессов не остаётся)")
    cases = [
        (["role", "a;b", a.role], "не по форме"),
        (["role", a.pool, "net-takoy-roli"], "не поднята"),
        (["role", a.pool], "ждёт два имени"),
        (["zzz"], "Неизвестный вход"),
        (["\x1b[31mKRASNY"], "Неизвестный вход «??31m??????»"),   # ни ESC, ни «[», ни заглавных — всё знаками вопроса
        ([], "Не сказано"),
        (["pool", "net-takogo-pula"], "не найден"),   # пульт смены отвечает по снимку сборщика: «в снимке не найден»
    ]
    for args, expect in cases:
        b = views()
        text, ws = open_terminal(term, args, seconds=2.5, cols=cols, rows=rows)
        ok("вход %s → «%s»" % ([x.encode("unicode_escape").decode() for x in args] or ["<пусто>"], expect), expect in text,
           text.strip().replace("\n", " ")[:90])
        ws.close()
        time.sleep(1)
        ok("  видов после отказа не прибавилось", not (views() - b))

    print("5. пульт цеха")
    b = views()
    desk_before = set(subprocess.run(["pgrep", "-f", "shop-desk.sh"], capture_output=True, text=True).stdout.split())
    # 🛑 Признак — ЗАПУЩЕН ЛИ ПУЛЬТ, а не «нарисовался ли за N секунд». Пульт сперва собирает
    # снимок всего цеха, и время сбора плавает от десятков секунд (десять пулов, pwsh): замеры
    # 10.09 дали и 40 с с картинкой, и 35 с без неё. Признак по времени отрисовки объявлял бы
    # исправный пульт сломанным — ровно тот класс, что уже случился с запросом позиции курсора.
    text, ws = open_terminal(term, ["desk"], seconds=25.0, cols=cols, rows=rows)
    desk_now = set(subprocess.run(["pgrep", "-f", "shop-desk.sh"], capture_output=True, text=True).stdout.split())
    desk_new = desk_now - desk_before
    ok("пульт цеха запущен", bool(desk_new),
       " ".join(sorted(desk_new)) or "было [%s], стало [%s]" % (" ".join(sorted(desk_before)), " ".join(sorted(desk_now))))
    ok("вывод из пульта идёт", len(text) > 100, "%d знаков" % len(text))
    if "Пул" in text:
        print("  ok   пульт успел нарисовать выбор пула")
    else:
        print("  --   пульт ещё собирал снимок цеха — отрисовку не жду, это не отказ")
    ws.close()
    dt = wait_gone(lambda: not (set(subprocess.run(["pgrep", "-f", "shop-desk.sh"], capture_output=True, text=True).stdout.split()) & desk_new), limit=4)
    ok("после закрытия панели пульт ушёл", dt is not None, "%s с" % dt if dt is not None else "процесс остался")
    ok("  видов от пульта не осталось", not (views() - b))

    print()
    if FAILS:
        print("ПРОВАЛ: %d — %s" % (len(FAILS), "; ".join(FAILS)))
        return 1
    print("ВСЁ ЗЕЛЁНОЕ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
