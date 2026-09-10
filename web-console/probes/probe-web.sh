#!/usr/bin/env bash
# Проба обёртки входа из браузера БЕЗ ttyd: форма аргументов и маршрутизация web-entry.sh,
# список ролей web-serve.py. Служб не трогает; на ферму смотрит только через web-serve --roster.
#
#   probe-web.sh            → отказы обёртки + список
#   probe-web.sh --mutate   → плюс мутация: убрать проверку формы и убедиться, что проба краснеет
set -uo pipefail
CONSOLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="${1:-}"; [ "$ENTRY" = "--mutate" ] && ENTRY=""
ENTRY="${ENTRY:-$CONSOLE/web-entry.sh}"
fails=0
ok() { if [ "$2" -eq 0 ]; then echo "  ok   $1"; else echo "  FAIL $1 — $3"; fails=$((fails+1)); fi; }

# stdin не терминал → read в bye() читает EOF мгновенно, ждать минуту не приходится.
run() { bash "$ENTRY" "$@" </dev/null 2>&1; }
expect() {  # <ожидание в выводе> <аргументы…>
  local want="$1"; shift
  local out rc
  out=$(run "$@"); rc=$?
  if [ "$rc" -eq 1 ] && grep -qF -- "$want" <<<"$out"; then ok "web-entry $* → «$want»" 0
  else ok "web-entry $* → «$want»" 1 "rc=$rc: $(tr '\n' ' ' <<<"$out" | cut -c1-120)"; fi
}

echo "1. форма аргументов (до enter.sh дело не доходит)"
expect "не по форме"   role 'a;b' lead
expect "не по форме"   role demo-pool 'lead$(id)'
expect "не по форме"   role 'A-Z' lead
expect "не по форме"   role "$(printf 'x%.0s' $(seq 1 65))" lead
expect "ждёт два имени" role demo-pool
expect "ждёт два имени" role demo-pool lead extra
expect "ждёт одно имя"  pool
expect "не по форме"   pool '../x'
expect "аргументов не берёт" desk x
expect "Неизвестный вход" zzz
expect "Не сказано"

echo "2. маршрутизация: правильные аргументы уходят в enter.sh / shop-desk.sh"
# Подставные скрипты печатают, чем их позвали; CONSOLE подменить нельзя (берётся от файла),
# поэтому кладём копию обёртки в песочницу рядом с подставными.
SB=$(mktemp -d); mkdir -p "$SB/shop"
cp "$ENTRY" "$SB/web-entry.sh"
printf '#!/usr/bin/env bash\necho "ENTER:$#:$*"\n' > "$SB/enter.sh"
printf '#!/usr/bin/env bash\necho "DESK:$#:$*"\n' > "$SB/shop/shop-desk.sh"
out=$(SHOP_DIR="$SB/shop" bash "$SB/web-entry.sh" role demo-pool lead </dev/null 2>&1)
[ "$out" = "ENTER:2:demo-pool lead" ]; ok "role → enter.sh <пул> <роль>" $? "$out"
out=$(SHOP_DIR="$SB/shop" bash "$SB/web-entry.sh" pool demo-pool </dev/null 2>&1)
[ "$out" = "ENTER:1:demo-pool" ]; ok "pool → enter.sh <пул>" $? "$out"
# 🛑 Пульт обязан подниматься с «--warp»: без ключа он входит в роль ПРЯМО В СВОЕЙ панели
# (человек видит сессию под заголовком «пульт цеха») и уводит текущее окно рабочей сессии пула.
out=$(SHOP_DIR="$SB/shop" bash "$SB/web-entry.sh" desk </dev/null 2>&1)
[ "$out" = "DESK:1:--warp" ]; ok "desk → shop-desk.sh --warp" $? "$out"
grep -q "SHOP_ACTION_FILE" "$CONSOLE/web-entry.sh"; ok "у веб-пульта СВОЙ файл запроса" $? "общий делят локальный пульт и его обёртка — запрос заберёт первый прочитавший"
out=$(SHOP_DIR="$SB/nope" bash "$SB/web-entry.sh" desk </dev/null 2>&1)
grep -qF "Пульта цеха нет" <<<"$out"; ok "desk без пульта → сказано, чего нет" $? "$out"
rm -rf "$SB"

