#!/usr/bin/env python3
"""Assemble a preserved-proportion atlas for visual and numeric inspection.

This preview is deliberately not a compiler and never resizes a body part.
Each extracted crop is translated so its measured pivot meets the preceding
joint. The resulting image exposes the proportions that the native rig will
receive before any Godot pose code is involved.
"""

from __future__ import annotations

import argparse
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFont

import build_rigged_sheet as builder
from rig_atlas_import import clean_atlas, derived_tip
from rig_coordinate_contract import CELL_PARTS, detect_grid_cells, marker_fields, order_markers


CANVAS_SIZE = (1024, 1536)
PADDING = 96
PART_ORDER = [
    "torso",
    "head",
    "left_upper_arm",
    "left_forearm",
    "right_upper_arm",
    "right_forearm",
    "left_thigh",
    "right_thigh",
    "left_shin",
    "right_shin",
    "left_boot",
    "right_boot",
]
Z_ORDER = {
    "left_upper_arm": -2,
    "left_forearm": -1,
    "torso": 0,
    "head": 1,
    "left_boot": 2,
    "right_boot": 3,
    "left_shin": 4,
    "right_shin": 5,
    "left_thigh": 6,
    "right_thigh": 7,
    "right_upper_arm": 8,
    "right_forearm": 9,
}


@dataclass
class PartGeometry:
    name: str
    cell_name: str
    rect: list[int]
    crop_origin: list[int]
    crop: Image.Image
    mask: np.ndarray
    pivot: list[float]
    tip: list[float]
    page_bbox: list[int]
    axis_length: float
    axis_width: float


def _font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
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


def _key(part: str, field: str, index: int | None = None) -> str:
    return f"{part}.{field}" + (f".{index}" if index is not None else "")


def _without_cyan(image: Image.Image) -> Image.Image:
    array = np.asarray(image.convert("RGB")).copy()
    cyan = (array[:, :, 0] <= 40) & (array[:, :, 1] >= 220) & (array[:, :, 2] >= 220)
    array[cyan] = (255, 0, 255)
    return Image.fromarray(array, mode="RGB")


def _point_map(payload: dict[str, Any]) -> dict[str, list[float]]:
    points: dict[str, list[float]] = {}
    for cell_name, part_name in CELL_PARTS.items():
        entries = order_markers(cell_name, payload["pivots"][cell_name])
        fields = marker_fields(cell_name)
        if len(entries) != len(fields):
            raise ValueError(f"{cell_name}: marker count does not match the contract")
        for entry, (field, index) in zip(entries, fields):
            points[_key(part_name, field, index)] = [
                float(entry["center"][0]),
                float(entry["center"][1]),
            ]

    torso = points
    torso["torso.pivot"] = [
        (torso["torso.shoulders.0"][0] + torso["torso.shoulders.1"][0]) / 2.0,
        (torso["torso.shoulders.0"][1] + torso["torso.shoulders.1"][1]) / 2.0,
    ]
    torso["torso.tip"] = [
        (torso["torso.hips.0"][0] + torso["torso.hips.1"][0]) / 2.0,
        (torso["torso.hips.0"][1] + torso["torso.hips.1"][1]) / 2.0,
    ]
    return points


def _cell_mask(cell_rgba: np.ndarray) -> np.ndarray:
    return builder.foreground(cell_rgba)


