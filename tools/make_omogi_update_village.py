#!/usr/bin/env python3
"""Omogi 0.4.0 업데이트 영상(마을)의 프레임과 음악을 만든다. 0.3.0 영상과 같은 그림·같은 합성 음색을 쓴다.

사용: python3 tools/make_omogi_update_village.py <프레임 폴더> <음악.wav>
그다음 tools/frames_to_mp4.swift 로 영상을 만들고 tools/mux_audio.swift 로 음악을 입힌다.
"""
import math
import pathlib
import sys
import wave

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import make_omogi_demo as demo  # noqa: E402
import make_omogi_teaser as tz  # noqa: E402
import make_omogi_update as up  # noqa: E402
import make_pet_sprites as pet  # noqa: E402

W, H, FPS = demo.W, demo.H, demo.FPS
FLOOR, BG, INK, SUB, PAPER = demo.FLOOR, demo.BG, demo.INK, demo.SUB, demo.PAPER
font, fly, flap, draw = demo.font, demo.fly, demo.flap, up.draw
GREEN = tz.GREEN

ME = ("scarf", "glasses", "gradcap")
JIWOO = ("scarf", "straw")
SEOYEON = ("crown",)
BADGES = [(4, "약리학"), (5, "순환기"), (7, "소화기"), (12, "감염"), (17, "산과")]
HOP = ["hop0", "hop1", "hop2"]


def chip(d, text, x, y, color=INK):
    """작은 알약 모양 글자 상자 (가운데가 x)."""
    w = d.textlength(text, font=font(16, "bold")) + 28
    d.rounded_rectangle((x - w / 2, y, x + w / 2, y + 32), 16, fill=PAPER, outline=(205, 200, 190))
    d.text((x, y + 16), text, font=font(16, "bold"), fill=color, anchor="mm")


def bubble(d, text, x, y):
    w = d.textlength(text, font=font(15, "medium")) + 24
    d.rounded_rectangle((x - w / 2, y, x + w / 2, y + 30), 12, fill=PAPER, outline=(205, 200, 190))
    d.text((x, y + 15), text, font=font(15, "medium"), fill=INK, anchor="mm")


def hopper(img, i, x0, x1, start, speed, k, wear, y=FLOOR):
    """start 프레임부터 x0 → x1 로 뛰어간다. 도착하면 앉는다. 지금 x 를 돌려준다."""
    n = max(0, i - start)
    span = abs(x1 - x0)
    x = x0 + math.copysign(min(span, n * speed), x1 - x0)
    if i < start or abs(x - x1) < 0.5:
        draw(img, "sit0", x, y, k, right=x1 >= x0, wear=wear)
    else:
        draw(img, HOP[n % 3], x, y - (k * 3 if n % 3 == 1 else 0), k, right=x1 >= x0, wear=wear)
    return x


