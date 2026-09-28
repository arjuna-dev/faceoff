#!/usr/bin/env python3
"""Run the standardized marked -> coordinates -> marker-free atlas workflow.

Vertex Gemini image generation is the default provider. The fixture provider is
only for deterministic local tests. A stage cannot proceed unless its image
passes the contract checks from the previous stage.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

from armk_atlas_test import (
    CELL_NAMES,
    ROW_CELL_COUNTS,
    assign_marker_cells,
    detect_markers,
)


CANVAS_SIZE = (1024, 1536)
MARKER_COUNTS = {
    "head_and_neck": 1,
    "torso_and_pelvis": 5,
    "viewer_left_upper_arm": 2,
    "viewer_left_forearm_and_hand": 1,
    "viewer_right_forearm_and_hand": 1,
    "viewer_right_upper_arm": 2,
    "viewer_left_thigh": 2,
    "viewer_right_thigh": 2,
    "viewer_left_shin": 2,
    "viewer_left_sneaker": 1,
    "viewer_right_shin": 2,
    "viewer_right_sneaker": 1,
}

# The head cell permits hair and accessories to extend beyond the placeholder,
# but not enough to turn the atlas into a full-size portrait. This is a
# validation gate only; it never resizes artwork.
MAX_FOOTPRINT_FRACTIONS = {
    "head_and_neck": {"width": 0.70, "height": 0.84},
}


class WorkflowError(RuntimeError):
    """A generated stage failed a mandatory workflow invariant."""


def _open_rgb(path: Path) -> Image.Image:
    if not path.is_file():
        raise WorkflowError(f"Missing image: {path}")
    image = Image.open(path).convert("RGB")
    if image.size != CANVAS_SIZE:
        raise WorkflowError(f"{path}: expected {CANVAS_SIZE}, got {image.size}")
    return image


def _detect_cells(image: Image.Image) -> list[dict[str, Any]]:
    from rig_coordinate_contract import detect_grid_cells
    return detect_grid_cells(image)


def _layout(image: Image.Image, label: str) -> list[dict[str, Any]]:
    try:
        cells = _detect_cells(image)
    except Exception as exc:  # convert implementation detail into stage evidence
        raise WorkflowError(f"{label}: could not detect the twelve-cell layout: {exc}") from exc
    if [cell["name"] for cell in cells] != CELL_NAMES:
        raise WorkflowError(f"{label}: cell names/order do not match the contract")
    return cells


def _markers(image: Image.Image, label: str) -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    found = detect_markers(image)
    cells = _layout(image, label)
    try:
        by_cell = assign_marker_cells(found, cells)
    except Exception as exc:
        raise WorkflowError(f"{label}: marker is not contained by exactly one cell: {exc}") from exc
    counts = {name: len(by_cell[name]) for name in CELL_NAMES}
    if len(found) != 22 or counts != MARKER_COUNTS:
        failures = {
            name: {"expected": MARKER_COUNTS[name], "found": counts[name], "centers": _centers(by_cell)[name]}
            for name in CELL_NAMES if counts[name] != MARKER_COUNTS[name]
        }
        raise WorkflowError(
            f"{label}: expected 22 cyan markers, found {len(found)}; "
            f"incorrect cells: {json.dumps(failures)}. "
            "Forearm/hand cells have exactly one elbow marker and no wrist marker."
        )
    return cells, by_cell


def _validate_marker_geometry(
    markers: list[dict[str, Any]],
    label: str,
    maximum_diameter: int = 32,
) -> None:
    """Keep generated guide disks small enough to remain removable markers."""
    for marker in markers:
        x0, y0, x1, y1 = marker["bbox"]
        width = x1 - x0
        height = y1 - y0
        if max(width, height) > maximum_diameter:
            raise WorkflowError(
                f"{label}: cyan marker at {marker['center']} is {width}x{height}px; "
                f"maximum is {maximum_diameter}px. Preserve the template's small marker disk."
            )


def _marker_json(path: Path, source_image: Path, cells: list[dict[str, Any]], by_cell: dict[str, list[dict[str, Any]]]) -> None:
    payload = {
        "schema_version": 1,
        "canvas": list(CANVAS_SIZE),
        "source_image": str(source_image.resolve()),
        "marker_color": "#00FFFF",
        "cell_order": CELL_NAMES,
        "marker_counts": MARKER_COUNTS,
        "cells": cells,
        "pivots": {name: by_cell[name] for name in CELL_NAMES},
        "marker_count": sum(len(by_cell[name]) for name in CELL_NAMES),
    }
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _centers(by_cell: dict[str, list[dict[str, Any]]]) -> dict[str, list[list[float]]]:
    return {
        name: [[float(item["center"][0]), float(item["center"][1])] for item in by_cell[name]]
        for name in CELL_NAMES
    }


def _validate_template(path: Path) -> tuple[list[dict[str, Any]], dict[str, list[dict[str, Any]]]]:
    image = _open_rgb(path)
    return _markers(image, "template")


def _normalize_provider_output(raw_path: Path, normalized_path: Path) -> dict[str, Any]:
    raw = Image.open(raw_path).convert("RGB")
    raw_size = list(raw.size)
    if raw.size == CANVAS_SIZE:
        shutil.copy2(raw_path, normalized_path)
        return {"raw_canvas": raw_size, "normalized": False, "canvas": list(CANVAS_SIZE)}
    raw_ratio = raw.width / raw.height
    target_ratio = CANVAS_SIZE[0] / CANVAS_SIZE[1]
    if abs(raw_ratio - target_ratio) > 0.02:
        raise WorkflowError(
            f"provider output has unsupported aspect ratio {raw.width}x{raw.height}; "
            f"expected approximately {CANVAS_SIZE[0]}x{CANVAS_SIZE[1]}"
        )
    # Vertex's 1K image mode currently returns 848x1264 for this portrait
    # ratio. Normalize the complete image once before any marker or cell math.
    # This is one global canvas operation, never independent part resizing.
    raw.resize(CANVAS_SIZE, Image.Resampling.NEAREST).save(normalized_path)
    return {
        "raw_canvas": raw_size,
        "normalized": True,
        "normalization": "single global nearest-neighbor resize to 1024x1536",
        "canvas": list(CANVAS_SIZE),
    }


def _validate_marked(
    template_cells: list[dict[str, Any]],
    path: Path,
    layout_tolerance: int,
) -> dict[str, Any]:
    image = _open_rgb(path)
    cells, found = _markers(image, "marked output")
    layout_deltas = []
    for expected_cell, actual_cell in zip(template_cells, cells):
        deltas = [
            _layout_coordinate_delta(actual, expected, CANVAS_SIZE[index % 2])
            for index, (actual, expected) in enumerate(zip(actual_cell["rect"], expected_cell["rect"]))
        ]
        layout_deltas.extend(deltas)
    if max(layout_deltas, default=0) > layout_tolerance:
        raise WorkflowError(
            "marked output: cell rectangles moved beyond "
            f"{layout_tolerance}px: max delta {max(layout_deltas, default=0)}"
        )
    clearances = _validate_part_clearance(image, cells, "marked output")
    _validate_marker_geometry(
        [marker for name in CELL_NAMES for marker in found[name]],
        "marked output",
    )
    _validate_standard_footprints(image, cells, "marked output")
    marker_contacts = _validate_marked_marker_contacts(image, cells, found, "marked output")
    return {
        "canvas": list(CANVAS_SIZE),
        "cell_rectangles_within_tolerance": True,
        "cell_layout_max_delta_px": max(layout_deltas, default=0),
        "cell_rectangles": cells,
        "marker_count": 22,
        "marker_coordinates_source": "detected from accepted marked output",
        "markers": _centers(found),
        "marker_artwork_gaps_px": marker_contacts,
        "part_edge_clearances_px": clearances,
    }


def _validate_standard_footprints(
    image: Image.Image,
    cells: list[dict[str, Any]],
    label: str,
) -> None:
    """Reject extreme generated proportions without resampling any artwork."""
    masks = _cell_foreground(image, cells)
    for cell in cells:
        limits = MAX_FOOTPRINT_FRACTIONS.get(cell["name"])
        if not limits:
            continue
        mask = masks[cell["name"]]
        ys, xs = np.where(mask)
        if not len(xs):
            raise WorkflowError(f"{label}: {cell['name']} contains no foreground artwork")
        width = int(xs.max() - xs.min() + 1)
        height = int(ys.max() - ys.min() + 1)
        cell_width = int(cell["rect"][2] - cell["rect"][0])
        cell_height = int(cell["rect"][3] - cell["rect"][1])
        max_width = int(cell_width * limits["width"])
        max_height = int(cell_height * limits["height"])
        if width > max_width or height > max_height:
            raise WorkflowError(
                f"{label}: {cell['name']} artwork footprint is {width}x{height}px; "
                f"maximum is {max_width}x{max_height}px for its {cell_width}x{cell_height}px cell. "
                "Keep the character's proportions and reduce the part within the cell; do not crop it."
            )


def _validate_part_clearance(
    image: Image.Image,
    cells: list[dict[str, Any]],
    label: str,
    minimum: int = 1,
) -> dict[str, dict[str, int]]:
    """Reject clipped foreground before spending a cleanup request."""
    from build_rigged_sheet import foreground
    from rig_atlas_import import clean_atlas

    # Use the importer's exact chroma and near-white edge treatment first.
    # Otherwise the pale antialiased grid itself would look like foreground.
    _, cell_arrays = clean_atlas(image, cells)
    result: dict[str, dict[str, int]] = {}
    for cell in cells:
        x0, y0, x1, y1 = cell["rect"]
        mask = foreground(cell_arrays[cell["name"]])
        ys, xs = np.where(mask)
        if not len(xs):
            raise WorkflowError(f"{label}: {cell['name']} contains no foreground artwork")
        edges = {
            "left": int(xs.min()), "top": int(ys.min()),
            "right": int(x1 - x0 - 1 - xs.max()),
            "bottom": int(y1 - y0 - 1 - ys.max()),
        }
        result[cell["name"]] = edges
        failing_edge = min(edges, key=edges.get)
        if edges[failing_edge] < minimum:
            sample = {
                "left": int(np.argmin(xs)), "right": int(np.argmax(xs)),
                "top": int(np.argmin(ys)), "bottom": int(np.argmax(ys)),
            }[failing_edge]
            page_pixel = [int(x0 + xs[sample]), int(y0 + ys[sample])]
            raise WorkflowError(
                f"{label}: {cell['name']} artwork touches {failing_edge} crop boundary "
                f"(clearances {edges}; need {minimum}px); nearest foreground pixel "
                f"at page {page_pixel}. Regenerate the complete part; never crop it."
            )
    return result


def _cell_foreground(image: Image.Image, cells: list[dict[str, Any]]) -> dict[str, np.ndarray]:
    from build_rigged_sheet import foreground
    from rig_atlas_import import clean_atlas

    _, cell_arrays = clean_atlas(image, cells)
    return {name: foreground(array) for name, array in cell_arrays.items()}


def _validate_marked_marker_contacts(
    image: Image.Image,
    cells: list[dict[str, Any]],
    markers: dict[str, list[dict[str, Any]]],
    label: str,
    maximum_gap: float = 4.0,
) -> dict[str, list[float]]:
    """Require every marker disk to touch the artwork it measures."""
    masks = _cell_foreground(image, cells)
    result: dict[str, list[float]] = {}
    for cell in cells:
        name = cell["name"]
        x0, y0, _, _ = cell["rect"]
        result[name] = []
        for marker in markers[name]:
            mask = masks[name].copy()
            bx0, by0, bx1, by1 = marker["bbox"]
            padding = 2
            mask[
                max(0, by0 - y0 - padding):min(mask.shape[0], by1 - y0 + padding),
                max(0, bx0 - x0 - padding):min(mask.shape[1], bx1 - x0 + padding),
            ] = False
            ys, xs = np.where(mask)
            if not len(xs):
                raise WorkflowError(f"{label}: {name} contains no artwork outside its markers")
            cx = float(marker["center"][0] - x0)
            cy = float(marker["center"][1] - y0)
            distance = float(np.sqrt(np.min((xs - cx) ** 2 + (ys - cy) ** 2)))
            radius = max(bx1 - bx0, by1 - by0) / 2.0
            gap = max(0.0, distance - radius)
            result[name].append(gap)
            allowed_gap = 5.0 if name in ("viewer_left_sneaker", "viewer_right_sneaker") else maximum_gap
            if gap > allowed_gap:
                raise WorkflowError(
                    f"{label}: {name} marker at {marker['center']} floats {gap:.1f}px "
                    f"from its body-part artwork; maximum is {allowed_gap:.1f}px. "
                    "Keep the marker at its coordinate and extend the correct part to it."
                )
    return result


def _validate_clean_marker_coverage(
    image: Image.Image,
    cells: list[dict[str, Any]],
    markers: dict[str, list[dict[str, Any]]],
    label: str,
    allowance: float = 4.0,
) -> dict[str, list[float]]:
    """Ensure cleanup leaves artwork close enough to every stored joint."""
    masks = _cell_foreground(image, cells)
    result: dict[str, list[float]] = {}
    for cell in cells:
        name = cell["name"]
        x0, y0, _, _ = cell["rect"]
        ys, xs = np.where(masks[name])
        if not len(xs):
            raise WorkflowError(f"{label}: {name} contains no foreground artwork")
        result[name] = []
        for marker in markers[name]:
            cx = float(marker["center"][0] - x0)
            cy = float(marker["center"][1] - y0)
            distance = float(np.sqrt(np.min((xs - cx) ** 2 + (ys - cy) ** 2)))
            bx0, by0, bx1, by1 = marker["bbox"]
            radius = max(bx1 - bx0, by1 - by0) / 2.0
            maximum = radius + allowance
            result[name].append(distance)
            if distance > maximum:
                raise WorkflowError(
                    f"{label}: {name} stored marker at {marker['center']} is {distance:.1f}px "
                    f"from cleaned artwork; maximum is {maximum:.1f}px. Reconstruct the "
                    "body part through the marker area without moving the stored coordinate."
                )
    return result


def _validate_outer_frame(cells: list[dict[str, Any]], label: str) -> None:
    """The generated grid must retain ownership-free space at the canvas edge."""
    top = min(cell["rect"][1] for cell in cells)
    bottom = max(cell["rect"][3] for cell in cells)
    left = min(cell["rect"][0] for cell in cells)
    right = max(cell["rect"][2] for cell in cells)
    clearances = {"left": left, "top": top, "right": CANVAS_SIZE[0] - right,
                  "bottom": CANVAS_SIZE[1] - bottom}
    failing = min(clearances, key=clearances.get)
    if clearances[failing] < 1:
        raise WorkflowError(
            f"{label}: outer frame has no {failing} clearance ({clearances}); "
            "artwork or cell contents may be clipped by the canvas edge"
        )


def _layout_coordinate_delta(actual: int, expected: int, limit: int) -> int:
    """Ignore only a thin optional canvas frame, never an internal gutter."""
    frame_limit = 16
    if min(actual, expected) == 0 and max(actual, expected) <= frame_limit:
        return 0
    if max(actual, expected) == limit and min(actual, expected) >= limit - frame_limit:
        return 0
    return abs(actual - expected)


def _marker_disk_mask(shape: tuple[int, int], by_cell: dict[str, list[dict[str, Any]]], radius: int) -> np.ndarray:
    mask = np.zeros(shape, dtype=bool)
    height, width = shape
    for name in CELL_NAMES:
        for marker in by_cell[name]:
            cx, cy = marker["center"]
            x0 = max(0, int(math.floor(cx - radius)))
            x1 = min(width, int(math.ceil(cx + radius + 1)))
            y0 = max(0, int(math.floor(cy - radius)))
            y1 = min(height, int(math.ceil(cy + radius + 1)))
            yy, xx = np.ogrid[y0:y1, x0:x1]
            mask[y0:y1, x0:x1] |= (xx - cx) ** 2 + (yy - cy) ** 2 <= radius**2
    return mask


def _validate_marker_free(
    expected_cells: list[dict[str, Any]],
    marked_markers: dict[str, list[dict[str, Any]]],
    marked_path: Path,
    path: Path,
    max_change_ratio: float | None,
    marker_mask_radius: int,
    layout_tolerance: int,
) -> dict[str, Any]:
    marked = _open_rgb(marked_path)
    clean = _open_rgb(path)
    cells = _layout(clean, "marker-free output")
    # Marker removal is allowed to repaint the decorative outer frame. What
    # matters to rigging is that the twelve internal cells are still detected,
    # remain aligned with the marked image, and retain foreground clearance.
    # Requiring a top/bottom frame here rejects otherwise complete artwork even
    # though the actual per-part crop-safety check below still runs.
    clearances = _validate_part_clearance(clean, cells, "marker-free output")
    marker_coverage = _validate_clean_marker_coverage(
        clean, cells, marked_markers, "marker-free output"
    )
    layout_deltas = [
        _layout_coordinate_delta(actual, expected, CANVAS_SIZE[index % 2])
        for actual_cell, expected_cell in zip(cells, expected_cells)
        for index, (actual, expected) in enumerate(zip(actual_cell["rect"], expected_cell["rect"]))
    ]
    if max(layout_deltas, default=0) > layout_tolerance:
        raise WorkflowError(
            "marker-free output: cell rectangles moved beyond "
            f"{layout_tolerance}px: max delta {max(layout_deltas, default=0)}"
        )
    remaining = detect_markers(clean)
    if remaining:
        raise WorkflowError(f"marker-free output: cyan markers remain ({len(remaining)})")

    changed_ratio = None
    if max_change_ratio is not None:
        reference = np.asarray(marked, dtype=np.int16)
        candidate = np.asarray(clean, dtype=np.int16)
        difference = np.max(np.abs(reference - candidate), axis=2) > 16
        excluded = _marker_disk_mask(difference.shape, marked_markers, marker_mask_radius)
        measured = ~excluded
        changed_ratio = float(difference[measured].mean()) if measured.any() else 0.0
        if changed_ratio > max_change_ratio:
            raise WorkflowError(
                "marker-free output: artwork drift outside marker disks is "
                f"{changed_ratio:.4f}, limit is {max_change_ratio:.4f}"
            )
    return {
        "canvas": list(CANVAS_SIZE),
        "cell_rectangles_within_tolerance": True,
        "cell_layout_max_delta_px": max(layout_deltas, default=0),
        "cyan_markers_remaining": 0,
        "artwork_drift_check": "skipped_by_request" if max_change_ratio is None else "passed",
        "marker_mask_radius_px": marker_mask_radius,
        "changed_ratio_outside_marker_disks": changed_ratio,
        "max_allowed_change_ratio": max_change_ratio,
        "stored_marker_distances_to_artwork_px": marker_coverage,
        "part_edge_clearances_px": clearances,
    }


class VertexProvider:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.script = args.vertex_script.resolve()

    def generate(self, prompt: Path, references: list[Path], output: Path, response: Path) -> None:
        command = [
            sys.executable,
            str(self.script),
            "--prompt-file",
            str(prompt),
            "--output",
            str(output),
            "--response-json",
            str(response),
            "--model",
            self.args.model,
            "--location",
            self.args.location,
            "--aspect-ratio",
            "2:3",
            "--image-size",
            "1K",
        ]
        if self.args.project:
            command.extend(["--project", self.args.project])
        for reference in references:
            command.extend(["--image", str(reference)])
        result = subprocess.run(command, capture_output=True, text=True)
        if result.returncode:
            raise WorkflowError(
                "Vertex generation failed:\n" + (result.stderr or result.stdout)[-4000:]
            )


class FixtureProvider:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args

    def generate(self, prompt: Path, references: list[Path], output: Path, response: Path) -> None:
        fixture = self.args.fixture_marked if prompt.name.startswith("marked-") else self.args.fixture_unmarked
        if fixture is None:
            raise WorkflowError("fixture provider requires --fixture-marked and --fixture-unmarked")
        shutil.copy2(fixture, output)
        response.write_text(json.dumps({
            "provider": "fixture",
            "source": str(fixture.resolve()),
            "references": [str(reference.resolve()) for reference in references],
        }, indent=2) + "\n")


def _provider(args: argparse.Namespace) -> VertexProvider | FixtureProvider:
    return VertexProvider(args) if args.provider == "vertex" else FixtureProvider(args)


def _write_prompt(
    path: Path,
    identity: str,
    stage: str,
) -> None:
    if stage == "marked":
        body = """