echo "3. список ролей web-serve.py --roster"
out=$(python3 "$CONSOLE/web-serve.py" --roster 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '"pools"' <<<"$out"; ok "roster печатается" $? "rc=$rc"
# ⚠️ Не «печатается», а «непустой при поднятой ферме»: с разделителем 0x1f список был зелёным и пустым.
n=$(grep -c '"roles"' <<<"$out"); [ "$n" -gt 0 ] || ! tmux -L "${SHOP_TMUX_SOCKET:-agents}" has-session 2>/dev/null
ok "в списке столько пулов, сколько сессий у фермы (или ферма не поднята)" $? "пулов в списке: $n"
! grep -q '"error"' <<<"$out"; ok "ошибки фермы нет" $? "$(grep '"error"' <<<"$out")"
! grep -q '"name": "view-' <<<"$out"; ok "видов в списке нет" $? ""
! grep -q '"name": "stand"' <<<"$out"; ok "стенда в списке нет" $? ""

echo "4. страница: синтаксис и правила, которые нельзя терять"
WEB="$CONSOLE/web"
if command -v node >/dev/null; then
  node --check "$WEB/panes.js" 2>/dev/null; ok "panes.js — синтаксис" $? "node --check ругается"
  # Скрипты страниц лежат внутри html, и опечатка в них убивает страницу целиком — вырезаем и
  # проверяем тем же node. Без этого «ВСЁ ЗЕЛЁНОЕ» стояло бы над несобирающейся страницей.
  for f in index.html pane.html; do
    python3 -c "import re,sys; h=open(sys.argv[1],encoding='utf-8').read(); print('\n;\n'.join(re.findall(r'<script(?![^>]*src)[^>]*>(.*?)</script>', h, re.S)))" "$WEB/$f" > "/tmp/probe-web-$f.js" 2>/dev/null
    node --check "/tmp/probe-web-$f.js" 2>/dev/null; ok "$f — синтаксис скрипта" $? "node --check ругается"
    rm -f "/tmp/probe-web-$f.js"
  done
else
  echo "  --   node нет, синтаксис не проверен"
fi
# ⚠️ Шаблоны ловят КОД, а не слово: сперва они искали просто «dressFrame» и «stopPropagation», и
# мутация проходила мимо — имя находилось в комментарии рядом (а «dressFrameX» ещё и содержит
# «dressFrame» подстрокой). Проверено мутациями: без скобок и границ проба зелёная на вырезанном.
grep -q "window.ShopWeb *=" "$WEB/panes.js"; ok "panes.js объявляет ShopWeb" $? ""
grep -qE "function dressFrame\(" "$WEB/panes.js"; ok "panes.js несёт dressFrame" $? ""
# 🛑 Регрессия, за которой следим ИМЕННО ТАК: чтение буфера из обработчика клавиши в Chrome не
# отклоняется, а ВИСИТ (проверено — промис не завершился за две минуты). Вернётся строка —
# Ctrl+V снова умрёт молча, и признака у этого нет никакого.
# Ищем ВЫЗОВ (со скобкой), а не упоминание: в шапке функции этот путь описан словами как
# запрещённый, и запрет на собственное объяснение — верный способ потерять объяснение.
! grep -qE "clipboard\.readText\(" "$WEB/panes.js"; ok "panes.js НЕ читает буфер сам" $? "вернулся вызов clipboard.readText() — Ctrl+V повиснет"
grep -qE "e\.stopPropagation\(\)" "$WEB/panes.js"; ok "panes.js снимает перехват Ctrl+V" $? "нет вызова e.stopPropagation() — вставка не заработает"
# 🛑 И ГРАНИЦА этого перехвата: он обязан срабатывать ТОЛЬКО на Ctrl+V. Мутация, снявшая проверку
# клавиши, оставляла пробу зелёной, а на деле гасила бы В ТЕРМИНАЛЕ ВСЕ клавиши — роль перестала
# бы принимать ввод вовсе.
grep -qE "e\.code !== 'KeyV'" "$WEB/panes.js"; ok "перехват сужен до клавиши V" $? "нет проверки e.code — перехватываются все клавиши"
grep -qE "!e\.ctrlKey \|\| e\.shiftKey" "$WEB/panes.js"; ok "перехват сужен до Ctrl без Shift" $? "иначе задет Ctrl+Shift+V, который работал"
# И обратное: preventDefault на том же пути убил бы вставку так же надёжно, как xterm.
! grep -qE "onFrameKey[\s\S]{0,400}e\.preventDefault\(\)" "$WEB/panes.js"; ok "в обработчике Ctrl+V нет preventDefault" $? "вставку делает браузер — отменять событие нельзя"
for f in index.html pane.html; do
  grep -q 'src="panes.js"' "$WEB/$f"; ok "$f подключает panes.js" $? ""
  grep -qi "доехал panes.js" "$WEB/$f"; ok "$f говорит о недоехавшем panes.js" $? "без этого будет пустое окно молча"
done
grep -q "sessionStorage.removeItem" "$WEB/pane.html"; ok "pane.html чистит чужой набор панелей" $? ""
grep -q "charCodeAt(0).toString(16)" "$WEB/index.html"; ok "имена отдельных окон различимы" $? "схлопывание имён вернёт чужое окно"
# 🛑 Перетаскивание: зона сброса включается по событию на ОКНЕ. Пока файл висит над панелью,
# события забирает документ рамки терминала, и «dragenter» на самой панели не наступает вовсе —
# владелец видел «панель не готова принять». Проверяем именно это, а не наличие зоны.
grep -qE "window.addEventListener\('dragenter'" "$WEB/index.html"; ok "перетаскивание слушается на окне" $? "вернётся слушатель на панели — зона не включится"
grep -q "body.dragging .drop" "$WEB/index.html"; ok "зоны включаются классом на body" $? ""
grep -q 'data-a="up"' "$WEB/index.html"; ok "есть кнопка выбора файла (запасной путь)" $? "перетаскивание бывает запрещено политикой браузера"

echo "5. загрузка файлов со страницы — на ПОДДЕЛЬНОМ пространстве, боевые пулы не трогаем"
UPWS=/tmp/probe-webup-ws; UPHOME=/tmp/probe-webup-home; UPPORT=7699
rm -rf "$UPWS" "$UPHOME"; mkdir -p "$UPWS/pooldir/.bus/lead/new" "$UPWS/pooldir/.bus/architect/new" "$UPHOME"
cat > "$UPWS/pooldir/pool.manifest.json" <<'JSON'
{"schema":"pool-manifest/v1","slug":"probe-web","lead":"lead","root":"D:\\чужая","roles":["lead","architect"]}
JSON
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> %s/sent.log\nexit 0\n' "$UPHOME" > "$UPHOME/fake-pool"; chmod +x "$UPHOME/fake-pool"
# Приёмник берём НАСТОЯЩИЙ (в нём вся страховка), а пространство, журнал и отправку писем
# подменяем на поддельные — так проверяется весь путь, не задевая боевые пулы.
# 🛑 Порт обязан быть СВОБОДЕН. Иначе curl уйдёт в чужой экземпляр (стенд, забытая песочница),
# который пишет в своё пространство: файлы там, а проба смотрит здесь — «код 200, а файла нет».
# Поймано на себе 10.09: рядом крутился ручной стенд на этом же порту.
if curl -s -m 2 -o /dev/null "http://127.0.0.1:$UPPORT/health" 2>/dev/null; then
  ok "порт $UPPORT свободен под пробу" 1 "на нём уже кто-то отвечает — сначала погасите его"
  echo; echo "ПРОВАЛ: $fails"; exit 1
fi
SHOP_WORKSPACE="$UPWS" SHOP_HOME="$UPHOME" POOL_CLI="$UPHOME/fake-pool" \
  SHOP_DIR="${SHOP_DIR:-$HOME/workspace/.launcher/shop}" \
  SHOP_ACTION_FILE="$UPHOME/desk-action-web" \
  python3 "$CONSOLE/web-serve.py" --bind 127.0.0.1 --port $UPPORT >/dev/null 2>&1 &
UPPID=$!
for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -m 2 -o /dev/null "http://127.0.0.1:$UPPORT/health" && break; sleep 0.4; done
up() { curl -s -m 30 -o /tmp/probe-up.out -w "%{http_code}" -X POST --data-binary "$2" "http://127.0.0.1:$UPPORT/upload?$1"; }
code=$(up "pool=probe-web&role=architect&name=%D0%BF%D0%BB%D0%B0%D0%BD.md" "для архитектора")
[ "$code" = "200" ]; ok "файл роли принят (код 200)" $? "код $code: $(head -2 /tmp/probe-up.out | tr '\n' ' ')"
[ -f "$UPWS/pooldir/exchange/inbox/architect/план.md" ]; ok "лёг в подъящик роли" $? "$(ls -R "$UPWS/pooldir/exchange/inbox" 2>/dev/null | tr '\n' ' ')"
grep -q -- "-To architect " "$UPHOME/sent.log" 2>/dev/null; ok "письмо ушло роли" $? "$(cat "$UPHOME/sent.log" 2>/dev/null | tr '\n' '|')"
! grep -q -- "-To lead " "$UPHOME/sent.log" 2>/dev/null; ok "лида не тревожили" $? "$(cat "$UPHOME/sent.log" 2>/dev/null | tr '\n' '|')"
rm -f "$UPHOME/sent.log"
code=$(up "pool=probe-web&name=obshiy.txt" "всем")
[ "$code" = "200" ] && [ -f "$UPWS/pooldir/exchange/inbox/obshiy.txt" ]; ok "без роли — в общий ящик" $? "код $code"
grep -q -- "-To lead " "$UPHOME/sent.log" 2>/dev/null; ok "и письмо лиду" $? "$(cat "$UPHOME/sent.log" 2>/dev/null | tr '\n' '|')"
for bad in "pool=НЕ_ПУЛ&name=a.txt" "pool=probe-web&role=../x&name=a.txt" "pool=probe-web&name=" "pool=probe-web&role=НЕ_РОЛЬ&name=a.txt"; do
  code=$(up "$bad" "x")
  case "$code" in 400) ok "отказ на «$bad»" 0 ;; *) ok "отказ на «$bad»" 1 "код $code: $(head -1 /tmp/probe-up.out)" ;; esac