def yard(img, d, i):
    """마을 마당: 풀밭 위에 나와 친구들."""
    x0, y0, x1, y1 = 110, 128, 690, 348
    d.rounded_rectangle((x0, y0, x1, y1), 18, fill=(222, 238, 249), outline=(196, 212, 222))
    d.rounded_rectangle((x0, y1 - 74, x1, y1), 18, fill=(168, 214, 142))
    d.rectangle((x0, y1 - 74, x1, y1 - 50), fill=(168, 214, 142))
    for gx in range(x0 + 14, x1 - 10, 44):
        d.rectangle((gx, y1 - 78, gx + 7, y1 - 74), fill=(143, 196, 120))
        d.rectangle((gx + 20, y1 - 40, gx + 27, y1 - 36), fill=(143, 196, 120))
    feet = y1 - 34
    t = i / FPS
    # 지우는 공부 중, 나와 서연은 뛰어다니고, 민재는 잔다
    draw(img, "read1" if i % 30 in (14, 15) else "read0", 200, feet, 3, wear=JIWOO)
    mx = 310 + 50 * math.sin(t * 1.1)
    moving = abs(math.cos(t * 1.1)) > 0.25
    draw(img, HOP[i % 3] if moving else "sit0", mx, feet - (9 if moving and i % 3 == 1 else 0), 3, right=math.cos(t * 1.1) > 0, wear=ME)
    sx = 480 + 40 * math.sin(t * 1.5 + 2)
    smov = abs(math.cos(t * 1.5 + 2)) > 0.3
    draw(img, HOP[(i + 1) % 3] if smov else "sit0", sx, feet - (9 if smov and (i + 1) % 3 == 1 else 0), 3, right=math.cos(t * 1.5 + 2) > 0, wear=SEOYEON)
    draw(img, "sleep0" if (i // 9) % 2 == 0 else "sleep1", 610, feet, 3, right=False)
    for name, x in (("지우", 200), ("나", mx), ("서연", sx), ("민재", 610)):
        d.text((x, feet + 6), name, font=font(13, "semibold"), fill=(40, 60, 40), anchor="ma")
    chip(d, "지우 · 공부 중 · 1시간 15분", 250, y0 + 14, GREEN)


def frames():
    def n(sec):
        return range(int(round(sec * FPS)))

    # 0–2초: 제목
    for i in n(2.0):
        img, d = tz.scene("")
        draw(img, "frontBlink" if i in (10, 11) else "front", W / 2, 210, 6, wear=ME)
        d.text((W / 2, 236), "Omogi 0.4.0", font=font(46, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 300), "친구들과 마을", font=font(24, "medium"), fill=SUB, anchor="ma")
        yield img

    # 2–5초: 공부 시작
    for i in n(3.0):
        t = i / FPS
        img, d = tz.scene("공부 시작을 누르면 책을 본다")
        if t < 0.6:
            draw(img, "sit0", W / 2, FLOOR, 5, wear=ME)
            chip(d, "공부 시작", W / 2, 150)
        else:
            draw(img, "read1" if i in (20, 21, 32, 33) else "read0", W / 2, FLOOR, 5, wear=ME)
            chip(d, f"공부 중 · {12 + int((t - 0.6) / 0.8)}분", W / 2, 150, GREEN)
        yield img

    # 5–9초: 과목 배지
    for i in n(4.0):
        t = i / FPS
        idx = min(len(BADGES) - 1, int(t / 0.8))
        row, name = BADGES[idx]
        since = t - idx * 0.8
        img, d = tz.scene("한 과목 100문제를 맞히면 과목 배지")
        pop = 0.5 * max(0, 1 - since / 0.15)
        draw(img, "frontBlink" if since > 0.6 else "front", W / 2, 290 - pop * 6, 6 + pop, wear=(f"badge{row}", "glasses", "gradcap"))
        d.text((W / 2, 304), name + " 배지", font=font(26, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 342), "과목마다 하나씩, 모두 25개", font=font(16, "medium"), fill=SUB, anchor="ma")
        yield img

    # 9–13초: 마을
    for i in n(4.0):
        img, d = tz.scene("친구들의 새가 마을에 모인다")
        yard(img, d, i)
        yield img

    # 13–17.5초: 친구 새가 놀러 온다
    for i in n(4.5):
        t = i / FPS
        img, d = tz.scene("친구의 새가 놀러 왔다 간다")
        draw(img, "happy0" if 1.0 < t < 2.2 and i % 2 == 0 else "happy1" if 1.0 < t < 2.2 else "sit0", 250, FLOOR, 4, wear=ME)
        if t < 1.0:
            bx, by = fly(t / 1.0, (W + 60, 190), (360, FLOOR), 60)
            draw(img, flap(i), bx, by, 4, right=False, wear=JIWOO)
        elif t < 2.2:
            draw(img, "happy0" if i % 2 == 0 else "happy1", 360, FLOOR - (6 if i % 2 else 0), 4, right=False, wear=JIWOO)
            bubble(d, "지우가 놀러 왔어요", 360, FLOOR - 150)
        elif t < 3.6:
            hopper(img, i, 360, 600, int(2.2 * FPS), 20, 4, JIWOO)
        else:
            a = (t - 3.6) / 0.9
            bx, by = fly(min(1, a), (600, FLOOR), (W + 80, 170), 50)
            draw(img, flap(i), bx, by, 4, wear=JIWOO)
        yield img

    # 17.5–21초: 내 새가 놀러 간다
    for i in n(3.5):
        t = i / FPS
        img, d = tz.scene("내 새도 친구 화면으로 놀러 간다")
        if t < 0.7:
            draw(img, "sit0", 300, FLOOR, 4, wear=ME)
            chip(d, "놀러 가기", 300, FLOOR - 170)
        elif t < 1.7:
            bx, by = fly((t - 0.7) / 1.0, (300, FLOOR), (620, -70), 30)
            draw(img, flap(i), bx, by, 4, wear=ME)
        elif t < 2.5:
            d.text((W / 2, 230), "지우네에서 노는 중…", font=font(20, "medium"), fill=SUB, anchor="mm")
        else:
            a = min(1, (t - 2.5) / 0.6)
            bx, by = fly(a, (620, -70), (300, FLOOR), 30)
            if a < 1:
                draw(img, flap(i), bx, by, 4, right=False, wear=ME)
            else:
                draw(img, "happy0" if i % 2 == 0 else "happy1", 300, FLOOR, 4, right=False, wear=ME)
                bubble(d, "지우네 다녀왔어요", 300, FLOOR - 150)
        yield img

    # 21–24.5초: 끝
    for i in n(3.5):
        img = Image.new("RGBA", (W, H), BG + (255,))
        d = ImageDraw.Draw(img)
        name = "frontBlink" if i in (14, 15) else "tilt" if 22 <= i < 32 else "front"
        side = "frontBlink" if i in (20, 21) else "front"
        draw(img, side, W / 2 - 150, 70 + pet.GROUND * 5, 5, wear=JIWOO)
        draw(img, side, W / 2 + 150, 70 + pet.GROUND * 5, 5, right=False, wear=SEOYEON)
        draw(img, name, W / 2, 54 + pet.GROUND * 7, 7, wear=ME)
        d.text((W / 2, 262), "Omogi 0.4.0", font=font(52, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 332), "친구들과 마을", font=font(22, "medium"), fill=SUB, anchor="ma")
        d.text((W / 2, 374), "Mac · Windows · 테스트 버전 · 제작 @hi20010205", font=font(15, "medium"), fill=(160, 156, 148), anchor="ma")
        yield img


# ───────────────────── 음악 (0.3.0 영상과 같은 화음·음색) ─────────────────────
SR, BEAT = tz.SR, tz.BEAT
tone, noise, kick, hz = tz.tone, tz.noise, tz.kick, tz.hz


def music(total):
    out = np.zeros(int(SR * (total + 0.5)))

    def put(sig, at):
        i = int(SR * at)
        j = min(len(out), i + len(sig))
        if i < len(out):
            out[i:j] += sig[: j - i]

    def coin(at, up_=0):
        put(tone("sq", 88 + up_, 0.07, 0.11), at)
        put(tone("sq", 93 + up_, 0.16, 0.11), at + 0.07)

    def whoosh(at, rise=True):                           # 날아오거나 날아갈 때
        t = np.arange(int(SR * 0.45)) / SR
        f = (400 * t + 1300 * t * t) if rise else (1500 * t - 1300 * t * t)
        put(np.sign(np.sin(2 * np.pi * f)) * 0.09 * np.minimum(1, t / 0.05) * np.minimum(1, (0.45 - t) / 0.1), at)

    chords = [(60, 64, 67), (55, 59, 62), (57, 60, 64), (53, 57, 60)]         # C  G  Am  F
    tunes = [[72, None, 76, 79, 76, None, 72, 74], [74, None, 79, 83, 79, None, 74, 71],
             [72, None, 76, 81, 76, None, 72, 76], [77, 76, 72, None, 69, 72, 77, None]]
    b = 0
    while b * 2.0 < 21.0:                                # 21초까지
        t0 = b * 2.0
        ch, tune = chords[b % 4], tunes[b % 4]
        soft = 1.0 <= b < 2.5                            # 공부 장면은 조용히
        lift = 12 if 4.5 <= b < 6.5 else 0               # 마을 장면은 한 옥타브 위로
        if b >= 1:
            for s, m in enumerate(tune):
                if m is not None and t0 + s * 0.25 < 21.0:
                    put(tone("sq", m + lift, 0.24, 0.09 if soft else 0.15), t0 + s * 0.25)
        for s in range(8):
            if t0 + s * 0.25 < 21.0:
                put(tone("pulse", ch[s % 3] + 12, 0.2, 0.07), t0 + s * 0.25)
        for beat in range(4):
            at = t0 + beat * BEAT
            if at < 21.0:
                put(tone("tri", ch[0] - 24 + (7 if beat == 2 else 0), 0.45, 0.30), at)
                if not soft:
                    put(kick(), at)
                put(noise(0.05, 0.10, 90), at + 0.25)
        b += 1
    put(noise(0.08, 0.14, 60), 2.6)                      # 책을 편다
    for at in (3.7, 4.7):
        put(noise(0.06, 0.10, 80), at)                   # 책장 넘기기
    for j in range(5):                                   # 배지를 받을 때
        coin(5.0 + j * 0.8, up_=j)
    whoosh(13.0, rise=False)                             # 친구 새가 날아온다
    for s, m in enumerate((79, 84, 88)):                 # 인사
        put(tone("sq", m, 0.12, 0.13), 14.0 + s * 0.1)
    whoosh(16.6)                                         # 돌아간다
    whoosh(18.2)                                         # 내 새가 떠난다
    whoosh(20.0, rise=False)                             # 돌아온다
    for s, m in enumerate((84, 88, 91)):
        put(tone("sq", m, 0.12, 0.13), 20.6 + s * 0.1)
    for s, m in enumerate((72, 76, 79, 84, 79, 84, 88)):  # 21초부터: 마무리
        put(tone("sq", m, 0.3, 0.15), 21.0 + s * 0.25)
    for m, v in ((48, 0.3), (60, 0.12), (64, 0.12), (67, 0.12), (72, 0.14)):
        tt = np.arange(int(SR * 2.0)) / SR
        f = hz(m)
        w = (2 * np.abs(2 * ((tt * f) % 1) - 1) - 1) if m == 48 else np.where((tt * f) % 1 < 0.5, 1.0, -1.0)
        put(w * np.exp(-tt * 1.6) * v, 22.75)
    out = out[: int(SR * total)]
    fade = int(SR * 0.6)
    out[-fade:] *= np.linspace(1, 0, fade)
    out = np.tanh(out * 1.1) * 0.8
    return (out * 32767).astype(np.int16)


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    d = pathlib.Path(sys.argv[1])
    d.mkdir(parents=True, exist_ok=True)
    count = 0
    for i, f in enumerate(frames()):
        f.convert("RGB").resize((W * 2, H * 2), Image.NEAREST).save(d / f"{i:04d}.png")
        count += 1
    total = count / FPS
    pcm = music(total)
    with wave.open(sys.argv[2], "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"{count}프레임 ({total:.1f}초) → {d}, 음악 → {sys.argv[2]}")


if __name__ == "__main__":
    main()
