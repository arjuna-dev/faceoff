#!/usr/bin/env python3
"""Decide which isolated parts need repair from the part map alone, with no LLM.

Every part owns one known color, and each part should be one solid region that
touches its skeletal neighbors only at a joint. Three geometric cues show that
another part was drawn in front of it and hid some of its surface:

- split: the part falls into several large pieces, so something separates them;
- holes: the part fully encloses areas that are not its own;
- wraps: most of another part's outline touches this part, so that other part
  sits in front of it.

For each flagged part the hidden area is the region of those occluding parts
(and enclosed holes) inside the part's convex hull. That region is what the
repair step asks the model to complete.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image


MIN_PIECE_PX = 300
MIN_HOLE_PX = 150
# A neighbor whose outline touches this part for at least this share is in front of it.
WRAP_SHARE = 0.3
# Skeletal neighbors touch at their joint by design, so they need a larger share.
NEIGHBOR_WRAP_SHARE = 0.5
# Beside a wrapped neighbor only a band this wide is treated as hidden surface.
OCCLUSION_BAND_PX = 40
# A piece smaller than this share of its part is segmentation noise, not a split.
MIN_PIECE_SHARE = 0.05
# Repairs smaller than this are not worth a model call and a risk of new art.
MIN_FILL_PX = 1500
MIN_FILL_SHARE = 0.04
MAGENTA = (255, 0, 255)


def page_masks(analysis: dict[str, Any], core: bool = False) -> dict[str, np.ndarray]:
    """Page-sized part masks; core=True uses exclusive ownership without joint overlaps."""
    width, height = analysis["canvas"]
    masks = {}
    for name, metadata in analysis["parts"].items():
        mask = np.zeros((height, width), dtype=bool)
        if metadata.get("status") == "EXTRACTED":
            use_core = core and "core_image" in metadata
            with Image.open(metadata["core_image"] if use_core else metadata["image"]) as image:
                alpha = np.asarray(image.convert("RGBA"))[:, :, 3] > 0
            x, y = metadata["core_crop_origin"] if use_core else metadata["crop_origin"]
            mask[y:y + alpha.shape[0], x:x + alpha.shape[1]] = alpha
        masks[name] = mask
    return masks


def _outline(mask: np.ndarray) -> np.ndarray:
    return mask & ~cv2.erode(mask.astype(np.uint8), np.ones((3, 3), dtype=np.uint8)).astype(bool)


def _touching(mask: np.ndarray, other: np.ndarray) -> np.ndarray:
    return mask & cv2.dilate(other.astype(np.uint8), np.ones((3, 3), dtype=np.uint8)).astype(bool)


def _enclosed(mask: np.ndarray) -> np.ndarray:
    count, labels = cv2.connectedComponents((~mask).astype(np.uint8), connectivity=4)
    border = set(np.unique(np.concatenate((labels[0], labels[-1], labels[:, 0], labels[:, -1]))))
    return np.isin(labels, [index for index in range(1, count) if index not in border])


def _hull(mask: np.ndarray) -> np.ndarray:
    points = cv2.findNonZero(mask.astype(np.uint8))
    hull = np.zeros(mask.shape, dtype=np.uint8)
    if points is not None:
        cv2.fillConvexPoly(hull, cv2.convexHull(points), 1)
    return hull.astype(bool)


def detect(analysis: dict[str, Any]) -> dict[str, Any]:
    from render_whole_character_poses import draw_order
    from whole_character_workflow import JOINTS
    neighbors = {frozenset((first, second)) for _, first, second in JOINTS}
    layers = draw_order(analysis)
    masks = page_masks(analysis, core=True)
    height, width = next(iter(masks.values())).shape
    # A joint's overlap circle already carries art for the two parts of that
    # joint, so those two never need repair there; any other part still does.
    yy, xx = np.mgrid[0:height, 0:width]
    circles_by_part: dict[str, np.ndarray] = {}
    for overlap in analysis.get("joint_overlaps", []):
        cx, cy = overlap["center"]
        disk = (xx - cx) ** 2 + (yy - cy) ** 2 <= overlap["radius_px"] ** 2
        for member in overlap["connects"]:
            circles_by_part[member] = circles_by_part.get(member, np.zeros((height, width), dtype=bool)) | disk
    grip = analysis["parts"].get("held_item", {}).get("attached_to")
    results: dict[str, Any] = {}
    for name, own in masks.items():
        if not own.any() or name not in layers:
            continue
        covered_by_overlaps = circles_by_part.get(name, np.zeros((height, width), dtype=bool))
        # Only parts drawn in front of this one can hide it. A held item rides
        # rigidly on its hand, so the grip never uncovers.
        front = [other for other in layers[layers.index(name) + 1:] if masks.get(other) is not None
                 and masks[other].any() and not (name == "held_item" and other == grip)]
        area = int(own.sum())
        findings: list[str] = []
        occluders: set[str] = set()
        split_by: set[str] = set()
        count, pieces, stats, _ = cv2.connectedComponentsWithStats(own.astype(np.uint8), connectivity=8)
        minimum_piece = max(MIN_PIECE_PX, int(area * MIN_PIECE_SHARE))
        large = [index for index in range(1, count) if stats[index, cv2.CC_STAT_AREA] >= minimum_piece]
        if len(large) > 1:
            between = sorted(other for other in front if sum(
                bool(_touching(pieces == index, masks[other]).any()) for index in large) >= 2)
            if between:
                occluders.update(between)
                split_by.update(between)
                findings.append(f"split into {len(large)} pieces by {', '.join(between)}")
        # Holes count only where a part in front covers them; an enclosed
        # background gap is a real see-through gap, not missing art.
        enclosed = _enclosed(own)
        hole_count, hole_labels, hole_stats, _ = cv2.connectedComponentsWithStats(enclosed.astype(np.uint8), connectivity=4)
        front_union = np.any([masks[other] for other in front], axis=0) if front else np.zeros_like(own)
        holes = np.zeros_like(own)
        for index in range(1, hole_count):
            hole = hole_labels == index
            if hole_stats[index, cv2.CC_STAT_AREA] >= MIN_HOLE_PX and (hole & front_union).mean() > 0:
                holes |= hole & front_union
        if holes.any():
            inside = sorted(other for other in front if (masks[other] & holes).any())
            occluders.update(inside)
            findings.append(f"enclosed area of {int(holes.sum())} px covered by {', '.join(inside)}")
        wraps = {}
        for other in front:
            mask = masks[other]
            if mask.sum() < MIN_PIECE_PX:
                continue
            outline = _outline(mask)
            share = float(_touching(outline, own).sum()) / max(1, int(outline.sum()))
            limit = NEIGHBOR_WRAP_SHARE if frozenset((name, other)) in neighbors else WRAP_SHARE
            if share >= limit:
                wraps[other] = round(share, 2)
        if wraps:
            occluders.update(wraps)
            findings.append("wraps around " + ", ".join(
                f"{other} ({share:.0%} of its outline touches this part)" for other, share in wraps.items()))
        if not findings:
            continue
        hull = _hull(own)
        # Hidden surface lies next to the part: a band beside it, never the
        # whole silhouette of the limb in front.
        near = cv2.distanceTransform((~own).astype(np.uint8), cv2.DIST_L2, 3) <= OCCLUSION_BAND_PX
        fill = holes & ~own
        covered_by: dict[str, int] = {}
        for other in sorted(occluders):
            region = hull & masks[other] & near
            if other in split_by:
                region |= hull & masks[other]
            region = (region | (holes & masks[other])) & ~own & ~covered_by_overlaps
            fill |= region
            covered_by[other] = int(region.sum())
        fill &= ~covered_by_overlaps
        minimum_fill = max(MIN_FILL_PX, int(area * MIN_FILL_SHARE))
        if int(fill.sum()) < minimum_fill:
            continue
        results[name] = {"reason": "; ".join(findings), "occluders": sorted(occluders),
                         "covered_by": {key: value for key, value in covered_by.items() if value},
                         "fill_pixels": int(fill.sum()), "fill": fill}
    return results


def write_detection(analysis_path: Path, output_dir: Path) -> dict[str, Any]:
    """Save detection results, fill masks and one overlay per flagged part."""
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    output_dir.mkdir(parents=True, exist_ok=True)
    found = detect(analysis)
    masks = page_masks(analysis, core=True)
    parts = {}
    for name, entry in found.items():
        fill_path = output_dir / f"{name}.fill.png"
        Image.fromarray(entry["fill"].astype(np.uint8) * 255, mode="L").save(fill_path)
        overlay = np.full((*entry["fill"].shape, 3), 40, dtype=np.uint8)
        for other, mask in masks.items():
            overlay[mask] = (90, 90, 90)
        overlay[masks[name]] = (255, 255, 255)
        overlay[entry["fill"]] = MAGENTA
        overlay_path = output_dir / f"{name}.overlay.png"
        Image.fromarray(overlay, mode="RGB").save(overlay_path)
        parts[name] = {key: value for key, value in entry.items() if key != "fill"}
        parts[name].update({"fill_mask": str(fill_path.resolve()), "overlay": str(overlay_path.resolve())})
    result = {"method": ("geometric: split pieces, covered enclosed areas and wrapped neighbors, counting only "
                         "parts drawn in front, outside joint overlaps"),
              "thresholds": {"min_piece_px": MIN_PIECE_PX, "min_piece_share": MIN_PIECE_SHARE,
                             "min_hole_px": MIN_HOLE_PX, "wrap_share": WRAP_SHARE,
                             "neighbor_wrap_share": NEIGHBOR_WRAP_SHARE,
                             "occlusion_band_px": OCCLUSION_BAND_PX, "min_fill_px": MIN_FILL_PX,
                             "min_fill_share": MIN_FILL_SHARE},
              "parts_needing_repair": parts}
    (output_dir / "detection.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result
