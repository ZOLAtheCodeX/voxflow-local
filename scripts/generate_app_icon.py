#!/usr/bin/env python3
"""Generate a VoxFlow macOS iconset using Pillow."""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path

from PIL import Image, ImageDraw


ICON_FILES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def blend(c1: tuple[int, int, int], c2: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return (
        int(lerp(c1[0], c2[0], t)),
        int(lerp(c1[1], c2[1], t)),
        int(lerp(c1[2], c2[2], t)),
    )


def _quad_bezier(p0, p1, p2, steps=80):
    """Sample a quadratic bezier as a point list."""
    pts = []
    for i in range(steps + 1):
        s = i / steps
        x = (1 - s) ** 2 * p0[0] + 2 * (1 - s) * s * p1[0] + s ** 2 * p2[0]
        y = (1 - s) ** 2 * p0[1] + 2 * (1 - s) * s * p1[1] + s ** 2 * p2[1]
        pts.append((x, y))
    return pts


# Waveline design (2026-06-12, direction A from docs/design/2026-06-12-icon-directions.html):
# one continuous monoline stroke — a voice waveform resolving into a written
# baseline — ending in a teal cursor dot. Flat ink ground, no gloss, no glow.
INK_TOP = (35, 38, 46)       # #23262e
INK_BOTTOM = (20, 22, 27)    # #14161b
PAPER = (244, 242, 236, 255)  # #f4f2ec
TEAL = (47, 212, 197, 255)    # #2fd4c5

# Path in 0-100 body coordinates (T segments pre-expanded to explicit controls).
WAVE_SEGMENTS = [
    ((12, 50), (17, 22), (22, 50)),
    ((22, 50), (27, 78), (32, 50)),
    ((32, 50), (37, 30), (42, 50)),
    ((42, 50), (47, 70), (52, 50)),
]
BASELINE_END = (76, 50)
DOT_CENTER = (85, 50)


def build_icon(size: int) -> Image.Image:
    # Supersample 4x for clean anti-aliased strokes at every ladder size.
    ss = 4
    big = size * ss
    image = Image.new("RGBA", (big, big), (0, 0, 0, 0))

    # macOS icon grid: the squircle body floats inside the canvas with
    # ~9.8% margins; the corner radius is ~22.5% of the body width.
    inset = big * 0.098
    body = big - 2 * inset
    radius = body * 0.225

    # Flat ink ground with a barely-there vertical gradient (not a glow).
    bg = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    bg_draw = ImageDraw.Draw(bg)
    for y in range(int(inset), int(big - inset) + 1):
        s = (y - inset) / max(body, 1)
        bg_draw.line((0, y, big, y), fill=blend(INK_TOP, INK_BOTTOM, s) + (255,))
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, big - inset, big - inset), radius=radius, fill=255
    )
    image.paste(bg, (0, 0), mask)
    draw = ImageDraw.Draw(image)

    def bx(v: float) -> float:
        return inset + v / 100.0 * body

    def by(v: float) -> float:
        return inset + v / 100.0 * body

    # Small sizes need a heavier stroke and dot to stay legible.
    if size >= 128:
        stroke_pct, dot_pct = 6.5, 4.6
    elif size >= 32:
        stroke_pct, dot_pct = 8.0, 5.5
    else:
        stroke_pct, dot_pct = 11.0, 7.0
    stroke = max(2, int(body * stroke_pct / 100.0))
    dot_r = body * dot_pct / 100.0

    points: list[tuple[float, float]] = []
    for p0, p1, p2 in WAVE_SEGMENTS:
        seg = _quad_bezier((bx(p0[0]), by(p0[1])), (bx(p1[0]), by(p1[1])), (bx(p2[0]), by(p2[1])))
        if points:
            seg = seg[1:]
        points.extend(seg)
    points.append((bx(BASELINE_END[0]), by(BASELINE_END[1])))

    # Brush-stamp the stroke: filled circles at tight arc-length intervals.
    # Pillow's thick polylines produce seam/joint artifacts; stamping gives a
    # clean monoline with round caps for free.
    r = stroke / 2.0
    step = max(1.0, r * 0.3)
    stamped: list[tuple[float, float]] = [points[0]]
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
    for (sx, sy) in stamped:
        draw.ellipse((sx - r, sy - r, sx + r, sy + r), fill=PAPER)

    cx, cy = bx(DOT_CENTER[0]), by(DOT_CENTER[1])
    draw.ellipse((cx - dot_r, cy - dot_r, cx + dot_r, cy + dot_r), fill=TEAL)

    return image.resize((size, size), Image.LANCZOS)


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate VoxFlow .iconset images")
    parser.add_argument(
        "--output",
        required=True,
        help="Destination iconset directory (e.g. /tmp/VoxFlow.iconset)",
    )
    args = parser.parse_args()

    output_dir = Path(args.output)
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    for filename, size in ICON_FILES:
        icon = build_icon(size)
        icon.save(output_dir / filename)

    print(f"Iconset written: {output_dir}")


if __name__ == "__main__":
    main()
