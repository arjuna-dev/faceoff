#!/usr/bin/env python3
"""Build a featureless flat-shape template for the 12-part rig contract."""
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw

from character_generation_workflow import CANVAS_SIZE, _marker_json, _markers


MAGENTA = (255, 0, 255)
WHITE = (255, 255, 255)
OUTLINE = (45, 49, 56)
BODY = (186, 190, 196)
LEG_GARMENT = (126, 133, 143)
FOOTWEAR = (82, 88, 98)
CYAN = (0, 255, 255)


def center(entry: dict[str, Any]) -> tuple[float, float]:
    return float(entry["center"][0]), float(entry["center"][1])


def capsule(
    draw: ImageDraw.ImageDraw,
    start: tuple[float, float],
    end: tuple[float, float],
    width: int,
    fill: tuple[int, int, int],
    outline_width: int = 5,
) -> None:
    rounded_start = tuple(round(value) for value in start)
    rounded_end = tuple(round(value) for value in end)
    draw.line((rounded_start, rounded_end), fill=OUTLINE, width=width + outline_width * 2)
    radius = (width + outline_width * 2) // 2
    for x, y in (rounded_start, rounded_end):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=OUTLINE)
    draw.line((rounded_start, rounded_end), fill=fill, width=width)
    radius = width // 2
    for x, y in (rounded_start, rounded_end):
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), fill=fill)


def polygon(
    draw: ImageDraw.ImageDraw,
    points: list[tuple[float, float]],
    fill: tuple[int, int, int],
    outline_width: int = 5,
) -> None:
    rounded = [(round(x), round(y)) for x, y in points]
    draw.polygon(rounded, fill=fill)
    draw.line(rounded + [rounded[0]], fill=OUTLINE, width=outline_width, joint="curve")


def draw_marker(draw: ImageDraw.ImageDraw, marker: dict[str, Any]) -> None:
    x0, y0, x1, y1 = (int(value) for value in marker["bbox"])
    draw.ellipse((x0 - 2, y0 - 2, x1 + 1, y1 + 1), fill=OUTLINE)
    draw.ellipse((x0, y0, x1 - 1, y1 - 1), fill=CYAN)


def build(source: Path, output: Path) -> dict[str, Any]:
    payload = json.loads(source.read_text(encoding="utf-8"))
    if tuple(payload["canvas"]) != CANVAS_SIZE or payload.get("marker_count") != 22:
        raise ValueError("Source coordinate file must describe the 1024x1536, 22-marker contract")

    image = Image.new("RGB", CANVAS_SIZE, WHITE)
    draw = ImageDraw.Draw(image)
    pivots = payload["pivots"]

    # Paint only the cell interiors magenta. The untouched canvas becomes the
    # exact white frame and gutters, independent of any earlier artwork.
    for cell in payload["cells"]:
        x0, y0, x1, y1 = cell["rect"]
        draw.rectangle((x0, y0, x1 - 1, y1 - 1), fill=MAGENTA)

    # Head and neck are deliberately symbols, not a face or gendered anatomy.
    head_marker = center(pivots["head_and_neck"][0])
    draw.ellipse((154, 92, 304, 278), fill=BODY, outline=OUTLINE, width=5)
    draw.rounded_rectangle((207, 255, 250, round(head_marker[1]) + 4), radius=18,
                           fill=BODY, outline=OUTLINE, width=5)

    # The upper block and lower garment-ownership block are flat polygons. The
    # latter means a generated waistband and upper trousers belong to this cell.
    torso = pivots["torso_and_pelvis"]
    neck, left_shoulder, right_shoulder, left_hip, right_hip = map(center, torso)
    polygon(draw, [
        (neck[0] - 24, neck[1] - 24),
        (neck[0] + 24, neck[1] - 24),
        (right_shoulder[0] + 23, right_shoulder[1] - 12),
        (right_hip[0] + 22, 286),
        (left_hip[0] - 22, 286),
        (left_shoulder[0] - 23, left_shoulder[1] - 12),
    ], BODY)
    polygon(draw, [
        (left_hip[0] - 22, 282),
        (right_hip[0] + 22, 282),
        (right_hip[0] + 14, 390),
        (left_hip[0] - 14, 390),
    ], LEG_GARMENT)

    for name in ("viewer_left_upper_arm", "viewer_right_upper_arm"):
        start, end = (center(item) for item in pivots[name])
        capsule(draw, start, end, 70, BODY)

    forearm_ends = {
        "viewer_left_forearm_and_hand": (407, 744),
        "viewer_right_forearm_and_hand": (617, 744),
    }
    for name, end in forearm_ends.items():
        capsule(draw, center(pivots[name][0]), end, 62, BODY)
        draw.ellipse((end[0] - 31, end[1] - 29, end[0] + 37, end[1] + 35),
                     fill=BODY, outline=OUTLINE, width=5)

    for name in ("viewer_left_thigh", "viewer_right_thigh"):
        start, end = (center(item) for item in pivots[name])
        capsule(draw, start, end, 64, LEG_GARMENT)

    for name in ("viewer_left_shin", "viewer_right_shin"):
        start, end = (center(item) for item in pivots[name])
        capsule(draw, start, end, 72, LEG_GARMENT)

    shoe_ends = {
        "viewer_left_sneaker": (438, 1372),
        "viewer_right_sneaker": (943, 1372),
    }
    for name, toe in shoe_ends.items():
        ankle = center(pivots[name][0])
        polygon(draw, [
            (ankle[0] - 27, ankle[1] - 18),
            (ankle[0] + 25, ankle[1] - 18),
            (toe[0] + 14, toe[1] - 13),
            (toe[0] + 18, toe[1] + 24),
            (ankle[0] - 34, toe[1] + 24),
        ], FOOTWEAR)

    # Markers are the only non-placeholder detail and always draw last.
    for name in payload["cell_order"]:
        for marker in pivots[name]:
            draw_marker(draw, marker)

    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output)
    detected_cells, detected_markers = _markers(image, "geometric template")
    pivots_path = output.with_suffix(".pivots.json")
    _marker_json(pivots_path, output, detected_cells, detected_markers)
    report = {
        "schema_version": 1,
        "output": str(output.resolve()),
        "source_coordinates": str(source.resolve()),
        "construction": "deterministic flat geometric placeholders; no source artwork copied",
        "canvas": list(CANVAS_SIZE),
        "marker_count": 22,
        "pivots": str(pivots_path.resolve()),
        "colors": {
            "background": "#FF00FF",
            "gutters": "#FFFFFF",
            "body_placeholder": "#BABEC4",
            "leg_garment_placeholder": "#7E858F",
            "footwear_placeholder": "#525862",
            "markers": "#00FFFF",
        },
    }
    output.with_suffix(".build.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coordinates", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(build(args.coordinates, args.output), indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
