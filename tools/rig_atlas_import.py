#!/usr/bin/env python3
"""Import the standardized marked-character atlas into the v3 rig workflow.

The input contract is deliberately narrow and deterministic: one clean
1024x1536 atlas, one matching marked atlas, twelve fixed cells, and twenty
two cyan landmarks.  The adapter maps those landmarks to the existing v3
source binding and derives the missing axis tips from the cleaned artwork.
The compiler slices the owned rectangles without resampling. The rig uses
one common pixel scale and source-derived segment lengths.

This is an adapter for the format, not for a particular fighter.  It does not
resize the source, discard pixels, or accept a missing marker.
"""

from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image

import build_rigged_sheet as builder
from rig_coordinate_contract import build_contract, order_markers


CELL_NAMES = [
    "head_and_neck",
    "torso_and_pelvis",
    "viewer_left_upper_arm",
    "viewer_left_forearm_and_hand",
    "viewer_right_forearm_and_hand",
    "viewer_right_upper_arm",
    "viewer_left_thigh",
    "viewer_right_thigh",
    "viewer_left_shin",
    "viewer_left_sneaker",
    "viewer_right_shin",
    "viewer_right_sneaker",
]
ROW_CELL_COUNTS = (2, 4, 2, 4)
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
# The runtime smoke test probes three game pixels around every joint. The
# compiler's ten-pixel source check is necessary but not sufficient after the
# sprite is scaled into game units, so the adapter targets a wider normalized
# safety radius and chooses source candidates with corresponding coverage.
MIN_OUTPUT_JOINT_RADIUS = 12.0
MIN_SOURCE_COVERAGE_FOR_CORRECTION = 16.0
# The runtime validates a five-point cross around each joint after scaling a
# part into game units. Generated outlines can be opaque at the marker center
# while still being too narrow at that cross. Add a small, deterministic
# overlap from nearby existing art before binding and record the count in the
# import report. This never expands beyond the declared part cell and never
# removes or clips a source pixel.
JOINT_PADDING_RADIUS = 36
CELL_TO_PART = {
    "head_and_neck": "head",
    "torso_and_pelvis": "torso",
    "viewer_left_upper_arm": "left_upper_arm",
    "viewer_left_forearm_and_hand": "left_forearm",
    "viewer_right_forearm_and_hand": "right_forearm",
    "viewer_right_upper_arm": "right_upper_arm",
    "viewer_left_thigh": "left_thigh",
    "viewer_right_thigh": "right_thigh",
    "viewer_left_shin": "left_shin",
    "viewer_left_sneaker": "left_boot",
    "viewer_right_shin": "right_shin",
    "viewer_right_sneaker": "right_boot",
}


def contiguous_bands(values: list[int], threshold: int, minimum_width: int = 2) -> list[dict[str, int]]:
    bands: list[dict[str, int]] = []
    index = 0
    while index < len(values):
        if values[index] < threshold:
            index += 1
            continue
        end = index
        while end < len(values) and values[end] >= threshold:
            end += 1
        if end - index >= minimum_width:
            bands.append({"start": index, "end": end})
        index = end
    return bands


def near_white(pixel: tuple[int, int, int]) -> bool:
    return pixel[0] >= 245 and pixel[1] >= 245 and pixel[2] >= 245


