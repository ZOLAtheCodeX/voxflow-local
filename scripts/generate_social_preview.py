#!/usr/bin/env python3
"""Generate the GitHub social preview card (1280x640) for VoxFlow Local.

Reuses the Waveline mark + palette from generate_app_icon.py so the card and
the app icon stay one identity: a monoline voice-waveform resolving into a
written baseline, ending in a teal cursor dot, on flat ink. No gloss, no glow.

Output is kept well under GitHub's 1 MB social-card limit (flat colors → tiny
PNG). Upload it in repo Settings → Social preview (that toggle is UI-only).
"""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# ── Brand (shared with generate_app_icon.py) ──────────────────────────
INK_TOP = (35, 38, 46)        # #23262e
INK_BOTTOM = (20, 22, 27)     # #14161b
PAPER = (244, 242, 236)       # #f4f2ec
TEAL = (47, 212, 197)         # #2fd4c5

CARD_W, CARD_H = 1280, 640
SS = 2  # supersample for crisp edges, then downscale

# Waveline path in 0-100 mark-box coordinates (matches the app icon).
WAVE_SEGMENTS = [
    ((12, 50), (17, 22), (22, 50)),
    ((22, 50), (27, 78), (32, 50)),
    ((32, 50), (37, 30), (42, 50)),
    ((42, 50), (47, 70), (52, 50)),
]
BASELINE_END = (76, 50)
DOT_CENTER = (85, 50)


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def blend(c1, c2, t: float):
    return tuple(int(lerp(c1[i], c2[i], t)) for i in range(3))


def _quad_bezier(p0, p1, p2, steps=80):
    pts = []
    for i in range(steps + 1):
        s = i / steps
        x = (1 - s) ** 2 * p0[0] + 2 * (1 - s) * s * p1[0] + s ** 2 * p2[0]
        y = (1 - s) ** 2 * p0[1] + 2 * (1 - s) * s * p1[1] + s ** 2 * p2[1]
        pts.append((x, y))
    return pts


def _load_font(size: int, bold: bool):
    """Best-effort system font; falls back to Pillow's default."""
    candidates = [
        ("/System/Library/Fonts/Helvetica.ttc", 1 if bold else 0),
        ("/System/Library/Fonts/HelveticaNeue.ttc", 1 if bold else 0),
        ("/Library/Fonts/Arial Bold.ttf" if bold else "/Library/Fonts/Arial.ttf", 0),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold
         else "/System/Library/Fonts/Supplemental/Arial.ttf", 0),
    ]
    for path, index in candidates:
        try:
            return ImageFont.truetype(path, size, index=index), Path(path).name
        except Exception:
            continue
    return ImageFont.load_default(), "default"


def _draw_mark(draw: ImageDraw.ImageDraw, box_x: float, box_y: float, box: float) -> None:
    """Draw the Waveline mark inside a square box (0-100 local coords)."""
    def mx(v): return box_x + v / 100.0 * box
    def my(v): return box_y + v / 100.0 * box

    stroke = box * 0.062
    dot_r = box * 0.050

    points: list[tuple[float, float]] = []
    for p0, p1, p2 in WAVE_SEGMENTS:
        seg = _quad_bezier((mx(p0[0]), my(p0[1])), (mx(p1[0]), my(p1[1])), (mx(p2[0]), my(p2[1])))
        points.extend(seg[1:] if points else seg)
    points.append((mx(BASELINE_END[0]), my(BASELINE_END[1])))

    # Brush-stamp filled circles for a clean monoline with round caps.
    r = stroke / 2.0
    step = max(1.0, r * 0.3)
    stamped = [points[0]]
    carry = 0.0
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        seg_len = ((x1 - x0) ** 2 + (y1 - y0) ** 2) ** 0.5
        if seg_len == 0:
            continue
        d = step - carry
        while d <= seg_len:
            s = d / seg_len
            stamped.append((x0 + (x1 - x0) * s, y0 + (y1 - y0) * s))
            d += step
        carry = (carry + seg_len) % step
    stamped.append(points[-1])
    for sx, sy in stamped:
        draw.ellipse((sx - r, sy - r, sx + r, sy + r), fill=PAPER + (255,))

    cx, cy = mx(DOT_CENTER[0]), my(DOT_CENTER[1])
    draw.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=TEAL + (255,))


def build_card() -> Image.Image:
    w, h = CARD_W * SS, CARD_H * SS
    img = Image.new("RGB", (w, h), INK_BOTTOM)
    draw = ImageDraw.Draw(img)

    # Full-bleed ink ground, barely-there vertical gradient (not a glow).
    for y in range(h):
        draw.line((0, y, w, y), fill=blend(INK_TOP, INK_BOTTOM, y / h))

    # Mark, centered horizontally near the top.
    box = 300 * SS
    _draw_mark(draw, (w - box) / 2, 20 * SS, box)

    cx = w / 2
    title_font, tf = _load_font(96 * SS, bold=True)
    tag_font, _ = _load_font(40 * SS, bold=False)
    foot_font, _ = _load_font(28 * SS, bold=False)

    draw.text((cx, 364 * SS), "VoxFlow Local", font=title_font, fill=PAPER, anchor="mm")
    draw.text((cx, 452 * SS), "Local-first dictation for macOS",
              font=tag_font, fill=blend(PAPER, INK_BOTTOM, 0.28), anchor="mm")
    draw.text((cx, 528 * SS), "Privacy by architecture  ·  Build from source",
              font=foot_font, fill=TEAL, anchor="mm")

    print(f"font: {tf}")
    return img.resize((CARD_W, CARD_H), Image.LANCZOS)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate the VoxFlow social preview card")
    parser.add_argument(
        "--output",
        default=str(Path(__file__).resolve().parent.parent / "docs" / "assets" / "social-preview.png"),
        help="Destination PNG path",
    )
    args = parser.parse_args()

    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    card = build_card()
    card.save(out, optimize=True)
    kb = out.stat().st_size / 1024
    print(f"Social card written: {out} ({card.width}x{card.height}, {kb:.0f} KB)")


if __name__ == "__main__":
    main()
