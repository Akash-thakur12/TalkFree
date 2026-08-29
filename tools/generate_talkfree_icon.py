#!/usr/bin/env python3
"""
TalkFree Pro — premium tile: handset + “+1” virtual badge, signal waves, sparkles.
Virtual free US line — clean, readable at app-icon size.
Regenerate: python tools/generate_talkfree_icon.py
"""
from __future__ import annotations

import math
import os
import random
import sys

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
BLACK = (0, 0, 0, 255)
SLATE = (15, 23, 42, 255)
SLATE_L = (30, 41, 59, 255)
NEON_D = (5, 95, 75, 255)
NEON_M = (16, 185, 129, 255)
NEON_H = (110, 231, 183, 255)
CYAN = (45, 212, 191, 255)
AMBER = (251, 191, 36, 255)
AMBER_D = (217, 119, 6, 255)


def blend_rgba(
    a: tuple[int, ...], b: tuple[int, ...], t: float
) -> tuple[int, int, int, int]:
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(4))


def draw_round_rect(
    dr: ImageDraw.ImageDraw, xy: tuple[int, int, int, int], r: int, fill: tuple[int, ...]
) -> None:
    dr.rounded_rectangle(xy, radius=r, fill=fill)


def main() -> int:
    random.seed(24)
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out = os.path.join(root, "assets", "logo.png")

    im = Image.new("RGBA", (SIZE, SIZE), BLACK)
    dr = ImageDraw.Draw(im)

    cx, cy = SIZE // 2, SIZE // 2 + 6

    # Ambient emerald glow
    glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gdr = ImageDraw.Draw(glow)
    gdr.ellipse((cx - 280, cy - 300, cx + 280, cy + 320), fill=(16, 185, 129, 48))
    glow = glow.filter(ImageFilter.GaussianBlur(32))
    im.alpha_composite(glow)
    dr = ImageDraw.Draw(im)

    # Rounded “premium” tile — deep slate
    pad = 52
    tile = (pad, pad, SIZE - pad, SIZE - pad)
    draw_round_rect(dr, tile, 76, SLATE)
    draw_round_rect(dr, (pad + 4, pad + 4, SIZE - pad - 4, SIZE - pad - 4), 72, SLATE_L)
    draw_round_rect(dr, (pad + 10, pad + 10, SIZE - pad - 10, SIZE - pad - 10), 66, SLATE)

    # Faint “global” arc behind handset
    arc_bb = (cx - 210, cy - 260, cx + 210, cy + 220)
    dr.arc(arc_bb, start=200, end=340, fill=(16, 185, 129, 55), width=4)
    dr.arc(
        (arc_bb[0] + 20, arc_bb[1] + 20, arc_bb[2] - 20, arc_bb[3] - 20),
        start=210,
        end=330,
        fill=(45, 212, 191, 40),
        width=3,
    )

    # Handset (upright, friendly proportions)
    bw, bh = 158, 360
    bx0 = cx - bw // 2
    by0 = cy - bh // 2 - 4
    body = (bx0, by0, bx0 + bw, by0 + bh)
    draw_round_rect(dr, body, 52, blend_rgba(CYAN, NEON_M, 0.2))
    draw_round_rect(
        dr, (body[0] + 4, body[1] + 4, body[2] - 4, body[3] - 4), 48, NEON_M
    )
    draw_round_rect(
        dr,
        (body[0] + 14, body[1] + 32, body[0] + 36, body[3] - 95),
        14,
        blend_rgba(NEON_H, NEON_M, 0.5),
    )
    draw_round_rect(
        dr,
        (body[2] - 30, body[1] + 44, body[2] - 10, body[3] - 110),
        10,
        blend_rgba(NEON_D, NEON_M, 0.55),
    )
    dr.ellipse(
        (cx - 34, by0 + 24, cx + 34, by0 + 68),
        fill=blend_rgba(NEON_D, BLACK, 0.5),
        outline=blend_rgba(NEON_H, NEON_M, 0.35),
        width=2,
    )

    # Signal waves (virtual / connected)
    wx, wy = cx + 48, cy - 95
    for i, w in enumerate([6, 11, 16]):
        bb = (wx - 18 - i * 32, wy - 8 - i * 24, wx + 88 + i * 8, wy + 72 + i * 28)
        dr.arc(bb, start=195, end=315, fill=blend_rgba(NEON_H, CYAN, 0.35 + i * 0.12), width=w)

    # “+1” virtual badge (free US line)
    br = 34
    bx, by = bx0 + bw - 8, by0 + bh // 2 - 10
    dr.ellipse((bx - br, by - br, bx + br, by + br), fill=AMBER, outline=AMBER_D, width=3)
    # “+1” (US virtual) — simple vector shapes
    dr.line((bx - 11, by, bx + 5, by), fill=SLATE, width=5)
    dr.line((bx - 3, by - 11, bx - 3, by + 11), fill=SLATE, width=5)
    dr.line((bx + 12, by - 9, bx + 12, by + 11), fill=SLATE, width=4)

    # Sparkle particles (energy / “free” magic)
    dr = ImageDraw.Draw(im)
    for _ in range(56):
        px = cx + random.randint(-120, 120)
        py = cy + random.randint(-180, 180)
        pr = random.randint(1, 3)
        al = random.randint(50, 210)
        c = random.choice([NEON_H, CYAN, NEON_M])
        dr.ellipse((px - pr, py - pr, px + pr, py + pr), fill=(c[0], c[1], c[2], al))

    im.save(out, "PNG")
    print("Wrote", out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