def near_cyan(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    return r <= 40 and g >= 220 and b >= 220 and abs(g - b) <= 30


def near_magenta(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    return (
        r >= 12
        and b >= 12
        and g <= 245
        and min(r, b) - g >= 8
        and abs(r - b) <= 75
    )


def detect_cells(image: Image.Image) -> list[dict[str, Any]]:
    from rig_coordinate_contract import detect_grid_cells
    return detect_grid_cells(image)


def resolve_path(path: Path) -> Path:
    if path.is_absolute():
        return path
    from_root = builder.ROOT / path
    if from_root.exists():
        return from_root
    return path.resolve()


def rect_size(rect: list[int]) -> tuple[float, float]:
    return float(rect[2] - rect[0]), float(rect[3] - rect[1])


def map_point(point: list[float], source_rect: list[int], destination_rect: list[int]) -> list[float]:
    # Both images already share one canonical canvas. Gutter/crop boundaries
    # change ownership, never the position of a measured landmark on that page.
    x, y = float(point[0]), float(point[1])
    for label, rect in (("marked", source_rect), ("clean", destination_rect)):
        if not (rect[0] <= x < rect[2] and rect[1] <= y < rect[3]):
            raise ValueError(f"Marker {point} is outside its {label} cell {rect}; regenerate instead of moving the point")
    return [x, y]


def marker_centers(payload: dict[str, Any]) -> dict[str, list[list[float]]]:
    pivots = payload.get("pivots")
    if not isinstance(pivots, dict):
        raise ValueError("Marker JSON must contain a pivots object")
    result: dict[str, list[list[float]]] = {}
    total = 0
    for name in CELL_NAMES:
        entries = pivots.get(name)
        expected = MARKER_COUNTS[name]
        if not isinstance(entries, list) or len(entries) != expected:
            raise ValueError(f"{name}: expected {expected} markers, found {len(entries) if isinstance(entries, list) else 0}")
        centers: list[list[float]] = []
        for entry in entries:
            if not isinstance(entry, dict) or not isinstance(entry.get("center"), list) or len(entry["center"]) != 2:
                raise ValueError(f"{name}: every marker must have a two-coordinate center")
            x, y = float(entry["center"][0]), float(entry["center"][1])
            if not np.isfinite([x, y]).all():
                raise ValueError(f"{name}: marker contains a non-finite coordinate")
            centers.append([x, y])
        centers = [entry["center"] for entry in order_markers(name, [{"center": point} for point in centers])]
        result[name] = centers
        total += len(centers)
    if total != 22:
        raise ValueError(f"Expected exactly 22 markers, found {total}")
    return result


def map_markers(
    payload: dict[str, Any],
    marked_cells: list[dict[str, Any]],
    clean_cells: list[dict[str, Any]],
) -> dict[str, list[list[float]]]:
    marked_by_name = {cell["name"]: cell for cell in marked_cells}
    clean_by_name = {cell["name"]: cell for cell in clean_cells}
    centers = marker_centers(payload)
    mapped: dict[str, list[list[float]]] = {}
    for name in CELL_NAMES:
        mapped[name] = [
            map_point(point, marked_by_name[name]["rect"], clean_by_name[name]["rect"])
            for point in centers[name]
        ]
    return mapped


def clean_atlas(image: Image.Image, cells: list[dict[str, Any]]) -> tuple[np.ndarray, dict[str, np.ndarray]]:
    """Make gutters transparent while preserving every pixel inside a cell."""
    rgb = np.array(image.convert("RGB"))
    alpha = np.zeros(rgb.shape[:2], dtype=np.uint8)
    cell_arrays: dict[str, np.ndarray] = {}
    for cell in cells:
        x0, y0, x1, y1 = cell["rect"]
        cell_rgb = rgb[y0:y1, x0:x1]
        cell_alpha = np.full(cell_rgb.shape[:2], 255, dtype=np.uint8)
        for y in range(cell_rgb.shape[0]):
            for x in range(cell_rgb.shape[1]):
                if near_magenta(tuple(int(value) for value in cell_rgb[y, x])):
                    cell_alpha[y, x] = 0
        # Only remove the detected cell gutter edge. Intentional white costume
        # details deeper inside the cell are never classified as background.
        edge_guard = 2
        for x in range(cell_rgb.shape[1]):
            for y in list(range(min(edge_guard, cell_rgb.shape[0]))) + list(range(max(0, cell_rgb.shape[0] - edge_guard), cell_rgb.shape[0])):
                if near_white(tuple(int(value) for value in cell_rgb[y, x])):
                    cell_alpha[y, x] = 0
        for y in range(cell_rgb.shape[0]):
            for x in list(range(min(edge_guard, cell_rgb.shape[1]))) + list(range(max(0, cell_rgb.shape[1] - edge_guard), cell_rgb.shape[1])):
                if near_white(tuple(int(value) for value in cell_rgb[y, x])):
                    cell_alpha[y, x] = 0
        alpha[y0:y1, x0:x1] = cell_alpha
        cell_arrays[cell["name"]] = np.dstack((cell_rgb, cell_alpha))
    rgba = np.dstack((rgb, alpha))
    rgba[alpha == 0, :3] = 0
    return rgba, cell_arrays


def pad_joint_regions(
    rgba: np.ndarray,
    cells: list[dict[str, Any]],
    mapped_markers: dict[str, list[list[float]]],
    radius: int = JOINT_PADDING_RADIUS,
) -> tuple[np.ndarray, dict[str, int]]:
    """Create a small opaque overlap around each declared landmark.

    The source image remains authoritative for colors. Newly covered pixels
    copy the nearest nearby source pixel from the same cell, so this operation
    closes a narrow seam without inventing a new material or borrowing pixels
    from another body part. It is deliberately local, deterministic and
    reported for review.
    """
    padded = rgba.copy()
    original = rgba.copy()
    counts: dict[str, int] = {}
    radius_sq = radius * radius
    for cell in cells:
        cell_name = cell["name"]
        x0, y0, x1, y1 = cell["rect"]
        source = original[y0:y1, x0:x1]
        source_mask = builder.foreground(source)
        source_points = np.column_stack(np.where(source_mask))
        if not len(source_points):
            raise ValueError(f"{cell_name}: cannot pad joints in an empty cell")
        added = 0
        for point in mapped_markers.get(cell_name, []):
            center = np.array([float(point[1] - y0), float(point[0] - x0)])
            cy, cx = int(round(center[0])), int(round(center[1]))
            if not (0 <= cx < source.shape[1] and 0 <= cy < source.shape[0]):
                raise ValueError(f"{cell_name}: marker is outside its owned cell")
            # Preserve the compiler's required four-pixel safety margin. If
            # the generated art is already too close to a cell edge, the
            # adapter leaves that edge untouched and the normal validator
            # reports the source as unfit instead of clipping it.
            edge_margin = 4
            y_start = max(edge_margin, cy - radius)
            y_end = min(source.shape[0] - edge_margin, cy + radius + 1)
            x_start = max(edge_margin, cx - radius)
            x_end = min(source.shape[1] - edge_margin, cx + radius + 1)
            for local_y in range(y_start, y_end):
                for local_x in range(x_start, x_end):
                    if (local_x - cx) ** 2 + (local_y - cy) ** 2 > radius_sq:
                        continue
                    if source_mask[local_y, local_x]:
                        continue
                    delta = source_points - np.array([local_y, local_x])
                    distance_sq = np.sum(delta * delta, axis=1)
                    nearest_index = int(np.argmin(distance_sq))
                    nearest_y, nearest_x = source_points[nearest_index]
                    padded[y0 + local_y, x0 + local_x, :3] = source[nearest_y, nearest_x, :3]
                    padded[y0 + local_y, x0 + local_x, 3] = 255
                    source_mask[local_y, local_x] = True
                    added += 1
        counts[cell_name] = added
    return padded, counts


def _choose_boundary(current: int, lower: int, upper: int, label: str) -> int:
    if lower > upper:
        raise ValueError(
            f"{label}: the standardized cell layout leaves less than four pixels of artwork margin"
        )
    return max(lower, min(current, upper))


def expand_cells_for_margin(
    cells: list[dict[str, Any]],
    mask: np.ndarray,
    canvas: tuple[int, int],
) -> list[dict[str, Any]]:
    """Assign empty gutter pixels to cells when generated art reaches a grid edge.

    A generated atlas can place an outline on the detected grid edge even
    though the neighboring gutter is empty. The importer may move ownership
    boundaries through empty pixels, but it never removes a foreground pixel.
    """
    width, height = canvas
    by_row: dict[int, list[dict[str, Any]]] = {}
    for cell in cells:
        by_row.setdefault(int(cell["row"]), []).append(cell)
    for row in by_row.values():
        row.sort(key=lambda cell: int(cell["column"]))

    row_requirements: dict[int, tuple[int, int]] = {}
    cell_requirements: dict[str, tuple[int, int]] = {}
    for cell in cells:
        x0, y0, x1, y1 = cell["rect"]
        part_mask = mask[y0:y1, x0:x1]
        ys, xs = np.where(part_mask)
        if not len(xs):
            raise ValueError(f"{cell['name']}: clean cell has no artwork")
        min_x, max_x = int(x0 + xs.min()), int(x0 + xs.max() + 1)
        min_y, max_y = int(y0 + ys.min()), int(y0 + ys.max() + 1)
        cell_requirements[cell["name"]] = (min_x, max_x)
        row = int(cell["row"])
        if row not in row_requirements:
            row_requirements[row] = (min_y, max_y)
        else:
            old_min, old_max = row_requirements[row]
            row_requirements[row] = (min(old_min, min_y), max(old_max, max_y))

    row_boundaries: list[int] = [0]
    ordered_rows = sorted(by_row)
    for row_index in range(len(ordered_rows) - 1):
        upper_row = ordered_rows[row_index]
        lower_row = ordered_rows[row_index + 1]
        current = max(cell["rect"][3] for cell in by_row[upper_row])
        lower = row_requirements[upper_row][1] + 4
        upper = row_requirements[lower_row][0] - 4
        row_boundaries.append(_choose_boundary(current, lower, upper, f"rows {upper_row}/{lower_row}"))
    last_row = ordered_rows[-1]
    row_boundaries.append(min(height, row_requirements[last_row][1] + 4))
    if len(row_boundaries) != len(ordered_rows) + 1:
        raise ValueError("Could not construct non-overlapping row ownership boundaries")

    expanded: list[dict[str, Any]] = []
    for row_position, row_index in enumerate(ordered_rows):
        row = by_row[row_index]
        x_boundaries: list[int] = [
            max(0, cell_requirements[row[0]["name"]][0] - 4)
        ]
        for column_index in range(len(row) - 1):
            left = row[column_index]
            right = row[column_index + 1]
            current = int(left["rect"][2])
            lower = cell_requirements[left["name"]][1] + 4
            upper = cell_requirements[right["name"]][0] - 4
            x_boundaries.append(
                _choose_boundary(current, lower, upper, f"{left['name']}/{right['name']}")
            )
        x_boundaries.append(
            min(width, cell_requirements[row[-1]["name"]][1] + 4)
        )
        for column_index, cell in enumerate(row):
            y0 = row_boundaries[row_position]
            y1 = row_boundaries[row_position + 1]
            x0 = x_boundaries[column_index]
            x1 = x_boundaries[column_index + 1]
            if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
                raise ValueError(f"{cell['name']}: expanded ownership rectangle is invalid")
            expanded.append({**cell, "rect": [x0, y0, x1, y1]})
    return expanded


def derived_tip(
    part_name: str,
    pivot: list[float],
    destination_rect: list[int],
    cell_rgba: np.ndarray,
    cell_mask: np.ndarray | None = None,
    distance: np.ndarray | None = None,
) -> list[float]:
    """Find a covered tip in the contract's standard axis direction.

    Single-marker cells still need an axis for the compiler. The direction is
    inherited from the shared contract, while the distance is measured from
    the actual cleaned pixels. Choosing the farthest pixel with ten pixels of
    coverage prevents an invented point in transparent space.
    """
    contract_slot = builder.contract()["slots"][part_name]
    axis = np.subtract(contract_slot["tip"], contract_slot["pivot"]).astype(float)
    axis /= np.linalg.norm(axis)
    opaque = cell_mask if cell_mask is not None else builder.foreground(cell_rgba)
    distance = distance if distance is not None else cv2.distanceTransform(opaque.astype(np.uint8), cv2.DIST_L2, 5)
    if part_name.endswith("boot"):
        # Foot art is a side view: the shared contract axis runs from the
        # ankle down through the sole, while the toe is measured across that
        # axis. Keep the source axis vertical instead of letting the farthest
        # sole pixel skew it diagonally toward the toe.
        x0, y0, _, _ = destination_rect
        local_x = int(round(float(pivot[0]) - x0))
        local_x = max(0, min(local_x, distance.shape[1] - 1))
        covered_y = np.where(distance[:, local_x] >= 10.0)[0]
        if len(covered_y):
            return [float(pivot[0]), float(y0 + covered_y.max())]
    ys, xs = np.where((distance >= 10.0) & opaque)
    if not len(xs):
        raise ValueError(f"{part_name}: no covered pixels available to derive a tip")
    x0, y0, _, _ = destination_rect
    local_pivot = np.array([pivot[0] - x0, pivot[1] - y0], dtype=float)
    points = np.column_stack((xs, ys)).astype(float)
    projections = (points - local_pivot) @ axis
    max_projection = float(projections.max())
    # Prefer the furthest well-covered pixel, then stay close to the marker's
    # transverse coordinate so the axis remains stable for asymmetric art.
    candidates = np.where(projections >= max_projection - 3.0)[0]
    across = np.array([-axis[1], axis[0]])
    best = min(
        candidates.tolist(),
        key=lambda index: abs(float((points[index] - local_pivot) @ across)),
    )
    return [float(x0 + points[best, 0]), float(y0 + points[best, 1])]


def snap_to_coverage(
    part_name: str,
    point: list[float],
    destination_rect: list[int],
    cell_rgba: np.ndarray,
    minimum_radius: float = 10.0,
    search_radius: float = 32.0,
    cell_mask: np.ndarray | None = None,
    distance_map: np.ndarray | None = None,
) -> tuple[list[float], float]:
    """Move a marker out of a small cleanup hole or a thin outline only.

    The cyan marker can cover the exact pixel that the clean-up model later
    removes, and a generated seam can be narrower than the compiler's joint
    coverage threshold. The marker remains the requested coordinate in the
    import report; the binding uses the nearest genuinely covered pixel and
    records the displacement. A larger failure is rejected instead of being
    hidden by clipping or arbitrary repositioning.
    """
    mask = cell_mask if cell_mask is not None else builder.foreground(cell_rgba)
    distance = distance_map if distance_map is not None else cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    x0, y0, _, _ = destination_rect
    local = np.array([float(point[0] - x0), float(point[1] - y0)])
    ix, iy = int(round(local[0])), int(round(local[1]))
    if not (0 <= ix < distance.shape[1] and 0 <= iy < distance.shape[0]):
        raise ValueError(f"{part_name}: marker is outside its owned cell")
    if float(distance[iy, ix]) >= minimum_radius:
        return point, 0.0
    ys, xs = np.where(distance >= minimum_radius)
    if not len(xs):
        raise ValueError(f"{part_name}: no covered pixels satisfy the joint radius")
    candidates = np.column_stack((xs, ys)).astype(float)
    delta = candidates - local
    lengths = np.linalg.norm(delta, axis=1)
    valid = lengths <= search_radius
    if not valid.any():
        raise ValueError(
            f"{part_name}: marker is {float(distance[iy, ix]):.1f}px covered and no valid joint is within {search_radius:.0f}px"
        )
    valid_indices = np.where(valid)[0]
    best = min(
        valid_indices.tolist(),
        key=lambda index: (float(lengths[index]), -float(distance[int(ys[index]), int(xs[index])])),
    )
    snapped = [float(x0 + xs[best]), float(y0 + ys[best])]
    return snapped, float(lengths[best])


def assess_normalization(
    part_name: str,
    pivot: list[float],
    tip: list[float],
    destination_rect: list[int],
    cell_rgba: np.ndarray,
    body_type: str,
    cell_mask: np.ndarray | None = None,
) -> tuple[bool, dict[str, Any]]:
    """Apply the compiler transform to one part without writing anything."""
    contract = builder.contract()
    slot = contract["slots"][part_name]
    shape = contract["body_types"][body_type]
    mask = cell_mask if cell_mask is not None else builder.foreground(cell_rgba)
    x0, y0, _, _ = destination_rect
    source_pivot = np.subtract(pivot, [x0, y0]).astype(float)
    source_tip = np.subtract(tip, [x0, y0]).astype(float)
    source_axis = source_tip - source_pivot
    source_length = float(np.linalg.norm(source_axis))
    if source_length <= 0:
        return False, {"reason": "zero source axis"}
    ys, xs = np.where(mask)
    if not len(xs):
        return False, {"reason": "empty source mask"}
    source_axis /= source_length
    source_across = np.array([-source_axis[1], source_axis[0]])
    destination_pivot = np.array(slot["pivot"], dtype=float)
    destination_tip = np.array(slot["tip"], dtype=float)
    destination_axis = destination_tip - destination_pivot
    destination_length = float(np.linalg.norm(destination_axis))
    destination_axis /= destination_length
    destination_across = np.array([-destination_axis[1], destination_axis[0]])
    kind = builder.category(part_name)
    target_length = {
        "head": shape["head_length"],
        "torso": 67,
        "upper_arm": 48,
        "forearm": 50,
        "thigh": 64,
        "shin": 32,
        "boot": shape["boot_length"],
    }[kind]
    width = builder.axis_width(mask, source_pivot, source_tip)
    destination_width = shape[kind] * destination_length / target_length
    matrix = (
        np.outer(destination_axis, source_axis) * (destination_length / source_length)
        + np.outer(destination_across, source_across) * (destination_width / width)
    )
    offset = destination_pivot - matrix @ source_pivot
    points = np.column_stack((xs, ys))
    mapped = points @ matrix.T + offset
    rect = slot["rect"]
    bounds_ok = not (
        (mapped.min(axis=0) < np.array(rect[:2]) + 5).any()
        or (mapped.max(axis=0) > np.array(rect[2:]) - 6).any()
    )
    transform = np.column_stack((matrix, offset - np.array(rect[:2])))
    warped = cv2.warpAffine(
        mask.astype(np.uint8),
        transform,
        (rect[2] - rect[0], rect[3] - rect[1]),
        flags=cv2.INTER_NEAREST,
    )
    distance = cv2.distanceTransform(warped, cv2.DIST_L2, 5)
    pivot_radius = float(distance[int(destination_pivot[1] - rect[1]), int(destination_pivot[0] - rect[0])])
    tip_radius = float(distance[int(destination_tip[1] - rect[1]), int(destination_tip[0] - rect[0])])
    result = {
        "mapped_min": mapped.min(axis=0).round(3).tolist(),
        "mapped_max": mapped.max(axis=0).round(3).tolist(),
        "pivot_radius": pivot_radius,
        "tip_radius": tip_radius,
        "bounds_ok": bounds_ok,
    }
    return bounds_ok and pivot_radius >= MIN_OUTPUT_JOINT_RADIUS and tip_radius >= MIN_OUTPUT_JOINT_RADIUS, result


def axis_tip_candidates(
    pivot: list[float],
    requested_tip: list[float],
    destination_rect: list[int],
    cell_rgba: np.ndarray,
    cell_mask: np.ndarray | None = None,
    distance_map: np.ndarray | None = None,
) -> list[list[float]]:
    """Return covered points near the requested axis, closest first."""
    mask = cell_mask if cell_mask is not None else builder.foreground(cell_rgba)
    distance = distance_map if distance_map is not None else cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    ys, xs = np.where(distance >= MIN_SOURCE_COVERAGE_FOR_CORRECTION)
    if not len(xs):
        return []
    x0, y0, _, _ = destination_rect
    local_pivot = np.array(pivot, dtype=float) - [x0, y0]
    local_requested_tip = np.array(requested_tip, dtype=float) - [x0, y0]
    axis = local_requested_tip - local_pivot
    length = float(np.linalg.norm(axis))
    if length <= 0:
        return []
    axis /= length
    across = np.array([-axis[1], axis[0]])
    points = np.column_stack((xs, ys)).astype(float)
    projection = (points - local_pivot) @ axis
    transverse = np.abs((points - local_pivot) @ across)
    keep = (projection >= max(8.0, length * 0.35)) & (projection <= length * 1.65)
    keep &= transverse <= max(28.0, length * 0.35)
    points = points[keep]
    if not len(points):
        return []
    distances = np.linalg.norm(points - local_requested_tip, axis=1)
    # One representative per integer distance along the axis is enough for
    # deterministic fitting and avoids trying thousands of neighboring
    # pixels through the full compiler transform.
    buckets: dict[int, int] = {}
    for index, point in enumerate(points):
        bucket = int(round(float((point - local_pivot) @ axis)))
        previous = buckets.get(bucket)
        if previous is None or abs(float((points[previous] - local_pivot) @ across)) > abs(float((point - local_pivot) @ across)):
            buckets[bucket] = index
    reduced = np.array(list(buckets.values()), dtype=int)
    order = reduced[np.argsort(distances[reduced])]
    candidates: list[list[float]] = []
    seen: set[tuple[int, int]] = set()
    for index in order[:120]:
        point = points[index]
        key = (int(point[0]), int(point[1]))
        if key in seen:
            continue
        seen.add(key)
        candidates.append([float(x0 + point[0]), float(y0 + point[1])])
    return candidates


def point_candidates(
    reference: list[float],
    destination_rect: list[int],
    cell_rgba: np.ndarray,
    search_radius: float = 64.0,
    cell_mask: np.ndarray | None = None,
    distance_map: np.ndarray | None = None,
) -> list[list[float]]:
    """Return nearby source pixels with enough opaque joint coverage."""
    mask = cell_mask if cell_mask is not None else builder.foreground(cell_rgba)
    distance = distance_map if distance_map is not None else cv2.distanceTransform(mask.astype(np.uint8), cv2.DIST_L2, 5)
    ys, xs = np.where(distance >= MIN_SOURCE_COVERAGE_FOR_CORRECTION)
    if not len(xs):
        return []
    x0, y0, _, _ = destination_rect
    local_reference = np.array(reference, dtype=float) - [x0, y0]
    points = np.column_stack((xs, ys)).astype(float)
    lengths = np.linalg.norm(points - local_reference, axis=1)
    keep = lengths <= search_radius
    points = points[keep]
    lengths = lengths[keep]
    order = np.argsort(lengths)
    candidates: list[list[float]] = []
    seen: set[tuple[int, int]] = set()
    for index in order[:80]:
        point = points[index]
        key = (int(point[0]), int(point[1]))
        if key in seen:
            continue
        seen.add(key)
        candidates.append([float(x0 + point[0]), float(y0 + point[1])])
    return candidates


def resolve_axis(
    part_name: str,
    requested_pivot: list[float],
    requested_tip: list[float],
    destination_rect: list[int],
    cell_rgba: np.ndarray,
    body_type: str,
) -> tuple[list[float], list[float], str, float, float]:
    """Resolve marker anchors while requiring the normalized art to fit."""
    cell_mask = builder.foreground(cell_rgba)
    distance = cv2.distanceTransform(cell_mask.astype(np.uint8), cv2.DIST_L2, 5)
    pivot, pivot_snap = snap_to_coverage(
        part_name,
        requested_pivot,
        destination_rect,
        cell_rgba,
        cell_mask=cell_mask,
        distance_map=distance,
    )
    tip, tip_snap = snap_to_coverage(
        part_name,
        requested_tip,
        destination_rect,
        cell_rgba,
        cell_mask=cell_mask,
        distance_map=distance,
    )
    valid, _ = assess_normalization(part_name, pivot, tip, destination_rect, cell_rgba, body_type, cell_mask)
    if valid:
        return pivot, tip, "marker_coordinates", pivot_snap, tip_snap

    # A sneaker marker is the ankle landmark, but the marker can land in the
    # middle of a tall shoe. Search upward on the same centerline until the
    # full shoe can fit in the shared boot slot.
    if part_name.endswith("boot"):
        x0, y0, _, _ = destination_rect
        local_x = int(round(float(requested_pivot[0]) - x0))
        local_x = max(0, min(local_x, distance.shape[1] - 1))
        candidate_ys = np.where(distance[:, local_x] >= MIN_SOURCE_COVERAGE_FOR_CORRECTION)[0]
        candidate_ys = candidate_ys[candidate_ys <= int(round(requested_pivot[1] - y0))]
        for local_y in candidate_ys[::-1]:
            candidate_pivot = [float(x0 + local_x), float(y0 + local_y)]
            candidate_tip = derived_tip(part_name, candidate_pivot, destination_rect, cell_rgba, cell_mask, distance)
            candidate_tip, candidate_tip_snap = snap_to_coverage(
                part_name,
                candidate_tip,
                destination_rect,
                cell_rgba,
                cell_mask=cell_mask,
                distance_map=distance,
            )
            valid, _ = assess_normalization(
                part_name,
                candidate_pivot,
                candidate_tip,
                destination_rect,
                cell_rgba,
                body_type,
                cell_mask,
            )
            if valid:
                return (
                    candidate_pivot,
                    candidate_tip,
                    "ankle_marker_reanchored_to_covered_shoe_axis",
                    float(np.linalg.norm(np.subtract(candidate_pivot, requested_pivot))),
                    candidate_tip_snap,
                )

    # For the other cells the markers define the joint, but the artwork may
    # have a rounded end beyond it or a cleanup hole at the exact point. Keep
    # the marker axis and choose the closest covered tip that survives the
    # same compiler transform. The correction is recorded in atlas_import.json.
    tip_candidates = axis_tip_candidates(
        requested_pivot, requested_tip, destination_rect, cell_rgba, cell_mask, distance
    )
    pivot_candidates = [pivot] + point_candidates(
        requested_pivot,
        destination_rect,
        cell_rgba,
        cell_mask=cell_mask,
        distance_map=distance,
    )
    seen_pivots: set[tuple[int, int]] = set()
    preferred_pivots: list[tuple[float, list[float]]] = []
    for candidate_pivot in pivot_candidates[:81]:
        pivot_key = (round(candidate_pivot[0]), round(candidate_pivot[1]))
        if pivot_key in seen_pivots:
            continue
        seen_pivots.add(pivot_key)
        candidate_pivot, candidate_pivot_snap = snap_to_coverage(
            part_name,
            candidate_pivot,
            destination_rect,
            cell_rgba,
            cell_mask=cell_mask,
            distance_map=distance,
        )
        valid, info = assess_normalization(
            part_name,
            candidate_pivot,
            tip,
            destination_rect,
            cell_rgba,
            body_type,
            cell_mask,
        )
        if valid:
            return candidate_pivot, tip, "marker_axis_retargeted_to_normalized_coverage", candidate_pivot_snap, tip_snap
        if float(info.get("pivot_radius", 0.0)) >= MIN_OUTPUT_JOINT_RADIUS:
            preferred_pivots.append((float(np.linalg.norm(np.subtract(candidate_pivot, requested_pivot))), candidate_pivot))

    preferred_pivots.sort(key=lambda item: item[0])
    for _, candidate_pivot in preferred_pivots[:12]:
        candidates_for_tip = [tip] + tip_candidates
        for candidate_tip in candidates_for_tip:
            candidate_tip, candidate_tip_snap = snap_to_coverage(
                part_name,
                candidate_tip,
                destination_rect,
                cell_rgba,
                cell_mask=cell_mask,
                distance_map=distance,
            )
            valid, _ = assess_normalization(
                part_name,
                candidate_pivot,
                candidate_tip,
                destination_rect,
                cell_rgba,
                body_type,
                cell_mask,
            )
            if valid:
                pivot_changed = float(np.linalg.norm(np.subtract(candidate_pivot, requested_pivot)))
                tip_changed = float(np.linalg.norm(np.subtract(candidate_tip, requested_tip)))
                return (
                    candidate_pivot,
                    candidate_tip,
                    "marker_axis_retargeted_to_normalized_coverage",
                    pivot_changed + candidate_pivot_snap,
                    tip_changed + candidate_tip_snap,
                )
    raise ValueError(
        f"{part_name}: marker axis cannot produce covered artwork inside the shared slot; regenerate the atlas"
    )


def build_binding(
    fighter_id: str,
    body_type: str,
    source_reference: str,
    clean_cells: list[dict[str, Any]],
    mapped_markers: dict[str, list[list[float]]],
    cell_rgba: dict[str, np.ndarray],
) -> tuple[dict[str, Any], dict[str, Any]]:
    contract = builder.contract()
    parts: dict[str, dict[str, Any]] = {}
    landmarks: dict[str, Any] = {}
    cells_by_name = {cell["name"]: cell for cell in clean_cells}
    for cell_name in CELL_NAMES:
        part_name = CELL_TO_PART[cell_name]
        rect = cells_by_name[cell_name]["rect"]
        points = mapped_markers[cell_name]
        if part_name == "torso":
            # The top-center marker is the neck landmark for the head. The
            # torso bone itself begins at the shoulder line, so use the
            # shoulder midpoint as its source pivot and retain all five torso
            # markers in the import report.
            requested_pivot = [
                (points[1][0] + points[2][0]) / 2.0,
                (points[1][1] + points[2][1]) / 2.0,
            ]
            requested_tip = [
                (points[3][0] + points[4][0]) / 2.0,
                (points[3][1] + points[4][1]) / 2.0,
            ]
            requested_landmarks = {"neck": points[0], "shoulders": points[1:3], "hips": points[3:5]}
        elif len(points) == 2:
            requested_pivot, requested_tip = points
            requested_landmarks = {"pivot": requested_pivot, "tip": requested_tip}
        elif len(points) == 1:
            requested_pivot = points[0]
            requested_tip = derived_tip(part_name, requested_pivot, rect, cell_rgba[cell_name])
            requested_landmarks = {
                "pivot": requested_pivot,
                "tip": requested_tip,
                "tip_method": "covered_pixels_in_contract_axis",
            }
        else:
            raise ValueError(f"{cell_name}: unsupported marker count")
        pivot, tip = requested_pivot, requested_tip
        axis_method, pivot_snap, tip_snap = "source_markers_preserved", 0.0, 0.0
        landmarks[part_name] = {
            **requested_landmarks,
            "used_pivot": pivot,
            "used_tip": tip,
            "axis_method": axis_method,
            "pivot_snap_distance": pivot_snap,
            "tip_snap_distance": tip_snap,
        }
        parts[part_name] = {"rect": rect, "pivot": pivot, "tip": tip}
        if part_name == "torso":
            parts[part_name]["neck"] = points[0]
            parts[part_name]["shoulders"] = points[1:3]
            parts[part_name]["hips"] = points[3:5]

    # Keep the fixed contract order in the file for easy review.
    ordered_parts = {name: parts[name] for name in contract["part_order"]}
    binding = {
        "schema_version": 3,
        "fighter_id": fighter_id,
        "body_type": body_type,
        "source": source_reference,
        "render_mode": "preserve_proportions",
        "pixel_scale": float(np.linalg.norm(np.subtract(contract["rest_joints"]["hip"], contract["rest_joints"]["shoulder"]))
                             / np.linalg.norm(np.subtract(parts["torso"]["tip"], parts["torso"]["pivot"]))),
        "parts": ordered_parts,
    }
    report = {
        "format": "standardized_12_part_22_marker_atlas",
        "fighter_id": fighter_id,
        "body_type": body_type,
        "source": source_reference,
        "canvas": list(builder.CANVAS_SIZE),
        "cell_order": CELL_NAMES,
        "marker_counts": MARKER_COUNTS,
        "landmarks": landmarks,
    }
    return binding, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True, help="Marker-free canonical 1024x1536 atlas")
    parser.add_argument("--markers", type=Path, required=True, help="JSON containing the 22 marker centers")
    parser.add_argument("--marked-source", type=Path, help="Marked atlas; defaults to source_image in marker JSON")
    parser.add_argument("--fighter-id", required=True)
    parser.add_argument("--body-type", choices=list(builder.contract()["body_types"]), default="standard")
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--pixel-scale", type=float, help="One uniform scale for all twelve parts")
    args = parser.parse_args()

    source_path = resolve_path(args.source)
    markers_path = resolve_path(args.markers)
    payload = json.loads(markers_path.read_text(encoding="utf-8"))
    marked_path = resolve_path(args.marked_source) if args.marked_source else resolve_path(Path(payload.get("source_image", "")))
    if not source_path.exists() or not marked_path.exists():
        raise ValueError("Source and marked atlas files must exist")
    source_image = Image.open(source_path).convert("RGB")
    marked_image = Image.open(marked_path).convert("RGB")
    if source_image.size != builder.CANVAS_SIZE:
        raise ValueError(f"Expected clean source {builder.CANVAS_SIZE}, got {source_image.size}; normalize explicitly first")
    detected_clean_cells = detect_cells(source_image)
    marked_cells = detect_cells(marked_image)
    if len(detected_clean_cells) != len(marked_cells):
        raise ValueError("Marked and clean atlases do not have the same twelve-cell layout")
    initial_rgba, _ = clean_atlas(source_image, detected_clean_cells)
    initial_mask = builder.foreground(initial_rgba)
    clean_cells = expand_cells_for_margin(
        detected_clean_cells,
        initial_mask,
        source_image.size,
    )
    mapped_markers = map_markers(payload, marked_cells, detected_clean_cells)
    rgba, joint_padding = pad_joint_regions(rgba=initial_rgba, cells=clean_cells, mapped_markers=mapped_markers)
    # Keep the first cleanup's alpha ownership. Expanding a rectangle through
    # an empty gutter must not reactivate anti-aliased grid pixels that were
    # outside the detected source cell.
    cell_rgba = {
        cell["name"]: rgba[cell["rect"][1]:cell["rect"][3], cell["rect"][0]:cell["rect"][2]]
        for cell in clean_cells
    }

    args.directory.mkdir(parents=True, exist_ok=True)
    imported_source = args.directory / "imported_source.png"
    Image.fromarray(rgba, mode="RGBA").save(imported_source)
    try:
        source_reference = str(imported_source.resolve().relative_to(builder.ROOT))
    except ValueError:
        source_reference = str(imported_source.resolve())
    binding, report = build_binding(
        args.fighter_id,
        args.body_type,
        source_reference,
        clean_cells,
        mapped_markers,
        cell_rgba,
    )
    if args.pixel_scale is not None:
        if not np.isfinite(args.pixel_scale) or args.pixel_scale <= 0:
            raise ValueError("pixel_scale must be positive and finite")
        binding["pixel_scale"] = args.pixel_scale
    binding["coordinate_contract"] = build_contract(payload, binding, markers_path)
    extracted_path = args.directory / "extracted_pivots.json"
    if markers_path.resolve() != extracted_path.resolve():
        shutil.copy2(markers_path, extracted_path)
    # Reapply the same local operation at the final used axes as well. Single
    # marker cells derive their distal tip from the artwork, so that point is
    # not present in mapped_markers and needs its own seam coverage check.
    used_markers = {
        cell["name"]: [
            report["landmarks"][CELL_TO_PART[cell["name"]]]["used_pivot"],
            report["landmarks"][CELL_TO_PART[cell["name"]]]["used_tip"],
        ]
        for cell in clean_cells
    }
    rgba, used_joint_padding = pad_joint_regions(
        rgba=rgba,
        cells=clean_cells,
        mapped_markers=used_markers,
    )
    Image.fromarray(rgba, mode="RGBA").save(imported_source)
    binding_path = args.directory / "source.json"
    binding_path.write_text(json.dumps(binding, indent=2) + "\n", encoding="utf-8")
    report["marked_source"] = str(marked_path)
    report["marker_json"] = str(markers_path)
    report["detected_cells"] = detected_clean_cells
    report["owned_cells"] = clean_cells
    report["mapped_markers"] = mapped_markers
    report["joint_padding"] = {
        "radius": JOINT_PADDING_RADIUS,
        "requested_markers": {
            "added_pixels_by_cell": joint_padding,
            "added_pixels_total": sum(joint_padding.values()),
        },
        "used_axes": {
            "added_pixels_by_cell": used_joint_padding,
            "added_pixels_total": sum(used_joint_padding.values()),
        },
    }
    (args.directory / "atlas_import.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"binding": str(binding_path), "source": str(imported_source), "report": str(args.directory / "atlas_import.json")}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
