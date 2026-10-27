/* update-ui.js — 자동 업데이트 화면 조각 (바닐라 JS, 외부 라이브러리 없음)
   ① 새 버전을 받아 두면 화면 위에 알림 띠를 보여 줍니다  ② 설정 화면에 id="update-settings" 칸이 있으면 버전 정보와 [지금 업데이트 확인] 버튼을 채웁니다.
   사용: <script src="/update-ui.js"></script>  (설정 화면에 <div id="update-settings"></div> 추가) */
(function () {
  'use strict';
  var API = '/api/update/';
  var dismissed = false, restarting = false, timer = null, fast = 0;

  function el(tag, attrs, text) {
    var e = document.createElement(tag);
    if (attrs) for (var k in attrs) e.setAttribute(k, attrs[k]);
    if (text != null) e.textContent = text;          // 커밋 메시지 등은 항상 textContent로만 넣음
    return e;
  }
  var css = el('style', null,
    '#upd-banner{position:fixed;top:0;left:0;right:0;z-index:99999;display:none;align-items:center;gap:12px;flex-wrap:wrap;padding:10px 16px;background:#14532d;color:#fff;font:14px/1.4 "Malgun Gothic",system-ui,sans-serif;box-shadow:0 2px 8px rgba(0,0,0,.25)}' +
    '#upd-banner b{font-weight:700}#upd-banner button{font:inherit;padding:6px 14px;border-radius:6px;border:1px solid rgba(255,255,255,.6);background:transparent;color:#fff;cursor:pointer}' +
    '#upd-banner button.main{background:#fff;color:#14532d;font-weight:700}' +
    '#update-settings{font:14px/1.6 "Malgun Gothic",system-ui,sans-serif}#update-settings .upd-row{margin:4px 0}#update-settings .upd-muted{opacity:.7}' +
    '#update-settings button{font:inherit;padding:6px 14px;border-radius:6px;border:1px solid currentColor;background:transparent;color:inherit;cursor:pointer}#update-settings button:disabled{opacity:.5;cursor:default}' +
    '#update-settings .upd-msg{margin-top:8px;min-height:1.4em}#update-settings .upd-err{color:#b91c1c}');
  document.head.appendChild(css);

  var banner = el('div', { id: 'upd-banner', role: 'status' });
  document.body.appendChild(banner);

  function call(path, method) {
    return fetch(API + path, { method: method || 'GET', headers: { 'X-Requested-With': 'update-ui' }, cache: 'no-store' })
      .then(function (r) { return r.json(); });
  }
  function fmtDate(s) {
    if (!s) return '';
    var d = new Date(s); if (isNaN(d.getTime())) return s;
    return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
  }
  function fmtTime(s) {
    if (!s) return '';
    var d = new Date(s); if (isNaN(d.getTime())) return '';
    return fmtDate(s) + ' ' + ('0' + d.getHours()).slice(-2) + ':' + ('0' + d.getMinutes()).slice(-2);
  }

  function restart() {
    if (restarting) return; restarting = true;
    banner.style.display = 'flex'; banner.textContent = '다시 켜는 중입니다… 잠시만 기다려 주세요.';
    call('restart', 'POST').catch(function () {});
    var tries = 0;                                         // 새 프로그램이 뜰 때까지 기다렸다가 화면 새로고침
    var iv = setInterval(function () {
      tries++;
      fetch(API + 'status', { cache: 'no-store' }).then(function (r) { return r.json(); }).then(function (s) {
        if (tries > 3 && s && s.current) { clearInterval(iv); location.reload(); }
      }).catch(function () {});
      if (tries > 90) { clearInterval(iv); banner.textContent = '자동으로 다시 열리지 않았습니다. 프로그램을 직접 다시 실행해 주세요.'; }
    }, 1000);
  }

  function renderBanner(s) {
    if (restarting) return;
    var st = s.staged;
    if (st && !dismissed && !s.dev) {
      banner.style.display = 'flex'; banner.textContent = '';
      banner.appendChild(el('b', null, '새 버전을 받아 두었습니다'));
      banner.appendChild(el('span', null, [fmtDate(st.date), st.message].filter(Boolean).join(' · ')));
      var go = el('button', { 'class': 'main', type: 'button' }, '지금 다시 켜기');
      go.onclick = restart; banner.appendChild(go);
      var later = el('button', { type: 'button' }, '나중에 (다음에 켤 때 바뀜)');
      later.onclick = function () { dismissed = true; banner.style.display = 'none'; }; banner.appendChild(later);
    } else { banner.style.display = 'none'; }
  }

  var host = null, msgBox = null, btn = null, busy = false;
  function checkText(c) {
    if (!c) return '아직 확인하지 않았습니다.';
    return (c.text || '') + (c.checkedAt ? '  (' + fmtTime(c.checkedAt) + ')' : '');
  }
  function renderSettings(s) {
    if (!host) return;
    var keepMsg = msgBox ? msgBox.textContent : '', keepErr = msgBox ? msgBox.className : 'upd-msg';
    host.textContent = '';
    var cur = s.current || {};
    var r1 = el('div', { 'class': 'upd-row' });
    r1.appendChild(el('b', null, '현재 버전: '));
    r1.appendChild(document.createTextNode(cur.short ? cur.short + (cur.date ? ' · ' + fmtDate(cur.date) : '') : '(기록 없음)'));
    host.appendChild(r1);
    if (cur.message) host.appendChild(el('div', { 'class': 'upd-row upd-muted' }, cur.message));
    var c = s.check;
    var r2 = el('div', { 'class': 'upd-row upd-muted' }, '마지막 확인: ' + (s.dev ? '개발 폴더에서 실행 중이라 업데이트는 꺼져 있습니다.' : checkText(c)));
    host.appendChild(r2);
    btn = el('button', { type: 'button' }, '지금 업데이트 확인');
    btn.disabled = !!s.dev || busy;
    btn.onclick = manualCheck; host.appendChild(btn);
    msgBox = el('div', { 'class': keepErr, role: 'status' }, keepMsg); host.appendChild(msgBox);
  }

  function say(text, isErr) { if (msgBox) { msgBox.textContent = text; msgBox.className = 'upd-msg' + (isErr ? ' upd-err' : ''); } }

  function manualCheck() {
    if (busy) return; busy = true; if (btn) btn.disabled = true; say('확인하는 중…');
    call('check', 'POST').then(function (r) {
      if (r && r.dev) { busy = false; say('개발 폴더에서 실행 중이라 업데이트를 확인하지 않습니다.'); return; }
      var n = 0;
      (function poll() {
        call('status').then(function (s) {
          var c = s.check || {};
          if (c.state === 'checking' && n++ < 300) { setTimeout(poll, 800); return; }
          busy = false; renderSettings(s); renderBanner(s);
          if (c.state === 'uptodate') say('이미 최신입니다.');
          else if (c.state === 'staged' || s.staged) { say('새 버전을 받았습니다. 다시 켭니다…'); setTimeout(restart, 600); }
          else if (c.state === 'offline') say(c.text, true);
          else if (c.state === 'error') say(c.text, true);
          else say(c.text || '확인을 마쳤습니다.');
        }).catch(function () { busy = false; say('프로그램과 연결이 끊어졌습니다.', true); });
      })();
    }).catch(function () { busy = false; say('요청을 보내지 못했습니다.', true); });
  }

  function refresh() {
    call('status').then(function (s) {
      renderBanner(s);
      if (!busy) renderSettings(s);
      var checking = s.check && s.check.state === 'checking';
      schedule(checking || fast > 0 ? 3000 : 300000);
      if (fast > 0) fast--;
    }).catch(function () { schedule(30000); });
  }
  function schedule(ms) { clearTimeout(timer); timer = setTimeout(refresh, ms); }

  function start() { host = document.getElementById('update-settings'); fast = 20; refresh(); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
