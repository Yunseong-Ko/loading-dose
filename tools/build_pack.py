#!/usr/bin/env python3
"""기본 제공 퀴즈(packs/kmle.txt)를 크롬 확장이 읽는 pack.js 로 바꾼다.

문항 형식도 함께 검사한다. Mac 앱은 mac/build.sh 가 packs/kmle.txt 를 그대로 넣는다.
사용: python3 tools/build_pack.py
"""
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parent.parent
src = root / "packs" / "kmle.txt"
text = src.read_text(encoding="utf-8")

topic, counts, errors = None, {}, []
for n, line in enumerate(text.splitlines(), 1):
    raw = line.strip()
    if raw.startswith("##"):
        topic = raw[2:].strip()
        continue
    if not raw or raw.startswith("#"):
        continue
    parts = [p.strip() for p in raw.split("|")]
    if "{{c" in parts[0]:
        pass  # 빈칸 문제
    elif len(parts) < 2 or not parts[0] or parts[1].upper() not in ("O", "X"):
        errors.append(f"{n}번째 줄: 형식이 맞지 않습니다 — {raw[:40]}")
        continue
    if topic is None:
        errors.append(f"{n}번째 줄: '## 과목' 줄보다 앞에 있습니다")
        continue
    o, x = counts.get(topic, (0, 0))
    is_o = len(parts) > 1 and parts[1].upper() == "O"
    counts[topic] = (o + is_o, x + (not is_o))

if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)

out = root / "pack.js"
out.write_text(
    "// tools/build_pack.py 가 packs/kmle.txt 에서 만든 파일입니다. 직접 고치지 마세요.\n"
    f"const ENTER_PACK_TEXT = {json.dumps(text, ensure_ascii=False)};\n",
    encoding="utf-8",
)
for t, (o, x) in counts.items():
    print(f"{t}: {o + x}문항 (O {o}, X {x})")
print(f"→ {out.relative_to(root)}")
