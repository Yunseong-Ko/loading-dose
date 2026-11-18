#!/usr/bin/env python3
"""Omogi 소개 영상을 만든다: 앱과 같은 스프라이트로 장면을 그린 것 (화면 녹화가 아니다).

결과: assets/omogi-demo.gif (README·릴리스 페이지용), assets/omogi-poses.png (자세 모음)
      프레임 폴더를 주면 PNG 프레임도 저장한다 → tools/frames_to_mp4.swift 로 MP4 를 만든다.
사용: python3 tools/make_omogi_demo.py [프레임 폴더]
"""
import math
import pathlib
import sys

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import make_pet_sprites as pet  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
FONT = "/System/Library/Fonts/AppleSDGothicNeo.ttc"
W, H, FPS, K = 800, 450, 12, 4          # K: 스프라이트 1픽셀 = 화면 4픽셀
FLOOR = 384                             # 오모기가 다니는 바닥 (Dock 위)

BG = (241, 237, 229)
INK = (40, 42, 50)
SUB = (120, 116, 108)
LINE = (58, 63, 72)
PAPER = (252, 250, 246)
SPR = {name: im for name, im in pet.FRAMES}


def font(size, weight="regular"):
    return ImageFont.truetype(FONT, size, index={"regular": 0, "medium": 2, "semibold": 4, "bold": 6}[weight])


def base(caption, sub=None):
    img = Image.new("RGBA", (W, H), BG + (255,))
    d = ImageDraw.Draw(img)
    # 메뉴 막대와 Dock 을 아주 단순하게
    d.rectangle((0, 0, W, 26), fill=(230, 226, 217))
    face = SPR["front"].crop((8, 5, 28, 28)).resize((20, 23), Image.NEAREST)
    img.alpha_composite(face, (W - 96, 2))
    d.text((W - 64, 5), "오후 2:10", font=font(13, "medium"), fill=SUB)
    d.rounded_rectangle((250, FLOOR + 8, W - 250, H - 10), 16, fill=(226, 221, 211))
    for i, c in enumerate([(120, 170, 240), (242, 190, 203), (150, 200, 150), (240, 200, 120), (170, 160, 220)]):
        d.rounded_rectangle((276 + i * 52, FLOOR + 17, 276 + i * 52 + 36, FLOOR + 49), 9, fill=c)
    d.text((W / 2, 52), caption, font=font(27, "bold"), fill=INK, anchor="ma")
    if sub:
        d.text((W / 2, 90), sub, font=font(16, "medium"), fill=SUB, anchor="ma")
    return img, d


def bird(img, name, x, y, right=True):
    """발바닥 가운데가 (x, y) 에 오게 그린다."""
    im = SPR[name]
    if not right:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    big = im.resize((pet.W * K, pet.H * K), Image.NEAREST)
    img.alpha_composite(big, (int(x - 18 * K), int(y - pet.GROUND * K)))


def bubble(img, d, text, x, y):
    f = font(17, "medium")
    w = d.textlength(text, font=f) + 30
    left = min(W - w - 10, max(10, x - w / 2))
    d.rounded_rectangle((left, y - 132, left + w, y - 96), 13, fill=PAPER, outline=(200, 195, 186))
    d.text((left + 15, y - 125), text, font=f, fill=INK)


def ease(t):
    t = min(1, max(0, t))
    return t * t * (3 - 2 * t)


def fly(t, a, b, arc=50):
    k = ease(t)
    return a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k - math.sin(k * math.pi) * arc


def flap(i, mail=False):
    return (["mailFly0", "mailFly1", "mailFly2", "mailFly1"] if mail else ["fly0", "fly1", "fly2", "fly1"])[i % 4]


