#!/usr/bin/env python3
"""Generate TalkFree Pro launcher icons:
- talkfree_pro_icon.png — full 1024 master (gradient + white glyph) for iOS / fallback
- talkfree_pro_foreground.png — transparent + white glyph only for Android adaptive foreground
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
C0 = (15, 118, 110)
C1 = (4, 120, 87)


def lerp(a: float, b: float, t: float) -> int:
    return int(a + (b - a) * t)


def gradient_rgb() -> Image.Image:
    img = Image.new("RGB", (SIZE, SIZE))
    px = img.load()
    for y in range(SIZE):
        for x in range(SIZE):
            t = (x + y) / max(1, 2 * (SIZE - 1))
            t = max(0.0, min(1.0, t))
            r = lerp(C0[0], C1[0], t)
            g = lerp(C0[1], C1[1], t)
            b = lerp(C0[2], C1[2], t)
            px[x, y] = (r, g, b)
    return img


def draw_glyph(d: ImageDraw.ImageDraw) -> None:
    cx, cy = SIZE // 2, SIZE // 2 + 18
    w, h = 330, 390
    shield = [
        (cx, cy - h // 2),
        (cx + w // 2 - 8, cy - h // 4),
        (cx + w // 2, cy + h // 8),
        (cx + w // 3, cy + h // 2 - 12),
        (cx, cy + h // 2),
        (cx - w // 3, cy + h // 2 - 12),
        (cx - w // 2, cy + h // 8),
        (cx - w // 2 + 8, cy - h // 4),
    ]
    d.polygon(shield, outline=(255, 255, 255, 255), width=34)

    bw, bh = 210, 148
    x0 = cx - bw // 2
    y0 = cy - bh // 2 - 28
    x1 = x0 + bw
    y1 = y0 + bh
    d.rounded_rectangle(
        [x0, y0, x1, y1],
        radius=38,
        outline=(255, 255, 255, 255),
        width=26,
    )
    tail = [
        (cx - 26, y1 - 2),
        (cx + 6, y1 + 26),
        (cx + 34, y1 - 2),
    ]
    d.line(tail + [tail[0]], fill=(255, 255, 255, 255), width=26, joint="curve")
    d.arc(
        [cx - 58, y0 + 18, cx + 58, y0 + 118],
        start=200,
        end=340,
        fill=(255, 255, 255, 255),
        width=14,
    )


def main() -> None:
    root = Path(__file__).resolve().parent.parent
    icon_dir = root / "assets" / "icon"
    icon_dir.mkdir(parents=True, exist_ok=True)

    # Full-bleed (iOS / marketing)
    base = gradient_rgb().convert("RGBA")
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    draw_glyph(d)
    full = Image.alpha_composite(base, layer).convert("RGB")
    p_full = icon_dir / "talkfree_pro_icon.png"
    full.save(p_full, "PNG", optimize=True)
    print(f"Wrote {p_full}")

    # Adaptive foreground: transparent + white only
    fg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d2 = ImageDraw.Draw(fg)
    draw_glyph(d2)
    p_fg = icon_dir / "talkfree_pro_foreground.png"
    fg.save(p_fg, "PNG", optimize=True)
    print(f"Wrote {p_fg}")


if __name__ == "__main__":
    main()
