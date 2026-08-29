#!/usr/bin/env python3
"""
Import assets/reference/logo.png (+ optional splash) into assets/.

Writes: logo.png, splash_mark.png, ic_foreground.png (large glyph for adaptive launcher)
"""
from __future__ import annotations

import os
import sys

from PIL import Image, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF_LOGO = os.path.join(ROOT, "assets", "reference", "logo.png")
REF_SPLASH_A = os.path.join(ROOT, "assets", "reference", "splash_background.png")
REF_SPLASH_B = os.path.join(ROOT, "assets", "reference", "splash.png")
OUT_LOGO = os.path.join(ROOT, "assets", "logo.png")
OUT_MARK = os.path.join(ROOT, "assets", "splash_mark.png")
OUT_IC_FG = os.path.join(ROOT, "assets", "ic_foreground.png")
OUT_SPLASH = os.path.join(ROOT, "assets", "splash.png")


def _ref_splash_path() -> str | None:
    if os.path.isfile(REF_SPLASH_A):
        return REF_SPLASH_A
    if os.path.isfile(REF_SPLASH_B):
        return REF_SPLASH_B
    return None


def _is_neon_content(r: int, g: int, b: int, a: int) -> bool:
    if a < 8:
        return False
    if r < 52 and g < 52 and b < 52:
        return False
    if g >= max(r, b) + 10 and g >= 50:
        return True
    if g > r and g > b and (r + g + b) > 100:
        return True
    return False


def extract_transparent_mark(src: Image.Image) -> Image.Image:
    src = src.convert("RGBA")
    w, h = src.size
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    spx = src.load()
    opx = out.load()
    for y in range(h):
        for x in range(w):
            r, g, b, a = spx[x, y]
            if _is_neon_content(r, g, b, a):
                opx[x, y] = (r, g, b, a)
    return out


def soften_mark(im: Image.Image) -> Image.Image:
    g = im.copy().filter(ImageFilter.GaussianBlur(10))
    o = Image.new("RGBA", im.size, (0, 0, 0, 0))
    o.alpha_composite(g)
    o.alpha_composite(im)
    return o


def resize_square_1024(im: Image.Image) -> Image.Image:
    im = im.convert("RGBA")
    return im.resize((1024, 1024), Image.Resampling.LANCZOS)


def fit_launcher_foreground(
    im: Image.Image, overscale: float = 1.16
) -> Image.Image:
    """Crop to bbox, scale past 1024 then center-crop so the glyph fills the adaptive icon."""
    im = im.convert("RGBA")
    bbox = im.getbbox()
    if not bbox:
        return Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    im = im.crop(bbox)
    tw, th = im.size
    target = int(1024 * overscale)
    scale = target / max(tw, th)
    nw, nh = max(1, int(tw * scale)), max(1, int(th * scale))
    im = im.resize((nw, nh), Image.Resampling.LANCZOS)
    if nw < 1024 or nh < 1024:
        out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
        out.paste(im, ((1024 - nw) // 2, (1024 - nh) // 2), im)
        return out
    left = (nw - 1024) // 2
    top = (nh - 1024) // 2
    return im.crop((left, top, left + 1024, top + 1024))


def main() -> int:
    if not os.path.isfile(REF_LOGO):
        print(
            "Missing assets/reference/logo.png\n"
            "Save your logo PNG there, then re-run."
        )
        return 1

    raw = Image.open(REF_LOGO)
    logo1024 = resize_square_1024(raw)
    logo1024.save(OUT_LOGO, "PNG")
    print("Wrote", OUT_LOGO)

    crisp = extract_transparent_mark(logo1024)
    mark = soften_mark(crisp.copy())
    mark.save(OUT_MARK, "PNG")
    print("Wrote", OUT_MARK)

    fg = fit_launcher_foreground(crisp)
    fg.save(OUT_IC_FG, "PNG")
    print("Wrote", OUT_IC_FG)

    ref_sp = _ref_splash_path()
    if ref_sp:
        bg = Image.open(ref_sp).convert("RGBA")
        bg = bg.resize((1080, 1920), Image.Resampling.LANCZOS)
        bg.save(OUT_SPLASH, "PNG")
        print("Wrote", OUT_SPLASH, f"(from {os.path.basename(ref_sp)})")
    else:
        print("(Optional) skipped - no reference splash png")

    print("\nNext: dart run flutter_launcher_icons\n      dart run flutter_native_splash:create")
    return 0


if __name__ == "__main__":
    sys.exit(main())
