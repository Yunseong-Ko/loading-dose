#!/usr/bin/env python3
"""펫(흰오목눈이)의 픽셀 스프라이트 시트를 만든다.

한 프레임은 36x28 픽셀이고 바닥은 y=26 이다. 옆모습은 오른쪽을 본다.
결과: omogi/pet/sprites.png (프레임을 가로로 이어 붙인 한 장) — 프레임 순서는 FRAMES 와 같고,
omogi/pet.swift 의 Frame 열거형 순서와 맞아야 한다.
사용: python3 tools/make_pet_sprites.py [미리보기.png]   (미리보기는 8배 확대한 확인용 그림)
"""
import pathlib
import sys

from PIL import Image, ImageDraw

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "omogi" / "pet" / "sprites.png"
W, H = 36, 28

WHITE = (255, 255, 255, 255)
SHADE = (218, 224, 233, 255)     # 배 아래쪽 그늘
LINE = (58, 63, 72, 255)         # 흰 몸의 테두리
DARK = (44, 48, 56, 255)         # 날개, 꼬리, 다리
DARK2 = (98, 106, 120, 255)      # 날개·꼬리의 밝은 줄
EYE = (24, 25, 30, 255)
PINK = (242, 190, 203, 255)
BLUE = (120, 170, 240, 255)      # 땀방울
CLEAR = (0, 0, 0, 0)


# 몸: 행마다 (왼쪽 끝, 오른쪽 끝) — 머리 깃 한 줄 + 지름 16픽셀의 동그라미
BODY = [(7, 8),
        (5, 10), (3, 12), (2, 13), (1, 14), (1, 14),
        (0, 15), (0, 15), (0, 15), (0, 15), (0, 15), (0, 15),
        (1, 14), (1, 14), (2, 13), (3, 12), (5, 10)]
# 날개: 자세마다 {행: (왼쪽, 오른쪽)}. 좌표는 몸의 왼쪽 위가 (0, 0).
WINGS = {
    "fold": {8: (5, 8), 9: (3, 8), 10: (2, 8), 11: (2, 7), 12: (3, 5)},
    "up": {-3: (1, 2), -2: (1, 4), -1: (2, 5), 0: (2, 6), 1: (3, 7), 2: (4, 8), 3: (5, 8), 4: (5, 8), 5: (6, 8), 6: (6, 8)},
    "mid": {6: (5, 8), 7: (0, 8), 8: (-3, 8), 9: (-1, 7), 10: (3, 6)},
    "down": {7: (5, 8), 8: (4, 8), 9: (3, 8), 10: (2, 7), 11: (1, 6), 12: (0, 5), 13: (-1, 3), 14: (-1, 1)},
}
WING_LINE = {"fold": [(4, 10), (5, 10), (6, 10)], "up": [(3, -1), (4, 0), (5, 1), (6, 2)],
             "mid": [(0, 8), (1, 8), (2, 8), (3, 8), (4, 8)], "down": [(5, 9), (4, 10), (3, 11), (2, 12)]}
BX, GROUND = 10, 26          # 몸의 왼쪽 끝 x, 발바닥 y (발 가운데가 프레임 한가운데 x=18 에 온다)

# ───────────── 옷 ─────────────
# 물건마다 옆모습·앞모습에서 찍을 점을 몸 좌표(몸의 왼쪽 위가 0,0)로 적는다.
# 순서(=wear.png 의 줄 순서)를 바꾸면 pet.swift 와 Pet.cs 의 목록도 같이 바꿀 것.
WEAR_OUT = ROOT / "omogi" / "pet" / "wear.png"
BADGES = 25                  # 과목별 배지 (kmle.txt 의 과목 순서). 모양은 같고 색만 다르다.
ITEMS = ["scarf", "straw", "glasses", "scrubcap", "steth", "gradcap", "crown", "medal"] + [f"badge{i}" for i in range(BADGES)]

RED, RED2 = (222, 62, 58, 255), (168, 40, 46, 255)
STRAW, STRAW2, BAND = (236, 200, 124, 255), (190, 150, 82, 255), (200, 84, 70, 255)
TEAL, TEAL2 = (92, 184, 176, 255), (56, 138, 134, 255)
BLACK, GOLD, GOLD2 = (38, 40, 48, 255), (246, 204, 70, 255), (198, 150, 40, 255)
TUBE, STEEL = (66, 122, 212, 255), (170, 178, 192, 255)
RIM = (30, 30, 36, 255)


