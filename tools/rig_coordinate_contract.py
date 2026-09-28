"""Exact page coordinates and semantic roles for the 12-part, 22-marker rig."""
from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any


CELL_PARTS = {
    "head_and_neck": "head", "torso_and_pelvis": "torso",
    "viewer_left_upper_arm": "left_upper_arm",
    "viewer_left_forearm_and_hand": "left_forearm",
    "viewer_right_forearm_and_hand": "right_forearm",
    "viewer_right_upper_arm": "right_upper_arm",
    "viewer_left_thigh": "left_thigh", "viewer_right_thigh": "right_thigh",
    "viewer_left_shin": "left_shin", "viewer_left_sneaker": "left_boot",
    "viewer_right_shin": "right_shin", "viewer_right_sneaker": "right_boot",
}


def order_markers(cell_name: str, entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ordered = sorted(entries, key=lambda item: (item["center"][1], item["center"][0]))
    if cell_name == "torso_and_pelvis" and len(ordered) == 5:
        # Small vertical differences must never swap left/right shoulders or hips.
        return ordered[:1] + sorted(ordered[1:3], key=lambda item: item["center"][0]) + sorted(ordered[3:5], key=lambda item: item["center"][0])
    return ordered

def detect_grid_cells(image: Any) -> list[dict[str, Any]]:
    """One gutter detector shared by extraction, generation, and import."""
    import numpy as np
    # Repeated Vertex edits can turn white rules either neutral gray or pale
    # magenta. Accept both forms while requiring enough green to exclude the
    # saturated #FF00FF background itself.
    rgb = np.asarray(image.convert("RGB"))
    neutral_light = np.all(rgb >= 170, axis=2)
    tinted_white = (rgb[:, :, 0] >= 240) & (rgb[:, :, 1] >= 120) & (rgb[:, :, 2] >= 240)
    white = neutral_light | tinted_white
    height, width = white.shape
    def bands(values: Any, threshold: int, minimum_width: int = 2) -> list[dict[str, int]]:
        spans = []
        start = None
        for index, value in enumerate(list(values)+[0]):
            if value >= threshold and start is None:
                start = index
            elif value < threshold and start is not None:
                if index-start >= minimum_width:
                    if spans and start-spans[-1]["end"] <= 4:
                        spans[-1]["end"] = index
                    else:
                        spans.append({"start": start, "end": index})
                start = None
        return spans
    # Compression can leave one complete pure-white scanline inside a wider
    # tinted gutter. It remains a real separator, not a missing layout rule.
    horizontal = bands(white.sum(axis=1), int(width*0.75), minimum_width=1)
    inner = [band for band in horizontal if band["start"] > 4 and band["end"] < height-4]
    if len(inner) != 3:
        raise ValueError(f"expected three horizontal gutters, found {inner}")
    # Inspect the full edge-connected gutter band, not only five scanlines.
    # This supports both thin tinted rules and deliberately thicker frames.
    row_white = white.sum(axis=1)
    top_rules = [y for band in horizontal if band["start"] <= 4
                 for y in range(band["start"], band["end"]) if row_white[y] >= width*0.9]
    bottom_rules = [y for band in horizontal if band["end"] >= height-4
                    for y in range(band["start"], band["end"]) if row_white[y] >= width*0.9]
    top = max(top_rules)+1 if top_rules else 0
    bottom = min(bottom_rules) if bottom_rules else height
    rows = [(top, inner[0]["start"]), (inner[0]["end"], inner[1]["start"]),
            (inner[1]["end"], inner[2]["start"]), (inner[2]["end"], bottom)]
    cells = []
    names = list(CELL_PARTS)
    for row, ((y0, y1), count) in enumerate(zip(rows, (2, 4, 2, 4))):
        # Real dividers run through essentially the full row. The stronger
        # vertical threshold prevents pale wings or limbs from being mistaken
        # for an extra gutter after color degradation across image edits.
        vertical = bands(white[y0:y1].sum(axis=0), int((y1-y0)*0.9), minimum_width=1)
        if len(vertical) != count+1:
            raise ValueError(f"row {row}: expected {count+1} vertical gutters, found {vertical}")
        for column in range(count):
            rect = [vertical[column]["end"], y0, vertical[column+1]["start"], y1]
            if rect[0] >= rect[2] or rect[1] >= rect[3]:
                raise ValueError(f"Invalid crop rectangle {rect}")
            cells.append({"name": names[len(cells)], "row": row, "column": column, "rect": rect})
    return cells


def marker_fields(cell_name: str) -> list[tuple[str, int | None]]:
    part = CELL_PARTS[cell_name]
    if part == "torso":
        return [("neck", None), ("shoulders", 0), ("shoulders", 1), ("hips", 0), ("hips", 1)]
    if part in ("head", "left_forearm", "right_forearm", "left_boot", "right_boot"):
        return [("pivot", None)]
    return [("pivot", None), ("tip", None)]


def point_at(parts: dict, part: str, field: str, index: int | None) -> list[float]:
    value = parts[part][field]
    return list(value if index is None else value[index])


def point_key(part: str, field: str, index: int | None) -> str:
    return f"{part}.{field}" + (f".{index}" if index is not None else "")


def build_contract(payload: dict, binding: dict, marker_path: Path) -> dict:
    records = []
    extracted_keys = set()
    for cell_name, part in CELL_PARTS.items():
        entries = order_markers(cell_name, payload["pivots"][cell_name])
        fields = marker_fields(cell_name)
        if len(entries) != len(fields):
            raise ValueError(f"{cell_name}: marker count differs from the coordinate contract")
        for entry, (field, index) in zip(entries, fields):
            page = [float(value) for value in entry["center"]]
            if point_at(binding["parts"], part, field, index) != page:
                raise ValueError(f"{point_key(part, field, index)} differs from original extracted coordinates")
            extracted_keys.add(point_key(part, field, index))
            record = _record(binding, part, field, index, page, "extracted")
            record["extraction_cell"] = cell_name
            record["original_index"] = payload["pivots"][cell_name].index(entry)
            records.append(record)
    for part in binding["parts"]:
        for field in ("pivot", "tip"):
            if point_key(part, field, None) not in extracted_keys:
                records.append(_record(binding, part, field, None, point_at(binding["parts"], part, field, None), "calculated"))
    if len(records) != 29:
        raise ValueError("Expected 22 extracted and seven calculated coordinates")
    return {
        "schema_version": 1, "canvas": payload["canvas"],
        "mapping": "identity_page_coordinates; crop_local = page - crop_origin",
        "marker_json": "extracted_pivots.json",
        "marker_json_sha256": hashlib.sha256(marker_path.read_bytes()).hexdigest(),
        "marker_count": 22, "calculated_count": 7, "points": records,
    }


def _record(binding: dict, part: str, field: str, index: int | None, page: list, kind: str) -> dict:
    rect = binding["parts"][part]["rect"]
    return {"key": point_key(part, field, index), "part": part, "field": field,
            "index": index, "kind": kind, "page": page,
            "crop_local": [page[0] - rect[0], page[1] - rect[1]]}


def audit_binding(binding: dict, payload: dict) -> list[dict]:
    contract = binding.get("coordinate_contract", {})
    if contract.get("marker_count") != 22 or contract.get("calculated_count") != 7:
        raise ValueError("Missing exact 22-marker/seven-calculated-point coordinate contract")
    original = {}
    pivots = payload.get("pivots", {})
    if set(pivots) != set(CELL_PARTS):
        raise ValueError("Original extraction must contain exactly the twelve expected cells")
    for cell, part in CELL_PARTS.items():
        fields = marker_fields(cell)
        if len(pivots[cell]) != len(fields):
            raise ValueError(f"{cell}: original marker count differs from the coordinate contract")
        for entry, (field, index) in zip(order_markers(cell, pivots[cell]), fields):
            original[point_key(part, field, index)] = entry["center"]
    result = []
    seen = set()
    for item in contract["points"]:
        key = item["key"]
        if key != point_key(item["part"], item["field"], item["index"]):
            raise ValueError(f"{key}: incorrect coordinate field reference")
        if key in seen:
            raise ValueError(f"Duplicate coordinate {key}")
        seen.add(key)
        page = point_at(binding["parts"], item["part"], item["field"], item["index"])
        rect = binding["parts"][item["part"]]["rect"]
        local = [page[0] - rect[0], page[1] - rect[1]]
        if page != item["page"] or local != item["crop_local"]:
            raise ValueError(f"{key}: binding or crop-local coordinate differs from reference")
        if item["kind"] == "extracted" and page != original.get(key):
            raise ValueError(f"{key}: binding differs from original extracted marker")
        if item["kind"] != ("extracted" if key in original else "calculated"):
            raise ValueError(f"{key}: incorrect coordinate ownership")
        result.append({**item, "source_matches": True})
    if len(result) != 29 or sum(item["kind"] == "extracted" for item in result) != 22:
        raise ValueError("Coordinate reference is incomplete")
    expected_keys = set(original) | {point_key(part, field, None) for part in binding["parts"] for field in ("pivot", "tip")}
    if seen != expected_keys:
        raise ValueError("Coordinate reference does not cover exactly the expected 29 points")
    torso = binding["parts"]["torso"]
    for field, landmarks in (("pivot", "shoulders"), ("tip", "hips")):
        midpoint = [(torso[landmarks][0][i] + torso[landmarks][1][i])/2 for i in (0, 1)]
        if torso[field] != midpoint:
            raise ValueError(f"torso.{field}: differs from extracted {landmarks} midpoint")
    return result