done
# 🛑 Имя с путём не отвергается, а ОБЕЗВРЕЖИВАЕТСЯ до последнего куска: браузеры и файловые
# менеджеры кладут в имя путь целиком, и отказ здесь читался бы как «страница сломалась».
# Важно не то, что мы ответили, а то, КУДА легло.
code=$(up "pool=probe-web&role=architect&name=..%2F..%2Fnaruzhu.txt" "x")
[ "$code" = "200" ] && [ -f "$UPWS/pooldir/exchange/inbox/architect/naruzhu.txt" ] \
  && [ ! -e "$UPWS/naruzhu.txt" ] && [ ! -e "$UPWS/pooldir/naruzhu.txt" ]
ok "путь в имени обезврежен, файл лёг в подъящик" $? "код $code"
# 🛑 Секреты: страница не предлагает «везти вместе с секретами» — это отдельное осознанное
# действие с пультом. Приёмник обязан придержать, а страница — сказать об этом словами.
code=$(up "pool=probe-web&role=architect&name=.env" "TOKEN=1")
[ "$code" = "200" ] && grep -q "придержал файл" /tmp/probe-up.out; ok "секрет придержан и назван" $? "код $code: $(head -3 /tmp/probe-up.out | tr '\n' ' ')"
[ ! -f "$UPWS/pooldir/exchange/inbox/architect/.env" ]; ok "и на диск не лёг" $? ""
echo "6. запрос от пульта: страница забирает его один раз и открывает панели сама"
ACT="$UPHOME/desk-action-web"
printf 'enter\tdemo-pool\tlead operator\n' > "$ACT"
A1=$(curl -s -m 5 "http://127.0.0.1:$UPPORT/desk-action")
grep -q '"what": "enter"' <<<"$A1" && grep -q '"pool": "demo-pool"' <<<"$A1" && grep -q '"lead", "operator"' <<<"$A1"
ok "запрос прочитан и разобран" $? "$A1"
[ ! -f "$ACT" ]; ok "файл запроса убран после чтения" $? "иначе панели откроются повторно"
A2=$(curl -s -m 5 "http://127.0.0.1:$UPPORT/desk-action")
[ "$(tr -d ' ' <<<"$A2")" = "{}" ]; ok "второй раз запроса нет" $? "$A2"

