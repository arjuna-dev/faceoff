#!/usr/bin/env python3
"""Repack a marked 12-part template vertically without resampling any artwork."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
from armk_atlas_test import assign_marker_cells, detect_markers
from build_rigged_sheet import foreground
from character_generation_workflow import _marker_json
from rig_atlas_import import clean_atlas
from rig_coordinate_contract import detect_grid_cells


TARGET_ROWS = [(10, 525), (530, 830), (835, 1155), (1160, 1526)]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    pivots_path = args.output.with_suffix(".pivots.json")
    report_path = args.output.with_suffix(".repack.json")
    for path in (args.output, pivots_path, report_path):
        if path.exists():
            raise SystemExit(f"Refusing to overwrite {path}")

    source_image = Image.open(args.source).convert("RGB")
    if source_image.size != (1024, 1536):
        raise SystemExit("Source must be 1024x1536")
    source_rgb = np.asarray(source_image)
    source_cells = detect_grid_cells(source_image)
    _, cell_arrays = clean_atlas(source_image, source_cells)

    output = np.empty((1536, 1024, 3), dtype=np.uint8)
    output[:] = (255, 0, 255)
    output[:10] = 255
    output[1526:] = 255
    for start, end in ((525, 530), (830, 835), (1155, 1160)):
        output[start:end] = 255

    target_cells = []
    translations = {}
    for row_index, (target_y0, target_y1) in enumerate(TARGET_ROWS):
        row = [cell for cell in source_cells if cell["row"] == row_index]
        row.sort(key=lambda cell: cell["column"])
        output[target_y0:target_y1, :row[0]["rect"][0]] = 255
        output[target_y0:target_y1, row[-1]["rect"][2]:] = 255
        for left, right in zip(row, row[1:]):
            output[target_y0:target_y1, left["rect"][2]:right["rect"][0]] = 255
        for cell in row:
            x0, source_y0, x1, source_y1 = cell["rect"]
            rgba = cell_arrays[cell["name"]]
            mask = foreground(rgba)
            ys, xs = np.where(mask)
            if not len(xs):
                raise SystemExit(f"{cell['name']}: empty source artwork")
            object_y0, object_y1 = int(ys.min()), int(ys.max() + 1)
            available = target_y1 - target_y0
            object_height = object_y1 - object_y0
            if object_height + 2 > available:
                raise SystemExit(f"{cell['name']}: target row is too short")
            destination_object_y0 = target_y0 + (available - object_height) // 2
            dy = destination_object_y0 - (source_y0 + object_y0)
            destination_y = source_y0 + ys + dy
            destination_x = x0 + xs
            output[destination_y, destination_x] = source_rgb[source_y0 + ys, x0 + xs]
            translations[cell["name"]] = [0, int(dy)]
            target_cells.append({**cell, "rect": [x0, target_y0, x1, target_y1]})

    args.output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(output).save(args.output)
    result_image = Image.open(args.output).convert("RGB")
    detected_cells = detect_grid_cells(result_image)
    detected_markers = assign_marker_cells(detect_markers(result_image), detected_cells)
    source_markers = assign_marker_cells(detect_markers(source_image), source_cells)
    if sum(map(len, detected_markers.values())) != 22:
        raise SystemExit("Repacked template does not contain exactly 22 markers")
    maximum_error = 0.0
    for name, entries in source_markers.items():
        expected = sorted([[item["center"][0], item["center"][1] + translations[name][1]] for item in entries])
        actual = sorted([item["center"] for item in detected_markers[name]])
        if len(expected) != len(actual):
            raise SystemExit(f"{name}: marker count changed")
        for wanted, found in zip(expected, actual):
            maximum_error = max(maximum_error, float(np.linalg.norm(np.subtract(wanted, found))))
    if maximum_error > 0.01:
        raise SystemExit(f"Marker translation audit failed: {maximum_error}")
    _marker_json(pivots_path, args.output, detected_cells, detected_markers)
    report = {
        "schema_version": 1,
        "source": str(args.source.resolve()),
        "source_sha256": hashlib.sha256(args.source.read_bytes()).hexdigest(),
        "output": str(args.output.resolve()),
        "canvas": [1024, 1536],
        "operation": "integer translation per cell; no resizing or resampling",
        "target_rows": TARGET_ROWS,
        "translations": translations,
        "marker_count": 22,
        "maximum_marker_translation_error_px": maximum_error,
    }
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