def span(y, l, r, c):
    return [(x, y, c) for x in range(l, r + 1)]


def ring(cx, cy):
    return [(cx + a, cy + b, RIM) for a, b in ((-1, -1), (0, -1), (1, -1), (-2, 0), (2, 0), (-2, 1), (2, 1), (-1, 2), (0, 2), (1, 2))]


def cap_cells(c, edge):
    """머리 위쪽 네 줄을 덮는 모자 (몸 모양을 따라간다)."""
    out = span(0, 5, 10, edge)                       # 머리 깃까지 덮는 둥근 윗면
    for y in range(1, 5):
        l, r = BODY[y]
        out += [(x, y, edge if x in (l, r) or y == 4 else c) for x in range(l, r + 1)]
    return out


# 옆모습 (오른쪽을 본다: 눈은 x=12, 부리는 x=16~17)
SIDE = {
    "scarf": span(10, 9, 15, RED) + span(11, 9, 15, RED) + [(10, 12, RED), (11, 12, RED), (10, 13, RED), (11, 13, RED), (10, 14, RED2), (11, 14, RED2)],
    "straw": span(-1, 5, 10, STRAW) + span(0, 4, 11, STRAW) + span(1, 4, 11, BAND) + span(2, 0, 17, STRAW) + span(3, 13, 17, STRAW2),
    "glasses": ring(12, 6) + span(6, 6, 9, RIM),
    "scrubcap": cap_cells(TEAL, TEAL2),
    "steth": [(9, 10, TUBE), (9, 11, TUBE), (10, 12, TUBE), (11, 13, TUBE), (12, 13, TUBE), (13, 12, TUBE), (14, 11, TUBE), (14, 10, TUBE),
              (11, 14, STEEL), (12, 14, STEEL), (11, 15, STEEL), (12, 15, STEEL)],
    "gradcap": span(0, 4, 11, BLACK) + span(1, 4, 11, BLACK) + span(-1, 1, 15, BLACK) + [(15, 0, GOLD), (15, 1, GOLD), (15, 2, GOLD2)],
    "crown": [(4, -3, GOLD), (11, -3, GOLD), (4, -2, GOLD), (7, -2, GOLD), (8, -2, GOLD), (11, -2, GOLD)] + span(-1, 4, 11, GOLD)
             + span(0, 4, 11, GOLD2) + [(7, -1, RED), (8, -1, RED)],
    "medal": [(12, 10, RED), (13, 10, RED), (12, 11, GOLD), (13, 11, GOLD), (12, 12, GOLD2), (13, 12, GOLD2)],
}
# 앞모습 (눈은 x=4, 11)
FRONT = {
    "scarf": span(10, 1, 14, RED) + span(11, 1, 14, RED) + [(9, 12, RED), (10, 12, RED), (9, 13, RED), (10, 13, RED), (9, 14, RED2), (10, 14, RED2)],
    "straw": span(-1, 4, 11, STRAW) + span(0, 3, 12, STRAW) + span(1, 3, 12, BAND) + span(2, -2, 17, STRAW) + span(3, -1, 0, STRAW2) + span(3, 15, 16, STRAW2),
    "glasses": ring(4, 6) + ring(11, 6) + [(7, 6, RIM), (8, 6, RIM)],
    "scrubcap": cap_cells(TEAL, TEAL2),
    "steth": [(3, 10, TUBE), (3, 11, TUBE), (4, 12, TUBE), (5, 13, TUBE), (6, 13, TUBE), (9, 13, TUBE), (10, 13, TUBE), (11, 12, TUBE),
              (12, 11, TUBE), (12, 10, TUBE), (7, 13, TUBE), (8, 13, TUBE), (7, 14, STEEL), (8, 14, STEEL), (7, 15, STEEL), (8, 15, STEEL)],
    "gradcap": span(0, 3, 12, BLACK) + span(1, 3, 12, BLACK) + span(-1, 0, 15, BLACK) + [(14, 0, GOLD), (14, 1, GOLD), (14, 2, GOLD2)],
    "crown": [(4, -3, GOLD), (11, -3, GOLD), (4, -2, GOLD), (7, -2, GOLD), (8, -2, GOLD), (11, -2, GOLD)] + span(-1, 4, 11, GOLD)
             + span(0, 4, 11, GOLD2) + [(7, -1, RED), (8, -1, RED)],
    "medal": [(7, 10, RED), (8, 10, RED), (7, 11, GOLD), (8, 11, GOLD), (7, 12, GOLD2), (8, 12, GOLD2)],
}


