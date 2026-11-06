#!/usr/bin/env python3
"""Render Jupiter's placeholder artwork.

The SVG logo is hand-written; this script only produces the raster files
that KDE needs (icon PNGs, wallpaper and its preview). It is not part of
the build: the generated PNGs are committed. Run it again after changing
the palette, or replace the PNGs with your own artwork.

Requires Pillow (python-pillow on Arch).
"""

from __future__ import annotations

import random
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
# The artwork sits beside PKGBUILD: makepkg only resolves local sources in
# the package directory, so there is no files/ subdirectory.
FILES = HERE

SKY_TOP = (5, 7, 15)
SKY_BOTTOM = (18, 28, 54)
SAND = (249, 226, 189)
RUST = (168, 83, 27)
BAND = (140, 68, 19)
AMBER = (232, 163, 61)


def mix(start: tuple[int, int, int], end: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(round(start[i] + (end[i] - start[i]) * t) for i in range(3))


def gradient(
    width: int,
    height: int,
    top: tuple[int, int, int] = SKY_TOP,
    bottom: tuple[int, int, int] = SKY_BOTTOM,
) -> Image.Image:
    image = Image.new("RGB", (width, height))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        draw.line(
            [(0, y), (width, y)],
            fill=mix(top, bottom, y / max(height - 1, 1)),
        )
    return image


def starfield(image: Image.Image, count: int = 520, seed: int = 7) -> Image.Image:
    draw = ImageDraw.Draw(image, "RGBA")
    rng = random.Random(seed)
    width, height = image.size
    for _ in range(count):
        x, y = rng.randrange(width), rng.randrange(height)
        radius = rng.choice((0, 0, 0, 1))
        alpha = rng.randrange(30, 170)
        draw.ellipse(
            (x - radius, y - radius, x + radius, y + radius),
            fill=(255, 248, 232, alpha),
        )
    return image


def planet(size: int) -> Image.Image:
    """A stylised gas giant with a ring, on a transparent canvas."""
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    centre = size / 2
    radius = size * 0.30

    disc = Image.new("L", (size, size), 0)
    ImageDraw.Draw(disc).ellipse(
        (centre - radius, centre - radius, centre + radius, centre + radius),
        fill=255,
    )

    body = gradient(size, size, SAND, RUST).convert("RGBA")
    bands = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    band_draw = ImageDraw.Draw(bands)
    band_draw.rectangle((0, size * 0.42, size, size * 0.46), fill=BAND + (95,))
    band_draw.rectangle((0, size * 0.52, size, size * 0.55), fill=BAND + (70,))
    band_draw.rectangle((0, size * 0.60, size, size * 0.68), fill=BAND + (110,))
    body = Image.alpha_composite(body, bands)

    body.putalpha(disc)
    image = Image.alpha_composite(image, body)

    ring = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(ring).ellipse(
        (size * 0.02, size * 0.40, size * 0.98, size * 0.62),
        outline=SAND + (210,),
        width=max(2, size // 80),
    )
    ring = ring.rotate(-14, resample=Image.BICUBIC, center=(centre, centre))

    return Image.alpha_composite(image, ring)


def write_png(image: Image.Image, name: str) -> None:
    path = FILES / name
    image.save(path, "PNG", optimize=True)
    print(f"wrote {path.relative_to(HERE)} ({path.stat().st_size // 1024} KiB)")


def main() -> None:
    for size in (256, 512):
        icon = planet(size)
        write_png(icon, f"logo-{size}.png")

    width, height = 2560, 1440
    wallpaper = starfield(gradient(width, height), count=700)
    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))

    glow = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(
        (width * 0.50, height * 0.12, width * 1.05, height * 1.05),
        fill=AMBER + (52,),
    )
    glow = glow.filter(ImageFilter.GaussianBlur(160))
    wallpaper = Image.alpha_composite(wallpaper.convert("RGBA"), glow)

    size = 980
    world = planet(size)
    position = (width - size - 150, height // 2 - size // 2 + 40)
    layer.paste(world, position, world)
    wallpaper = Image.alpha_composite(wallpaper, layer)

    wallpaper = wallpaper.convert("RGB")
    write_png(wallpaper, "wallpaper.png")

    preview = wallpaper.resize((1280, 720), Image.LANCZOS)
    write_png(preview, "wallpaper-preview.png")


if __name__ == "__main__":
    main()
