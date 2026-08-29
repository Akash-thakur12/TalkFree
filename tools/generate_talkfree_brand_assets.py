#!/usr/bin/env python3
"""
TalkFree — horizontal classic handset (ear–bar–mouth). Exactly 2 waves above.
Avoids stacked circles + rotation reading as “8” / infinity.

splash_mark.png — transparent (splash + native + adaptive foreground)
logo.png — same mark on rounded-square plate

Regenerate: python tools/generate_talkfree_brand_assets.py

To use YOUR exported logo + splash art instead, place PNGs under assets/reference/
and run: python tools/sync_reference_brand.py (see that file for filenames).
"""
from __future__ import annotations

import os
import random
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

NEON = (0, 255, 156, 255)
NEON_DARK = (0, 150, 105, 255)
BLACK = (0, 0, 0, 255)
PLATE_TOP = (10, 12, 14, 255)
PLATE_BOT = (0, 2, 4, 255)


def draw_two_waves(dr: ImageDraw.ImageDraw, ax: float, ay: float) -> None:
    """Exactly 2 arcs — narrow angle range so anti-aliasing doesn’t read as a 3rd line."""
    for i in range(2):
        r = 22 + i * 32
        w = 6 - i
        bb = (ax - r * 1.12, ay - r * 0.42, ax + r * 1.12, ay + r * 0.62)
        dr.arc(bb, start=210, end=318, fill=NEON, width=max(4, w))


def draw_horizontal_handset(sd: ImageDraw.ImageDraw, mx: float, my: float, s: float) -> None:
    """
    Classic telephone receiver: two vertical ovals + straight bridge (reads as handset, not “C”).
    """
    # Left ear (smaller oval)
    sd.ellipse(
        (mx - 188 * s, my - 72 * s, mx - 78 * s, my + 72 * s),
        fill=NEON_DARK,
        outline=NEON,
        width=6,
    )
    sd.ellipse(
        (mx - 172 * s, my - 58 * s, mx - 92 * s, my + 58 * s),
        fill=NEON,
    )
    # Right mouth (larger oval)
    sd.ellipse(
        (mx + 78 * s, my - 88 * s, mx + 198 * s, my + 88 * s),
        fill=NEON_DARK,
        outline=NEON,
        width=6,
    )
    sd.ellipse(
        (mx + 92 * s, my - 72 * s, mx + 182 * s, my + 72 * s),
        fill=NEON,
    )
    # Straight handle — ties ends together (stops abstract curve read)
    sd.rounded_rectangle(
        (mx - 102 * s, my - 42 * s, mx + 102 * s, my + 42 * s),
        radius=36 * s,
        fill=NEON,
        outline=NEON,
        width=4,
    )


def render_mark_bitmap(size: int, scale: float) -> Image.Image:
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    cx, cy = size / 2, size / 2 + 24

    lw, lh = 720, 520
    sub = Image.new("RGBA", (lw, lh), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sub)
    mx, my = lw / 2, lh / 2 + 10
    draw_two_waves(sd, mx - 118, my - 162)
    draw_horizontal_handset(sd, mx, my, scale)

    # Standard “call” icon tilt
    sub = sub.rotate(-46, resample=Image.Resampling.BICUBIC, expand=True)
    sw, sh = sub.size
    layer = Image.new("RGBA", im.size, (0, 0, 0, 0))
    layer.paste(sub, (int(cx - sw / 2), int(cy - sh / 2)), sub)
    im.alpha_composite(layer)
    return im


