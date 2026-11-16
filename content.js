// 답변 생성 중(로딩)인지 감지해서 화면 위쪽 가운데에 알약을 띄운다.
// 알약은 진행 표시로 시작해 O/X 문제로 펼쳐지고, 답변이 오면 체크로 접힌다.
(() => {
  if (window.__enterQuizLoaded) return;
  window.__enterQuizLoaded = true;

  // ── 사이트별 "생성 중" 표시 ─────────────────────────────
  // 사이트가 화면 구조를 바꾸면 여기만 고치면 된다.
  const SITE_SELECTORS = {
    'claude.ai': [
      '[data-is-streaming="true"]',
      'button[aria-label="Stop response"]',
      'button[aria-label="응답 중지"]'
    ],
    'chatgpt.com': [
      'button[data-testid="stop-button"]',
      'button[aria-label="Stop streaming"]',
      'button[aria-label="스트리밍 중지"]'
    ]
  };
  const selectors =
    SITE_SELECTORS[location.hostname] || Object.values(SITE_SELECTORS).flat();
  const isStreaming = () => selectors.some((s) => document.querySelector(s));

  const POLL_MS = 400;
  const END_GRACE_MS = 1200; // 표시가 사라진 뒤 이만큼 지나면 끝난 것으로 본다
  const PENDING_TIMEOUT_MS = 8000; // 엔터를 눌렀는데 생성이 시작되지 않을 때
  const OPEN_DELAY_MS = 450; // 알약으로 잠깐 보였다가 문제로 펼쳐진다
  const AUTO_NEXT_MS = 4000;
  const SUMMARY_MS = 1600; // 접힌 알약에 오늘 기록을 보여 주는 시간

  // ── 저장소 (확장 프로그램 밖 테스트 페이지에서는 localStorage) ──
  const hasChrome =
    typeof chrome !== 'undefined' && chrome.storage && chrome.storage.local;
  const store = {
    get(keys) {
      return new Promise((resolve) => {
        try {
          if (hasChrome) return chrome.storage.local.get(keys, (v) => resolve(v || {}));
          const out = {};
          keys.forEach((k) => {
            const v = localStorage.getItem('enterquiz:' + k);
            if (v != null) out[k] = JSON.parse(v);
          });
          resolve(out);
        } catch (e) {
          resolve({});
        }
      });
    },
    set(obj) {
      try {
        if (hasChrome) return chrome.storage.local.set(obj);
        Object.keys(obj).forEach((k) =>
          localStorage.setItem('enterquiz:' + k, JSON.stringify(obj[k]))
        );
      } catch (e) {
        /* 확장 프로그램이 새로고침된 경우 등 — 무시 */
      }
    }
  };

  // ── 카드와 기록 ────────────────────────────────────────
  const todayKey = () => new Date().toLocaleDateString('sv'); // YYYY-MM-DD
  let cards = ENTER_DEFAULT_CARDS;
  let stats = {}; // { 문장: { right, wrong } }
  let day = { date: todayKey(), done: 0 };
  let streak = 0; // 연속 정답
  let enabled = true;

  async function loadData() {
    const v = await store.get(['customCardsText', 'stats', 'enabled', 'day', 'streak', 'packOff']);
    const parsed = enterParseCards(v.customCardsText || '').cards;
    // 내 문제가 없으면 기본 제공 퀴즈에서, 끈 과목(packOff)을 빼고 낸다.
    const off = new Set(v.packOff || []);
    const pack = ENTER_DEFAULT_CARDS.filter((c) => !off.has(c.topic));
    cards = parsed.length ? parsed : pack.length ? pack : ENTER_DEFAULT_CARDS;
    stats = v.stats || {};
    day = v.day && v.day.date === todayKey() ? v.day : { date: todayKey(), done: 0 };
    streak = v.streak || 0;
    enabled = v.enabled !== false;
  }
  if (hasChrome && chrome.storage.onChanged) {
    chrome.storage.onChanged.addListener((changes) => {
      if (changes.customCardsText || changes.enabled || changes.packOff) loadData();
    });
  }

  const summary = () =>
    day.done
      ? `오늘 ${day.done}문제` + (streak >= 2 ? ` · 연속 ${streak}` : '')
      : `문제 ${cards.length}개 준비됨`;

  let lastQ = null;
  function pickCard() {
    // 틀린 문제일수록 자주, 많이 맞힌 문제일수록 드물게.
    const pool = cards.length > 1 ? cards.filter((c) => c.q !== lastQ) : cards;
    const weights = pool.map((c) => {
      const s = stats[c.q] || { right: 0, wrong: 0 };
      return Math.max(0.25, 1 + 2 * s.wrong - 0.5 * s.right);
    });
    let r = Math.random() * weights.reduce((a, b) => a + b, 0);
    for (let i = 0; i < pool.length; i++) {
      r -= weights[i];
      if (r <= 0) return pool[i];
    }
    return pool[pool.length - 1];
  }

  // ── 화면 ───────────────────────────────────────────────
  // 색은 세 가지 뜻으로만 쓴다: 파랑 = 진행 중, 초록 = 정답·도착, 빨강 = 오답.
  const CSS = `
    :host { all: initial; }
    [hidden] { display: none !important; }
    .pill {
      --fg: #1c1b19; --sub: #77736a; --faint: #9a968c; --bg: #ffffff; --line: #e3e0d8;
      --ctl: #f3f1ec; --ctl-hover: #e9e6df; --run: #3b6fd4; --ok: #1a7f4b; --no: #c0392b;
      --ease: cubic-bezier(.2, .8, .2, 1);
      position: fixed; top: 14px; left: 50%; width: 250px; z-index: 2147483647; box-sizing: border-box;
      font: 14px/1.5 -apple-system, BlinkMacSystemFont, "Pretendard", "Apple SD Gothic Neo", "Malgun Gothic", sans-serif;
      background: var(--bg); color: var(--fg); border: 1px solid var(--line); border-radius: 20px;
      box-shadow: 0 8px 28px rgba(0,0,0,.14); padding: 8px 12px; overflow: hidden;
      opacity: 0; transform: translate(-50%, -8px); pointer-events: none;
      transition: opacity .18s ease, transform .18s ease, width .3s var(--ease), padding .3s var(--ease);
    }
    .pill.on { opacity: 1; transform: translate(-50%, 0); pointer-events: auto; }
    .pill.open { width: 330px; padding: 10px 14px 12px; }

    .head { display: flex; align-items: center; gap: 7px; font-size: 12px; color: var(--sub);
      white-space: nowrap; font-variant-numeric: tabular-nums; }
    .title { flex: 1; overflow: hidden; text-overflow: ellipsis; }
    .meta { color: var(--faint); }
    .open .meta, .pill:not(.open) .close { display: none; }
    .close { all: unset; cursor: pointer; padding: 0 2px; font-size: 16px; line-height: 1; color: var(--sub); }

    .orb { width: 16px; height: 16px; flex: none; }
    .ring { fill: none; stroke: var(--run); stroke-width: 2.5; stroke-linecap: round;
      stroke-dasharray: 22 44; transform-origin: 50% 50%; animation: spin 1s linear infinite; }
    .check { fill: none; stroke: var(--ok); stroke-width: 2.5; stroke-linecap: round; stroke-linejoin: round;
      stroke-dasharray: 14; stroke-dashoffset: 14; }
    /* 답변 도착: 고리가 닫히고 체크가 그려진다 */
    .done .ring { animation: none; stroke: var(--ok); stroke-dasharray: 44 0;
      transition: stroke-dasharray .4s ease, stroke .3s ease; }
    .done .check { stroke-dashoffset: 0; transition: stroke-dashoffset .35s ease-out .25s; }
    .done .title { color: var(--ok); font-weight: 600; }
    @keyframes spin { to { transform: rotate(360deg); } }

    /* 펼침: 높이는 grid 행으로, 너비는 .pill 에서 움직인다 */
    .fold { display: grid; grid-template-rows: 0fr; transition: grid-template-rows .3s var(--ease); }
    .open .fold { grid-template-rows: 1fr; }
    .body { min-height: 0; overflow: hidden; opacity: 0; transition: opacity .15s ease; }
    .open .body { opacity: 1; transition: opacity .2s ease .12s; }

    .topic { margin-top: 7px; font-size: 11px; font-weight: 600; color: var(--sub);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .q .blank { color: var(--run); font-weight: 750; }
    .q .shown { color: var(--ok); font-weight: 750; }
    .btn.word { font-size: 14px; padding: 10px 0; }
    .ask { margin-top: 8px; font-size: 12px; color: var(--faint);
      white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    .q { font-size: 16px; font-weight: 650; line-height: 1.45; margin: 6px 0 10px; word-break: keep-all; }
    .btns { display: flex; gap: 8px; }
    .btn { all: unset; flex: 1; text-align: center; cursor: pointer; padding: 8px 0; box-sizing: border-box;
      border-radius: 10px; font-size: 18px; font-weight: 700;
      background: var(--ctl); color: var(--fg); border: 1px solid var(--line);
      transition: background .2s ease, color .2s ease, border-color .2s ease, opacity .2s ease; }
    .btn:hover { background: var(--ctl-hover); }
    .btn:focus-visible, .close:focus-visible, .next:focus-visible { outline: 2px solid var(--run); outline-offset: 2px; }
    /* 답한 뒤: 정답 버튼이 초록으로, 잘못 고른 버튼이 빨강으로 채워진다 */
    .answered .btn { pointer-events: none; }
    .btn.right { background: var(--ok); border-color: var(--ok); color: #fff; }
    .btn.wrong { background: var(--no); border-color: var(--no); color: #fff; }
    .btn.dim { opacity: .4; }
    .fb { margin-top: 9px; }
    .verdict { font-weight: 700; }
    .verdict.ok { color: var(--ok); }
    .verdict.no { color: var(--no); }
    .why { color: var(--sub); font-size: 13px; }
    .foot { display: flex; align-items: center; justify-content: space-between;
      margin-top: 9px; font-size: 12px; color: var(--faint); font-variant-numeric: tabular-nums; }
    .next { all: unset; cursor: pointer; color: var(--run); font-weight: 600; }

    @media (prefers-color-scheme: dark) {
      .pill { --fg: #f1efe9; --sub: #a8a499; --faint: #807c73; --bg: #262624; --line: #3d3b37;
        --ctl: #34322f; --ctl-hover: #403d39; --run: #8fb3f5; --ok: #58c98a; --no: #f08477;
        box-shadow: 0 8px 28px rgba(0,0,0,.5); }
      .btn.right, .btn.wrong { color: #1c1b19; }
    }
    @media (prefers-reduced-motion: reduce) {
      .pill, .fold, .body, .open .body, .btn, .done .ring, .done .check { transition: none; }
      .ring { animation: none; }
    }
  `;

  const host = document.createElement('div');
  host.id = 'enter-quiz-host';
  const root = host.attachShadow({ mode: 'open' });
  root.innerHTML = `<style>${CSS}</style>
    <div class="pill" role="complementary" aria-label="로딩 중 O/X 복습">
      <div class="head">
        <svg class="orb" viewBox="0 0 20 20" aria-hidden="true">
          <circle class="ring" cx="10" cy="10" r="7"/><path class="check" d="M6.5 10.2l2.5 2.5 4.5-5"/>
        </svg>
        <span class="title" role="status"></span>
        <span class="meta"></span>
        <button class="close" aria-label="이번에는 닫기">×</button>
      </div>
      <div class="fold"><div class="body">
        <div class="ask" hidden></div>
        <div class="topic" hidden></div>
        <p class="q"></p>
        <div class="btns">
          <button class="btn" data-a="O" aria-label="O (맞다)">O</button>
          <button class="btn" data-a="X" aria-label="X (틀리다)">X</button>
        </div>
        <div class="fb" hidden><div class="verdict"></div><div class="why"></div></div>
        <div class="foot">
          <span class="score"></span>
          <span class="hint">⌥O · ⌥X</span>
          <button class="next" hidden>다음 문제 →</button>
        </div>
      </div></div>
    </div>`;
  const $ = (s) => root.querySelector(s);
  const pill = $('.pill');
  const isOn = () => pill.classList.contains('on');
  const isOpen = () => pill.classList.contains('open');

  let current = null;
  let answered = false;
  let revealed = false; // 빈칸 카드에서 정답을 열어 봤는지
  const timers = {};
  const after = (name, ms, fn) => {
    clearTimeout(timers[name]);
    timers[name] = setTimeout(fn, ms);
  };
  const cancel = (...names) => names.forEach((n) => clearTimeout(timers[n]));

  // 문제 문장. 빈칸 카드는 가려진 자리를 파랑 "[ ? ]"로, 정답을 연 뒤에는 초록 정답으로 보여 준다.
  function drawQuestion(reveal) {
    const q = $('.q');
    q.textContent = '';
    const segs = current.cloze ? current.segs : [{ t: current.q, blank: false }];
    segs.forEach((s) => {
      if (!s.blank) return q.append(s.t);
      const span = document.createElement('span');
      span.className = reveal ? 'shown' : 'blank';
      span.textContent = reveal ? s.t : current.hint ? `[ ${current.hint} ]` : '[ ? ]';
      q.append(span);
    });
  }

  // 버튼 글자를 바꾼다. x 를 비우면 버튼 하나만 보인다.
  function setButtons(o, x, hint) {
    const [bo, bx] = root.querySelectorAll('.btn');
    bo.textContent = o;
    bx.textContent = x || '';
    bx.hidden = !x;
    [bo, bx].forEach((b) => {
      b.classList.remove('right', 'wrong', 'dim');
      b.classList.toggle('word', o.length > 1);
    });
    $('.hint').textContent = hint;
  }

  function renderCard() {
    cancel('autoNext');
    const card = pickCard();
    lastQ = card.q;
    current = card.cloze ? { ...card, ...enterMakeCloze(card) } : card;
    answered = false;
    revealed = false;
    pill.classList.remove('answered');
    $('.topic').textContent = current.topic || '';
    $('.topic').hidden = !current.topic;
    drawQuestion(false);
    if (current.cloze) setButtons('정답 보기', '', '⌥O 정답 보기');
    else setButtons('O', 'X', '⌥O · ⌥X');
    $('.fb').hidden = true;
    $('.next').hidden = true;
    $('.hint').hidden = false;
    $('.score').textContent = summary();
  }

  // O/X 카드: O 또는 X 를 고른다.
  // 빈칸 카드: 첫 입력은 정답 보기, 그다음 O = 알았음, X = 몰랐음.
  function answer(choice) {
    if (!current || answered || !isOn() || !isOpen()) return;
    if (current.cloze && !revealed) {
      revealed = true;
      drawQuestion(true);
      setButtons('알았음', '몰랐음', '⌥O 알았음 · ⌥X 몰랐음');
      $('.verdict').textContent = '';
      $('.why').textContent = current.why || '';
      $('.fb').hidden = !current.why;
      return;
    }
    answered = true;
    const correct = current.cloze ? choice === 'O' : (choice === 'O') === current.a;
    const s = stats[current.q] || { right: 0, wrong: 0 };
    correct ? s.right++ : s.wrong++;
    stats[current.q] = s;
    if (day.date !== todayKey()) day = { date: todayKey(), done: 0 };
    day.done++;
    streak = correct ? streak + 1 : 0;
    store.set({ stats, day, streak });

    pill.classList.add('answered');
    if (current.cloze) {
      root.querySelectorAll('.btn').forEach((b) => {
        b.classList.add(b.dataset.a !== choice ? 'dim' : correct ? 'right' : 'wrong');
      });
    } else {
      const rightKey = current.a ? 'O' : 'X';
      root.querySelectorAll('.btn').forEach((b) => {
        if (b.dataset.a === rightKey) b.classList.add('right');
        else b.classList.add(b.dataset.a === choice ? 'wrong' : 'dim');
      });
      const v = $('.verdict');
      v.textContent = correct ? '정답' : `오답 — 답은 ${rightKey}`;
      v.className = 'verdict ' + (correct ? 'ok' : 'no');
      $('.why').textContent = current.why || '';
      $('.fb').hidden = false;
    }
    $('.hint').hidden = true;
    $('.next').hidden = false;
    $('.score').textContent = summary();

    // 빈칸 카드는 이미 정답을 본 뒤라 빨리 넘어간다.
    if (state === 'idle') after('collapse', current.cloze ? 1500 : 2500, collapse);
    else after('autoNext', current.cloze ? 1200 : AUTO_NEXT_MS, () => state !== 'idle' && renderCard());
  }

  function show() {
    if (!enabled || dismissed) return;
    cancel('collapse', 'hide');
    if (!host.isConnected) document.documentElement.appendChild(host);
    pill.classList.remove('done');
    $('.meta').textContent = '';
    renderProgress();
    $('.ask').textContent = askText ? '내 질문: ' + askText : '';
    $('.ask').hidden = !askText;
    if (isOn() && isOpen()) return; // 지난 답변의 카드가 아직 열려 있으면 그대로 이어 간다
    requestAnimationFrame(() => pill.classList.add('on'));
    after('open', OPEN_DELAY_MS, () => {
      if (state === 'idle') return;
      renderCard();
      pill.classList.add('open');
    });
  }

  // 문제를 접고, 오늘 기록을 잠깐 보여 준 뒤 사라진다.
  function collapse() {
    cancel('autoNext', 'open');
    pill.classList.remove('open');
    $('.meta').textContent = day.done ? summary() : '';
    after('hide', SUMMARY_MS, hide);
  }

  function hide() {
    cancel('autoNext', 'open', 'collapse', 'hide');
    pill.classList.remove('on', 'open');
  }

  $('.btns').addEventListener('click', (e) => {
    const b = e.target.closest('.btn');
    if (b) answer(b.dataset.a);
  });
  $('.next').addEventListener('click', () => {
    if (state === 'idle') collapse();
    else renderCard();
  });
  $('.close').addEventListener('click', () => {
    dismissed = true;
    hide();
  });

  // ── 로딩 감지 ──────────────────────────────────────────
  let state = 'idle'; // idle | pending(엔터 직후) | streaming
  let dismissed = false; // 이번 답변 동안 사용자가 닫았는지
  let pendingAt = 0;
  let lastSeen = 0;
  let startedAt = 0; // 이번 요청을 보낸 시각
  let askText = ''; // 방금 보낸 질문 (한 줄로 보여 준다)

  const elapsedSec = () => Math.max(0, Math.round((Date.now() - startedAt) / 1000));

  function renderProgress() {
    $('.title').textContent = `답변 생성 중 · ${elapsedSec()}초`;
  }

  function begin(text) {
    if (state !== 'idle') return;
    state = 'pending';
    pendingAt = startedAt = Date.now();
    askText = (text || '').trim().replace(/\s+/g, ' ').slice(0, 80);
    dismissed = false;
    show();
  }

  function finish() {
    const wasStreaming = state === 'streaming';
    state = 'idle';
    dismissed = false;
    cancel('autoNext', 'open');
    if (!isOn()) return;
    if (!wasStreaming) return hide(); // 엔터만 누르고 생성이 시작되지 않은 경우
    pill.classList.add('done');
    $('.title').textContent = `답변 도착 · ${elapsedSec()}초`;
    // 풀던 문제는 마저 풀 수 있게 잠깐 남겨 둔다.
    if (isOpen()) after('collapse', answered ? 2000 : 6000, collapse);
    else collapse();
  }

  setInterval(() => {
    const now = Date.now();
    if (isStreaming()) {
      lastSeen = now;
      if (state !== 'streaming') {
        if (state === 'idle') {
          dismissed = false;
          startedAt = now;
          askText = '';
          state = 'streaming';
          show();
        }
        state = 'streaming';
      }
      renderProgress();
      return;
    }
    if (state === 'streaming' && now - lastSeen > END_GRACE_MS) finish();
    else if (state === 'pending' && now - pendingAt > PENDING_TIMEOUT_MS) finish();
    else if (state !== 'idle') renderProgress();
  }, POLL_MS);

  const editableOf = (t) =>
    t && t.closest ? t.closest('textarea, [contenteditable="true"], input[type="text"]') : null;

  document.addEventListener(
    'keydown',
    (e) => {
      // 단축키: 어디에 커서가 있든 Option(Alt)+O / Option(Alt)+X
      if (e.altKey && !e.metaKey && !e.ctrlKey && isOn() && isOpen() && !answered) {
        if (e.code === 'KeyO' || e.code === 'KeyX') {
          e.preventDefault();
          e.stopPropagation();
          answer(e.code === 'KeyO' ? 'O' : 'X');
          return;
        }
      }
      // 엔터로 전송 (한글 조합 중 엔터는 제외)
      if (e.key !== 'Enter' || e.shiftKey || e.isComposing || e.keyCode === 229) return;
      const box = editableOf(e.target);
      if (!box) return;
      const text = (box.value != null ? box.value : box.innerText) || '';
      if (text.trim()) begin(text);
    },
    true
  );

  document.addEventListener(
    'click',
    (e) => {
      const b = e.target.closest && e.target.closest('button');
      if (!b) return;
      const label = (b.getAttribute('aria-label') || '') + (b.dataset.testid || '');
      if (!/send|보내기|전송/i.test(label)) return;
      const box = document.querySelector('[contenteditable="true"], textarea');
      begin(box ? (box.value != null ? box.value : box.innerText) || '' : '');
    },
    true
  );

  loadData();
})();