def _extract_part_geometry(
    image: Image.Image,
    payload: dict[str, Any],
) -> dict[str, PartGeometry]:
    cells = detect_grid_cells(image)
    if [cell["name"] for cell in cells] != list(CELL_PARTS):
        raise ValueError("Image cells do not match the twelve-part contract")
    points = _point_map(payload)
    _, cell_arrays = clean_atlas(image, cells)
    result: dict[str, PartGeometry] = {}

    for cell in cells:
        cell_name = cell["name"]
        part_name = CELL_PARTS[cell_name]
        rect = [int(value) for value in cell["rect"]]
        cell_rgba = cell_arrays[cell_name]
        mask = _cell_mask(cell_rgba)
        ys, xs = np.where(mask)
        if not len(xs):
            raise ValueError(f"{part_name}: no visible artwork after background removal")
        local_bbox = [int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)]
        rgba = cell_rgba.copy()
        rgba[:, :, 3] = (mask.astype(np.uint8) * 255)
        rgba[~mask, :3] = 0
        crop = Image.fromarray(rgba, mode="RGBA").crop(tuple(local_bbox))
        crop_origin = [rect[0] + local_bbox[0], rect[1] + local_bbox[1]]

        pivot = list(points[_key(part_name, "pivot")])
        tip_key = _key(part_name, "tip")
        if tip_key in points:
            tip = list(points[tip_key])
        else:
            tip = derived_tip(
                part_name,
                pivot,
                rect,
                cell_rgba,
                cell_mask=mask,
            )
            points[tip_key] = tip

        local_pivot = np.subtract(pivot, rect[:2]).astype(float)
        local_tip = np.subtract(tip, rect[:2]).astype(float)
        axis = np.subtract(local_tip, local_pivot)
        axis_length = float(np.linalg.norm(axis))
        if axis_length <= 0:
            raise ValueError(f"{part_name}: zero source axis")
        axis_width = float(builder.axis_width(mask, local_pivot, local_tip))
        result[part_name] = PartGeometry(
            name=part_name,
            cell_name=cell_name,
            rect=rect,
            crop_origin=crop_origin,
            crop=crop,
            mask=mask,
            pivot=pivot,
            tip=tip,
            page_bbox=[
                rect[0] + local_bbox[0],
                rect[1] + local_bbox[1],
                rect[0] + local_bbox[2],
                rect[1] + local_bbox[3],
            ],
            axis_length=axis_length,
            axis_width=axis_width,
        )
    return result


def _assembly_targets(parts: dict[str, PartGeometry], points: dict[str, list[float]]) -> dict[str, dict[str, list[float]]]:
    torso = parts["torso"]
    root = np.array([0.0, 0.0], dtype=float)
    offset = root - np.array(torso.pivot, dtype=float)

    def source(point: list[float]) -> np.ndarray:
        return np.array(point, dtype=float) + offset

    targets: dict[str, dict[str, list[float]]] = {
        "torso": {
            "pivot": root.tolist(),
            "tip": source(torso.tip).tolist(),
        }
    }
    for field, index in [
        ("neck", None),
        ("shoulders", 0),
        ("shoulders", 1),
        ("hips", 0),
        ("hips", 1),
    ]:
        key = _key("torso", field, index)
        targets["torso"][key.split(".", 1)[1]] = source(points[key]).tolist()

    def put_chain(part_name: str, pivot_target: np.ndarray) -> None:
        part = parts[part_name]
        axis = np.subtract(part.tip, part.pivot)
        tip_target = pivot_target + axis
        targets[part_name] = {
            "pivot": pivot_target.tolist(),
            "tip": tip_target.tolist(),
        }

    put_chain("head", np.array(targets["torso"]["neck"], dtype=float))
    for side in ("left", "right"):
        shoulder = np.array(targets["torso"][f"shoulders.{0 if side == 'left' else 1}"], dtype=float)
        put_chain(f"{side}_upper_arm", shoulder)
        put_chain(f"{side}_forearm", np.array(targets[f"{side}_upper_arm"]["tip"], dtype=float))
        hip = np.array(targets["torso"][f"hips.{0 if side == 'left' else 1}"], dtype=float)
        put_chain(f"{side}_thigh", hip)
        put_chain(f"{side}_shin", np.array(targets[f"{side}_thigh"]["tip"], dtype=float))
        put_chain(f"{side}_boot", np.array(targets[f"{side}_shin"]["tip"], dtype=float))
    return targets


def _placement(part: PartGeometry, target_pivot: list[float], shift: np.ndarray) -> dict[str, Any]:
    local_pivot = np.subtract(part.pivot, part.crop_origin)
    top_left = np.array(target_pivot, dtype=float) - local_pivot + shift
    return {
        "top_left": [float(top_left[0]), float(top_left[1])],
        "target_pivot": [float(target_pivot[0]), float(target_pivot[1])],
        "crop_origin": list(part.crop_origin),
        "crop_size": [part.crop.width, part.crop.height],
    }