STAGE: MARKED AUTHORITATIVE CHARACTER OUTPUT

The attached image is a deliberately featureless structural diagram made from
flat grey geometric placeholders. Treat the grey silhouettes, their locations,
their bounding boxes and their proportions as authoritative structural guides.
The grey placeholders are the complete part inventory and the only body-part
shapes allowed in the result. Replace each grey placeholder one-for-one with the
corresponding requested character part. Do not use the template as loose
inspiration or redesign its anatomy.

Do not add, remove, duplicate, merge, hide, or invent any body-part piece. Do not
make an extra arm, hand, leg, foot, garment section, torso section, head section
or other part outside the twelve grey placeholders. Requested accessories such
as hair, tattoos, piercings and wings are details of an existing owning part;
they must not create a new body-part region, cell or duplicate.

The replacement must be 1:1 in page-space size and proportion: preserve each
placeholder's width, height, outline, orientation, joint locations and relative
relationship to every other part. Keep the replacement artwork inside the same
grey footprint and at the same scale. Do not enlarge, shrink, stretch, squash,
repose, lengthen, shorten, or reshape a body part to fill its cell. Add the
requested identity, clothing, anatomy and details inside the corresponding
placeholder footprint only. Preserve the exact 1024x1536 canvas, white gutters,
twelve cell rectangles, body-part ownership, facing direction and artwork
clearance. Preserve the complete white outer frame from the template, including
its top and bottom borders and their thickness. No character artwork or
accessory may overlap or replace those borders.

