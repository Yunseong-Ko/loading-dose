#!/usr/bin/env python3
"""인스타그램용 "오늘의 O/X" 카드 이미지를 만든다 (1080x1350, 문제 장 + 정답 장).

사용:
  python3 tools/make_cards.py --list 홍보/카드/목록.txt        목록 파일의 문항으로 만든다
  python3 tools/make_cards.py --random 5 --topic 약리학       그 과목에서 무작위로 5개
  python3 tools/make_cards.py --random 10                     전체에서 무작위로 10개

목록 파일은 한 줄에 문항 문장의 앞부분을 적는다 (packs/kmle.txt 의 문장과 앞이 같으면 된다).
결과는 홍보/카드/ 에 01-문제.png, 01-정답.png 처럼 저장된다. Pillow 가 필요하다 (pip install pillow).
기본 문항은 검수되지 않았으니, 올리기 전에 문항과 해설을 직접 확인할 것.
"""
import argparse
import pathlib
import random
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
PACK = ROOT / "packs" / "kmle.txt"
ICON = ROOT / "icons" / "icon128.png"
FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"   # macOS 기본 한글 글꼴
W, H = 1080, 1350

INK = (28, 28, 30)
SUB = (92, 90, 86)
FAINT = (150, 146, 140)
PANEL = (232, 229, 223)
BTN = (208, 205, 199)
GREEN = (72, 172, 66)
RED = (222, 66, 52)
WHITE = (255, 255, 255)


def font(size, weight="regular"):
    index = {"regular": 0, "medium": 2, "semibold": 4, "bold": 6}[weight]
    return ImageFont.truetype(FONT, size, index=index)


def load_pack():
    cards, topic = [], ""
    for line in PACK.read_text(encoding="utf-8").splitlines():
        raw = line.strip()
        if raw.startswith("##"):
            topic = raw[2:].strip()
            continue
        f = [p.strip() for p in raw.split("|")]
        if len(f) == 3 and f[1] in ("O", "X"):
            cards.append({"topic": topic, "q": f[0], "a": f[1], "why": f[2]})
    return cards


def wrap(draw, text, fnt, width):
    """낱말 단위로 줄을 나눈다. 낱말 하나가 너무 길면 글자 단위로 자른다."""
    lines, cur = [], ""
    for word in text.split(" "):
        trial = (cur + " " + word).strip()
        if draw.textlength(trial, font=fnt) <= width:
            cur = trial
            continue
        if cur:
            lines.append(cur)
        cur = word
        while draw.textlength(cur, font=fnt) > width:
            cut = len(cur)
            while cut > 1 and draw.textlength(cur[:cut], font=fnt) > width:
                cut -= 1
            lines.append(cur[:cut])
            cur = cur[cut:]
    if cur:
        lines.append(cur)
    # 마지막 줄에 낱말 하나만 남으면 앞줄에서 한 낱말을 내려 균형을 맞춘다.
    if len(lines) >= 2 and " " not in lines[-1] and " " in lines[-2]:
        head, tail = lines[-2].rsplit(" ", 1)
        if draw.textlength(tail + " " + lines[-1], font=fnt) <= width:
            lines[-2], lines[-1] = head, tail + " " + lines[-1]
    return lines


def fit(draw, text, weight, width, max_lines, sizes):
    """줄 수가 max_lines 이하가 되는 가장 큰 글자 크기를 고른다."""
    for size in sizes:
        fnt = font(size, weight)
        lines = wrap(draw, text, fnt, width)
        if len(lines) <= max_lines:
            return fnt, lines, size
    return fnt, lines, size


def draw_lines(draw, lines, fnt, x, y, fill, line_h, width=None, center=False):
    for i, line in enumerate(lines):
        lx = x + (width - draw.textlength(line, font=fnt)) / 2 if center else x
        draw.text((lx, y + i * line_h), line, font=fnt, fill=fill)
    return y + len(lines) * line_h


def background():
    img = Image.new("RGB", (W, H))
    px = img.load()
    top, bottom = (40, 46, 72), (20, 22, 34)
    for y in range(H):
        t = y / (H - 1)
        c = tuple(round(top[k] + (bottom[k] - top[k]) * t) for k in range(3))
        for x in range(W):
            px[x, y] = c
    return img


def header(img, draw, topic, number):
    if ICON.exists():
        icon = Image.open(ICON).convert("RGBA").resize((84, 84), Image.LANCZOS)
        img.paste(icon, (70, 78), icon)
    draw.text((174, 84), "오늘의 O/X", font=font(50, "bold"), fill=WHITE)
    draw.text((176, 144), f"#{number:02d}", font=font(26, "medium"), fill=(150, 158, 182))
    chip = font(32, "semibold")
    tw = draw.textlength(topic, font=chip)
    draw.rounded_rectangle((W - 70 - tw - 52, 92, W - 70, 156), 32, fill=(66, 74, 108))
    draw.text((W - 70 - tw - 26, 104), topic, font=chip, fill=(226, 230, 244))


