#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Антифлуд-напоминание ведущему пула.

Владелец: «иногда команда впадает в обсуждение различных мелочей и эхо, и тратит ресурсы,
не отчитываясь по задаче. Лид должен это увидеть и прекратить.»
Слепок НЕ строим — только напоминание по триггеру. Содержание писем не открывается:
из письма читается ТОЛЬКО шапка (From/To), и только у писем, появившихся после прошлого прохода.

ПОРОГИ ПОДОБРАНЫ ЗАМЕРОМ по настоящей переписке (2391 письмо pool-A за 26 активных дней,
130 у pool-B-1 за 3 дня), а не назначены:

    окно час · всего >= 25 ИЛИ пара >= 12 -> письмо лиду, повтор после 50 новых писем;
    исходящих одной роли за час >= 12 -> письмо РОЛИ, повтор после 20 её новых исходящих

    pool-A   36 напоминаний за 26 активных дней (1.4/день, худший день 4)
    pool-B-1   1 за 3 дня
    пул с одной ролью — 0

⚠️ Половина «про пару» — не украшение: из 36 срабатываний 20 дала именно она, то есть случаи,
когда общий объём был НИЖЕ порога, а двое ролей ходили по кругу. По объёму они не видны.

🛑 Признак «глубокая ветка обсуждения» ОТВЕРГНУТ ЗАМЕРОМ, не мнением: за месяц 2108 веток,
медиана 1 письмо, ни одна не доросла до 5. Роли не спорят внутри ветки — заводят новые письма.
Такой триггер не сработал бы ни разу. Не возвращать без нового замера.

Запускается по таймеру: один проход и выход. Живой сторож shop-watch.py НЕ трогаем — отдельный
модуль ничего не может ему сломать.
⚠️ Имя файла намеренно НЕ начинается с shop-watch: уборка сторожей в контроллере гашения
валит всё, что так называется.