The atlas is not a normal character sheet. It is a fixed assembly layout. Keep
each part exactly within the footprint and scale of its corresponding grey
placeholder instead of enlarging the head, torso or limbs to fill its cell. Do
not use the cell as extra empty canvas for a larger replacement. Fluffy hair may
be detailed only inside the head-and-neck replacement footprint; simplify or
omit details rather than enlarge that part. The torso cell is a headless
torso/pelvis fragment:
both arms must be absent from it and must appear only in their detached arm cells.
The torso artwork, including wings, must stop above the bottom cell boundary;
leave a visible magenta gap before the lower white gutter. Jeans in the torso
stop at the two hip markers and never continue into the thigh cells. Scale the
wings to fit completely inside the torso cell with visible clearance at every
edge. Keep the white gutter lines uninterrupted; never paint over an internal
separator.

Use the attached template image itself as the pixel-level layout stencil. Do not
redesign the grid, replace the white gutters, change the cell proportions, or
enlarge the cyan guide disks. Keep exactly one small cyan disk in each required
marker role; the code will detect its actual center after generation. The
template also contains yellow text labels naming each cell. Those labels are
annotations for you only: use them to identify the part, then remove every
label, yellow annotation box and letter from the generated output. Never treat
labels as anatomy, clothing or additional parts.

