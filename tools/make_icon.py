#!/usr/bin/env python3
"""앱 아이콘을 만든다: 밝은 바탕에 펫(흰오목눈이)의 정면 얼굴을 크게.

그림은 tools/make_pet_sprites.py 의 정면 스프라이트를 그대로 키운 것이라 앱 안의 펫과 같은 얼굴이다.
결과: mac/AppIcon.icns (Mac 앱), icons/icon16·32·48·128.png (크롬 확장)
사용: python3 tools/make_icon.py [미리보기.png]      (macOS 의 iconutil 이 필요하다)
"""
import pathlib
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import make_pet_sprites as pet  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
SIZE, SS = 1024, 2                      # 1024 로 만들되 모서리가 매끈하게 2배로 그린 뒤 줄인다
BG = (241, 237, 229, 255)               # 밝은 크림색 바탕
PIXEL = 0.047                           # 스프라이트 한 픽셀의 크기 (타일 너비 대비)


def master():
    s = SIZE * SS
    margin, radius = int(s * 0.10), int(s * 0.185)
    shape = Image.new("L", (s, s), 0)
    ImageDraw.Draw(shape).rounded_rectangle([margin, margin, s - margin, s - margin], radius=radius, fill=255)

    art = Image.new("RGBA", (s, s), BG)
    bx, by = pet.BX, pet.GROUND - 2 - (len(pet.BODY) - 1)
    face = pet.front().crop((bx - 1, by - 1, bx + 17, by + 20))      # 몸과 다리 (꼬리는 뺀다)
    k = round(PIXEL * s)
    big = face.resize((face.width * k, face.height * k), Image.NEAREST)
    art.alpha_composite(big, (int(s * 0.5 - big.width / 2), int(s * 0.60 - big.height / 2)))

    out = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    out.paste(art, (0, 0), shape)                                    # 타일 밖은 잘라 낸다
    return out.resize((SIZE, SIZE), Image.LANCZOS)


def main():
    icon = master()
    for n in (16, 32, 48, 128):
        icon.resize((n, n), Image.LANCZOS).save(ROOT / "icons" / f"icon{n}.png")
    with tempfile.TemporaryDirectory() as tmp:
        iconset = pathlib.Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for n in (16, 32, 128, 256, 512):
            icon.resize((n, n), Image.LANCZOS).save(iconset / f"icon_{n}x{n}.png")
            icon.resize((n * 2, n * 2), Image.LANCZOS).save(iconset / f"icon_{n}x{n}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "mac" / "AppIcon.icns")], check=True)
    print("아이콘 → mac/AppIcon.icns, icons/icon16·32·48·128.png")
    if len(sys.argv) > 1:
        sheet = Image.new("RGBA", (SIZE // 2 + 40 + 160, SIZE // 2 + 40), (214, 214, 214, 255))
        sheet.alpha_composite(icon.resize((SIZE // 2, SIZE // 2), Image.LANCZOS), (20, 20))
        for j, n in enumerate((128, 64, 32, 16)):
            sheet.alpha_composite(icon.resize((n, n), Image.LANCZOS), (SIZE // 2 + 40, 20 + j * 100 + (40 if j else 0)))
        sheet.save(sys.argv[1])


if __name__ == "__main__":
    main()