echo "7. обратная дорога: забрать из ящика пула то, что положили роли"
OUT="$UPWS/pooldir/exchange/outbox"
mkdir -p "$OUT/architect"
printf 'итог работы' > "$OUT/architect/отчёт.md"
printf 'общий' > "$OUT/просто.txt"
# 🛑 Ссылка наружу — не «странный файл», а способ вынести с сервера что угодно: проверяем, что
# ящик отдаёт только то, что в нём лежит на самом деле, а не то, куда указывает имя.
ln -sfn /etc/passwd "$OUT/увести.txt" 2>/dev/null
LIST=$(curl -s -m 10 "http://127.0.0.1:$UPPORT/outbox.json?pool=probe-web")
grep -q 'architect/отчёт.md' <<<"$LIST"; ok "файл роли виден в списке" $? "$LIST"
grep -q '"from": "architect"' <<<"$LIST"; ok "и помечен, от кого" $? "$LIST"
grep -q 'просто.txt' <<<"$LIST"; ok "общий файл тоже виден" $? "$LIST"
! grep -q 'увести.txt' <<<"$LIST"; ok "ссылка наружу в список НЕ попала" $? "$LIST"
code=$(curl -s -m 10 -o /tmp/probe-dl.out -w "%{http_code}" "http://127.0.0.1:$UPPORT/download?pool=probe-web&path=architect%2F%D0%BE%D1%82%D1%87%D1%91%D1%82.md")
[ "$code" = "200" ] && [ "$(cat /tmp/probe-dl.out)" = "итог работы" ]; ok "файл скачивается целиком" $? "код $code: $(head -c 60 /tmp/probe-dl.out)"
curl -s -m 10 -D /tmp/probe-hdr.out -o /dev/null "http://127.0.0.1:$UPPORT/download?pool=probe-web&path=%D0%BF%D1%80%D0%BE%D1%81%D1%82%D0%BE.txt"
grep -qi "content-disposition: attachment" /tmp/probe-hdr.out; ok "браузеру велено сохранить, а не показать" $? "$(grep -i content-disposition /tmp/probe-hdr.out)"
# ⚠️ Каждый параметр кодируется ОТДЕЛЬНО. С одной строкой «pool=…&path=…» curl закодировал бы и
# «&», и «=» внутрь одного значения: запрос уходил бы вообще без параметров и отбивался по
# пустому имени пула — то есть проверка была бы зелёной, ничего не проверяя. Поймано мутацией:
# снятие защиты путей проба не заметила.
dl_bad() {   # <ярлык> <пул> <путь>
  local code
  code=$(curl -s -m 10 -o /tmp/probe-dl.out -w "%{http_code}" --get \
         --data-urlencode "pool=$2" --data-urlencode "path=$3" "http://127.0.0.1:$UPPORT/download")
  case "$code" in 400) ok "скачивание отбито: $1" 0 ;;
                  *) ok "скачивание отбито: $1" 1 "код $code: $(head -c 80 /tmp/probe-dl.out)" ;; esac
}
dl_bad "путь наружу"        "probe-web" "../../../etc/passwd"
dl_bad "ссылка наружу"      "probe-web" "увести.txt"
dl_bad "пустой путь"        "probe-web" ""
dl_bad "чужое имя пула"     "НЕ_ПУЛ"    "просто.txt"
dl_bad "путь наружу глубже" "probe-web" "architect/../../../../etc/hostname"
code=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:$UPPORT/remove?pool=probe-web&path=architect%2F%D0%BE%D1%82%D1%87%D1%91%D1%82.md")
[ "$code" = "200" ] && [ ! -f "$OUT/architect/отчёт.md" ]; ok "убранный файл исчез" $? "код $code"
[ ! -d "$OUT/architect" ]; ok "пустая папка роли убрана следом" $? "$(ls "$OUT" | tr '\n' ' ')"
[ -f "$OUT/просто.txt" ]; ok "соседний файл не тронут" $? ""
printf 'не трогать' > /tmp/probe-chuzhoe.txt
code=$(curl -s -m 10 -o /dev/null -w "%{http_code}" -X POST \
       "http://127.0.0.1:$UPPORT/remove?pool=probe-web&path=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1],safe=''))" "../../../tmp/probe-chuzhoe.txt")")