def footer(draw, text):
    draw.text((W / 2, 1218), text, font=font(36, "semibold"), fill=(226, 230, 244), anchor="ma")
    draw.text((W / 2, 1280), "Loading Dose · AI 답변을 기다리는 동안 한 문제씩", font=font(26), fill=(140, 148, 172), anchor="ma")


def buttons(draw, y, answer=None):
    """answer 가 None 이면 문제 장(둘 다 회색), 아니면 정답 쪽만 색을 칠한다."""
    x0, gap, h = 110, 24, 150
    bw = (W - 2 * x0 - gap) // 2
    for i, label in enumerate("OX"):
        left = x0 + i * (bw + gap)
        if answer is None:
            fill, color = BTN, INK
        elif answer == label:
            fill, color = (GREEN if label == "O" else RED), WHITE
        else:
            fill, color = (220, 217, 211), (176, 172, 166)
        draw.rounded_rectangle((left, y, left + bw, y + h), 30, fill=fill)
        draw.text((left + bw / 2, y + h / 2), label, font=font(84, "bold"), fill=color, anchor="mm")
    return y + h


def question_card(card, number):
    img = background()
    draw = ImageDraw.Draw(img)
    header(img, draw, card["topic"], number)
    panel = (70, 230, W - 70, 1150)
    draw.rounded_rectangle(panel, 48, fill=PANEL)
    width = W - 2 * 110
    fnt, lines, size = fit(draw, card["q"], "bold", width, 7, [68, 62, 56, 50, 46])
    line_h = round(size * 1.42)
    block = len(lines) * line_h
    top, bottom = panel[1] + 60, 940
    draw_lines(draw, lines, fnt, 110, top + (bottom - top - block) / 2, INK, line_h)
    buttons(draw, 950)
    footer(draw, "맞으면 O, 틀리면 X — 정답은 다음 장에")
    return img


def answer_card(card, number):
    img = background()
    draw = ImageDraw.Draw(img)
    header(img, draw, card["topic"], number)
    panel = (70, 230, W - 70, 1150)
    draw.rounded_rectangle(panel, 48, fill=PANEL)
    width = W - 2 * 110
    fnt, lines, size = fit(draw, card["q"], "semibold", width, 5, [46, 42, 38, 34])
    y = draw_lines(draw, lines, fnt, 110, panel[1] + 56, SUB, round(size * 1.4))
    y = buttons(draw, y + 40, card["a"])
    color = GREEN if card["a"] == "O" else RED
    draw.text((110, y + 50), f"정답은 {card['a']}", font=font(64, "bold"), fill=color)
    wf, wl, ws = fit(draw, card["why"], "medium", width, 6, [46, 42, 38, 34])
    draw_lines(draw, wl, wf, 110, y + 160, INK, round(ws * 1.45))
    footer(draw, "틀린 곳이 보이면 댓글로 알려 주세요")
    return img


def main():
    ap = argparse.ArgumentParser(description="오늘의 O/X 카드 이미지 만들기")
    ap.add_argument("--list", help="문항 문장(앞부분)을 한 줄씩 적은 파일")
    ap.add_argument("--random", type=int, help="무작위로 뽑을 문항 수")
    ap.add_argument("--topic", help="--random 과 함께: 이 과목에서만 뽑는다")
    ap.add_argument("--out", default=str(ROOT / "홍보" / "카드"), help="저장할 폴더")
    ap.add_argument("--start", type=int, default=1, help="첫 카드 번호")
    args = ap.parse_args()

    cards = load_pack()
    picked = []
    if args.list:
        for line in pathlib.Path(args.list).read_text(encoding="utf-8").splitlines():
            key = line.strip()
            if not key or key.startswith("#"):
                continue
            found = [c for c in cards if c["q"].startswith(key)]
            if len(found) != 1:
                sys.exit(f"목록의 문항을 하나로 찾지 못함 ({len(found)}개): {key}")
            picked.append(found[0])
    elif args.random:
        pool = [c for c in cards if not args.topic or c["topic"] == args.topic]
        if not pool:
            sys.exit(f"과목을 찾지 못함: {args.topic}")
        picked = random.sample(pool, min(args.random, len(pool)))
    else:
        ap.error("--list 또는 --random 중 하나가 필요합니다")

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    for i, card in enumerate(picked, args.start):
        question_card(card, i).save(out / f"{i:02d}-문제.png")
        answer_card(card, i).save(out / f"{i:02d}-정답.png")
        print(f"{i:02d} [{card['topic']}] {card['a']} | {card['q']}")
    print(f"{len(picked)}세트 → {out}")


if __name__ == "__main__":
    main()
