#!/usr/bin/env python3
"""Omogi 0.3.0 업데이트 영상(꼬마 뱁새와 옷장)의 프레임과 음악을 만든다. 티저와 같은 그림·같은 합성 음색을 쓴다.

사용: python3 tools/make_omogi_update.py <프레임 폴더> <음악.wav>
그다음 tools/frames_to_mp4.swift 로 영상을 만들고 tools/mux_audio.swift 로 음악을 입힌다.
"""
import math
import pathlib
import random
import sys
import wave

import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import make_omogi_demo as demo  # noqa: E402
import make_omogi_teaser as tz  # noqa: E402
import make_pet_sprites as pet  # noqa: E402

W, H, FPS = demo.W, demo.H, demo.FPS
FLOOR, BG, INK, SUB, PAPER = demo.FLOOR, demo.BG, demo.INK, demo.SUB, demo.PAPER
font, fly, flap = demo.font, demo.fly, demo.flap
GREEN, BLUE = tz.GREEN, (52, 120, 246)

_cache = {}


def sprites(wear=()):
    """옷을 입힌 스프라이트 묶음 (이름 → 그림)."""
    if wear not in _cache:
        _cache[wear] = dict(pet.build(wear))
    return _cache[wear]


def draw(img, name, x, y, k, right=True, wear=()):
    """배율 k 로 그린다 (발바닥 가운데가 x, y)."""
    im = sprites(wear)[name]
    if not right:
        im = im.transpose(Image.FLIP_LEFT_RIGHT)
    big = im.resize((max(1, round(pet.W * k)), max(1, round(pet.H * k))), Image.NEAREST)
    img.alpha_composite(big, (int(x - 18 * k), int(y - pet.GROUND * k)))


def counter(img, d, n, bump=0.0):
    """오른쪽 위의 꼬마 뱁새 수."""
    x1, y0 = W - 28, 22
    text = f"꼬마 뱁새 {n}"
    w = d.textlength(text, font=font(17, "bold")) + 62
    d.rounded_rectangle((x1 - w, y0 - bump, x1, y0 + 36 - bump), 18, fill=PAPER, outline=(205, 200, 190))
    draw(img, "sit0", x1 - w + 26, y0 + 31 - bump, 1.0)
    d.text((x1 - 16, y0 + 18 - bump), text, font=font(17, "bold"), fill=INK, anchor="rm")


def plus(d, x, y, age):
    """잡았을 때 떠오르는 +1."""
    if 0 <= age < 0.6:
        d.text((x, y - 34 * age / 0.6), "+1", font=font(20, "bold"), fill=BLUE, anchor="mm")


def cursor(d, x, y):
    pts = [(0, 0), (0, 19), (5, 15), (9, 23), (12, 21), (8, 14), (15, 14)]
    d.polygon([(x + a, y + b) for a, b in pts], fill=(255, 255, 255), outline=(30, 30, 34))


ITEMS = [(("scarf",), "빨간 목도리", "30마리"), (("straw",), "밀짚모자", "40마리"), (("glasses",), "동그란 안경", "40마리"),
         (("scrubcap",), "수술모", "60마리"), (("steth",), "청진기", "80마리"), (("gradcap",), "학사모", "120마리"),
         (("crown",), "왕관", "250마리"), (("scarf", "glasses", "straw"), "머리 · 얼굴 · 목에 하나씩", "")]
OUTFIT = ("scarf", "glasses", "straw")


