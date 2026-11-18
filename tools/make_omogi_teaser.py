#!/usr/bin/env python3
"""Omogi 티저 영상(23초)의 프레임과 음악을 만든다. 그림은 앱과 같은 스프라이트, 음악은 이 파일이 합성한 8비트풍 멜로디다
(남의 곡을 쓰지 않는다).

사용: python3 tools/make_omogi_teaser.py <프레임 폴더> <음악.wav>
그다음 tools/frames_to_mp4.swift 로 영상을 만들고 tools/mux_audio.swift 로 음악을 입힌다.
박자는 120 BPM (한 박 = 0.5초 = 6프레임)이고, 장면이 박에 맞춰 바뀐다.
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
import make_pet_sprites as pet  # noqa: E402

W, H, FPS = demo.W, demo.H, demo.FPS
FLOOR, BG, INK, SUB, PAPER, SPR = demo.FLOOR, demo.BG, demo.INK, demo.SUB, demo.PAPER, demo.SPR
font, bird, bubble, fly, flap = demo.font, demo.bird, demo.bubble, demo.fly, demo.flap
GREEN, RED = (72, 172, 66), (222, 66, 52)


def scene(caption):
    """배경과 큰 자막 한 줄."""
    img, d = demo.base("")
    d.text((W / 2, 58), caption, font=font(34, "bold"), fill=INK, anchor="ma")
    return img, d


def big_bird(img, name, x, y, k, right=True):
    """배율 k 로 그린다 (발바닥 가운데가 x, y)."""
    im = SPR[name] if right else SPR[name].transpose(Image.FLIP_LEFT_RIGHT)
    big = im.resize((max(1, round(pet.W * k)), max(1, round(pet.H * k))), Image.NEAREST)
    img.alpha_composite(big, (int(x - 18 * k), int(y - pet.GROUND * k)))


def card(img, d, state, streak=0):
    """화면 위의 O/X 카드. state: "ask" 또는 "right"."""
    x0, y0, x1, y1 = 300, 112, 640, 318
    d.rounded_rectangle((x0, y0, x1, y1), 18, fill=PAPER, outline=(205, 200, 190))
    d.text((x0 + 20, y0 + 14), "순환기", font=font(13, "semibold"), fill=SUB)
    if streak >= 2:
        d.text((x1 - 20, y0 + 14), f"연속 {streak}", font=font(13, "semibold"), fill=GREEN, anchor="ra")
    d.text((x0 + 20, y0 + 40), "심방조동의 심전도에서는", font=font(19, "bold"), fill=INK)
    d.text((x0 + 20, y0 + 68), "톱니 모양의 F파가 보인다.", font=font(19, "bold"), fill=INK)
    for i, letter in enumerate("OX"):
        bx = x0 + 20 + i * 154
        on = state == "right" and letter == "O"
        fill = GREEN if on else (236, 233, 227) if state == "ask" else (240, 238, 233)
        d.rounded_rectangle((bx, y0 + 112, bx + 146, y0 + 162), 12, fill=fill)
        d.text((bx + 73, y0 + 137), letter, font=font(30, "bold"),
               fill=(255, 255, 255) if on else INK if state == "ask" else (190, 186, 180), anchor="mm")
    if state == "right":
        d.text((x0 + 20, y0 + 174), "정답", font=font(15, "bold"), fill=GREEN)


def frames():
    def n(sec):
        return range(int(round(sec * FPS)))

    # 0–2초: 날아 들어와 앉는다
    land = (400, FLOOR)
    for i in n(2.0):
        img, d = scene("화면에 뭐가 산다")
        if i < 14:
            bx, by = fly(i / 13, (840, 60), land, 20)
            bird(img, flap(i), bx, by, right=False)
        else:
            bird(img, "tilt" if i >= 18 else "front", *land)
        yield img

    # 2–8초: 한 박 반씩 네 장면
    for cap, seq in (("졸고", ["blink"] * 3 + ["sleep1"] * 3 + ["nod1"] * 4 + ["nod2"] * 8),
                     ("구르고", None),
                     ("둥지 짓고", ["build1", "build1", "sit0", "build2", "build2", "build1"] + ["nest0"] * 6 + ["nest1"] * 6),
                     ("물 마시라 하고", ["drink0"] * 4 + ["drink1"] * 4 + ["drink0"] * 3 + ["drink1"] * 4 + ["drink2"] * 3)):
        for i in n(1.5):
            img, d = scene(cap)
            if seq is None:
                bird(img, ["nod2", "roll1", "roll2", "roll3"][(i * 4 // 5) % 4], 250 + i * 18, FLOOR)
            else:
                bird(img, seq[min(i, len(seq) - 1)], 400, FLOOR)
                if cap.startswith("물"):
                    bubble(img, d, "물 한 잔 마실 시간이에요", 400, FLOOR)
            yield img

    # 8–11초: 집중 모드
    cap = "유튜브는 닫아 버리고"
    home, tab = (150, FLOOR), (432, 196)

    def browser(d, open_tab):
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

    for i in n(3.0):
        img, d = scene(cap)
        browser(d, open_tab=i < 18)
        if i < 12:
            bird(img, flap(i), *fly(i / 11, home, tab, 60))
        elif i < 18:
            bird(img, "sit0" if i % 2 == 0 else "nod1", *tab)
        elif i < 26:
            bird(img, "happy0" if i % 2 == 0 else "happy1", *tab)
        else:
            bx, by = fly((i - 26) / 9, tab, home, 40)
            bird(img, flap(i), bx, by, right=False)
        yield img

    # 11–14초: 편지
    cap = "친구에게 편지를 나르고"
    for i in n(3.0):
        img, d = scene(cap)
        if i < 18:
            if i < 8:
                d.rounded_rectangle((270, 150, 610, 250), 14, fill=PAPER, outline=(205, 200, 190))
                d.text((292, 166), "받는 사람   지우", font=font(15, "medium"), fill=SUB)
                d.text((292, 198), "시험 끝나면 밥 먹자!"[: i * 2 + 2], font=font(22, "medium"), fill=INK)
                bird(img, "sit0", 170, FLOOR)
            else:
                bird(img, flap(i, mail=True), *fly((i - 8) / 9, (170, FLOOR), (660, -40), 30))
        else:
            t = (i - 18) / 9
            if t < 1:
                bird(img, flap(i, mail=True), *fly(t, (120, -40), (430, FLOOR), -30))
            else:
                bird(img, "mail1" if i % 6 == 0 else "mail0", 430, FLOOR)
                bubble(img, d, "서연의 편지가 왔어요", 430, FLOOR)
        yield img

    # 14–19.5초: O/X — 맞힐수록 커지다가 펑
    cap = "O/X 문제도 물어 온다"
    perch = (262, 300)
    scales = [4, 4, 5.4, 7.2, 9.6, 12.8]            # 연속 정답 0, 1, 2, 3, 4, 5
    random.seed(7)
    minis = [(math.pi * (0.1 + 0.8 * j / 13) + random.uniform(-0.1, 0.1), random.uniform(260, 620)) for j in range(14)]
    k = 4.0
    for i in n(5.5):
        t = i / FPS
        streak = 0 if t < 1.0 else min(5, 1 + int((t - 1.0) / 0.75))
        popped = t >= 4.5
        img, d = scene(cap if t < 1.0 else "맞힐수록 커지다가" if not popped else "펑")
        card(img, d, "ask" if t < 1.0 else "right", streak if not popped else 0)
        if not popped:
            k += (scales[streak] - k) * 0.45
            name = "sit0" if t < 1.0 else ("happy0" if i % 2 == 0 else "happy1")
            big_bird(img, name, perch[0] - (k - 4) * 9, perch[1] + (k - 4) * 16, k)
        else:
            u = t - 4.5
            cx, cy = 250, 250
            for ang, sp in minis:
                r = sp * (1 - math.exp(-3.2 * u)) / 3.2 * 3.4
                x, y = cx + math.cos(ang) * r, cy - math.sin(ang) * r * 0.75 - 30 + 40 * u * u
                big_bird(img, flap(i) if u > 0.25 else "hop1", x, y, 2.4, right=math.cos(ang) >= 0)
            big_bird(img, "happy0" if i % 2 == 0 else "happy1", perch[0], perch[1], 4)
        yield img

    # 19.5–23초: 끝
    for i in n(3.5):
        img = Image.new("RGBA", (W, H), BG + (255,))
        d = ImageDraw.Draw(img)
        name = "frontBlink" if i in (14, 15) else "tilt" if 22 <= i < 32 else "front"
        big = SPR[name].resize((pet.W * 7, pet.H * 7), Image.NEAREST)
        img.alpha_composite(big, (int(W / 2 - 18 * 7), 54))
        d.text((W / 2, 262), "Omogi", font=font(56, "bold"), fill=INK, anchor="ma")
        d.text((W / 2, 336), "화면에 사는 작은 뱁새", font=font(22, "medium"), fill=SUB, anchor="ma")
        d.text((W / 2, 376), "Mac · 테스트 버전 · 제작 @hi20010205", font=font(15, "medium"), fill=(160, 156, 148), anchor="ma")
        yield img


# ───────────────────── 음악 ─────────────────────
SR = 44100
BEAT = 0.5


def hz(m):
    return 440.0 * 2 ** ((m - 69) / 12)


def tone(kind, midi, dur, vol):
    t = np.arange(int(SR * dur)) / SR
    f = hz(midi)
    if kind == "sq":                                   # 사각파 (멜로디)
        w = np.where((t * f) % 1 < 0.5, 1.0, -1.0)
    elif kind == "pulse":                              # 폭이 좁은 사각파 (반주)
        w = np.where((t * f) % 1 < 0.25, 1.0, -1.0)
    else:                                              # 삼각파 (베이스)
        w = 2 * np.abs(2 * ((t * f) % 1) - 1) - 1
    env = np.minimum(1, t / 0.006) * np.exp(-t * (3.0 if kind != "tri" else 1.2))
    tail = np.minimum(1, (dur - t) / 0.02)
    return w * env * tail * vol


def noise(dur, vol, decay):
    t = np.arange(int(SR * dur)) / SR
    return np.random.default_rng(3).uniform(-1, 1, len(t)) * np.exp(-t * decay) * vol


def kick(vol=0.5):
    t = np.arange(int(SR * 0.16)) / SR
    return np.sin(2 * np.pi * (120 * np.exp(-t * 28) + 45) * t) * np.exp(-t * 20) * vol


def music(total):
    out = np.zeros(int(SR * (total + 0.5)))

    def put(sig, at):
        i = int(SR * at)
        j = min(len(out), i + len(sig))
        if i < len(out):
            out[i:j] += sig[: j - i]

    chords = [(60, 64, 67), (55, 59, 62), (57, 60, 64), (53, 57, 60)]         # C  G  Am  F
    # 한 마디(4박 = 8개의 8분음표) 멜로디. None 은 쉼표.
    tunes = [[72, None, 76, 79, 76, None, 72, 74], [74, None, 79, 83, 79, None, 74, 71],
             [72, None, 76, 81, 76, None, 72, 76], [77, 76, 72, None, 69, 72, 77, None]]
    bars = int(18.0 / 2)                                # 18초까지는 같은 흐름
    for b in range(bars):
        t0 = b * 2.0
        ch, tune = chords[b % 4], tunes[b % 4]
        lift = 12 if b >= 4 and b < 7 else 0            # 가운데 부분은 한 옥타브 위로
        if b >= 1:                                      # 첫 마디는 멜로디 없이 시작
            for s, m in enumerate(tune):
                if m is not None:
                    put(tone("sq", m + lift, 0.24, 0.16), t0 + s * 0.25)
        for s in range(8):                              # 반주: 화음을 차례로
            put(tone("pulse", ch[s % 3] + 12, 0.2, 0.07), t0 + s * 0.25)
        for beat in range(4):
            put(tone("tri", ch[0] - 24 + (7 if beat == 2 else 0), 0.45, 0.30), t0 + beat * BEAT)
            put(kick(), t0 + beat * BEAT)
            put(noise(0.05, 0.10, 90), t0 + beat * BEAT + 0.25)
    # 15–18초: 커질 때마다 올라가는 소리
    for j in range(4):
        base = 72 + j * 4
        for s, m in enumerate((base, base + 4, base + 7, base + 12)):
            put(tone("sq", m, 0.14, 0.15), 15.0 + j * 0.75 + s * 0.09)
    # 18–18.5초: 솟아오르는 소리, 18.5초: 펑
    t = np.arange(int(SR * 0.5)) / SR
    put(np.sign(np.sin(2 * np.pi * (300 * t + 1400 * t * t))) * 0.13 * np.minimum(1, t / 0.05), 18.0)
    put(noise(0.5, 0.5, 9), 18.5)
    for m in (72, 76, 79, 84):
        put(tone("sq", m, 0.9, 0.12), 18.5)
    put(kick(0.8), 18.5)
    # 19.5초부터: 마무리
    for s, m in enumerate((72, 76, 79, 84, 79, 84, 88)):
        put(tone("sq", m, 0.3, 0.15), 19.5 + s * 0.25)
    for m, v in ((48, 0.3), (60, 0.12), (64, 0.12), (67, 0.12), (72, 0.14)):
        tt = np.arange(int(SR * 2.0)) / SR
        f = hz(m)
        w = (2 * np.abs(2 * ((tt * f) % 1) - 1) - 1) if m == 48 else np.where((tt * f) % 1 < 0.5, 1.0, -1.0)
        put(w * np.exp(-tt * 1.6) * v, 21.25)
    out = out[: int(SR * total)]
    fade = int(SR * 0.6)
    out[-fade:] *= np.linspace(1, 0, fade)
    out = np.tanh(out * 1.1) * 0.8                      # 살짝 눌러서 찢어지지 않게
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