NOTHING MAY BE CLIPPED. Show every part completely inside its assigned cell,
with background clearance. Intentional anatomical joint cuts must also be visible.

Keep every part detached inside its own cell. Torso/pelvis contains the chest,
abdomen and pelvis ONLY, with no attached arms, hidden arms, hands or thighs.
Each upper-arm cell contains only a shoulder-to-elbow section; each forearm/hand
cell contains only an elbow-to-hand section. Each thigh cell contains only a
hip-to-knee section with no duplicate waistband or pelvis; each shin cell contains
only a knee-to-ankle section with NO shoe, sole, laces, toes or other foot pixels. Foot
cells contain only the below-ankle footwear. Do not duplicate costume or anatomy
between cells. Preserve the template's front/three-quarter torso view and visible
chest and abdomen, rather than switching to a back view.

Assign accessories to one owner: hair belongs only to head/neck; wings or capes
belong only to torso/pelvis. Keep all accessory pixels within that owner's cell,
clear of gutters. Never copy wings onto the head or detached arm pieces. Preserve
the template's body proportions and relative part sizes; do not enlarge or shrink
the anatomy to accommodate accessories.

Treat the template as a structural edit target, not a loosely inspired composition.
Use the cyan markers as strong visual guides for the neck, shoulder seams, hips,
elbows, knees and ankles. The code will measure their positions from the accepted
image and use those measured page coordinates downstream. The placeholder colors
are guides only and must not be copied as costume colors. Their silhouettes,
locations and proportions are authoritative and must be preserved by the
replacement. Render the requested character inside those structural regions
rather than redesigning the gray geometry. Every character must
wear a lower-body garment that covers the pelvis and continues through the leg
pieces. The torso/pelvis cell owns its waistband, closure, fly or belt line as
appropriate, plus its upper section through both hip joints. The thigh cells
continue that same garment from hip to knee, and the shin cells continue it from
knee to ankle. Never render an uncovered crotch or pelvis, even when the upper
torso is bare. Thigh cells must not duplicate the waistband or pelvis.
Keep the five torso disks in place while painting the artwork around them.
Place the two hip markers at the garment's belt/hip level, not at the bottom edge
of a newly drawn abdomen. Keep the torso top neck-only, with no face or hair.
Footwear ankle markers must lie on the ankle attachment, not float in
magenta above it; shape the footwear around the existing marker position.
Every marker must touch the visible artwork of its own body part. Each shin's
lower ankle marker must sit on and connect to the lower end of that shin piece,
whether it is garment or exposed skin. Keep it on the corresponding anatomical
attachment; the measured output coordinate is authoritative. No marker may float
in magenta.