def _bounds(parts: dict[str, PartGeometry], targets: dict[str, dict[str, list[float]]]) -> tuple[np.ndarray, np.ndarray, dict[str, dict[str, Any]]]:
    placements: dict[str, dict[str, Any]] = {}
    minimum = np.array([math.inf, math.inf], dtype=float)
    maximum = np.array([-math.inf, -math.inf], dtype=float)
    zero = np.array([0.0, 0.0], dtype=float)
    for name, part in parts.items():
        placement = _placement(part, targets[name]["pivot"], zero)
        top_left = np.array(placement["top_left"], dtype=float)
        bottom_right = top_left + np.array([part.crop.width, part.crop.height], dtype=float)
        minimum = np.minimum(minimum, top_left)
        maximum = np.maximum(maximum, bottom_right)
        placements[name] = placement
    return minimum, maximum, placements


def _paste(destination: Image.Image, source: Image.Image, top_left: list[float]) -> None:
    x = int(round(top_left[0]))
    y = int(round(top_left[1]))
    destination.alpha_composite(source, (x, y))


def _metric(part: PartGeometry, torso: PartGeometry, reference: PartGeometry | None) -> dict[str, Any]:
    value: dict[str, Any] = {
        "cell": part.cell_name,
        "measurement_scope": "full foreground in the assigned cell",
        "page_bbox": part.page_bbox,
        "foreground_size_px": [part.page_bbox[2] - part.page_bbox[0], part.page_bbox[3] - part.page_bbox[1]],
        "pivot": part.pivot,
        "tip": part.tip,
        "axis_length_px": round(part.axis_length, 3),
        "axis_width_px": round(part.axis_width, 3),
        "axis_length_vs_torso": round(part.axis_length / torso.axis_length, 4),
        "axis_width_vs_torso": round(part.axis_width / torso.axis_width, 4),
    }
    if part.name == "torso":
        value["measurement_note"] = "Full foreground breadth includes owned wings or other torso accessories."
    if reference is not None and reference.axis_length > 0 and reference.axis_width > 0:
        value["axis_length_vs_template"] = round(part.axis_length / reference.axis_length, 4)
        value["axis_width_vs_template"] = round(part.axis_width / reference.axis_width, 4)
        value["foreground_width_vs_template"] = round(
            (part.page_bbox[2] - part.page_bbox[0]) / max(1, reference.page_bbox[2] - reference.page_bbox[0]), 4
        )
        value["foreground_height_vs_template"] = round(
            (part.page_bbox[3] - part.page_bbox[1]) / max(1, reference.page_bbox[3] - reference.page_bbox[1]), 4
        )
    return value


def _warnings(metrics: dict[str, dict[str, Any]]) -> list[str]:
    warnings: list[str] = []
    for name, item in metrics.items():
        ratio = item.get("axis_length_vs_template")
        if ratio is not None and (ratio < 0.8 or ratio > 1.2):
            warnings.append(f"{name}: source axis is {ratio:.2f}x the geometric template")
        width_ratio = item.get("axis_width_vs_template")
        if name != "torso" and width_ratio is not None and (width_ratio < 0.8 or width_ratio > 1.2):
            warnings.append(f"{name}: source breadth is {width_ratio:.2f}x the geometric template")
    return warnings