def frames():
    """(이미지) 를 차례로 내놓는다."""
    def n(sec):
        return range(int(sec * FPS))

    # 1. 돌아다니기
    cap = "화면에 사는 작은 뱁새, 오모기"
    x = 250
    for i in n(1.0):
        img, d = base(cap)
        bird(img, "blink" if i in (6, 7) else "sit0" if (i // 5) % 2 == 0 else "sit1", x, FLOOR)
        yield img
    for hop in range(5):                              # 콩콩 뛰어 오른쪽으로
        for name, dx, lift in (("hop0", 0, 0), ("hop1", 12, 26), ("hop1", 30, 34), ("hop2", 44, 0)):
            img, d = base(cap)
            bird(img, name, x + dx, FLOOR - lift)
            yield img
        x += 44
    for i in n(1.6):                                  # 앞을 보고 갸웃
        img, d = base(cap)
        bird(img, "tilt" if 5 <= i < 13 else "frontBlink" if i == 16 else "front", x, FLOOR)
        yield img

    # 2. 졸다가 구르기
    cap = "가끔은 꾸벅꾸벅 졸다가"
    for rep in range(2):
        for name, hold in (("blink", 4), ("sleep1", 4), ("nod1", 4), ("nod2", 7), ("nod1", 2)):
            for _ in range(hold):
                img, d = base(cap)
                bird(img, name, x, FLOOR)
                yield img
    for i in range(10):                               # 데굴
        img, d = base(cap, "데굴")
        bird(img, ["nod2", "roll1", "roll2", "roll3"][min(3, i * 4 // 10)], x + i * 14, FLOOR)
        yield img
    x += 140
    for i in n(0.9):
        img, d = base(cap, "데굴")
        bird(img, "tilt" if i > 4 else "front", x, FLOOR)
        yield img

    # 3. 둥지
    cap = "자리를 오래 비우면 둥지를 짓고 자요"
    x = 400
    for i in n(1.2):
        img, d = base(cap)
        bird(img, "build1" if (i // 3) % 2 == 0 else "sit0", x, FLOOR)
        yield img
    for i in n(1.0):
        img, d = base(cap)
        bird(img, "build2" if (i // 3) % 2 == 0 else "build1", x, FLOOR)
        yield img
    for i in n(1.8):
        img, d = base(cap)
        bird(img, "nest0" if (i // 9) % 2 == 0 else "nest1", x, FLOOR)
        yield img

    # 4. 습관 알림
    cap = "물 마실 때, 눈 쉴 때를 알려 줘요"
    for i in n(2.6):
        img, d = base(cap)
        name = "drink0" if i < 6 else ("drink1" if ((i - 6) // 4) % 2 == 0 else "drink0") if i < 24 else "drink2"
        bird(img, name, x, FLOOR)
        bubble(img, d, "물 한 잔 마실 시간이에요", x, FLOOR)
        yield img
    for i in n(1.6):
        img, d = base(cap)
        bird(img, "stretch" if (i // 6) % 2 == 0 else "tilt", x, FLOOR)
        bubble(img, d, "기지개 한번 켜요", x, FLOOR)
        yield img

    # 5. 집중 모드
    cap = "유튜브를 열면 날아가서 닫아요"

    def browser(img, d, open_tab=True):
        d.rounded_rectangle((250, 128, 700, 350), 12, fill=(255, 255, 255), outline=(205, 200, 190))
        d.rounded_rectangle((250, 128, 700, 164), 12, fill=(232, 228, 220))
        d.rectangle((250, 152, 700, 164), fill=(232, 228, 220))
        for j, c in enumerate([(236, 106, 94), (244, 191, 79), (98, 197, 84)]):
            d.ellipse((262 + j * 18, 140, 274 + j * 18, 152), fill=c)
        if open_tab:
            d.rounded_rectangle((326, 136, 476, 164), 8, fill=(255, 255, 255))
            d.text((338, 141), "YouTube", font=font(14, "medium"), fill=INK)
            d.text((455, 140), "×", font=font(15, "bold"), fill=SUB)
            d.rounded_rectangle((330, 196, 620, 330), 10, fill=(34, 34, 38))
            d.polygon([(460, 244), (460, 284), (496, 264)], fill=(236, 70, 60))
        else:
            d.text((475, 250), "새 탭", font=font(18, "medium"), fill=(190, 186, 178), anchor="ma")

    home, tab = (150, FLOOR), (432, 196)
    for i in n(0.9):
        img, d = base(cap, "집중 모드")
        browser(img, d)
        bird(img, "sit0" if i < 6 else "front", *home)
        yield img
    for i in n(1.0):
        img, d = base(cap, "집중 모드")
        browser(img, d)
        bird(img, flap(i), *fly(i / (FPS * 1.0 - 1), home, tab, 60))
        yield img
    for i in n(0.8):                                  # 콕콕
        img, d = base(cap, "집중 모드")
        browser(img, d)
        bird(img, "sit0" if i % 2 == 0 else "nod1", *tab)
        yield img
    for i in n(0.9):
        img, d = base(cap, "집중 모드")
        browser(img, d, open_tab=False)
        bird(img, "happy0" if i % 2 == 0 else "happy1", *tab)
        yield img
    for i in n(0.9):
        img, d = base(cap, "집중 모드")
        browser(img, d, open_tab=False)
        bx, by = fly(i / (FPS * 0.9 - 1), tab, home, 40)
        bird(img, flap(i), bx, by, right=False)
        yield img

    # 6. 편지 보내기
    cap = "친구에게 쪽지를 쓰면"
    text = "시험 끝나면 밥 먹자!"

    def note(img, d, shown):
        d.rounded_rectangle((270, 140, 610, 300), 14, fill=PAPER, outline=(205, 200, 190))
        d.text((292, 156), "받는 사람   지우", font=font(15, "medium"), fill=SUB)
        d.line((292, 184, 588, 184), fill=(225, 220, 211))
        d.text((292, 198), text[:shown], font=font(22, "medium"), fill=INK)
        d.rounded_rectangle((452, 252, 590, 284), 9, fill=(72, 132, 220) if shown >= len(text) else (190, 200, 216))
        d.text((521, 259), "오모기에게 맡기기", font=font(14, "semibold"), fill=(255, 255, 255), anchor="ma")

    x = 170
    for i in n(1.9):
        img, d = base(cap)
        note(img, d, min(len(text), i))
        bird(img, "sit0" if (i // 5) % 2 == 0 else "sit1", x, FLOOR)
        yield img
    out = (640, -40)
    for i in n(1.6):
        img, d = base(cap, "오모기가 물고 날아가요")
        bird(img, flap(i, mail=True), *fly(i / (FPS * 1.6 - 1), (x, FLOOR), out, 30))
        yield img

    # 7. 도착
    cap = "30분에서 3시간 뒤, 친구 화면에 도착해요"
    land = (430, FLOOR)
    for i in n(1.4):
        img, d = base(cap)
        bx, by = fly(i / (FPS * 1.4 - 1), (120, -40), land, -30)
        bird(img, flap(i, mail=True), bx, by)
        yield img
    for i in n(2.4):
        img, d = base(cap)
        bird(img, "mail1" if i % 8 == 0 else "mail0", *land)
        bubble(img, d, "서연의 편지가 왔어요 — 눌러서 열기", land[0], FLOOR)
        yield img

    # 8. 누락
    cap = "가끔은 가다가 잃어버리기도 해요"
    for i in n(2.4):
        img, d = base(cap)
        bird(img, "sad", *land)
        bubble(img, d, "지우에게 가던 편지를 잃어버렸어요…", land[0], FLOOR)
        yield img

    # 9. 끝
    for i in n(2.6):
        img = Image.new("RGBA", (W, H), BG + (255,))
        d = ImageDraw.Draw(img)
        name = "frontBlink" if i in (10, 11) else "tilt" if 18 <= i < 26 else "front"
        big = SPR[name].resize((pet.W * 7, pet.H * 7), Image.NEAREST)
        img.alpha_composite(big, (int(W / 2 - 18 * 7), 60))
        d.text((W / 2, 268), "Omogi", font=font(54, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 340), "화면에 사는 작은 뱁새 · Mac", font=font(21, "medium"), fill=SUB, anchor="ma")
        yield img


def poses():
    """자세 모음 한 장: 무엇을 하는 앱인지 한눈에."""
    items = [("sit0", "앉아 있기"), ("hop1", "콩콩 뛰기"), ("fly1", "날기"), ("tilt", "갸웃"),
             ("nod2", "꾸벅꾸벅"), ("nest1", "둥지에서 자기"), ("drink1", "물 마시기"), ("stretch", "기지개"),
             ("cal0", "일정 알림"), ("mailFly1", "편지 나르기"), ("mail0", "편지 도착"), ("sad", "잃어버림")]
    cols, cw, ch = 4, 220, 190
    img = Image.new("RGBA", (cols * cw + 40, 3 * ch + 40), BG + (255,))
    d = ImageDraw.Draw(img)
    for i, (name, label) in enumerate(items):
        cx, cy = 20 + (i % cols) * cw, 20 + (i // cols) * ch
        d.rounded_rectangle((cx + 8, cy + 8, cx + cw - 8, cy + ch - 8), 18, fill=PAPER)
        big = SPR[name].resize((pet.W * 4, pet.H * 4), Image.NEAREST)
        img.alpha_composite(big, (cx + (cw - pet.W * 4) // 2, cy + 22))
        d.text((cx + cw / 2, cy + 146), label, font=font(18, "semibold"), fill=INK, anchor="ma")
    return img


def main():
    out = ROOT / "assets"
    out.mkdir(exist_ok=True)
    all_frames = [f.convert("RGB") for f in frames()]
    # 모든 프레임이 같은 색을 쓰도록 팔레트를 하나로 맞춘다 (색이 프레임마다 흔들리지 않게).
    sample = Image.new("RGB", (W * 4, H * 3))
    for j, f in enumerate(all_frames[:: max(1, len(all_frames) // 12)][:12]):
        sample.paste(f, ((j % 4) * W, (j // 4) * H))
    palette = sample.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE)
    pal = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in all_frames]
    pal[0].save(out / "omogi-demo.gif", save_all=True, append_images=pal[1:], duration=round(1000 / FPS), loop=0, optimize=False)
    poses().convert("RGB").save(out / "omogi-poses.png")
    print(f"{len(all_frames)}프레임 ({len(all_frames) / FPS:.1f}초) → assets/omogi-demo.gif, assets/omogi-poses.png")
    if len(sys.argv) > 1:
        d = pathlib.Path(sys.argv[1])
        d.mkdir(parents=True, exist_ok=True)
        for i, f in enumerate(all_frames):
            f.resize((W * 2, H * 2), Image.NEAREST).save(d / f"{i:04d}.png")
        print(f"PNG 프레임 → {d}")


if __name__ == "__main__":
    main()