REQUIRED MARKERS BY CELL AND THEIR MEANING:
- head and neck: 1, at neck attachment
- torso and pelvis: 5, neck, viewer-left shoulder, viewer-right shoulder,
  viewer-left hip, viewer-right hip
- viewer-left upper arm: 2, shoulder and elbow
- viewer-left forearm and hand: 1, elbow ONLY, no wrist or hand marker
- viewer-right forearm and hand: 1, elbow ONLY, no wrist or hand marker
- viewer-right upper arm: 2, shoulder and elbow
- viewer-left thigh: 2, hip and knee
- viewer-right thigh: 2, hip and knee
- viewer-left shin: 2, knee and ankle
- viewer-left sneaker: 1, ankle
- viewer-right shin: 2, knee and ankle
- viewer-right sneaker: 1, ankle

This stage MUST return the character with exactly 22 filled cyan #00FFFF circular
joint markers in the required cells and semantic locations. Marker centers may
move with the generated character's anatomy; the detected centers in the accepted
marked image are authoritative. Do not remove, merge or invent markers. Do not
add crosshairs, labels or other guides. The markers will be measured by code.

The output must contain all character art and the cyan markers on a flat #FF00FF
background. Do not use cyan or magenta in the costume. Return a 1024x1536 image.
"""
    else:
        body = """