Проверено на живой шине (иначе половина решений ниже была бы догадкой): адресат в письме всегда
ОДИН (веерных писем нет), лишних 13-значных чисел в именах нет, слаги пулов уникальны, лид ВХОДИТ
в состав — значит размен «лид ↔ роль» считается наравне с прочими.
"""
import argparse, errno, fcntl, hashlib, json, os, re, subprocess, sys, tempfile, time

# Сбор обязательств (§ 4 spec-obligations.md) вынесен в отдельный модуль: здесь остаётся только
# вызов, поэтому уронить антифлуд он не может. Имя файла с подчёркиванием — с дефисом модуль
# не импортируется.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import shop_oblig as _oblig                                                     # noqa: E402

WINDOW   = 3600      # окно наблюдения, секунды
N_TOTAL  = 25        # всего писем между участниками за окно
N_PAIR   = 12        # писем в одной паре ролей за окно
# 🛑 Временного остыва больше НЕТ — слово владельца 20.08 после боевого случая: остыв 2 ч
# спрятал вал в 105 писем/час (сработало на первых 12, остальное прошло в тишине). Повторность
# мерится СЧЁТОМ: следующее письмо лиду — после LEAD_RESEND новых писем пула, роли — после
# PERROLE_RESEND её новых исходящих. Затихло — напоминаний нет; льётся — идут пропорционально.
# Числа подобраны прогоном по архиву pool-A за 36.8 сут (2653 письма ролей, мостовые
# исключены): лидовых 1.1/сут против 0.9 при остыве 2 ч, пер-ролевых ~1.7/сут на весь пул.
LEAD_RESEND    = 50  # новых писем пула после лидового письма до следующего лидового
PERROLE_HOURLY = 12  # исходящих одной роли за окно — порог пер-ролевого напоминания
PERROLE_RESEND = 20  # новых исходящих роли после её напоминания до следующего
GRACE    = 600       # запас, на котором письмо ещё узнаётся по списку известных
SENDTMO  = 45        # отправка не должна пережить период таймера, иначе проходы наложатся
NOTE_TTL = 3600      # один и тот же неизменившийся исход в журнал чаще раза в час не пишем
SENDER   = "pool-monitor"

HDR = re.compile(r"^\|\s*(From|To)\s*\|\s*(.+?)\s*\|\s*$")
# Тема письма — первая строка «# …». Нужна ровно для одного: отличить служебную побудку моста
# (он всегда ставит «bridge: …») от побудки РОЛИ. По отправителю их не отличить — мост
# подписывается именем роли-хозяина своего инстанса.
SUBJ = re.compile(r"^#\s+(.+?)\s*$")
# ⚠️ Без пробела намеренно: шире, чем нынешний формат моста, — «bridge:foo» тоже поймается.
# Плата за это — роль, назвавшая письмо «bridge: …» И пославшая его через `note -Wake`, выпадет
# из счёта. Считаю приемлемым: письмо не теряется, не идёт только в счёт флуда.
BRIDGE_SUBJ = "bridge:"
NAME = re.compile(r"^(?P<id>\d{13}-[0-9a-fA-F]+)\.(?P<rest>.+)\.md$")


def shop_home():
    return os.environ.get("SHOP_HOME") or os.path.join(os.path.expanduser("~"), ".shop")


def workspace():
    return os.path.normpath(os.environ.get("SHOP_WORKSPACE")
                            or os.path.join(os.path.expanduser("~"), "workspace"))


def pool_cli():
    # переопределяется ради пробы: боевую отправку иначе не проверить, не разбудив живую роль
    return os.environ.get("POOL_CLI") or os.path.join(os.path.expanduser("~"), ".local", "bin", "pool")


def pools(root):
    """Пулы ищем по манифесту — он же даёт лида. Способ тот же, что у сборщика.
    Возвращаем и причину пропуска: «тихо» и «не работает» обязаны различаться."""
    found, skipped = [], []
    root = os.path.normpath(root)
    depth0 = root.count(os.sep)
    for dp, dn, fn in os.walk(root):
        dn[:] = [d for d in dn if not d.startswith(".") and d not in ("node_modules", "archive")]
        if dp.count(os.sep) - depth0 > 3:
            dn[:] = []
            continue
        if "pool.manifest.json" not in fn:
            continue
        path = os.path.join(dp, "pool.manifest.json")
        dn[:] = []
        try:
            with open(path, encoding="utf-8") as f:
                m = json.load(f)
        except Exception as e:
            skipped.append((dp, "манифест не читается: %s" % e))
            continue
        slug, lead = m.get("slug"), m.get("lead")
        if not slug or not lead:
            skipped.append((dp, "в манифесте нет %s" % ("слага" if not slug else "лида")))
            continue
        # ⚠️ root из манифеста бывает от ЧУЖОЙ машины (после переноса пула там оставался путь
        # вида D:\...). Берём каталог, где лежит манифест, — он верен всегда.
        found.append(dict(slug=slug, lead=lead, dir=dp, bus=os.path.join(dp, ".bus")))
    return found, skipped


def roster(bus):
    """Состав пула. Файл или каталог — на боевой машине файл, но обе формы законны."""
    p = os.path.join(bus, ".control", "roster")
    try:
        if os.path.isdir(p):
            names = os.listdir(p)
        else:
            with open(p, encoding="utf-8", errors="replace") as f:
                names = f.read().splitlines()
    except Exception:
        return set()
    out = set()
    for n in names:
        n = n.strip()
        if not n or n.startswith(".") or n.startswith("#"):
            continue
        out.add(n.split("\t")[0])        # если однажды станет таблицей, имя всё равно первое
    return out


def letters(bus, since):
    """Письма пула, где бы они сейчас ни лежали: new -> cur -> archive.
    ⚠️ Считать только по archive нельзя: незаклеймённое письмо туда не попадает, а это и есть
    свежий трафик. Имя при переезде не меняется — проверено на живом, поэтому один и тот же
    id узнаётся в любом каталоге. Отсюда же обязанность звать это ОДИН раз за проход и
    схлопывать одинаковые id: между двумя listdir письмо успевает переехать и попасться дважды.
    `since` отсекает старьё по первым 13 знакам имени, не тратя разбор на весь архив."""
    out, seen_here = {}, None
    edge_ms = int(since * 1000)
    try:
        entries = os.listdir(bus)
    except OSError:
        return out
    dirs = [os.path.join(bus, "archive")]
    for e in entries:
        if e.startswith("."):
            continue
        for sub in ("new", "cur"):
            dirs.append(os.path.join(bus, e, sub))
    for d in dirs:
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if len(n) < 13 or not n[:13].isdigit():
                continue
            if int(n[:13]) < edge_ms:
                continue                  # дешёвый отсев ДО регулярки: архив в тысячи файлов
            m = NAME.match(n)
            if not m:
                continue
            mid = m.group("id")
            if mid in out:
                continue                  # то же письмо, найденное в двух каталогах на переезде
            nums = [int(s) for s in m.group("rest").split(".") if s.isdigit()]
            nums = [x for x in nums if 10 ** 12 < x < 10 ** 13]
            ts = (max(nums) if nums else int(mid[:13])) / 1000.0
            out[mid] = (ts, os.path.join(d, n))
    return out


def header(path):
    """Шапка письма: From, To и тема. Тело не читается.

    ⚠️ Ранний выход теперь наступает при трёх ключах. У письма БЕЗ темы его не будет, и функция
    прочтёт все 26 строк вместо шести — это не дефект, а осознанная плата: `header()` вызывается
    только для писем, впервые попавших в проход (архив отсекается по имени, посчитанные — по
    `seen`), то есть на боевом трафике это ноль-одно письмо за проход.
    """
    h = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for i, line in enumerate(f):
                if i > 25:
                    break
                line = line.rstrip("\n")
                if "Subject" not in h:
                    ms = SUBJ.match(line)
                    if ms:
                        # ⚠️ Тема НЕ уходит ни в состояние, ни в журнал, ни в текст письма —
                        # только сравнение с префиксом. Содержание по-прежнему не открывается.
                        # Берём ПЕРВОЕ вхождение: в живых письмах заголовок продублирован в теле.
                        h["Subject"] = ms.group(1)
                        continue
                mm = HDR.match(line)
                if mm:
                    h[mm.group(1)] = mm.group(2)
                    if len(h) == 3:
                        break
    except OSError:
        pass
    return h


def is_bridge_wake(path, h):
    """Служебная побудка моста, а не переписка ролей.

    🛑 Оба условия обязательны. Только вид — мало: `note-wake` шлют и роли, это единственный
    способ разбудить спящего соседа (замер 14.08: 47 таких писем из 814 в архиве pool-A,
    среди них финалы лида и передачи хроникёра). Только тема — тоже мало: роль вправе назвать
    письмо как угодно, а вид ставит CLI.

    ⚠️ Признак держится на ЧУЖОЙ строке: тему задаёт мост pool-A, файл не наш. За месяц
    формулировка менялась трижды, префикс `bridge: ` уцелел во всех — но если их builder его
    сменит, антифлуд молча вернётся к ложным тревогам. Лиду об этом сказано отдельным письмом:
    префикс стал контрактом между пулами.
    """
    return ".note-wake." in os.path.basename(path) and \
        h.get("Subject", "").startswith(BRIDGE_SUBJ)


def state_path(slug, bus):
    # ⚠️ ключ — не только слаг: два каталога с одним слагом (копия пула, восстановленный дубль)
    # делили бы состояние и сложили бы свои счёта в один
    tag = hashlib.sha1(os.path.abspath(bus).encode("utf-8")).hexdigest()[:8]
    return os.path.join(shop_home(), "flood", "%s.%s.json" % (slug, tag))


def load_state(slug, bus):
    try:
        with open(state_path(slug, bus), encoding="utf-8") as f:
            s = json.load(f)
        if not isinstance(s, dict):
            raise ValueError("состояние не словарь")
        s.setdefault("seen", [])
        s.setdefault("window", [])
        s.setdefault("last_fire", 0)
        s.setdefault("cursor", 0)
        s.setdefault("note", ["", 0])
        # ⚠️ setdefault обязателен: боевые состояния писались ДО этой правки и ключа не имеют.
        # Без него первый же проход дал бы KeyError, его проглотил бы `except` в pass_once, и
        # антифлуд печатал бы «СБОЙ» раз в минуту, оставаясь мёртвым.
        s.setdefault("wakes", [])
        s.setdefault("since_fire", 0)      # новых писем пула после последнего лидового
        s.setdefault("role_fired", {})     # роль -> [когда слали ей, её исходящих с тех пор]
        s.setdefault("role_note", {})      # роль -> [последний исход, когда записан]
        if not isinstance(s["role_fired"], dict) or not isinstance(s["role_note"], dict):
            raise ValueError("состояние испорчено")
        if not isinstance(s["since_fire"], (int, float)):
            raise ValueError("состояние испорчено")
        for v in s["role_fired"].values():
            if not (isinstance(v, list) and len(v) == 2
                    and all(isinstance(x, (int, float)) for x in v)):
                raise ValueError("состояние испорчено")
        if not isinstance(s["seen"], list) or not isinstance(s["window"], list) \
                or not isinstance(s["wakes"], list):
            raise ValueError("состояние испорчено")
        return s
    except Exception:
        return None                       # испорченное состояние = начать заново, а не упасть


def save_state(slug, bus, s):
    p = state_path(slug, bus)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(s, f, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())              # без этого жёсткая перезагрузка оставляет пустой файл,
    os.replace(tmp, p)                    # а пустой читается как «первый проход» и теряет гашение


def blocked(slug, lead, bus):
    """Когда напоминание НЕ отправляем. Не «пропускаем», а откладываем: гашение не заводим,
    иначе повод потеряется вместе с ожиданием."""
    if os.path.exists(os.path.join(shop_home(), "compacting", "%s__%s" % (slug, lead))):
        return "лид сжимается"
    c = os.path.join(bus, ".control")
    for f, why in (("shutdown-intent-" + lead, "пул гасится"),
                   ("clean-intent-" + lead, "идёт чистка"),
                   ("quiet-" + lead, "метка обслуживания"),
                   ("quiet-ALL", "метка обслуживания на пул")):
        if os.path.exists(os.path.join(c, f)):
            return why
    return None


def bridge_age(blast, now):
    """Сколько прошло с последней распознанной мостовой побудки — словами, для человека.

    Ноль означает «не видели ни разу», а не «только что»: состояние может быть молодым (пул
    переехал, файл состояния пересоздан), и различать это обязан читатель, а не догадка."""
    if not blast:
        return "ни разу"
    h = (now - blast) / 3600.0
    if h < 1:
        return "меньше часа назад"
    if h < 48:
        return "%d ч назад" % int(h)
    return "%d сут назад" % int(h / 24)


def body(total, pair, pair_n, wakes=0, age=None):
    """Текст машинный и короткий: на экране роли это алгоритм, а не письмо человека.
    Ответа не просим — дело лида посмотреть свой пул, а не отчитаться передо мной.

    ⚠️ Второе число печатается, когда побудки были: без него «стало тихо» неотличимо от
    «фильтр съел». Требование лида pool-A, довод его.
    """
    lines = ["За последний час между участниками пула — %d писем." % total]
    if wakes:
        lines.append("Служебных побудок моста за тот же час — %d, в счёт они не идут." % wakes)
    if age is not None and not wakes:
        # 🛑 Печатаем ФАКТ, а не вывод. «Похоже, префикс сменился» было бы утверждением, ложным
        # каждую тихую ночь; сколько времени мостовых не видно — проверяемое наблюдение, и роль
        # сама решит, что оно значит.
        lines.append("Служебных побудок моста за этот час нет; последняя — %s." % age)
    if pair:
        lines.append("Больше всего у пары %s и %s: %d." % (pair[0], pair[1], pair_n))
    lines += ["", "Посмотри, идёт ли размен по задаче. Если это эхо на мелочах — прекрати.",
              # Краткий вброс правила — поручение владельца 20.08: стандарт «когда отвечать»
              # периодически напоминается по поводу, и повод — ровно это письмо.
              "Правило шины (слово владельца): отвечать на выполненную задачу/сообщение —",
              "только если ответ прямо запрошен или итог меняет действия отправителя;",
              "иначе просто ack/dismiss.",
              "Отвечать не нужно."]
    return "\n".join(lines) + "\n"


def perrole_body(n_out):
    """Письмо САМОЙ роли — слово владельца 20.08: правила доставляются периодическими
    вбросами по поводу, и повод здесь — собственная плотность исходящих адресата.
    Текст машинный и короткий, содержание чужих писем не упоминается."""
    return "\n".join([
        "За последний час у тебя %d исходящих писем в шине — плотнее обычного." % n_out,
        "",
        "Посмотри, всё ли из них двигает задачу. Правила шины (слово владельца):",
        "- отвечать на выполненную задачу/сообщение — только если ответ прямо запрошен",
        "  или итог меняет действия отправителя; иначе просто ack/dismiss без письма;",
        "- ответ по существу шли reply в ТОТ ЖЕ тред (-InReplyTo), а не новым письмом:",
        "  новые письма на каждый ответ плодят дубли тредов;",
        "- закрываешь обязательство и добавить нечего — `pool close -Key <ключ>`:",
        "  событие вместо письма, ход другой стороны на это не тратится.",
        "",
        "Форму письма забыл — вызови скил `coordinating-on-the-pool-bus`: он печатает",
        "правила целиком, с образцами. Это дешевле, чем переписываться о форме.",
        "Отвечать на это письмо не нужно.",
    ]) + "\n"


def send(bus, lead, subject, text, dry):
    if dry:
        print("    [сухой прогон] -> %s: %s" % (lead, subject))
        return True, ""
    d = os.path.join(shop_home(), "flood")
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="body-", suffix=".md", dir=d)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        r = subprocess.run([pool_cli(), "send", "-To", lead, "-From", SENDER,
                            "-Subject", subject, "-BodyFile", tmp, "-BusRoot", bus],
                           capture_output=True, text=True, timeout=SENDTMO)
        if r.returncode == 0:
            return True, ""
        return False, (r.stderr or r.stdout).strip()[:200].replace("\n", " ")
    except Exception as e:
        return False, str(e)[:200]
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def log(row):
    p = os.path.join(shop_home(), "stats", "flood.tsv")
    os.makedirs(os.path.dirname(p), exist_ok=True)
    new = not os.path.exists(p)
    with open(p, "a", encoding="utf-8") as f:
        if new:
            f.write("epoch\tпул\tлид\tвсего_за_час\tпара\tписем_в_паре\tитог\n")
        f.write("\t".join(str(x) for x in row) + "\n")


def one_pool(p, now, dry, verbose):
    """Разбор одного пула. Возвращает строку для печати. Своё исключение наружу не пускает —
    иначе один сбойный пул уносит с собой все следующие, и механика молча мертва."""
    # Обязательства собираем ДО проверки состава: они есть и в пуле с одной ролью, где
    # переписки между ролями нет вовсе. Свой try — сбор не имеет права уронить антифлуд.
    try:
        ix = _oblig.pass_bus(p["bus"])
        if isinstance(ix, dict):
            _POOL_INDEX[p["bus"]] = ix
        if os.environ.get("SHOP_OBLIG_NOTIFY", "1") != "0":
            for role, n in _oblig.notify_authors(p["bus"], ix):
                print("  %-18s форма: письмо %s, замечаний %d" % (p["slug"], role, n))
    except Exception as exc:                                   # noqa: BLE001
        if verbose:
            print("  %-18s сбор обязательств: СБОЙ %s" % (p["slug"], exc))

    crew = roster(p["bus"])
    if len(crew) < 2:
        return "  %-18s пропуск: в составе %d роль(ей), переписываться не с кем" % (p["slug"], len(crew)) if verbose else None

    st = load_state(p["slug"], p["bus"])
    first = st is None
    if first:
        st = dict(seen=[], window=[], wakes=[], last_fire=0, cursor=now, note=["", 0],
                  started=now, blast=0, since_fire=0, role_fired={}, role_note={})

    # 🛑 Свежесть определяет ВРЕМЯ письма, а не «нет в списке известных»: список приходится
    # подрезать, иначе он растёт без предела, а подрезанный архив на следующем же проходе
    # выглядел бы новым целиком — тысячи шапок каждую минуту.
    # ⚠️ Курсор НЕ ходит назад: перевод часов иначе открыл бы заново уже посчитанную полосу
    # и разбудил бы лида на пустом месте.
    st.setdefault("blast", 0)
    if not isinstance(st["blast"], (int, float)):
        st["blast"] = 0
    cursor = min(st["cursor"], now)
    edge = cursor - GRACE
    seen = set(st["seen"])
    mail = letters(p["bus"], edge)

    fresh = []
    wake_fresh = []                      # побудки моста этого прохода — отметки времени
    if not first:
        for mid, (ts, path) in mail.items():
            if ts <= edge or mid in seen or ts > now + GRACE:
                continue
            h = header(path)
            a, b = h.get("From"), h.get("To")
            if a in crew and b in crew:
                if is_bridge_wake(path, h):
                    wake_fresh.append(ts)   # считаем отдельно, в окно переписки не кладём
                    # 🛑 Живёт ОТДЕЛЬНО от окна и НЕ обнуляется при срабатывании: окно отвечает на
                    # «сколько было за час», а это — на «когда видели в последний раз». Обнули его
                    # вместе с окном, и признак поломки контракта исчезнет ровно тогда, когда
                    # антифлуд начнёт врать.
                    if ts > st["blast"]:
                        st["blast"] = ts
                    continue
                fresh.append([ts, "|".join(sorted((a, b))), a])

    win = [w for w in st["window"] + fresh if now - w[0] <= WINDOW]
    total = len(win)
    # 🛑 Побудки живут на ТОЙ ЖЕ шкале, что и окно переписки. Локальный счётчик мерил бы минуту
    # (интервал таймера) и докладывал как час — при срабатывании число оказывалось бы нулём или
    # заниженным на порядок, то есть подтверждало бы «стало тихо» именно тогда, когда лид просил
    # отличить это от «фильтр съел».
    wake_win = [t for t in st["wakes"] + wake_fresh if now - t <= WINDOW]
    wakes = len(wake_win)
    pairs = {}
    for w in win:           # w = [ts, пара] в старом состоянии, [ts, пара, from] в новом
        pairs[w[1]] = pairs.get(w[1], 0) + 1
    top_key, top_n = (max(pairs.items(), key=lambda kv: kv[1]) if pairs else (None, 0))
    # Счёт повторности: свежие письма двигают и общий счётчик, и счётчики ролей, уже
    # получавших напоминание (у не получавших первое письмо счётом не ограничено).
    st["since_fire"] += len(fresh)
    for w in fresh:
        rf = st["role_fired"].get(w[2])
        if rf:
            rf[1] += 1

    outcome = None
    if not first and (st["last_fire"] == 0 or st["since_fire"] >= LEAD_RESEND) and (total >= N_TOTAL or top_n >= N_PAIR):
        why = blocked(p["slug"], p["lead"], p["bus"])
        if why:
            outcome = "отложено: " + why
        else:
            subj = "антифлуд: %d писем за час" % total
            pair = tuple(top_key.split("|")) if top_key else None
            was_fire, was_win, was_wakes, was_since = st["last_fire"], win, wake_win, st["since_fire"]
            if not dry:
                # 🛑 Гашение ставим ДО отправки. Упади процесс между отправкой и записью —
                # напоминание уже ушло, а состояние сказало бы «не было», и лида будили бы
                # каждую минуту. Потерять одно напоминание дешевле, чем устроить шквал.
                st["last_fire"], st["window"], st["cursor"] = now, [], now
                st["wakes"] = []          # обнуляем симметрично окну, иначе счёт поедет
                st["since_fire"] = 0
                st["seen"] = sorted(mid for mid, (ts, _) in mail.items() if now - ts <= GRACE)
                save_state(p["slug"], p["bus"], st)
            ok, err = send(p["bus"], p["lead"], subj,
                           body(total, pair, top_n, wakes, bridge_age(st["blast"], now)), dry)
            if ok:
                outcome = "отправлено"
                if not dry:              # сухой прогон окно не трогает: диагностика read-only
                    win = []
            else:
                outcome = "ошибка отправки: " + err
                if not dry:                # живы и знаем, что не ушло, — гашение снимаем
                    st["last_fire"], win, wake_win = was_fire, was_win, was_wakes
                    st["since_fire"] = was_since
                    st["window"] = win   # и на диск тем же движением: пер-ролевой save_state
                                         # ниже иначе зафиксировал бы пустое окно


    # ─── Пер-ролевой канал: напоминание САМОЙ роли при плотных исходящих ───
    # Мостовые побудки в окно не попадают (см. is_bridge_wake) — хозяин моста не получает
    # напоминаний за службу. При лидовой отправке окно обнулено, роли копят заново — это
    # намеренно: два письма разом (лидовое + пер-ролевое) были бы дублем об одном событии.
    by_from = {}
    if not first:                        # на первом проходе окно и так пусто; пусть это видно
        for w in win:
            if len(w) > 2 and w[2]:
                by_from[w[2]] = by_from.get(w[2], 0) + 1
    role_lines = []
    for role in sorted(by_from):
        n_out = by_from[role]
        if n_out < PERROLE_HOURLY:
            continue
        if role not in crew:
            continue                     # выбыла из ростера, а письма её ещё в окне
        rf = st["role_fired"].get(role)
        if rf and rf[1] < PERROLE_RESEND:
            continue                       # недавно напоминали, её новых исходящих ещё мало
        why = blocked(p["slug"], role, p["bus"])
        if why:
            r_outcome = "отложено: " + why
        else:
            if not dry:
                # Гашение ДО отправки — тот же довод, что у лидового письма выше.
                st["role_fired"][role] = [now, 0]
                save_state(p["slug"], p["bus"], st)
            ok, err = send(p["bus"], role, "антифлуд: %d исходящих за час" % n_out,
                           perrole_body(n_out), dry)
            if ok:
                r_outcome = "отправлено"
            else:
                r_outcome = "ошибка отправки: " + err
                if not dry:                # живы и знаем, что не ушло, — гашение снимаем
                    if rf is not None:
                        st["role_fired"][role] = rf
                    else:
                        st["role_fired"].pop(role, None)
        prev, when = st["role_note"].get(role, ["", 0])
        if r_outcome != prev or now - when > NOTE_TTL:
            log([int(now), p["slug"], role, n_out, "исходящие:" + role, n_out,
                 "роль: " + r_outcome])
            st["role_note"][role] = [r_outcome, now]
        role_lines.append("%s:%s" % (role, r_outcome))
        if r_outcome == "отправлено":
            # Одна пер-ролевая отправка за проход: отправка стоит до SENDTMO, а таймер ходит
            # раз в минуту. Счётчики персистентны — остальные роли получат письмо следующим
            # проходом, ничего не теряется.
            break
    if outcome:
        # один и тот же неизменившийся исход в журнал чаще раза в час не пишем: ночь под
        # меткой обслуживания иначе даёт полтысячи одинаковых строк
        prev, when = st.get("note", ["", 0])
        if outcome != prev or now - when > NOTE_TTL:
            log([int(now), p["slug"], p["lead"], total, top_key or "-", top_n, outcome])
            st["note"] = [outcome, now]

    st["role_fired"] = {r: v for r, v in st["role_fired"].items() if r in crew}
    st["role_note"] = {r: v for r, v in st["role_note"].items() if r in crew}
    st["window"], st["cursor"], st["wakes"] = win, max(cursor, now), wake_win
    st["seen"] = sorted(mid for mid, (ts, _) in mail.items() if now - ts <= GRACE)
    save_state(p["slug"], p["bus"], st)

    if verbose or outcome or role_lines:
        mark = "первый проход, история не считается" if first else (outcome or "тихо")
        if role_lines:
            mark += " · роли: " + ", ".join(role_lines)
        return "  %-18s всего %3d · пара %-22s %3d · мост %s · %s" % (
            p["slug"], total, top_key or "-", top_n, bridge_age(st["blast"], now), mark)
    return None


_POOL_INDEX = {}          # шина -> индекс обязательств, собранный на этом проходе


def pass_once(dry=False, only=None, verbose=False):
    now = time.time()
    _POOL_INDEX.clear()
    found, skipped = pools(workspace())
    if verbose:
        for d, why in skipped:
            print("  ПРОПУСК %s — %s" % (d, why))
        if not found:
            print("  пулов не найдено в %s" % workspace())
    for p in found:
        if only and p["slug"] != only:
            continue
        try:
            line = one_pool(p, now, dry, verbose)
        except Exception as e:
            line = "  %-18s СБОЙ: %s" % (p["slug"], e)
        if line:
            print(line)

    # Сводка по чужим шинам — общая по своей природе: её нельзя собрать, разбирая один пул.
    # Считается по ВСЕМ найденным шинам, а не только по тем, чей сбор удался: иначе шина,
    # где обходчик споткнулся, вечно хранила бы устаревшую сводку.
    try:
        _oblig.write_cross([p["bus"] for p in found], _POOL_INDEX)
    except Exception as e:                                     # noqa: BLE001
        print("  сводка по чужим шинам: СБОЙ %s" % e)

    # Сторож замера: сам напомнит, когда на боевом пуле накопится столько писем, чтобы итоги
    # внедрения было с чем сравнивать. Молчит, пока порог не достигнут, и после напоминания.
    try:
        import rollout_gate
        rollout_gate.main()
    except Exception as e:                                     # noqa: BLE001
        print("  сторож замера: СБОЙ %s" % e)


def main():
    ap = argparse.ArgumentParser(description="антифлуд-напоминание ведущему пула (один проход)")
    ap.add_argument("--dry-run", action="store_true", help="ничего не отправлять")
    ap.add_argument("--pool", help="только этот пул (слаг)")
    ap.add_argument("--verbose", action="store_true", help="печатать каждый пул и каждый пропуск")
    a = ap.parse_args()

    # 🛑 Два прохода разом ломают состояние: второй читает ещё не записанное первым, шлёт
    # второе напоминание и затирает окно. Таймер раз в минуту, отправка может занять дольше.
    os.makedirs(shop_home(), exist_ok=True)
    lock = open(os.path.join(shop_home(), "flood.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except IOError as e:
        if e.errno in (errno.EACCES, errno.EAGAIN):
            if a.verbose:
                print("  проход уже идёт — этот пропускаю")
            return 0
        raise
    pass_once(dry=a.dry_run, only=a.pool, verbose=a.verbose)
    return 0


if __name__ == "__main__":
    sys.exit(main())