[ "$code" = "400" ] && [ -f /tmp/probe-chuzhoe.txt ]; ok "удаление за пределами ящика отбито" $? "код $code, файл на месте: $([ -f /tmp/probe-chuzhoe.txt ] && echo да || echo НЕТ)"
rm -f /tmp/probe-chuzhoe.txt

kill "$UPPID" 2>/dev/null; wait "$UPPID" 2>/dev/null
rm -rf "$UPWS" "$UPHOME" /tmp/probe-up.out /tmp/probe-dl.out /tmp/probe-hdr.out

if [ "${1:-}" = "--mutate" ]; then
  echo "8. мутация: убираем проверку формы — проба обязана покраснеть"
  M=$(mktemp); sed 's/^ok_name() {.*/ok_name() { return 0; }/' "$CONSOLE/web-entry.sh" > "$M"
  out=$(bash "$M" role 'a;b' lead </dev/null 2>&1)
  if grep -qF "не по форме" <<<"$out"; then ok "мутант пойман" 1 "мутант всё ещё отказывает — проба не смотрит на форму"
  else ok "мутант пойман (форма больше не проверяется → отказа нет)" 0; fi
  rm -f "$M"
fi

echo
if [ "$fails" -eq 0 ]; then echo "ВСЁ ЗЕЛЁНОЕ"; else echo "ПРОВАЛ: $fails"; exit 1; fi