def build_preview(
    marked_path: Path,
    marker_free_path: Path,
    pivots_path: Path,
    output_dir: Path,
    reference_template: Path | None = None,
) -> dict[str, Any]:
    marked = Image.open(marked_path).convert("RGB")
    marker_free = Image.open(marker_free_path).convert("RGB")
    if marked.size != CANVAS_SIZE or marker_free.size != CANVAS_SIZE:
        raise ValueError("Assembly preview requires normalized 1024x1536 marked and marker-free images")
    payload = json.loads(pivots_path.read_text(encoding="utf-8"))
    parts = _extract_part_geometry(marker_free, payload)
    points = _point_map(payload)
    targets = _assembly_targets(parts, points)
    minimum, maximum, _ = _bounds(parts, targets)
    shift = np.array([PADDING, PADDING], dtype=float) - minimum
    width = int(math.ceil(maximum[0] - minimum[0] + PADDING * 2))
    height = int(math.ceil(maximum[1] - minimum[1] + PADDING * 2))
    if width <= 0 or height <= 0:
        raise ValueError("Assembly preview has no visible bounds")

    output_dir.mkdir(parents=True, exist_ok=True)
    assembled = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    placements: dict[str, dict[str, Any]] = {}
    for name in sorted(parts, key=lambda item: Z_ORDER[item]):
        placement = _placement(parts[name], targets[name]["pivot"], shift)
        placements[name] = placement
        _paste(assembled, parts[name].crop, placement["top_left"])

    assembled_path = output_dir / "assembly-preview.png"
    assembled.save(assembled_path)

    debug = Image.new("RGBA", (width, height), (25, 28, 34, 255))
    debug.alpha_composite(assembled)
    draw = ImageDraw.Draw(debug)
    label_font = _font(18)
    point_font = _font(14)
    for name in sorted(parts, key=lambda item: Z_ORDER[item]):
        target_pivot = np.array(targets[name]["pivot"], dtype=float) + shift
        target_tip = np.array(targets[name]["tip"], dtype=float) + shift
        draw.line(
            (round(target_pivot[0]), round(target_pivot[1]), round(target_tip[0]), round(target_tip[1])),
            fill=(255, 220, 50, 230),
            width=2,
        )
        for point, color in ((target_pivot, (0, 255, 255, 255)), (target_tip, (255, 100, 80, 255))):
            x, y = round(float(point[0])), round(float(point[1]))
            draw.ellipse((x - 7, y - 7, x + 7, y + 7), fill=color, outline=(0, 0, 0, 255), width=2)
        label = name.replace("_", " ")
        bbox = parts[name].page_bbox
        label_x = round(float(bbox[0] + shift[0]))
        label_y = round(float(bbox[1] + shift[1]))
        draw.text((label_x, label_y - 24), label, fill=(255, 255, 255, 255), font=label_font)
        draw.text(
            (round(float(target_pivot[0])) + 10, round(float(target_pivot[1])) + 8),
            f"{parts[name].axis_length:.0f}px",
            fill=(255, 220, 50, 255),
            font=point_font,
        )
    debug_path = output_dir / "assembly-preview-debug.png"
    debug.convert("RGB").save(debug_path)

    reference_parts: dict[str, PartGeometry] | None = None
    if reference_template is not None and reference_template.is_file():
        reference_image = _without_cyan(Image.open(reference_template).convert("RGB"))
        reference_pivots_path = reference_template.with_suffix(".pivots.json")
        if reference_pivots_path.is_file():
            reference_payload = json.loads(reference_pivots_path.read_text(encoding="utf-8"))
            reference_parts = _extract_part_geometry(reference_image, reference_payload)

    torso = parts["torso"]
    metrics = {
        name: _metric(part, torso, reference_parts.get(name) if reference_parts else None)
        for name, part in parts.items()
    }
    torso_axis = np.subtract(torso.tip, torso.pivot)
    torso_angle = math.degrees(math.atan2(float(torso_axis[1]), float(torso_axis[0])))
    report: dict[str, Any] = {
        "schema_version": 1,
        "mode": "source_proportions_no_resizing",
        "marked_image": str(marked_path.resolve()),
        "marker_free_image": str(marker_free_path.resolve()),
        "pivots": str(pivots_path.resolve()),
        "reference_template": str(reference_template.resolve()) if reference_template else None,
        "canvas": [width, height],
        "padding_px": PADDING,
        "torso_axis_angle_degrees_image_space": round(torso_angle, 3),
        "torso_axis_length_px": round(torso.axis_length, 3),
        "placements": placements,
        "metrics": metrics,
        "warnings": _warnings(metrics),
        "outputs": {
            "assembled": str(assembled_path.resolve()),
            "debug": str(debug_path.resolve()),
        },
        "interpretation": {
            "head_size": "Compare head_and_neck foreground and axis ratios against torso and the geometric template.",
            "torso_posture": "The torso axis is preserved from the accepted source; no posture correction is applied.",
            "scaling": "No part scale, width, height, rotation, or crop was changed; only joint-aligned translation was applied.",
        },
    }
    report_path = output_dir / "assembly-preview.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    report["outputs"]["report"] = str(report_path.resolve())
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--marked", type=Path, required=True)
    parser.add_argument("--marker-free", type=Path, required=True)
    parser.add_argument("--pivots", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--reference-template", type=Path)
    args = parser.parse_args()
    report = build_preview(
        args.marked,
        args.marker_free,
        args.pivots,
        args.output_dir,
        args.reference_template,
    )
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
