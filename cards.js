// O/X 카드: { q: 문장, a: true(O) | false(X), why: 해설 }
// 빈칸 카드: { q: "… {{c1::정답}} …", cloze: true, why: 해설, topic: 단원 }  (Anki Cloze 형식 그대로)
// content.js 와 options.js 가 함께 쓴다.

// 기본 제공 퀴즈. pack.js(= packs/kmle.txt 를 tools/build_pack.py 로 변환한 것)에서 온다.
const ENTER_DEFAULT_CARDS = enterParseCards(typeof ENTER_PACK_TEXT === 'string' ? ENTER_PACK_TEXT : '').cards;

// 여러 줄 텍스트를 카드 배열로 바꾼다. 한 줄에 카드 하나:
//   O/X 카드   문장 | O 또는 X | 해설
//   빈칸 카드  문장 {{c1::정답}} | 해설 | 단원
//   "## 과목" 줄 아래의 카드는 그 과목(topic)으로 묶인다. 그 밖의 "#" 줄은 무시한다.
// 반환: { cards, errors: [줄 번호] }
function enterParseCards(text) {
  const cards = [];
  const errors = [];
  let topic = '';
  String(text || '').split('\n').forEach((line, i) => {
    const raw = line.trim();
    if (raw.startsWith('##')) {
      topic = raw.slice(2).trim();
      return;
    }
    if (!raw || raw.startsWith('#')) return;
    const parts = raw.split('|').map((s) => s.trim());
    if (/\{\{c\d+::/.test(parts[0])) {
      cards.push({ q: parts[0], cloze: true, a: true, why: parts[1] || '', topic: parts[2] || topic });
      return;
    }
    const ans = (parts[1] || '').toUpperCase();
    if (!parts[0] || (ans !== 'O' && ans !== 'X')) {
      errors.push(i + 1);
      return;
    }
    cards.push({ q: parts[0], a: ans === 'O', why: parts.slice(2).join(' | '), topic });
  });
  return { cards, errors };
}

// 빈칸 카드에서 빈칸 번호 하나를 골라 조각으로 나눈다. 나머지 빈칸은 정답을 채워 보여 준다.
// 반환: { segs: [{ t: 글, blank: 가릴지 }], hint }
function enterMakeCloze(card) {
  const matches = [...card.q.matchAll(/\{\{c(\d+)::([\s\S]*?)\}\}/g)];
  const ids = [...new Set(matches.map((m) => m[1]))];
  const chosen = ids[Math.floor(Math.random() * ids.length)];
  const segs = [];
  let pos = 0;
  let hint = '';
  matches.forEach((m) => {
    if (m.index > pos) segs.push({ t: card.q.slice(pos, m.index), blank: false });
    const inner = m[2].split('::');
    const blank = m[1] === chosen;
    if (blank && inner[1]) hint = inner[1];
    segs.push({ t: inner[0], blank });
    pos = m.index + m[0].length;
  });
  if (pos < card.q.length) segs.push({ t: card.q.slice(pos), blank: false });
  return { segs, hint };
}

function enterStripHtml(s) {
  const el = document.createElement('textarea');
  el.innerHTML = String(s || '')
    .replace(/<br\s*\/?>|<\/div>|<\/p>|<\/li>/gi, ' ')
    .replace(/<[^>]+>/g, '');
  return el.value.replace(/\s+/g, ' ').trim();
}

// Anki 의 "노트를 일반 텍스트로 내보내기(.txt)" 파일을 빈칸 카드 줄로 바꾼다.
// 반환: { lines: ["문장 | 해설 | 단원", …], skipped: 건너뛴 노트 수 }
function enterParseAnkiExport(text) {
  let sep = '\t';
  let deckCol = -1;
  let tagsCol = -1;
  let typeCol = -1;
  let guidCol = -1;
  // 머리말(#으로 시작하는 줄)을 읽고 떼어 낸다
  let body = String(text || '').replace(/^\uFEFF/, '');
  for (;;) {
    const m = body.match(/^#([^\n]*)\n/);
    if (!m) break;
    body = body.slice(m[0].length);
    const [k, v] = m[1].split(':').map((x) => x.trim());
    if (k === 'separator') sep = { tab: '\t', comma: ',', semicolon: ';', pipe: '|', space: ' ' }[v.toLowerCase()] || v;
    if (k === 'deck column') deckCol = Number(v) - 1;
    if (k === 'tags column') tagsCol = Number(v) - 1;
    if (k === 'notetype column') typeCol = Number(v) - 1;
    if (k === 'guid column') guidCol = Number(v) - 1;
  }
  // 따옴표로 감싼 칸(줄바꿈·구분자 포함 가능)을 처리하며 행으로 나눈다
  const rows = [];
  let row = [];
  let cell = '';
  let quoted = false;
  for (let i = 0; i < body.length; i++) {
    const ch = body[i];
    if (quoted) {
      if (ch === '"' && body[i + 1] === '"') { cell += '"'; i++; }
      else if (ch === '"') quoted = false;
      else cell += ch;
    } else if (ch === '"' && cell === '') quoted = true;
    else if (ch === sep) { row.push(cell); cell = ''; }
    else if (ch === '\n') { row.push(cell); rows.push(row); row = []; cell = ''; }
    else if (ch !== '\r') cell += ch;
  }
  if (cell || row.length) { row.push(cell); rows.push(row); }

  const meta = new Set([deckCol, tagsCol, typeCol, guidCol]);
  const safe = (s) => enterStripHtml(s).replace(/\|/g, '¦');
  const lines = [];
  let skipped = 0;
  rows.forEach((r) => {
    const at = r.findIndex((c, i) => !meta.has(i) && /\{\{c\d+::/.test(c));
    if (at < 0) return;
    const q = safe(r[at]);
    if (/<img/i.test(r[at]) || q.length > 260) { skipped++; return; }
    const extra = at + 1 < r.length && !meta.has(at + 1) ? safe(r[at + 1]) : '';
    const topic = deckCol >= 0 && r[deckCol] ? safe(r[deckCol]).split('::').pop() : '';
    lines.push([q, extra, topic].join(' | ').replace(/( \| )+$/, ''));
  });
  return { lines, skipped };
}

function enterCardsToText(cards) {
  let topic = '';
  const lines = [];
  cards.forEach((c) => {
    if ((c.topic || '') !== topic) {
      topic = c.topic || '';
      if (topic) lines.push(`## ${topic}`);
    }
    lines.push(`${c.q} | ${c.a ? 'O' : 'X'} | ${c.why || ''}`);
  });
  return lines.join('\n');
}
