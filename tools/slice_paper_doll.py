#!/usr/bin/env python3
"""Slice Faceoff chroma-key paper-doll sheets into transparent limb textures."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


REGIONS = {
    "head": (0.00, 0.00, 0.50, 0.36),
    "torso": (0.50, 0.00, 1.00, 0.36),
    "left_upper_arm": (0.00, 0.365, 0.25, 0.65),
    "left_forearm": (0.25, 0.365, 0.50, 0.65),
    "right_upper_arm": (0.50, 0.365, 0.75, 0.65),
    "right_forearm": (0.75, 0.365, 1.00, 0.65),
    "left_thigh": (0.00, 0.63, 0.25, 1.00),
    "left_shin": (0.25, 0.63, 0.50, 1.00),
    "right_thigh": (0.50, 0.63, 0.75, 1.00),
    "right_shin": (0.75, 0.63, 1.00, 1.00),
}


def trim_alpha(image: Image.Image, padding: int = 10) -> Image.Image:
    alpha = image.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        raise ValueError("region contains no visible pixels")
    left, top, right, bottom = bbox
    left = max(0, left - padding)
    top = max(0, top - padding)
    right = min(image.width, right + padding)
    bottom = min(image.height, bottom + padding)
    return image.crop((left, top, right, bottom))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()

    sheet = Image.open(args.input).convert("RGBA")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for name, region in REGIONS.items():
        x0, y0, x1, y1 = region
        crop = sheet.crop(
            (
                round(x0 * sheet.width),
                round(y0 * sheet.height),
                round(x1 * sheet.width),
                round(y1 * sheet.height),
            )
        )
        final = trim_alpha(crop)
        final.save(args.output_dir / f"{name}.png")
        print(f"{name}: {final.width}x{final.height}")


if __name__ == "__main__":
    main()