def render_glass_plate(base: Image.Image, pad: int, r: int) -> None:
    n = base.size[0]
    sh = Image.new("RGBA", base.size, (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle(
        (pad + 4, pad + 10, n - pad + 4, n - pad + 12),
        radius=r,
        fill=(0, 0, 0, 80),
    )
    base.alpha_composite(sh.filter(ImageFilter.GaussianBlur(14)))

    plate = Image.new("RGBA", base.size, (0, 0, 0, 0))
    pd = ImageDraw.Draw(plate)
    for y in range(pad, n - pad):
        t = (y - pad) / max(1, n - 2 * pad)
        col = (
            int(PLATE_TOP[0] + (PLATE_BOT[0] - PLATE_TOP[0]) * t),
            int(PLATE_TOP[1] + (PLATE_BOT[1] - PLATE_TOP[1]) * t),
            int(PLATE_TOP[2] + (PLATE_BOT[2] - PLATE_TOP[2]) * t),
            255,
        )
        pd.line([(pad, y), (n - pad, y)], fill=col)
    mask = Image.new("L", base.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (pad, pad, n - pad, n - pad), radius=r, fill=255
    )
    plate.putalpha(mask)
    base.alpha_composite(plate)
    ImageDraw.Draw(base).rounded_rectangle(
        (pad + 2, pad + 2, n - pad - 2, n - pad - 2),
        radius=r - 2,
        outline=(*NEON[:3], 80),
        width=2,
    )


def render_logo_1024() -> Image.Image:
    size = 1024
    out = Image.new("RGBA", (size, size), BLACK)
    cx, cy = size / 2, size / 2 + 8
    # Neon halo behind squircle (reference: green aura on black)
    for blur, alpha in ((52, 26), (72, 14)):
        glow = Image.new("RGBA", out.size, (0, 0, 0, 0))
        ImageDraw.Draw(glow).ellipse(
            (cx - 380, cy - 380, cx + 380, cy + 380), fill=(*NEON[:3], alpha)
        )
        out.alpha_composite(glow.filter(ImageFilter.GaussianBlur(blur)))
    pad, r = 78, 186
    render_glass_plate(out, pad, r)
    amb = Image.new("RGBA", out.size, (0, 0, 0, 0))
    ImageDraw.Draw(amb).ellipse(
        (cx - 190, cy - 190, cx + 190, cy + 190), fill=(*NEON[:3], 20)
    )
    out.alpha_composite(amb.filter(ImageFilter.GaussianBlur(30)))
    out.alpha_composite(render_mark_bitmap(size, 1.0))
    return out


def render_splash_mark_1024() -> Image.Image:
    """Soft glow for splash; slightly sharper than before."""
    im = render_mark_bitmap(1024, 1.06)
    g = im.copy().filter(ImageFilter.GaussianBlur(8))
    o = Image.new("RGBA", im.size, (0, 0, 0, 0))
    o.alpha_composite(g)
    o.alpha_composite(im)
    return o


def render_adaptive_foreground_1024() -> Image.Image:
    """Crisp mark scaled to fill adaptive safe area (home-screen icon reads larger)."""
    # Single full canvas + higher stroke scale so the handset isn’t visually tiny.
    return render_mark_bitmap(1024, 1.58)


def render_splash_9_16() -> Image.Image:
    """9:16 luxury backdrop — deep black, soft mint radial, floating particles."""
    w, h = 1080, 1920
    im = Image.new("RGBA", (w, h), BLACK)
    dr = ImageDraw.Draw(im)
    y = 0
    while y < h:
        t = y / h
        y2 = min(y + 3, h)
        dr.rectangle(
            (0, y, w, y2),
            fill=(int(t * 4), int(1 + t * 10), int(2 + t * 8), 255),
        )
        y = y2
    # Cinematic center glow (behind logo area).
    aur = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    cx, cy = w * 0.5, h * 0.34
    ImageDraw.Draw(aur).ellipse(
        (cx - w * 0.55, cy - h * 0.42, cx + w * 0.55, cy + h * 0.48),
        fill=(*NEON[:3], 22),
    )
    im.alpha_composite(aur.filter(ImageFilter.GaussianBlur(95)))
    random.seed(99)
    dr = ImageDraw.Draw(im)
    for _ in range(140):
        px = random.randint(0, w)
        py = random.randint(0, int(h * 0.88))
        pr = random.randint(1, 3)
        al = random.randint(5, 72)
        dr.ellipse((px - pr, py - pr, px + pr, py + pr), fill=(*NEON[:3], al))
    return im


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ref_logo = os.path.join(root, "assets", "reference", "logo.png")
    logo = os.path.join(root, "assets", "logo.png")
    mark = os.path.join(root, "assets", "splash_mark.png")
    ic_fg = os.path.join(root, "assets", "ic_foreground.png")
    splash = os.path.join(root, "assets", "splash.png")

    if os.path.isfile(ref_logo):
        print("Using assets/reference/logo.png (your chat export) …")
        sync = subprocess.run(
            [sys.executable, os.path.join(root, "tools", "sync_reference_brand.py")],
            cwd=root,
        )
        if sync.returncode != 0:
            return sync.returncode
        # ic_foreground.png is already written by sync_reference_brand.py (do not overwrite with splash_mark).
        render_splash_9_16().save(splash, "PNG")
        print("Wrote", splash)
        return 0

    render_logo_1024().save(logo, "PNG")
    print("Wrote", logo)
    render_splash_mark_1024().save(mark, "PNG")
    print("Wrote", mark)
    render_adaptive_foreground_1024().save(ic_fg, "PNG")
    print("Wrote", ic_fg)
    render_splash_9_16().save(splash, "PNG")
    print("Wrote", splash)
    return 0


if __name__ == "__main__":
    sys.exit(main())
