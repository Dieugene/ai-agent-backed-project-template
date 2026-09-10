// Общая обвязка панелей терминала: адрес ttyd, обёртка над рамкой (полосы прокрутки и Ctrl+V).
// Подключается и страницей-пультом (index.html), и отдельным окном панели (pane.html).
//
// 🛑 Общий файл, а не две копии: ровно на этом однажды разъехались enter.sh и pool-dash.sh —
// «копии разошлись, и в пульте не оказалось половины проверок» (console/README.md).
(() => {
  'use strict';

  // 🛑 Параметр term принимается ТОЛЬКО когда страница открыта с локального адреса (проба через
  // ssh-туннель) и только как http(s)-адрес: иначе ссылка вида ?term=javascript:… исполнила бы
  // чужой код в рамке от имени этой страницы — у того, кто уже вошёл по паролю.
  const q = new URLSearchParams(location.search);
  const local = /^(127\.0\.0\.1|localhost|\[::1\])$/.test(location.hostname);
  const raw = q.get('term') || '';
  const given = local && /^https?:\/\/[^\s"'<>]+$/.test(raw) ? raw.replace(/\/+$/, '') : '';
  const TERM = given || (location.origin + '/term');

  const esc = (s) => String(s).replace(/[&<>"]/g, c => ({'&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;'}[c]));

  const termUrl = (p) => {
    const a = p.kind === 'role' ? ['role', p.pool, p.role]
            : p.kind === 'pool' ? ['pool', p.pool] : ['desk'];
    return TERM + '/?' + a.map(x => 'arg=' + encodeURIComponent(x)).join('&');
  };

  // Полосы прокрутки внутри терминала рисует xterm.js в своей рамке — снаружи стилем не достать,
  // поэтому стиль вливаем внутрь. Оба набора свойств намеренно: scrollbar-* понимает Firefox,
  // ::-webkit-* — Chrome.
  const FRAME_CSS = `
    .xterm-viewport{scrollbar-width:thin;scrollbar-color:#2a3341 transparent}
    .xterm-viewport::-webkit-scrollbar{width:9px;height:9px}
    .xterm-viewport::-webkit-scrollbar-track{background:transparent}
    .xterm-viewport::-webkit-scrollbar-thumb{background:#2a3341;border-radius:6px}
    .xterm-viewport::-webkit-scrollbar-thumb:hover{background:#8fbce6}
  `;

  // Ctrl+V сам по себе в терминал не вставляет: xterm.js разбирает сочетание как управляющий
  // символ и ОТМЕНЯЕТ событие, поэтому браузер до своей вставки не доходит (проверено на стенде:
  // события paste нет вовсе, работают только Ctrl+Shift+V и Shift+Insert).
  // ⇒ Мы не вставляем сами, а СНИМАЕМ ПЕРЕХВАТ: гасим событие до xterm (stopPropagation) и
  // намеренно НЕ зовём preventDefault — тогда браузер делает свою обычную вставку, а xterm ловит
  // её как paste, ровно как при Ctrl+Shift+V.
  // 🛑 Читать буфер самим (`navigator.clipboard.readText`) НЕЛЬЗЯ: в обработчике клавиши с
  // модификатором у страницы нет пользовательского жеста, и вызов не отклоняется, а ВИСИТ, ожидая
  // разрешения, которое из этого пути не выдать (проверено: промис не завершился за две минуты,
  // ни вставки, ни ошибки). Отсюда же правило: путей, где ответа можно не дождаться вовсе, в
  // обработчике клавиш быть не должно.
  // ⚠️ Ловим по e.code, а не по e.key: в русской раскладке Ctrl+V даёт key='м'.
  function onFrameKey(e) {
    if (e.code !== 'KeyV' || !e.ctrlKey || e.shiftKey || e.altKey || e.metaKey) return;
    e.stopPropagation();
  }

  // Одеть рамку: полосы прокрутки + Ctrl+V. Возвращает true, если получилось.
  // ⚠️ Не достучаться до рамки можно ровно в одном законном случае — проба через ssh-туннель:
  // страница на 7680, терминал на 7681, для браузера это разные адреса. На настоящем адресе за
  // прокси адрес один, и тот же отказ означает ПОЛОМКУ (например, прокси стал отдавать /term с
  // другого имени) — тогда говорим вслух, а не молчим.
  function dressFrame(fr, say) {
    let doc = null;
    try { doc = fr.contentDocument; } catch (e) { doc = null; }
    if (!doc || !doc.head) {
      if (!local && typeof say === 'function') {
        say('терминал открыт с другого адреса — полосы прокрутки и Ctrl+V в нём не работают', true);
      }
      return false;
    }
    try {
      if (!doc.getElementById('shopweb-frame-style')) {
        const st = doc.createElement('style');
        st.id = 'shopweb-frame-style';
        st.textContent = FRAME_CSS;
        doc.head.appendChild(st);
      }
      doc.removeEventListener('keydown', onFrameKey, true);
      doc.addEventListener('keydown', onFrameKey, true);
      return true;
    } catch (e) {
      if (!local && typeof say === 'function') say('в терминал не влезть: ' + (e && e.message || e), true);
      return false;
    }
  }

  window.ShopWeb = {TERM, ASKED: given, LOCAL: local, esc, termUrl, dressFrame};
})();