def badge_colors(i):
    """과목마다 다른 색 (밝은 면, 어두운 면)."""
    import colorsys
    h = (i * 0.618034) % 1.0                          # 이웃한 과목끼리 색이 멀어지게 황금비로 돌린다
    lit = tuple(int(c * 255) for c in colorsys.hsv_to_rgb(h, 0.62, 0.95)) + (255,)
    dim = tuple(int(c * 255) for c in colorsys.hsv_to_rgb(h, 0.75, 0.62)) + (255,)
    return lit, dim


RIBBON = (70, 74, 88, 255)
for _i in range(BADGES):
    _lit, _dim = badge_colors(_i)
    SIDE[f"badge{_i}"] = [(12, 10, RIBBON), (13, 10, RIBBON), (11, 11, _lit), (12, 11, _lit), (13, 11, _lit), (14, 11, _dim),
                          (11, 12, _lit), (12, 12, WHITE), (13, 12, _lit), (14, 12, _dim), (12, 13, _dim), (13, 13, _dim)]
    FRONT[f"badge{_i}"] = [(7, 10, RIBBON), (8, 10, RIBBON), (6, 11, _lit), (7, 11, _lit), (8, 11, _lit), (9, 11, _dim),
                           (6, 12, _lit), (7, 12, WHITE), (8, 12, _lit), (9, 12, _dim), (7, 13, _dim), (8, 13, _dim)]


def dress(put, table, wear, bx, by, shift, squash=0):
    """입은 물건을 몸 위에 찍는다. 납작해진 자세에서는 아래쪽 줄을 그만큼 올린다."""
    for name in wear:
        for (x, y, c) in table[name]:
            yy = y if y < 8 else max(8, y - squash)
            put(bx + x + shift(min(y, 8) if y < 8 else yy), by + yy, c)


def body_cells(rows):
    return {(x, y) for y, (l, r) in enumerate(rows) for x in range(l, r + 1)}


def paint_body(put, rows, bx, by, lean=None):
    """가장자리는 테두리, 안쪽은 흰색, 아래 네 줄은 그늘. lean 은 행마다 옆으로 미는 픽셀 수."""
    cells = body_cells(rows)
    for (x, y) in cells:
        edge = any((x + a, y + b) not in cells for a, b in ((1, 0), (-1, 0), (0, 1), (0, -1)))
        color = LINE if edge else (SHADE if y >= len(rows) - 4 else WHITE)
        put(bx + x + (lean(y) if lean else 0), by + y, color)


