const $ = (id) => document.getElementById(id);

function say(msg, bad) {
  $('status').textContent = msg;
  $('status').className = bad ? 'bad' : '';
}

chrome.storage.local.get(['customCardsText', 'enabled'], (v) => {
  $('text').value = v.customCardsText || '';
  $('enabled').checked = v.enabled !== false;
});

$('save').addEventListener('click', () => {
  const text = $('text').value;
  const { cards, errors } = enterParseCards(text);
  if (errors.length) {
    say(`형식이 맞지 않는 줄: ${errors.join(', ')}번째 줄 — "문장 | O | 해설" 형식인지 확인하세요. 저장하지 않았습니다.`, true);
    return;
  }
  chrome.storage.local.set({ customCardsText: text }, () => {
    say(cards.length ? `${cards.length}문제 저장됨` : `비어 있어 기본 제공 퀴즈 ${ENTER_DEFAULT_CARDS.length}문제가 나옵니다.`);
  });
});

$('anki').addEventListener('click', () => $('ankiFile').click());
$('ankiFile').addEventListener('change', async () => {
  const file = $('ankiFile').files[0];
  if (!file) return;
  const { lines, skipped } = enterParseAnkiExport(await file.text());
  $('ankiFile').value = '';
  if (!lines.length) {
    say('이 파일에서 빈칸(Cloze) 카드를 찾지 못했습니다. Anki에서 "노트를 일반 텍스트로" 내보낸 파일인지 확인하세요.', true);
    return;
  }
  const head = $('text').value.trim();
  $('text').value = (head ? head + '\n' : '') + `# Anki: ${file.name}\n` + lines.join('\n') + '\n';
  say(`빈칸 카드 ${lines.length}장을 추가했습니다` + (skipped ? ` (그림이 있거나 너무 긴 ${skipped}장은 제외)` : '') + '. 저장을 눌러야 반영됩니다.');
});

$('sample').addEventListener('click', () => {
  $('text').value = enterCardsToText(ENTER_DEFAULT_CARDS);
  say('기본 제공 퀴즈를 불러왔습니다. 고친 뒤 저장을 누르세요.');
});

$('reset').addEventListener('click', () => {
  chrome.storage.local.set({ stats: {} }, () => say('정답 기록을 초기화했습니다.'));
});

$('enabled').addEventListener('change', () => {
  chrome.storage.local.set({ enabled: $('enabled').checked }, () =>
    say($('enabled').checked ? '카드를 띄웁니다.' : '카드를 띄우지 않습니다.')
  );
});

// ── 기본 제공 퀴즈 과목 선택 ──
// 끈 과목 이름을 packOff 에 저장한다 (새 과목이 추가되면 기본으로 켜지도록).
const topicCounts = new Map();
ENTER_DEFAULT_CARDS.forEach((c) => topicCounts.set(c.topic, (topicCounts.get(c.topic) || 0) + 1));

function savePackOff() {
  const off = [...$('topics').querySelectorAll('input')].filter((i) => !i.checked).map((i) => i.value);
  chrome.storage.local.set({ packOff: off }, () => {
    const on = topicCounts.size - off.length;
    say(on ? `기본 제공 퀴즈: ${on}개 과목 선택됨` : '과목을 하나도 고르지 않아 전체 과목에서 나옵니다.');
  });
}

chrome.storage.local.get(['packOff'], (v) => {
  const off = new Set(v.packOff || []);
  topicCounts.forEach((count, topic) => {
    const label = document.createElement('label');
    const box = document.createElement('input');
    box.type = 'checkbox';
    box.value = topic;
    box.checked = !off.has(topic);
    box.addEventListener('change', savePackOff);
    const small = document.createElement('small');
    small.textContent = `${count}문항`;
    label.append(box, topic, small);
    $('topics').append(label);
  });
});

function setAllTopics(checked) {
  $('topics').querySelectorAll('input').forEach((i) => (i.checked = checked));
  savePackOff();
}
$('topicsAll').addEventListener('click', () => setAllTopics(true));
$('topicsNone').addEventListener('click', () => setAllTopics(false));
