#!/usr/bin/env python3
"""Analyze, isolate, and remap the Armk manual-rigging atlas for testing.

This is deliberately a build artifact workflow. It does not modify the
production rig contract or any Godot scene.
"""

from __future__ import annotations

import argparse
import json
from collections import deque
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont


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
MARKER_RULE = "r<=40 and g>=220 and b>=220 and abs(g-b)<=30"
MAGENTA_RULE = "r>=180 and g<=80 and b>=170"


def near_white(pixel: tuple[int, int, int]) -> bool:
    return pixel[0] >= 245 and pixel[1] >= 245 and pixel[2] >= 245


def near_cyan(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    return r <= 40 and g >= 220 and b >= 220 and abs(g - b) <= 30


def near_magenta(pixel: tuple[int, int, int]) -> bool:
    r, g, b = pixel
    # Vertex slightly varies the magenta background and anti-aliases it into
    # the dark outline. The hue test is intentionally broader than the solid
    # background test, but the flood fill below limits removal to pixels that
    # are connected to the cell boundary.
    return (
        r >= 12
        and b >= 12
        and g <= 245
        and min(r, b) - g >= 8
        and abs(r - b) <= 75
    )


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
            bands.append({"start": index, "end": end, "max_count": max(values[index:end])})
        index = end
    return bands


def detect_row_spans(image: Image.Image) -> list[tuple[int, int]]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    white_counts = [
        sum(near_white(pixels[x, y]) for x in range(width))
        for y in range(height)
    ]
    bands = contiguous_bands(white_counts, int(width * 0.75))
    inner = [band for band in bands if band["start"] > 1 and band["end"] < height - 3]
    if len(inner) != 3:
        raise RuntimeError(
            f"Expected 3 internal horizontal gutters, found {len(inner)}: {inner}"
        )
    spans = [
        (0, inner[0]["start"]),
        (inner[0]["end"], inner[1]["start"]),
        (inner[1]["end"], inner[2]["start"]),
        (inner[2]["end"], height),
    ]
    if any(start >= end for start, end in spans):
        raise RuntimeError(f"Invalid row spans: {spans}")
    return spans


def detect_cells(image: Image.Image) -> list[dict[str, Any]]:
    from rig_coordinate_contract import detect_grid_cells
    return detect_grid_cells(image)


def detect_markers(image: Image.Image) -> list[dict[str, Any]]:
    rgb = image.convert("RGB")
    width, height = rgb.size
    pixels = rgb.load()
    mask = bytearray(width * height)
    for y in range(height):
        for x in range(width):
            if near_cyan(pixels[x, y]):
                mask[y * width + x] = 1

    seen = bytearray(width * height)
    components: list[dict[str, Any]] = []
    for start in range(width * height):
        if not mask[start] or seen[start]:
            continue
        queue: deque[int] = deque([start])
        seen[start] = 1
        points: list[int] = []
        while queue:
            index = queue.popleft()
            points.append(index)
            x = index % width
            y = index // width
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    if dx == 0 and dy == 0:
                        continue
                    nx = x + dx
                    ny = y + dy
                    if not (0 <= nx < width and 0 <= ny < height):
                        continue
                    neighbor = ny * width + nx
                    if mask[neighbor] and not seen[neighbor]:
                        seen[neighbor] = 1
                        queue.append(neighbor)

        if len(points) < 20:
            continue
        xs = [index % width for index in points]
        ys = [index // width for index in points]
        min_x, max_x = min(xs), max(xs)
        min_y, max_y = min(ys), max(ys)
        components.append(
            {
                "area": len(points),
                "bbox": [min_x, min_y, max_x + 1, max_y + 1],
                "center": [
                    round((min_x + max_x) / 2, 2),
                    round((min_y + max_y) / 2, 2),
                ],
            }
        )

    return sorted(components, key=lambda component: (component["center"][1], component["center"][0]))


def cell_by_name(cells: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    return {cell["name"]: cell for cell in cells}


def assign_marker_cells(
    markers: list[dict[str, Any]],
    cells: list[dict[str, Any]],
) -> dict[str, list[dict[str, Any]]]:
    assigned = {cell["name"]: [] for cell in cells}
    for marker in markers:
        x, y = marker["center"]
        matches = []
        for cell in cells:
            x0, y0, x1, y1 = cell["rect"]
            if x0 <= x < x1 and y0 <= y < y1:
                matches.append(cell["name"])
        if len(matches) != 1:
            raise RuntimeError(f"Could not assign marker {marker} to one cell: {matches}")
        assigned[matches[0]].append(marker)
    from rig_coordinate_contract import order_markers
    for name in assigned:
        assigned[name] = order_markers(name, assigned[name])
    return assigned


def remove_magenta(image: Image.Image) -> Image.Image:
    rgb = image.convert("RGB")
    width, height = rgb.size
    source = rgb.load()
    alpha = Image.new("L", (width, height), 255)
    alpha_pixels = alpha.load()

    # The atlas has multiple cells, so never classify across white gutters.
    # Within each cell, remove every magenta-like pixel, including enclosed
    # pockets inside hair loops or other concave silhouettes. The source art
    # intentionally contains no magenta design detail.
    for cell in detect_cells(rgb):
        x0, y0, x1, y1 = cell["rect"]
        for y in range(y0, y1):
            for x in range(x0, x1):
                if near_magenta(source[x, y]):
                    alpha_pixels[x, y] = 0

        # Remove the one to two pixel near-white anti-aliased gutter edge that
        # can remain just inside a detected cell boundary. The narrow frame
        # avoids touching intentional white wings or shoes farther inside.
        edge_guard = 2
        for x in range(x0, x1):
            for y in range(y0, min(y1, y0 + edge_guard)):
                if near_white(source[x, y]):
                    alpha_pixels[x, y] = 0
            for y in range(max(y0, y1 - edge_guard), y1):
                if near_white(source[x, y]):
                    alpha_pixels[x, y] = 0
        for y in range(y0, y1):
            for x in range(x0, min(x1, x0 + edge_guard)):
                if near_white(source[x, y]):
                    alpha_pixels[x, y] = 0
            for x in range(max(x0, x1 - edge_guard), x1):
                if near_white(source[x, y]):
                    alpha_pixels[x, y] = 0
    output = rgb.convert("RGBA")
    output.putalpha(alpha)
    output_pixels = output.load()
    for y in range(height):
        for x in range(width):
            if alpha_pixels[x, y] == 0:
                output_pixels[x, y] = (0, 0, 0, 0)
    return output


def crop_foreground(
    image: Image.Image,
    rect: list[int],
) -> tuple[Image.Image, list[int]]:
    x0, y0, x1, y1 = rect
    cell = image.crop((x0, y0, x1, y1))
    alpha = cell.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        raise RuntimeError(f"No foreground remained in cell {rect}")
    crop = cell.crop(bbox)
    return crop, [bbox[0], bbox[1], bbox[2], bbox[3]]


def draw_test_marker(draw: ImageDraw.ImageDraw, x: float, y: float, radius: int = 8) -> None:
    cx, cy = round(x), round(y)
    outer = radius + 3
    draw.ellipse(
        (cx - outer, cy - outer, cx + outer, cy + outer),
        fill=(0, 0, 0, 255),
    )
    draw.ellipse(
        (cx - radius, cy - radius, cx + radius, cy + radius),
        fill=(0, 255, 255, 255),
    )


def make_contact_sheet(
    test_crops: list[tuple[str, Image.Image]],
    output_path: Path,
) -> None:
    tile_width, tile_height = 320, 280
    columns = 4
    rows = (len(test_crops) + columns - 1) // columns
    sheet = Image.new("RGBA", (tile_width * columns, tile_height * rows), (32, 32, 38, 255))
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for index, (name, crop) in enumerate(test_crops):
        tile_x = (index % columns) * tile_width
        tile_y = (index // columns) * tile_height
        draw.text((tile_x + 8, tile_y + 8), name, fill=(255, 255, 255, 255), font=font)
        max_width = tile_width - 20
        max_height = tile_height - 42
        scale = min(max_width / crop.width, max_height / crop.height)
        new_size = (max(1, round(crop.width * scale)), max(1, round(crop.height * scale)))
        preview = crop.resize(new_size, Image.Resampling.NEAREST)
        px = tile_x + (tile_width - preview.width) // 2
        py = tile_y + 32 + (max_height - preview.height) // 2
        sheet.alpha_composite(preview, (px, py))
    sheet.convert("RGB").save(output_path)


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--marker-free", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()

    args.output_dir.mkdir(parents=True, exist_ok=True)
    source = Image.open(args.source).convert("RGB")
    marker_free = Image.open(args.marker_free).convert("RGB")
    raw_clean_size = marker_free.size
    if marker_free.size != source.size:
        marker_free = marker_free.resize(source.size, Image.Resampling.NEAREST)
    source_cells = detect_cells(source)
    marker_free_cells = detect_cells(marker_free)
    source_cell_map = cell_by_name(source_cells)
    marker_free_cell_map = cell_by_name(marker_free_cells)

    markers = detect_markers(source)
    if len(markers) != 22:
        raise RuntimeError(f"Expected 22 cyan marker components, found {len(markers)}")
    markers_by_cell = assign_marker_cells(markers, source_cells)

    foreground = remove_magenta(marker_free)
    isolated_dir = args.output_dir / "isolated"
    test_dir = args.output_dir / "isolated_test_markers"
    isolated_dir.mkdir(parents=True, exist_ok=True)
    test_dir.mkdir(parents=True, exist_ok=True)

    clean_rgba = foreground
    clean_width, clean_height = marker_free.size
    isolated_parts: dict[str, dict[str, Any]] = {}
    test_crops: list[tuple[str, Image.Image]] = []
    recomposed = marker_free.convert("RGBA")
    recomposed_draw = ImageDraw.Draw(recomposed)
    remapped_by_cell: dict[str, list[dict[str, Any]]] = {name: [] for name in CELL_NAMES}

    for cell in source_cells:
        name = cell["name"]
        source_rect = cell["rect"]
        clean_rect = marker_free_cell_map[name]["rect"]
        crop, crop_bbox = crop_foreground(clean_rgba, clean_rect)
        crop_path = isolated_dir / f"{name}.png"
        crop.save(crop_path)

        clean_x0, clean_y0, clean_x1, clean_y1 = clean_rect
        source_x0, source_y0, source_x1, source_y1 = source_rect
        source_cell_width = source_x1 - source_x0
        source_cell_height = source_y1 - source_y0
        clean_cell_width = clean_x1 - clean_x0
        clean_cell_height = clean_y1 - clean_y0
        crop_global_x0 = clean_x0 + crop_bbox[0]
        crop_global_y0 = clean_y0 + crop_bbox[1]
        test_crop = crop.copy()
        test_draw = ImageDraw.Draw(test_crop)
        remapped_items: list[dict[str, Any]] = []

        for marker in markers_by_cell[name]:
            source_x, source_y = marker["center"]
            clean_x, clean_y = source_x, source_y
            local_x = clean_x - crop_global_x0
            local_y = clean_y - crop_global_y0
            inside_crop = 0 <= local_x < crop.width and 0 <= local_y < crop.height
            if inside_crop:
                draw_test_marker(test_draw, local_x, local_y)
            draw_test_marker(recomposed_draw, clean_x, clean_y)
            remapped_items.append(
                {
                    "original_center": marker["center"],
                    "original_bbox": marker["bbox"],
                    "clean_page_center": [round(clean_x, 2), round(clean_y, 2)],
                    "isolated_local_center": [round(local_x, 2), round(local_y, 2)],
                    "inside_isolated_crop": inside_crop,
                }
            )
        remapped_by_cell[name] = remapped_items

        test_path = test_dir / f"{name}_test_markers.png"
        test_crop.save(test_path)
        test_crops.append((name, test_crop))
        isolated_parts[name] = {
            "source_cell_rect": source_rect,
            "marker_free_cell_rect": clean_rect,
            "crop_bbox_in_marker_free_cell": crop_bbox,
            "crop_global_top_left": [crop_global_x0, crop_global_y0],
            "crop_size": [crop.width, crop.height],
            "isolated_path": str(crop_path),
            "test_markers_path": str(test_path),
            "remapped_pivots": remapped_items,
        }

    contact_sheet_path = args.output_dir / "armk_isolated_contact_sheet_test_markers.png"
    make_contact_sheet(test_crops, contact_sheet_path)
    recomposed_path = args.output_dir / "armk_recomposed_test_markers.png"
    recomposed.convert("RGB").save(recomposed_path)

    normalized_path = args.output_dir / "armk_template_unmarked_vertex_normalized_1024x1536.png"
    source_width, source_height = source.size
    marker_free.save(normalized_path)

    original_coordinates = {
        "source_image": str(args.source),
        "canvas": [source_width, source_height],
        "coordinate_origin": "top-left, pixel-center coordinates",
        "marker_rule": MARKER_RULE,
        "marker_count": len(markers),
        "pivots": markers_by_cell,
    }
    remapped_coordinates = {
        "source_image": str(args.source),
        "marker_free_image": str(args.marker_free),
        "source_canvas": [source_width, source_height],
        "marker_free_canvas": [clean_width, clean_height],
        "transform": "identity page coordinates after one global canvas normalization; local = page - crop origin",
        "raw_marker_free_canvas": list(raw_clean_size),
        "pivots": remapped_by_cell,
    }
    manifest = {
        "purpose": "test-only manual atlas extraction and pivot remapping",
        "source_image": str(args.source),
        "marker_free_image": str(args.marker_free),
        "normalized_marker_free_image": str(normalized_path),
        "source_canvas": [source_width, source_height],
        "marker_free_canvas": [clean_width, clean_height],
        "marker_free_contains_cyan_components": len(detect_markers(marker_free)),
        "marker_rule": MARKER_RULE,
        "magenta_rule": MAGENTA_RULE,
        "source_cells": source_cells,
        "marker_free_cells": marker_free_cells,
        "original_pivots": markers_by_cell,
        "remapped_pivots": remapped_by_cell,
        "isolated_parts": isolated_parts,
        "contact_sheet": str(contact_sheet_path),
        "recomposed_test_markers": str(recomposed_path),
        "normalization_note": (
            "Provider output is globally normalized to the source canvas before all coordinate math. "
            "Page coordinates are preserved; isolated coordinates subtract only the crop origin."
        ),
    }
    write_json(args.output_dir / "armk_pivots_original.json", original_coordinates)
    write_json(args.output_dir / "armk_pivots_remapped.json", remapped_coordinates)
    write_json(args.output_dir / "armk_atlas_test_manifest.json", manifest)

    print(json.dumps({
        "marker_count": len(markers),
        "source_canvas": [source_width, source_height],
        "marker_free_canvas": [clean_width, clean_height],
        "marker_free_cyan_components": len(detect_markers(marker_free)),
        "contact_sheet": str(contact_sheet_path),
        "recomposed_test_markers": str(recomposed_path),
        "original_coordinates": str(args.output_dir / "armk_pivots_original.json"),
        "remapped_coordinates": str(args.output_dir / "armk_pivots_remapped.json"),
        "manifest": str(args.output_dir / "armk_atlas_test_manifest.json"),
    }, indent=2))


if __name__ == "__main__":
    main()
