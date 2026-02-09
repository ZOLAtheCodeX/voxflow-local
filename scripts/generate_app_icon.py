#!/usr/bin/env python3
"""Generate a VoxFlow macOS iconset using Pillow."""

from __future__ import annotations

import argparse
import math
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


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


def build_icon(size: int) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    top = (36, 182, 221)
    bottom = (11, 53, 120)

    for y in range(size):
        t = y / max(size - 1, 1)
        color = blend(top, bottom, t)
        draw.line((0, y, size, y), fill=color + (255,))

    inset = int(size * 0.08)
    radius = int(size * 0.24)
    mask = Image.new("L", (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    mask_draw.rounded_rectangle(
        (inset, inset, size - inset, size - inset),
        radius=radius,
        fill=255,
    )

    clipped = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    clipped.paste(image, (0, 0), mask)
    image = clipped
    draw = ImageDraw.Draw(image)

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        (
            int(size * 0.13),
            int(size * 0.08),
            int(size * 0.92),
            int(size * 0.83),
        ),
        fill=(255, 255, 255, 45),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(radius=size * 0.04))
    image.alpha_composite(glow)

    draw = ImageDraw.Draw(image)
    wave_color = (255, 255, 255, 230)
    stroke = max(2, int(size * 0.04))
    waveform_top = int(size * 0.36)
    waveform_height = int(size * 0.24)
    left = int(size * 0.22)
    right = int(size * 0.78)
    points: list[tuple[int, int]] = []
    steps = 12
    for i in range(steps + 1):
        x = int(lerp(left, right, i / steps))
        phase = (i / steps) * math.pi * 2.5
        y = waveform_top + int((math.sin(phase) * 0.36 + 0.5) * waveform_height)
        points.append((x, y))
    draw.line(points, fill=wave_color, width=stroke, joint="curve")

    mic_width = int(size * 0.18)
    mic_height = int(size * 0.23)
    mic_x = int((size - mic_width) / 2)
    mic_y = int(size * 0.53)
    draw.rounded_rectangle(
        (mic_x, mic_y, mic_x + mic_width, mic_y + mic_height),
        radius=int(mic_width * 0.45),
        outline=wave_color,
        width=stroke,
    )
    stem_x = int(size / 2)
    stem_y0 = mic_y + mic_height
    stem_y1 = int(size * 0.84)
    draw.line((stem_x, stem_y0, stem_x, stem_y1), fill=wave_color, width=stroke)
    draw.arc(
        (
            int(size * 0.37),
            int(size * 0.72),
            int(size * 0.63),
            int(size * 0.92),
        ),
        start=195,
        end=-15,
        fill=wave_color,
        width=stroke,
    )

    return image


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
