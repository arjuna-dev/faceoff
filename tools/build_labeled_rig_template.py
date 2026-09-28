#!/usr/bin/env python3
"""Create a labeled copy of the geometric rig template.

The source template is never modified. Labels are deterministic annotations for
image-generation models and are not part of the rig contract.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont

from armk_atlas_test import CELL_NAMES
from rig_coordinate_contract import detect_grid_cells


LABELS = {
    "head_and_neck": "HEAD + NECK",
    "torso_and_pelvis": "TORSO + PELVIS",
    "viewer_left_upper_arm": "VIEWER-LEFT\nUPPER ARM",
    "viewer_left_forearm_and_hand": "VIEWER-LEFT\nFOREARM + HAND",
    "viewer_right_forearm_and_hand": "VIEWER-RIGHT\nFOREARM + HAND",
    "viewer_right_upper_arm": "VIEWER-RIGHT\nUPPER ARM",
    "viewer_left_thigh": "VIEWER-LEFT\nTHIGH",
    "viewer_right_thigh": "VIEWER-RIGHT\nTHIGH",
    "viewer_left_shin": "VIEWER-LEFT\nSHIN",
    "viewer_left_sneaker": "VIEWER-LEFT\nSNEAKER",
    "viewer_right_shin": "VIEWER-RIGHT\nSHIN",
    "viewer_right_sneaker": "VIEWER-RIGHT\nSNEAKER",
}

LABEL_FILL = (255, 255, 96)
LABEL_OUTLINE = (20, 20, 20)
LABEL_TEXT = (10, 10, 10)


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Supplemental/Verdana Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ]
    for candidate in candidates:
        path = Path(candidate)
        if path.is_file():
            try:
                return ImageFont.truetype(str(path), size=size)
            except OSError:
                continue
    return ImageFont.load_default()


def _draw_label(draw: ImageDraw.ImageDraw, rect: list[int], text: str, font: Any) -> list[int]:
    x0, y0, x1, y1 = rect
    padding_x = 5
    padding_y = 3
    anchor = (x0 + 8, y0 + 8)
    bbox = draw.multiline_textbbox(anchor, text, font=font, spacing=1)
    label_rect = [
        bbox[0] - padding_x,
        bbox[1] - padding_y,
        bbox[2] + padding_x,
        bbox[3] + padding_y,
    ]
    if label_rect[2] >= x1 or label_rect[3] >= y1:
        raise ValueError(f"Label does not fit inside cell {rect}: {text!r}")
    draw.rounded_rectangle(label_rect, radius=3, fill=LABEL_FILL, outline=LABEL_OUTLINE, width=2)
    draw.multiline_text(anchor, text, font=font, fill=LABEL_TEXT, spacing=1)
    return label_rect


def build(source: Path, output: Path, metadata: Path) -> None:
    image = Image.open(source).convert("RGB")
    cells = detect_grid_cells(image)
    if [cell["name"] for cell in cells] != CELL_NAMES:
        raise ValueError("Source template cell order does not match the rig contract")

    labeled = image.copy()
    draw = ImageDraw.Draw(labeled)
    label_rectangles: dict[str, list[int]] = {}
    by_name = {cell["name"]: cell for cell in cells}
    for name in CELL_NAMES:
        size = 15 if name in {"head_and_neck", "torso_and_pelvis", "viewer_left_thigh", "viewer_right_thigh"} else 12
        label_rectangles[name] = _draw_label(draw, by_name[name]["rect"], LABELS[name], _font(size))

    output.parent.mkdir(parents=True, exist_ok=True)
    labeled.save(output)
    metadata.parent.mkdir(parents=True, exist_ok=True)
    metadata.write_text(
        json.dumps(
            {
                "schema_version": 1,
                "source_template": str(source.resolve()),
                "output_template": str(output.resolve()),
                "canvas": list(image.size),
                "annotation_color": "#FFFF60",
                "annotation_role": "model guidance only; remove labels from generated output",
                "labels": LABELS,
                "label_rectangles": label_rectangles,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    args = parser.parse_args()
    build(args.source, args.output, args.metadata)
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