def frames():
    def n(sec):
        return range(int(round(sec * FPS)))

    # 0–2초: 제목
    for i in n(2.0):
        img, d = tz.scene("")
        draw(img, "frontBlink" if i in (10, 11) else "front", W / 2, 210, 6)
        d.text((W / 2, 236), "Omogi 0.3.0", font=font(46, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 300), "꼬마 뱁새와 옷장", font=font(24, "medium"), fill=SUB, anchor="ma")
        yield img

    # 2–5초: 맞히면 한 마리씩
    perch = (262, 300)
    for i in n(3.0):
        t = i / FPS
        got = 0 if t < 0.75 else min(3, 1 + int((t - 0.75) / 0.75))
        img, d = tz.scene("문제를 맞히면 한 마리")
        tz.card(img, d, "ask" if t < 0.75 else "right", 0)
        draw(img, "sit0" if t < 0.75 else ("happy0" if i % 2 == 0 else "happy1"), perch[0], perch[1], 4)
        since = (t - 0.75) % 0.75 if t >= 0.75 else 9
        counter(img, d, got, bump=4 * max(0, 1 - since / 0.2) if since < 0.2 else 0)
        plus(d, W - 70, 78, since)
        yield img

    # 5–9.5초: 다섯 번 연속이면 펑, 흩어진 꼬마를 눌러 잡는다
    random.seed(11)
    minis = [(math.pi * (0.1 + 0.8 * j / 13) + random.uniform(-0.1, 0.1), random.uniform(300, 600)) for j in range(14)]
    order = [3, 6, 9, 11, 12, 8, 5, 1, 0]                # 잡는 순서
    catch_at = {j: 0.95 + s * 0.3 for s, j in enumerate(order)}      # 터진 뒤 몇 초에 잡히는지
    k, cur = 4.0, (520.0, 330.0)
    for i in n(4.5):
        t = i / FPS
        popped = t >= 1.5
        img, d = tz.scene("다섯 번 연속이면" if not popped else "펑 — 흩어진 꼬마를 눌러서 잡는다")
        if not popped:
            tz.card(img, d, "right", 4 if t < 0.75 else 5)
            k += ((9.6 if t < 0.75 else 12.8) - k) * 0.45
            draw(img, "happy0" if i % 2 == 0 else "happy1", perch[0] - (k - 4) * 9, perch[1] + (k - 4) * 16, k)
            counter(img, d, 3 if t < 0.75 else 4 if t < 1.4 else 5)
        else:
            u = t - 1.5
            cx, cy = 400, 330
            where = {}
            for j, (ang, sp) in enumerate(minis):
                r = sp * (1 - math.exp(-3.2 * u)) / 3.2 * 1.55
                x = cx + math.cos(ang) * r
                y = cy - math.sin(ang) * r * 0.72 + math.sin(u * 9 + j) * 3
                where[j] = (x, y)
                if j in catch_at and u >= catch_at[j]:
                    plus(d, x, y - 30, u - catch_at[j])
                    continue
                draw(img, flap(i + j) if u > 0.25 else "hop1", x, y, 2.4, right=math.cos(ang) >= 0)
            draw(img, "happy0" if i % 2 == 0 else "happy1", 400, FLOOR, 4)
            caught = sum(1 for j in catch_at if u >= catch_at[j])
            counter(img, d, 5 + caught)
            # 화살표는 다음에 잡을 꼬마 쪽으로 따라간다
            nxt = next((j for j in order if u < catch_at[j]), order[-1])
            tx, ty = where[nxt][0] - 2, where[nxt][1] - 30
            cur = (cur[0] + (tx - cur[0]) * 0.55, cur[1] + (ty - cur[1]) * 0.55)
            if u > 0.5:
                cursor(d, cur[0], cur[1])
        yield img

    # 9.5–15.5초: 옷장
    for i in n(6.0):
        t = i / FPS
        idx = min(len(ITEMS) - 1, int(t / 0.75))
        wear, name, price = ITEMS[idx]
        since = t - idx * 0.75
        img, d = tz.scene("모은 꼬마로 옷을 산다")
        pop = 0.5 * max(0, 1 - since / 0.15)
        draw(img, "frontBlink" if since > 0.55 and idx < 7 else "front", W / 2, 290 - pop * 6, 6 + pop, wear=wear)
        d.text((W / 2, 304), name, font=font(26, "bold"), fill=INK, anchor="ma")
        if price:
            d.text((W / 2, 342), "꼬마 뱁새 " + price, font=font(16, "medium"), fill=SUB, anchor="ma")
        yield img

    # 15.5–18초: 입은 채로 돌아다닌다
    for i in n(2.5):
        t = i / FPS
        img, d = tz.scene("입은 채로 돌아다닌다")
        if t < 1.25:
            x = 150 + (i // 3) * 46
            draw(img, ["hop0", "hop1", "hop2"][i % 3], x + (i % 3) * 15, FLOOR - (14 if i % 3 == 1 else 0), 4, wear=OUTFIT)
        else:
            a = (t - 1.25) / 1.25
            bx, by = fly(min(1, a * 1.15), (380, FLOOR), (660, FLOOR), 90)
            if a * 1.15 < 1:
                draw(img, flap(i), bx, by, 4, wear=OUTFIT)
            else:
                draw(img, "happy0" if i % 2 == 0 else "happy1", 660, FLOOR, 4, wear=OUTFIT)
        yield img

    # 18–21.5초: 끝
    end = ("scarf", "glasses", "gradcap")
    for i in n(3.5):
        img = Image.new("RGBA", (W, H), BG + (255,))
        d = ImageDraw.Draw(img)
        name = "frontBlink" if i in (14, 15) else "tilt" if 22 <= i < 32 else "front"
        draw(img, name, W / 2, 54 + pet.GROUND * 7, 7, wear=end)
        d.text((W / 2, 262), "Omogi 0.3.0", font=font(52, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 332), "꼬마 뱁새와 옷장", font=font(22, "medium"), fill=SUB, anchor="ma")
        d.text((W / 2, 374), "Mac · Windows · 테스트 버전 · 제작 @hi20010205", font=font(15, "medium"), fill=(160, 156, 148), anchor="ma")
        yield img


# ───────────────────── 음악 (티저와 같은 화음·음색) ─────────────────────
SR, BEAT = tz.SR, tz.BEAT
tone, noise, kick, hz = tz.tone, tz.noise, tz.kick, tz.hz


def music(total):
    out = np.zeros(int(SR * (total + 0.5)))

    def put(sig, at):
        i = int(SR * at)
        j = min(len(out), i + len(sig))
        if i < len(out):
            out[i:j] += sig[: j - i]

    def coin(at, up=0):                                  # 꼬마를 얻을 때의 짧은 두 음
        put(tone("sq", 88 + up, 0.07, 0.11), at)
        put(tone("sq", 93 + up, 0.16, 0.11), at + 0.07)

    chords = [(60, 64, 67), (55, 59, 62), (57, 60, 64), (53, 57, 60)]         # C  G  Am  F
    tunes = [[72, None, 76, 79, 76, None, 72, 74], [74, None, 79, 83, 79, None, 74, 71],
             [72, None, 76, 81, 76, None, 72, 76], [77, 76, 72, None, 69, 72, 77, None]]
    for b in range(9):                                   # 18초까지
        t0 = b * 2.0
        ch, tune = chords[b % 4], tunes[b % 4]
        quiet = 3.0 <= t0 / 2 < 3.25                     # 터지는 마디는 멜로디를 비운다
        lift = 12 if 5 <= b < 8 else 0                   # 옷장 장면은 한 옥타브 위로
        if b >= 1 and b != 3:
            for s, m in enumerate(tune):
                if m is not None:
                    put(tone("sq", m + lift, 0.24, 0.15), t0 + s * 0.25)
        for s in range(8):
            put(tone("pulse", ch[s % 3] + 12, 0.2, 0.07), t0 + s * 0.25)
        for beat in range(4):
            put(tone("tri", ch[0] - 24 + (7 if beat == 2 else 0), 0.45, 0.30), t0 + beat * BEAT)
            put(kick(), t0 + beat * BEAT)
            put(noise(0.05, 0.10, 90), t0 + beat * BEAT + 0.25)
    for j in range(3):                                   # 2.75, 3.5, 4.25초: 맞힐 때마다
        coin(2.75 + j * 0.75)
    for j in range(2):                                   # 5–6.5초: 커질 때 올라가는 소리
        base = 76 + j * 4
        for s, m in enumerate((base, base + 4, base + 7, base + 12)):
            put(tone("sq", m, 0.14, 0.15), 5.0 + j * 0.75 + s * 0.09)
    t = np.arange(int(SR * 0.5)) / SR                    # 6.0초: 솟아오르고, 6.5초: 펑
    put(np.sign(np.sin(2 * np.pi * (300 * t + 1400 * t * t))) * 0.13 * np.minimum(1, t / 0.05), 6.0)
    put(noise(0.5, 0.5, 9), 6.5)
    for m in (72, 76, 79, 84):
        put(tone("sq", m, 0.9, 0.12), 6.5)
    put(kick(0.8), 6.5)
    for s in range(9):                                   # 잡을 때마다 조금씩 높아진다
        coin(6.5 + 0.95 + s * 0.3, up=s % 5)
    for j in range(8):                                   # 옷을 갈아입을 때
        put(tone("sq", 84 + (j % 4) * 2, 0.09, 0.10), 9.5 + j * 0.75)
        put(noise(0.04, 0.12, 120), 9.5 + j * 0.75)
    for s, m in enumerate((72, 76, 79, 84, 79, 84, 88)):  # 18초부터: 마무리
        put(tone("sq", m, 0.3, 0.15), 18.0 + s * 0.25)
    for m, v in ((48, 0.3), (60, 0.12), (64, 0.12), (67, 0.12), (72, 0.14)):
        tt = np.arange(int(SR * 2.0)) / SR
        f = hz(m)
        w = (2 * np.abs(2 * ((tt * f) % 1) - 1) - 1) if m == 48 else np.where((tt * f) % 1 < 0.5, 1.0, -1.0)
        put(w * np.exp(-tt * 1.6) * v, 19.75)
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
