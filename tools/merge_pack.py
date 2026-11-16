#!/usr/bin/env python3
"""과목별 문항 파일(packs/parts/*.txt)을 검사해서 packs/kmle.txt 로 합친다.

순환기처럼 kmle.txt 에만 있는 과목은 그대로 두고, parts 에 있는 과목은 그 내용으로 바꾼다.
형식이 틀린 줄이나 과목 안에서 겹치는 문장이 있으면 합치지 않고 알려 준다.
사용: python3 tools/merge_pack.py   (그다음 tools/build_pack.py, mac/build.sh)
"""
import pathlib
import re
import sys

root = pathlib.Path(__file__).resolve().parent.parent
pack = root / "packs" / "kmle.txt"
parts = root / "packs" / "parts"

# 앱에 보이는 과목 순서
ORDER = [
    "해부학", "생화학", "생리학", "병리학", "약리학",
    "순환기", "호흡기", "소화기", "신장", "내분비", "혈액", "종양", "감염", "알레르기", "류마티스",
    "외과 총론", "외과 각론", "산과", "부인과", "소아청소년과 총론", "소아청소년과 각론",
    "정신건강의학과", "마이너", "예방의학", "의료법규",
]


def read_sections(text):
    """'## 과목' 단위로 나눠 {과목: [문항 줄]} 과 머리말 줄을 돌려준다."""
    head, sections, topic = [], {}, None
    for line in text.splitlines():
        raw = line.strip()
        if raw.startswith("##"):
            topic = raw[2:].strip()
            sections.setdefault(topic, [])
        elif topic is None:
            head.append(line)
        elif raw and not raw.startswith("#"):
            sections[topic].append(raw)
    return head, sections


def check(topic, lines):
    problems, seen = [], set()
    for n, raw in enumerate(lines, 1):
        f = [p.strip() for p in raw.split("|")]
        if len(f) != 3 or not f[0] or f[1] not in ("O", "X") or not f[2]:
            problems.append(f"{topic} {n}번: 형식 오류 — {raw[:50]}")
            continue
        key = re.sub(r"\W", "", f[0])
        if key in seen:
            problems.append(f"{topic} {n}번: 같은 문장이 두 번 — {f[0][:40]}")
        seen.add(key)
        if len(f[0]) > 95:
            problems.append(f"{topic} {n}번: 문장이 너무 김({len(f[0])}자) — {f[0][:40]}")
    return problems


head, sections = read_sections(pack.read_text(encoding="utf-8"))
problems = []
for path in sorted(parts.glob("*.txt")):
    _, got = read_sections(path.read_text(encoding="utf-8"))
    if len(got) != 1:
        problems.append(f"{path.name}: '## 과목' 줄이 정확히 하나여야 합니다 ({len(got)}개)")
        continue
    sections.update(got)

for topic, lines in sections.items():
    problems += check(topic, lines)
unknown = [t for t in sections if t not in ORDER]
if unknown:
    problems.append("과목 순서 목록(ORDER)에 없는 과목: " + ", ".join(unknown))

if problems:
    print("\n".join(problems), file=sys.stderr)
    sys.exit(1)

out = [line for line in head if line.strip()]
total = 0
for topic in ORDER:
    if topic not in sections:
        continue
    lines = sections[topic]
    o = sum(1 for raw in lines if raw.split("|")[1].strip() == "O")
    print(f"{topic}: {len(lines)}문항 (O {o}, X {len(lines) - o})")
    total += len(lines)
    out += ["", f"## {topic}", *lines]
pack.write_text("\n".join(out) + "\n", encoding="utf-8")
print(f"합계 {total}문항, {sum(1 for t in ORDER if t in sections)}개 과목 → {pack.relative_to(root)}")