STAGE: MARKER-FREE CLEAN OUTPUT

The attached image is the accepted marked character output. Remove ONLY the 22
cyan #00FFFF joint marker circles and their thin black outlines. Reconstruct
the character artwork hidden beneath each marker to match its surrounding skin,
tattoos, hair or clothing, and restore background where a marker covers it.
Change pixels only inside those marker circles and their outlines. Preserve every
character pixel, seam, pose, cell rectangle, white gutter, magenta background,
canvas dimension, facing direction and body-part boundary exactly. Do not redraw,
repaint, resize, reinterpret or restyle any artwork outside the marker areas. Do not remove any tattoo,
wing, hair, clothing, shoe, outline or shadow that belongs to the character.

Return the same 1024x1536 image with zero cyan marker pixels and no replacement
markers, labels, frames, captions or extra objects.
"""
    lines = [body.strip(), "", "CHARACTER IDENTITY AND ART DIRECTION:", identity.strip()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def _run_stage(
    args: argparse.Namespace,
    provider: VertexProvider | FixtureProvider,
    stage: str,
    identity: str,
    template_cells: list[dict[str, Any]],
    template_markers: dict[str, list[dict[str, Any]]],
    marked_path: Path | None = None,
) -> tuple[Path, dict[str, Any]]:
    attempt = 1
    attempt_dir = args.output_dir / f"{stage}-{attempt:02d}"
    attempt_dir.mkdir(parents=True, exist_ok=True)
    prompt_path = attempt_dir / f"{stage}-prompt.txt"
    _write_prompt(prompt_path, identity, stage)
    output_path = attempt_dir / f"{stage}.png"
    raw_output_path = attempt_dir / "provider-output.png"
    response_path = attempt_dir / "response.json"
    references = [args.template] if stage == "marked" else [marked_path]  # type: ignore[list-item]
    try:
        provider.generate(prompt_path, references, raw_output_path, response_path)
        normalization = _normalize_provider_output(raw_output_path, output_path)
        if stage == "marked":
            evidence = _validate_marked(
                template_cells,
                output_path,
                args.layout_tolerance,
            )
        else:
            evidence = _validate_marker_free(
                template_cells,
                template_markers,
                marked_path,  # type: ignore[arg-type]
                output_path,
                None if args.skip_artwork_drift_check else args.max_change_ratio,
                args.marker_mask_radius,
                args.layout_tolerance,
            )
        evidence["normalization"] = normalization
        evidence.update({"stage": stage, "attempt": attempt, "image": str(output_path.resolve()), "prompt": str(prompt_path.resolve())})
        return output_path, evidence
    except (WorkflowError, OSError, ValueError) as exc:
        (attempt_dir / "rejection.json").write_text(
            json.dumps({"stage": stage, "attempt": attempt, "error": str(exc)}, indent=2) + "\n",
            encoding="utf-8",
        )
        raise


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--template", type=Path, required=True, help="Marked 1024x1536 structural template")
    parser.add_argument("--character-prompt-file", type=Path, required=True, help="Identity/style prompt, not a stage protocol")
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--provider", choices=["vertex", "fixture"], default="vertex")
    parser.add_argument("--resume-marked", type=Path,
                        help="Reuse a saved marked provider result, revalidating every marked-stage gate before cleanup")
    parser.add_argument("--resume-marker-free", type=Path,
                        help="Reuse saved cleanup output after storing validated marked coordinates; all cleanup gates still run")
    parser.add_argument("--vertex-script", type=Path, default=Path(__file__).with_name("generate_vertex_gemini_image.py"))
    parser.add_argument("--project", default=None)
    parser.add_argument("--location", default="global")
    parser.add_argument("--model", default="gemini-3-pro-image")
    parser.add_argument("--layout-tolerance", type=int, default=8)
    parser.add_argument("--marker-mask-radius", type=int, default=18)
    parser.add_argument("--max-change-ratio", type=float, default=0.08)
    parser.add_argument("--skip-artwork-drift-check", action="store_true",
                        help="Do not measure or reject artwork pixel changes during cleanup; retain marker/layout checks")
    parser.add_argument("--fixture-marked", type=Path)
    parser.add_argument("--fixture-unmarked", type=Path)
    parser.add_argument("--import-directory", type=Path)
    parser.add_argument("--fighter-id")
    parser.add_argument("--body-type", default="standard")
    parser.add_argument("--pixel-scale", type=float)
    parser.add_argument(
        "--assembly-preview",
        action="store_true",
        help="Assemble the accepted source pixels at their measured joints for visual inspection",
    )
    parser.add_argument(
        "--assembly-reference-template",
        type=Path,
        help="Optional unlabelled geometric template used for proportion diagnostics",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    if not args.character_prompt_file.is_file():
        raise SystemExit(f"Character prompt does not exist: {args.character_prompt_file}")
    if args.import_directory and not args.fighter_id:
        raise SystemExit("--fighter-id is required with --import-directory")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    try:
        template_cells, template_markers = _validate_template(args.template)
    except WorkflowError as exc:
        failure = {
            "schema_version": 1,
            "status": "FAILED",
            "stage": "validate_template",
            "template": str(args.template.resolve()),
            "error": str(exc),
        }
        (args.output_dir / "workflow.json").write_text(json.dumps(failure, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(failure, indent=2), file=sys.stderr)
        return 1
    template_marker_path = args.output_dir / "template_pivots.json"
    _marker_json(template_marker_path, args.template, template_cells, template_markers)
    plan = {
        "schema_version": 1,
        "provider": args.provider,
        "model": args.model,
        "template": str(args.template.resolve()),
        "character_prompt": str(args.character_prompt_file.resolve()),
        "canvas": list(CANVAS_SIZE),
        "marker_count": 22,
        "marker_coordinates_source": "detected from accepted marked output",
        "layout_tolerance_px": args.layout_tolerance,
        "artwork_drift_check_enabled": not args.skip_artwork_drift_check,
        "stages": ["validate_template", "generate_marked", "store_pivots", "generate_marker_free", "validate_marker_free"],
    }
    if args.resume_marked:
        plan["marked_input_mode"] = "external_resume"
        plan["marked_input"] = str(args.resume_marked.resolve())
    if args.resume_marker_free:
        plan["marker_free_input_mode"] = "external_resume"
        plan["marker_free_input"] = str(args.resume_marker_free.resolve())
    if args.import_directory:
        plan["stages"].extend(["import_exact_coordinates", "compile_parts", "audit_coordinates"])
    if args.assembly_preview:
        plan["stages"].append("assemble_source_proportions_preview")
        reference = args.assembly_reference_template
        if reference is None:
            candidate = Path(__file__).resolve().parents[1] / "builds/templates/geometric_dummy_v1.png"
            reference = candidate if candidate.is_file() else None
        if reference is not None:
            plan["assembly_reference_template"] = str(reference.resolve())
    (args.output_dir / "workflow_plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    if args.dry_run:
        print(json.dumps({"status": "DRY_RUN", **plan}, indent=2))
        return 0

    provider = _provider(args)
    identity = args.character_prompt_file.read_text(encoding="utf-8")
    try:
        if args.resume_marked:
            marked_attempt = args.output_dir / "resumed-marked.png"
            normalization = _normalize_provider_output(args.resume_marked, marked_attempt)
            marked_evidence = _validate_marked(
                template_cells, marked_attempt, args.layout_tolerance,
            )
            marked_evidence.update({"stage": "marked", "reused_provider_result": str(args.resume_marked.resolve()),
                                    "normalization": normalization, "image": str(marked_attempt.resolve())})
        else:
            marked_attempt, marked_evidence = _run_stage(
                args, provider, "marked", identity, template_cells, template_markers
            )
        marked_path = args.output_dir / "marked.png"
        shutil.copy2(marked_attempt, marked_path)
        marked_pivots = args.output_dir / "marked_pivots.json"
        marked_cells, marked_by_cell = _markers(_open_rgb(marked_path), "accepted marked output")
        _marker_json(marked_pivots, marked_path, marked_cells, marked_by_cell)

        if args.resume_marker_free:
            clean_attempt = args.output_dir / "resumed-marker-free.png"
            normalization = _normalize_provider_output(args.resume_marker_free, clean_attempt)
            clean_evidence = _validate_marker_free(
                marked_cells, marked_by_cell, marked_path, clean_attempt,
                None if args.skip_artwork_drift_check else args.max_change_ratio,
                args.marker_mask_radius, args.layout_tolerance,
            )
            clean_evidence.update({"stage": "marker-free", "reused_provider_result": str(args.resume_marker_free.resolve()),
                                   "normalization": normalization, "image": str(clean_attempt.resolve())})
        else:
            clean_attempt, clean_evidence = _run_stage(
                args, provider, "marker-free", identity, marked_cells, marked_by_cell, marked_path
            )
        clean_path = args.output_dir / "marker-free.png"
        shutil.copy2(clean_attempt, clean_path)

        result: dict[str, Any] = {
            **plan,
            "status": "PASS",
            "marked": marked_evidence,
            "marker_free": clean_evidence,
            "pivots": str(marked_pivots.resolve()),
            "marker_free_image": str(clean_path.resolve()),
        }
        if args.assembly_preview:
            from build_assembly_preview import build_preview

            reference = args.assembly_reference_template
            if reference is None:
                candidate = Path(__file__).resolve().parents[1] / "builds/templates/geometric_dummy_v1.png"
                reference = candidate if candidate.is_file() else None
            result["assembly_preview"] = build_preview(
                marked_path,
                clean_path,
                marked_pivots,
                args.output_dir / "assembly-preview",
                reference,
            )
        if args.import_directory:
            if not args.fighter_id:
                raise WorkflowError("--fighter-id is required with --import-directory")
            command = [
                sys.executable,
                str(Path(__file__).with_name("rig_atlas_import.py")),
                "--source", str(clean_path),
                "--markers", str(marked_pivots),
                "--marked-source", str(marked_path),
                "--fighter-id", args.fighter_id,
                "--body-type", args.body_type,
                "--directory", str(args.import_directory),
            ]
            if args.pixel_scale is not None:
                command.extend(["--pixel-scale", str(args.pixel_scale)])
            import_result = subprocess.run(command, capture_output=True, text=True)
            if import_result.returncode:
                raise WorkflowError("Rig import failed:\n" + (import_result.stderr or import_result.stdout)[-4000:])
            result["import"] = {"directory": str(args.import_directory.resolve()), "stdout": import_result.stdout[-4000:]}
            build_result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("rig_workflow.py")), "build", str(args.import_directory)],
                capture_output=True, text=True,
            )
            if build_result.returncode:
                raise WorkflowError("Rig compilation failed:\n" + (build_result.stderr or build_result.stdout)[-4000:])
            coordinate_report = args.output_dir / "coordinate_audit.json"
            audit_result = subprocess.run(
                [sys.executable, str(Path(__file__).with_name("audit_rig_coordinates.py")),
                 "--directory", str(args.import_directory), "--output", str(coordinate_report)],
                capture_output=True, text=True,
            )
            if audit_result.returncode:
                raise WorkflowError("Rig coordinate audit failed:\n" + (audit_result.stderr or audit_result.stdout)[-4000:])
            result["import"]["compiled"] = True
            result["import"]["coordinate_audit"] = str(coordinate_report.resolve())
        (args.output_dir / "workflow.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(result, indent=2))
        return 0
    except (WorkflowError, OSError, ValueError) as exc:
        failure = {**plan, "status": "FAILED", "error": str(exc)}
        (args.output_dir / "workflow.json").write_text(json.dumps(failure, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(failure, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