def frame(dy=0, squash=0, wing="fold", legs="stand", eye="open", tail="down", extra=None, lean=0, wear=()):
    """옆모습. dy: 몸을 위로 띄우는 픽셀 수, squash: 몸을 납작하게 누르는 픽셀 수(바닥은 그대로),
    lean: 머리 쪽이 앞으로 쏠리는 픽셀 수(꾸벅 조는 자세)."""
    img = Image.new("RGBA", (W, H), CLEAR)
    rows = BODY[:8] + BODY[8 + squash:]              # 가장 넓은 줄을 빼서 납작하게
    bx, by = BX, GROUND - 2 - (len(BODY) - 1) + squash - dy
    bottom = by + len(rows) - 1

    def sh(y):                                       # 위쪽 줄일수록 앞으로 민다
        if not lean:
            return 0
        return lean if y <= 4 else (lean + 1) // 2 if y <= 9 else 0

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            img.putpixel((x, y), c)

    # 꼬리: 몸 뒤에서 왼쪽으로 뻗는 두 줄 굵기의 막대
    ty = by + len(rows) - 6
    for i in range(9):
        x = bx - i
        y = {"down": ty + 1 + i // 2, "back": ty, "up": ty - i // 2}[tail]
        put(x, y, DARK)
        put(x, y + 1, DARK)

    # 다리
    if legs == "stand":
        for x in (bx + 5, bx + 10):
            put(x, bottom + 1, DARK)
            put(x, bottom + 2, DARK)
            put(x + 1, bottom + 2, DARK)
    elif legs == "crouch":
        for x in (bx + 5, bx + 10):
            put(x, bottom + 1, DARK)
            put(x + 1, bottom + 1, DARK)
    elif legs == "tuck":
        for x in (bx + 3, bx + 4, bx + 7, bx + 8):
            put(x, bottom + 1, DARK)
    # legs == "none": 둥지에 앉아 다리가 안 보인다

    paint_body(put, rows, bx, by, lean=sh)

    # 날개
    for y, (l, r) in WINGS[wing].items():
        for x in range(l, r + 1):
            put(bx + x + sh(y), by + y, DARK)
    for (x, y) in WING_LINE[wing]:
        put(bx + x + sh(y), by + y, DARK2)

    # 얼굴
    ex, ey = bx + 12 + sh(6), by + 6
    if eye == "open":
        put(ex, ey, EYE); put(ex, ey + 1, EYE)
    elif eye == "closed":
        put(ex - 1, ey + 1, EYE); put(ex, ey + 1, EYE)
    elif eye == "happy":
        put(ex - 1, ey + 1, EYE); put(ex, ey, EYE); put(ex + 1, ey + 1, EYE)
    elif eye == "sad":
        put(ex - 1, ey, EYE); put(ex, ey + 1, EYE)
    put(ex - 1, ey + 3, PINK); put(ex, ey + 3, PINK)
    put(bx + 16 + sh(7), ey + 1, DARK); put(bx + 17 + sh(7), ey + 1, DARK); put(bx + 16 + sh(7), ey + 2, DARK)   # 부리

    dress(put, SIDE, wear, bx, by, lambda y: sh(max(y, 0)), squash)

    if extra == "sweat":
        for x, y in ((15, -1), (15, -2), (16, -1)):
            put(bx + x, by + y, BLUE)
    elif extra == "zz":
        for ox, oy in ((16, -2), (20, -6)):          # 작은 z 두 개
            for x, y in ((0, 0), (1, 0), (2, 0), (1, 1), (0, 2), (1, 2), (2, 2)):
                put(bx + ox + x, by + oy + y, DARK2)
    return img


def front(eye="open", lean=0, wings="fold", wear=()):
    """앞모습. lean: 위쪽으로 갈수록 옆으로 미는 정도(1 이면 기우뚱), wings="up" 이면 양 날개를 쭉 편다(기지개)."""
    img = Image.new("RGBA", (W, H), CLEAR)
    rows = BODY
    bx, by = BX, GROUND - 2 - (len(BODY) - 1)
    bottom = by + len(rows) - 1

    def shift(y):                                    # 발은 그대로, 머리 쪽이 옆으로 기운다
        if not lean:
            return 0
        return 4 if y <= 2 else 3 if y <= 5 else 2 if y <= 8 else 1 if y <= 12 else 0

    def put(x, y, c):
        if 0 <= x < W and 0 <= y < H:
            img.putpixel((x, y), c)

    def at(x, y, c):                                 # 몸 좌표로 찍는다 (기울기 반영)
        put(bx + x + shift(y), by + y, c)

    # 꼬리: 몸 뒤 오른쪽 아래로 삐죽
    for i in range(6):
        put(bx + 12 + i, by + 13 + i // 2, DARK)
        put(bx + 12 + i, by + 14 + i // 2, DARK)
    for x in (bx + 5, bx + 10):
        put(x, bottom + 1, DARK)
        put(x, bottom + 2, DARK)
    put(bx + 4, bottom + 2, DARK)
    put(bx + 11, bottom + 2, DARK)

    paint_body(put, rows, bx, by, lean=shift)

    if wings == "up":                                # 어깨에서 비스듬히 위로 뻗은 날개
        for i in range(7):
            for x in (-1 - i, -i, 1 - i):
                put(bx + x, by + 7 - i, DARK)
            for x in (16 + i, 15 + i, 14 + i):
                put(bx + x, by + 7 - i, DARK)
        for i in range(1, 6):
            put(bx - i, by + 7 - i, DARK2)
            put(bx + 15 + i, by + 7 - i, DARK2)
    else:                                            # 양옆에 접은 날개
        for y in range(8, 14):
            l, r = rows[y]
            at(l, y, DARK); at(l + 1, y, DARK)
            at(r, y, DARK); at(r - 1, y, DARK)
        at(1, 7, DARK); at(14, 7, DARK)

    # 얼굴: 기우뚱할 때는 한쪽 눈이 한 칸 내려간다
    drop = 1 if lean else 0
    for ex, down in ((4, 0), (11, drop)):
        if eye == "open":
            at(ex, 6 + down, EYE); at(ex, 7 + down, EYE)
        elif eye == "happy":
            at(ex - 1, 7 + down, EYE); at(ex, 6 + down, EYE); at(ex + 1, 7 + down, EYE)
        else:
            at(ex - 1, 7 + down, EYE); at(ex, 7 + down, EYE)
    at(2, 9, PINK); at(3, 9, PINK)
    at(12, 9 + drop, PINK); at(13, 9 + drop, PINK)
    at(7, 8, DARK); at(8, 8, DARK)                   # 부리
    dress(put, FRONT, wear, bx, by, lambda y: shift(max(y, 0)))
    if lean:                                         # 물음표 대신 작은 점 두 개
        put(bx + 21, by + 1, DARK2); put(bx + 22, by, DARK2)
    return img


def rolled(quarters, wear=()):
    """눈 감고 웅크린 옆모습을 몸 한가운데를 축으로 시계 방향 90도씩 돌린 그림 (데굴 구르기)."""
    base = frame(eye="closed", legs="crouch", wear=wear)
    side = 36
    work = Image.new("RGBA", (side, side), CLEAR)
    work.paste(base, (0, 1))                         # 몸의 가운데 (17.5, 16.5) 를 작업판 한가운데로
    work = work.rotate(-90 * quarters, resample=Image.NEAREST)
    return work.crop((0, 1, W, 1 + H))


TWIG = [(122, 90, 60, 255), (156, 122, 82, 255), (92, 66, 43, 255)]   # 둥지: 기본, 밝은 가지, 어두운 바닥
GLASS = (150, 165, 185, 255)
WATER = (120, 180, 245, 255)
WATER_TOP = (196, 224, 252, 255)


def nest(stage):
    """둥지 그림만 따로. stage 1·2 는 짓는 중(가지 더미), 3 은 다 지은 그릇 모양."""
    img = Image.new("RGBA", (W, H), CLEAR)

    def twig(x, y):
        c = TWIG[2] if y == GROUND else TWIG[1] if (x * 3 + y * 5) % 4 == 0 else TWIG[0]
        if 0 <= x < W and 0 <= y < H:
            img.putpixel((x, y), c)

    if stage == 1:
        for x in range(22, 31):
            twig(x, GROUND)
        for x in range(24, 29):
            twig(x, GROUND - 1)
    elif stage == 2:
        for y, (l, r) in {GROUND: (8, 30), GROUND - 1: (9, 29), GROUND - 2: (20, 28)}.items():
            for x in range(l, r + 1):
                twig(x, y)
    else:
        rows = {GROUND: (7, 28), GROUND - 1: (6, 29), GROUND - 2: (5, 30), GROUND - 3: (5, 30),
                GROUND - 4: (4, 31)}
        for y, (l, r) in rows.items():
            for x in range(l, r + 1):
                twig(x, y)
        for x in (4, 5, 30, 31):                      # 양옆으로 올라온 테두리
            twig(x, GROUND - 5)
        for x in (3, 32):                             # 삐져나온 가지
            twig(x, GROUND - 5)
            twig(x, GROUND - 6)
    return img


def glass(level):
    """물컵 그림만 따로 (새의 부리 앞). level: 물 높이 1~3."""
    img = Image.new("RGBA", (W, H), CLEAR)
    left, right, top = 28, 33, GROUND - 11
    for y in range(top, GROUND + 1):
        img.putpixel((left, y), GLASS)
        img.putpixel((right, y), GLASS)
    for x in range(left, right + 1):
        img.putpixel((x, GROUND), GLASS)
    surface = GROUND - 1 - level * 3
    for y in range(surface, GROUND):
        for x in range(left + 1, right):
            img.putpixel((x, y), WATER_TOP if y == surface else WATER)
    return img


def calendar():
    """달력 한 장 (새의 부리 앞에 세워 든 모습)."""
    img = Image.new("RGBA", (W, H), CLEAR)
    left, right, top, bottom = 28, 35, GROUND - 11, GROUND - 2
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            edge = x in (left, right) or y in (top, bottom)
            c = LINE if edge else (226, 76, 60, 255) if y <= top + 2 else WHITE
            img.putpixel((x, y), c)
    for x, y in ((left + 2, top + 5), (left + 4, top + 5), (left + 2, top + 7), (left + 4, top + 7), (left + 5, top + 7)):
        img.putpixel((x, y), DARK2)                  # 날짜 칸
    return img


def letter(dy=0):
    """부리에 문 편지 봉투. dy 는 몸을 띄운 만큼(나는 자세는 2)."""
    img = Image.new("RGBA", (W, H), CLEAR)
    left, right, top = 26, 34, GROUND - 11 - dy
    bottom = top + 6
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            edge = x in (left, right) or y in (top, bottom)
            img.putpixel((x, y), LINE if edge else (255, 250, 238, 255))
    for i in range(1, 4):                            # 봉투 덮개의 V 자
        img.putpixel((left + i, top + i), DARK2)
        img.putpixel((right - i, top + i), DARK2)
    img.putpixel((left + 4, top + 4), (226, 76, 60, 255))    # 빨간 봉인
    return img


def book(page=0):
    """펼친 책 (새의 부리 앞에 세워 놓고 본다). page=1 이면 한 장을 넘기는 중."""
    img = Image.new("RGBA", (W, H), CLEAR)
    cover, paper, line = (176, 92, 70, 255), (255, 250, 238, 255), (190, 184, 172, 255)
    left, right, top, bottom = 26, 35, GROUND - 9, GROUND - 2
    for y in range(top, bottom + 1):
        for x in range(left, right + 1):
            edge = x in (left, right) or y == bottom
            img.putpixel((x, y), cover if edge else paper)
    mid = (left + right) // 2
    for y in range(top, bottom):
        img.putpixel((mid, y), line)                      # 가운데 접힌 곳
    for y in (top + 2, top + 4):
        for x in (left + 2, left + 3, mid + 2, mid + 3):
            img.putpixel((x, y), line)                    # 글줄
    if page:
        for y in range(top - 1, top + 3):
            img.putpixel((mid + 2, y), paper)             # 넘어가는 한 장
        img.putpixel((mid + 2, top - 2), line)
    return img


def over(*layers):
    """뒤에 올 그림부터 차례로 겹친다."""
    out = Image.new("RGBA", (W, H), CLEAR)
    for l in layers:
        out.alpha_composite(l)
    return out


# 순서를 바꾸면 omogi/pet.swift 의 Frame 도 같이 바꿀 것.
def build(wear=()):
    w = dict(wear=wear)
    return [
        ("sit0", frame(**w)),
        ("sit1", frame(squash=1, **w)),
        ("blink", frame(eye="closed", **w)),
        ("hop0", frame(squash=2, legs="crouch", **w)),                       # 웅크림
        ("hop1", frame(dy=3, legs="tuck", wing="mid", tail="back", **w)),    # 공중
        ("hop2", frame(squash=1, legs="crouch", tail="up", **w)),            # 착지
        ("fly0", frame(dy=2, legs="tuck", wing="up", tail="back", **w)),
        ("fly1", frame(dy=2, legs="tuck", wing="mid", tail="back", **w)),
        ("fly2", frame(dy=2, legs="tuck", wing="down", tail="back", **w)),
        ("happy0", frame(wing="up", eye="happy", tail="up", **w)),
        ("happy1", frame(dy=2, legs="tuck", wing="down", eye="happy", tail="up", **w)),
        ("sad", frame(squash=1, eye="sad", extra="sweat", **w)),
        ("sleep0", frame(squash=2, legs="crouch", eye="closed", extra="zz", **w)),
        ("sleep1", frame(squash=3, legs="crouch", eye="closed", **w)),
        ("front", front(**w)),
        ("frontBlink", front(eye="closed", **w)),
        ("tilt", front(lean=1, **w)),
        ("nod1", frame(squash=1, legs="crouch", eye="closed", lean=2, **w)),               # 고개가 떨어지기 시작
        ("nod2", frame(squash=2, legs="crouch", eye="closed", lean=4, extra="zz", **w)),   # 푹 숙임
        ("roll1", rolled(1, wear)),
        ("roll2", rolled(2, wear)),
        ("roll3", rolled(3, wear)),
        ("build1", over(frame(squash=1, lean=3, eye="closed", **w), nest(1))),                    # 가지를 물어다 놓음
        ("build2", over(frame(**w), nest(2))),
        ("nest0", over(frame(dy=-2, legs="none", eye="closed", tail="up", **w), nest(3))),        # 둥지에서 잠
        ("nest1", over(frame(dy=-2, squash=1, legs="none", eye="closed", tail="up", extra="zz", **w), nest(3))),
        ("drink0", over(glass(3), frame(**w))),
        ("drink1", over(glass(3), frame(squash=1, lean=4, eye="closed", **w))),                   # 부리를 컵에
        ("drink2", over(glass(1), frame(eye="happy", **w))),
        ("stretch", front(eye="happy", wings="up", **w)),                                         # 기지개
        ("cal0", over(calendar(), frame(**w))),
        ("cal1", over(calendar(), frame(eye="happy", tail="up", **w))),
        ("mailFly0", over(frame(dy=2, legs="tuck", wing="up", tail="back", **w), letter(2))),      # 편지를 물고 난다
        ("mailFly1", over(frame(dy=2, legs="tuck", wing="mid", tail="back", **w), letter(2))),
        ("mailFly2", over(frame(dy=2, legs="tuck", wing="down", tail="back", **w), letter(2))),
        ("mail0", over(frame(**w), letter())),                                                  # 편지를 물고 기다림
        ("mail1", over(frame(eye="happy", tail="up", **w), letter())),
        ("read0", over(frame(squash=1, legs="crouch", lean=1, **w), book())),                # 책을 본다 (공부 중)
        ("read1", over(frame(squash=1, legs="crouch", lean=1, eye="closed", **w), book(1))),  # 깜박이며 한 장 넘김
    ]


FRAMES = build()


def main():
    sheet = Image.new("RGBA", (W * len(FRAMES), H), CLEAR)
    for i, (_, im) in enumerate(FRAMES):
        sheet.paste(im, (i * W, 0))
    OUT.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(OUT)
    print(f"{len(FRAMES)}프레임 → {OUT.relative_to(ROOT)}")

    # 옷: 물건 하나만 입힌 그림에서 맨몸과 달라진 점만 남긴다. 줄 = 물건, 칸 = 프레임.
    wear = Image.new("RGBA", (W * len(FRAMES), H * len(ITEMS)), CLEAR)
    for row, name in enumerate(ITEMS):
        for i, ((_, bare), (_, worn)) in enumerate(zip(FRAMES, build((name,)))):
            for y in range(H):
                for x in range(W):
                    c = worn.getpixel((x, y))
                    if c != bare.getpixel((x, y)):
                        wear.putpixel((i * W + x, row * H + y), c)
    wear.save(WEAR_OUT)
    print(f"옷 {len(ITEMS)}개 → {WEAR_OUT.relative_to(ROOT)}")

    if len(sys.argv) > 1:                     # 확인용: 9열로 6배 확대, 회색 바탕
        k, cols = 6, 10
        rows = (len(FRAMES) + cols - 1) // cols
        prev = Image.new("RGBA", (W * k * cols, H * k * rows), (214, 214, 214, 255))
        for i, (_, im) in enumerate(FRAMES):
            big = im.resize((W * k, H * k), Image.NEAREST)
            prev.alpha_composite(big, ((i % cols) * W * k, (i // cols) * H * k))
        prev.save(sys.argv[1])
    if len(sys.argv) > 2:                     # 옷 확인용: 물건마다 몇 가지 자세를 입혀 본다
        k, show = 6, [0, 4, 6, 9, 13, 14, 16, 18, 19, 20, 24, 27, 29, 35]
        sets = [(n,) for n in ITEMS] + [("scarf", "glasses", "straw"), ("steth", "glasses", "scrubcap"), ("medal", "crown")]
        prev = Image.new("RGBA", (W * k * len(show), H * k * len(sets)), (214, 214, 214, 255))
        for r, ws in enumerate(sets):
            fr = build(ws)
            for c, i in enumerate(show):
                prev.alpha_composite(fr[i][1].resize((W * k, H * k), Image.NEAREST), (c * W * k, r * H * k))
        prev.save(sys.argv[2])


if __name__ == "__main__":
    main()
