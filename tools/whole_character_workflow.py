#!/usr/bin/env python3
"""One run of the whole-character rig workflow, for human inspection.

Stages: character generation, clean segmentation, pivots marked on that map,
part isolation, geometric repair detection, part repair and an assembled rest
pose. Every run writes report.html with each stage's prompts and outputs.
Each provider stage runs once; saved inputs may be resumed or continued.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont


BACKGROUND_HEX = "#FF00FF"
MARKER_HEX = "#00FFFF"
PART_COLORS: dict[str, str] = {
    "head_neck": "#F44336",
    "torso_pelvis": "#FFC107",
    "near_upper_arm": "#4CAF50",
    "near_forearm_hand": "#1976D2",
    "far_upper_arm": "#FF6D00",
    "far_forearm_hand": "#CDDC39",
    "near_thigh": "#009688",
    "near_shin": "#607D8B",
    "near_foot": "#FFFFFF",
    "far_thigh": "#795548",
    "far_shin": "#8BC34A",
    "far_foot": "#3F51B5",
    "back_accessory": "#1B5E20",
    "held_item": "#000000",
}
# Optional parts may be absent; a character without wings, a cape or a weapon has none.
OPTIONAL_PARTS = {"back_accessory", "held_item"}
JOINTS: list[tuple[str, str, str]] = [
    ("neck", "head_neck", "torso_pelvis"),
    ("near_shoulder", "torso_pelvis", "near_upper_arm"),
    ("near_elbow", "near_upper_arm", "near_forearm_hand"),
    ("far_shoulder", "torso_pelvis", "far_upper_arm"),
    ("far_elbow", "far_upper_arm", "far_forearm_hand"),
    ("near_hip", "torso_pelvis", "near_thigh"),
    ("near_knee", "near_thigh", "near_shin"),
    ("near_ankle", "near_shin", "near_foot"),
    ("far_hip", "torso_pelvis", "far_thigh"),
    ("far_knee", "far_thigh", "far_shin"),
    ("far_ankle", "far_shin", "far_foot"),
]


# Map fragments smaller than this are misalignment noise, merged into a neighbor.
MIN_FRAGMENT_PX = 300
MIN_FRAGMENT_SHARE = 0.03
EDGE_RING_PX = 5
# A model's pivot dot farther than this from the parts' contact line is ignored.
MAX_DOT_TO_CONTACT_PX = 60
# Bone-based ownership fixes: past-the-joint margin, and how much nearer the
# counterpart limb's bone a pixel must be before it switches sides.
BEYOND_JOINT_PX = 8
COUNTERPART_BONE_RATIO = 0.6
COUNTERPART_MIN_PX = 25
# The neck is this share of the shoulder width above the shoulders' midpoint.
NECK_ABOVE_SHOULDERS = 0.15
# A sleeve is claimed by its arm within this multiple of the arm's half-width.
SLEEVE_WIDTH_SCALE = 1.15
# Isolated foreground specks smaller than this are background noise.
MIN_ARTWORK_SPECK_PX = 64
# A model-drawn canvas frame up to this thick is replaced with background.
MAX_FRAME_PX = 32
FRAME_EDGE_PX = 3
# Joint overlap circle: radius = scale x the child part's half-width near the
# pivot, clamped. JOINTS lists (joint, parent, child).
JOINT_PROBE_PX = 80
JOINT_OVERLAP_SCALE = 1.5
JOINT_OVERLAP_MIN_PX = 32
JOINT_OVERLAP_MAX_PX = 100


def rgb(hex_color: str) -> tuple[int, int, int]:
    return tuple(int(hex_color[index:index + 2], 16) for index in (1, 3, 5))


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


STYLE_IMAGE_LABEL = ("STYLE REFERENCE ONLY. Copy only how this image is rendered, never what it shows. "
                     "Do not copy its character:")
STYLE_IMAGE_RULE = (
    "STYLE REFERENCE: the attached style image shows only the target rendering style: linework weight, "
    "outline color, shading method, pixel texture, color treatment and level of detail. Replicate only "
    "that style. Do not copy anything it depicts: no face, hair, body type, clothing, accessories, "
    "markings, colors of specific items, pose, composition, layout, background or text. Every "
    "feature of the new character comes only from the character brief below.")
# Shared by every character; the brief only describes identity.
ART_DIRECTION = (
    "ART STYLE: detailed hand-pixelled 1990s arcade fighter sprite art, crisp dark colored outlines, "
    "clustered pixel shading, readable anatomy and clothing at game scale. The pixel texture is slight "
    "and fine, drawn at high resolution: not chunky, blocky or low-resolution pixel art, and not smooth "
    "anime, cel-shaded or painterly art. Avoid photorealistic rendering, glossy 3D, soft concept art, "
    "modern fashion illustration, scenery, cast shadows, labels, text or extra subjects.")
PART_GUIDANCE = json.loads((Path(__file__).resolve().parents[1]
                            / "prompts/workflows/whole_character_part_guidance.json").read_text(encoding="utf-8"))


def write_character_prompt(path: Path, identity: str, style_image: bool = False) -> None:
    path.write_text(
        "Create ONE complete, coherent adult fighting-game character from head to feet, for a 2D "
        "cut-out rig where every body part will be separated and animated independently.\n"
        "POSE: the character faces SCREEN RIGHT in a relaxed, balanced three-quarter stance. Both arms "
        "hang down, slightly open and away from the body, with elbows a little bent, so that clear "
        "background is visible between each arm and the torso and neither hand touches the body. The "
        "legs stand apart with clear background between them, knees slightly bent, both feet flat on "
        "the ground. Ideally no body part overlaps another: keep the head, both arms, both legs and "
        "both feet visibly separated from each other and from the torso, and keep accessories from "
        "covering other body parts. Keep the whole character inside the canvas with clear background "
        "around every extremity and a visible margin. Maintain believable adult head, torso and limb "
        "proportions.\n"
        "Draw a SINGLE assembled character, with no detached pieces, guides, joint dots, labels, grids "
        "or reference panels. Use a flat, uniform " + BACKGROUND_HEX + " magenta background. Do not use "
        "that magenta or " + MARKER_HEX + " cyan anywhere in the character.\n\n"
        + ART_DIRECTION + "\n\n"
        + (STYLE_IMAGE_RULE + "\n\n" if style_image else "")
        + "CHARACTER BRIEF:\n" + identity.strip() + "\n",
        encoding="utf-8",
    )


def _part_lines() -> str:
    return "\n".join(f"- {name}: {color} = {PART_GUIDANCE[name]}" for name, color in PART_COLORS.items())


def write_segmentation_prompt(path: Path) -> None:
    path.write_text(
        "The attached image is the AUTHORITATIVE complete character. Return a BODY-PART segmentation "
        "map of this SAME image, at exactly the same pixel dimensions and positions.\n\n"
        "This is body-part segmentation, NOT object or clothing segmentation. Each colored region is one "
        "whole body segment of a 2D cut-out rig, together with everything worn on it. Clothing, shoes, "
        "sandals, socks, gloves, sleeves, trouser legs, shorts and jewelry never get their own region: "
        "they take the color of the body segment they cover. A foot region is the whole foot with its "
        "footwear; a thigh region is the thigh with the part of the shorts, trousers or skirt over it; "
        "an upper arm region is the upper arm with its sleeve. A garment that spans both legs is split "
        "down the middle between the two legs.\n\n"
        "Keep every visible outer contour, silhouette and pose pixel-aligned with the reference. Do not "
        "redraw, resize, rotate, shift, add, remove, duplicate or invent anything. This is a flat data "
        "mask, not a new illustration: one solid color per region, with no shading, outlines, gradients, "
        "texture, markers, dots, labels or text. Keep all background solid " + BACKGROUND_HEX + ".\n\n"
        "BODY SEGMENTS (exact hex color = what it contains):\n" + _part_lines() + "\n\n"
        "The character faces screen right. NEAR limbs are the ones on the screen-LEFT side of the body "
        "(closer to the camera); FAR limbs are on the screen-RIGHT side. The near arm and the near leg "
        "are on the same side. Each upper arm starts at its shoulder, even under a sleeve, and ends at "
        "its elbow, where its forearm and hand begin. Each thigh runs hip to knee, each shin knee to "
        "ankle, and each foot is everything below the ankle. The pelvis and waistband belong to the "
        "torso; each thigh starts below them at its hip joint. Anything attached to the head, such as "
        "hair or a beard, belongs to the head, even where it hangs over the torso. Anything held in a "
        "hand, such as a weapon, staff or tool, is held_item, even where it crosses other parts; the "
        "hand holding it stays forearm and hand. Anything attached to the back that sits behind the "
        "torso and the far arm belongs to back_accessory; if the character has nothing like that, do not "
        "use that color at all. Assign every visible character pixel to exactly one segment. Preserve "
        "the original silhouette exactly.\n\n"
        "Return only the segmentation image.\n",
        encoding="utf-8",
    )


def write_pivot_prompt(path: Path) -> None:
    joint_lines = "\n".join(f"- {name}: where {first} meets {second}" for name, first, second in JOINTS)
    path.write_text(
        "The attached image is a flat body-part color map of a character for a 2D cut-out rig. Return "
        "the SAME image, unchanged in every pixel, except for adding joint markers.\n\n"
        "BODY PART COLORS:\n" + "\n".join(f"- {name}: {color}" for name, color in PART_COLORS.items())
        + "\n\nAdd exactly " + str(len(JOINTS)) + " small, filled " + MARKER_HEX + " cyan circles "
        "(about 8 pixels in diameter), one at each joint below. Center each circle on the boundary "
        "where its two colors meet, at the anatomical rotation point, so it touches both colors:\n"
        + joint_lines + "\n\n"
        "Do not add any other marks, do not move or recolor anything, and do not use cyan anywhere "
        "else. Mark only these " + str(len(JOINTS)) + " joints: no wrists, fingers, toes, props or "
        "other points. Return only the marked image.\n",
        encoding="utf-8",
    )


# Aspect ratios the image model can return; requests use the one nearest the source.
SUPPORTED_ASPECTS = ("1:1", "2:3", "3:2", "3:4", "4:3", "4:5", "5:4", "9:16", "16:9", "21:9")


def aspect_ratio_for(path: Path) -> str:
    with Image.open(path) as image:
        ratio = image.width / image.height
    return min(SUPPORTED_ASPECTS, key=lambda item: abs(
        np.log(int(item.split(":")[0]) / int(item.split(":")[1])) - np.log(ratio)))


def open_guide_map(path: Path, shape: tuple[int, ...], label: str, record: dict[str, Any]) -> np.ndarray:
    """Open a model-made guide map at the source size.

    The model returns fixed sizes per aspect ratio. Guide maps only decide
    ownership and pivots, so they are resized with nearest neighbor when needed;
    the source artwork itself is never resampled.
    """
    image = Image.open(path).convert("RGB")
    height, width = shape[:2]
    if image.size != (width, height):
        if abs(image.width / image.height - width / height) > 0.02:
            raise ValueError(f"{label} map {image.size} has a different aspect ratio than the source {(width, height)}")
        record[label] = {"from": list(image.size), "to": [width, height]}
        image = image.resize((width, height), Image.Resampling.NEAREST)
    return np.asarray(image).copy()


def open_rgb(path: Path) -> np.ndarray:
    image = Image.open(path).convert("RGB")
    return np.asarray(image).copy()


def sample_background(image: np.ndarray) -> tuple[np.ndarray, float, np.ndarray]:
    height, width = image.shape[:2]
    if min(height, width) < 128:
        raise ValueError("Image is too small to inspect")
    edge = np.concatenate((image[0], image[-1], image[:, 0], image[:, -1])).astype(np.float32)
    color = np.median(edge, axis=0)
    expected = np.array(rgb(BACKGROUND_HEX), dtype=np.float32)
    if float(np.linalg.norm(color - expected)) > 80:
        raise ValueError(f"Image border median {color.round().tolist()} is not close to {BACKGROUND_HEX}")
    edge_distances = np.linalg.norm(edge - color, axis=1)
    tolerance = float(max(18.0, min(38.0, np.percentile(edge_distances, 85) + 8.0)))
    distance = np.linalg.norm(image.astype(np.float32) - color, axis=2)
    candidate = distance <= tolerance
    count, labels = cv2.connectedComponents(candidate.astype(np.uint8), connectivity=8)
    connected = np.zeros((height, width), dtype=bool)
    if count > 1:
        edge_labels = np.unique(np.concatenate((labels[0], labels[-1], labels[:, 0], labels[:, -1])))
        connected = candidate & np.isin(labels, edge_labels[edge_labels != 0])
    if int(connected.sum()) < image.shape[0] * image.shape[1] * 0.1:
        raise ValueError("Less than 10% of the canvas is border-connected magenta")
    # Same sampled tone removes enclosed background pockets too. The character
    # prompt excludes magenta costume pixels because color alone cannot tell
    # costume magenta from an enclosed background hole.
    background = candidate
    foreground = ~background
    # Compression specks in the background are not artwork.
    count, labels, stats, _ = cv2.connectedComponentsWithStats(foreground.astype(np.uint8), connectivity=8)
    specks = [index for index in range(1, count) if stats[index, cv2.CC_STAT_AREA] < MIN_ARTWORK_SPECK_PX]
    if specks:
        foreground &= ~np.isin(labels, specks)
    return color, tolerance, foreground


def decode_segmentation(image: np.ndarray) -> tuple[np.ndarray, dict[str, Any]]:
    colors = [BACKGROUND_HEX, *PART_COLORS.values(), MARKER_HEX]
    palette = np.array([rgb(color) for color in colors], dtype=np.float32)
    pixels = image.reshape(-1, 3).astype(np.float32)
    classified = np.empty(len(pixels), dtype=np.int16)
    for start in range(0, len(pixels), 100_000):
        block = pixels[start:start + 100_000]
        squared = np.sum((block[:, None, :] - palette[None, :, :]) ** 2, axis=2)
        nearest = np.argmin(squared, axis=1)
        best = squared[np.arange(len(block)), nearest]
        classified[start:start + len(block)] = np.where(best <= 60**2, nearest, -1)
    labels = classified.reshape(image.shape[:2])
    names = ["background", *PART_COLORS, "joint_marker"]
    counts = {name: int((labels == index).sum()) for index, name in enumerate(names)}
    counts["unclassified"] = int((labels == -1).sum())
    return labels, {"palette": {"background": BACKGROUND_HEX, **PART_COLORS, "joint_marker": MARKER_HEX}, "pixel_counts": counts}


def find_joint_markers(labels: np.ndarray) -> list[dict[str, Any]]:
    marker_id = len(PART_COLORS) + 1
    mask = (labels == marker_id).astype(np.uint8)
    count, components, stats, centroids = cv2.connectedComponentsWithStats(mask, connectivity=8)
    markers: list[dict[str, Any]] = []
    for index in range(1, count):
        x, y, width, height, area = [int(value) for value in stats[index]]
        if area < 5:
            continue
        markers.append({"center": [round(float(centroids[index][0]), 2), round(float(centroids[index][1]), 2)],
                        "bbox": [x, y, x + width, y + height], "area": area})
    return sorted(markers, key=lambda item: (item["center"][1], item["center"][0]))


def nearest_part_distances(part_masks: dict[str, np.ndarray]) -> dict[str, np.ndarray]:
    return {name: cv2.distanceTransform((~mask).astype(np.uint8), cv2.DIST_L2, 3)
            for name, mask in part_masks.items()}


def assign_joints(markers: list[dict[str, Any]], part_masks: dict[str, np.ndarray]) -> tuple[dict[str, Any], list[str]]:
    if len(markers) < len(JOINTS):
        return {}, [f"Expected at least {len(JOINTS)} physical joint markers, found {len(markers)}"]
    if len(markers) > 16:
        return {}, [f"Found {len(markers)} marker components; too many for reliable diagnostic assignment"]
    distances = nearest_part_distances(part_masks)
    height, width = next(iter(part_masks.values())).shape
    cost = np.zeros((len(JOINTS), len(markers)), dtype=float)
    for row, (_, first, second) in enumerate(JOINTS):
        for column, marker in enumerate(markers):
            x = max(0, min(width - 1, int(round(marker["center"][0]))))
            y = max(0, min(height - 1, int(round(marker["center"][1]))))
            a = float(distances[first][y, x])
            b = float(distances[second][y, x])
            cost[row, column] = max(a, b) * 2.0 + a + b

    # Match the required joints to the best eleven marker components. Extra
    # full-size dots remain a review failure, but need not prevent diagnostic
    # poses when the eleven anatomical pairs can be assigned unambiguously.
    dp: dict[int, tuple[float, list[int]]] = {0: (0.0, [])}
    for row in range(len(JOINTS)):
        next_dp: dict[int, tuple[float, list[int]]] = {}
        for bitset, (total, used) in dp.items():
            for column in range(len(markers)):
                if bitset & (1 << column):
                    continue
                candidate = (total + cost[row, column], used + [column])
                key = bitset | (1 << column)
                if key not in next_dp or candidate[0] < next_dp[key][0]:
                    next_dp[key] = candidate
        dp = next_dp
    _, assignment = min(dp.values(), key=lambda item: item[0])
    result: dict[str, Any] = {}
    warnings: list[str] = []
    unused = [marker["center"] for index, marker in enumerate(markers) if index not in assignment]
    if unused:
        warnings.append(f"Ignored {len(unused)} extra joint markers at {unused}; poses are diagnostic only")
    for row, column in enumerate(assignment):
        name, first, second = JOINTS[row]
        marker = markers[column]
        x = max(0, min(width - 1, int(round(marker["center"][0]))))
        y = max(0, min(height - 1, int(round(marker["center"][1]))))
        member_distances = {first: round(float(distances[first][y, x]), 2),
                            second: round(float(distances[second][y, x]), 2)}
        result[name] = {"center": marker["center"], "connects": [first, second],
                        "distance_to_parts_px": member_distances, "marker_bbox": marker["bbox"]}
        if max(member_distances.values()) > 24:
            warnings.append(f"{name}: marker is more than 24px from a connected part: {member_distances}")
    return result, warnings


def extend_joint_disks(labels: np.ndarray) -> np.ndarray:
    result = labels.copy()
    marker_id = len(PART_COLORS) + 1
    valid = (result >= 1) & (result <= len(PART_COLORS))
    if not valid.any():
        return result
    marker_area = (result == marker_id).astype(np.uint8)
    # Antialiasing around a cyan disk often falls outside the exact palette.
    # Assign only that narrow ring to one of its adjacent parts, preserving the
    # corresponding pixels of the first image when the part is extracted.
    marker_and_outline = cv2.dilate(marker_area, np.ones((3, 3), dtype=np.uint8)) != 0
    marker_pixels = marker_and_outline & ~valid
    if marker_pixels.any():
        distances = np.stack([
            cv2.distanceTransform((result != index).astype(np.uint8), cv2.DIST_L2, 3)[marker_pixels]
            for index in range(1, len(PART_COLORS) + 1)
        ], axis=1)
        result[marker_pixels] = np.argmin(distances, axis=1).astype(np.int16) + 1
    return result


def _font() -> ImageFont.ImageFont:
    return ImageFont.load_default()


def strip_uniform_frame(path: Path, raw_copy: Path) -> dict[str, Any] | None:
    """Replace a thin, uniform frame a model drew around the canvas with the background.

    Only a frame is touched: every ring outside the first magenta ring must be
    a single flat color. The raw model output is kept next to the result.
    """
    image = open_rgb(path)
    height, width = image.shape[:2]
    expected = np.array(rgb(BACKGROUND_HEX), dtype=np.float32)

    def ring(depth: int) -> np.ndarray:
        return np.concatenate((image[depth, depth:width - depth], image[height - 1 - depth, depth:width - depth],
                               image[depth:height - depth, depth], image[depth:height - depth, width - 1 - depth]))

    for depth in range(MAX_FRAME_PX + 1):
        color = np.median(ring(depth).astype(np.float32), axis=0)
        if float(np.linalg.norm(color - expected)) <= 80:
            break
    else:
        return None
    if depth == 0:
        return None
    frame = np.concatenate([ring(index) for index in range(depth)]).astype(np.float32)
    if float(np.median(np.linalg.norm(frame - np.median(frame, axis=0), axis=1))) > 20:
        return None
    # The frame's inner edge is anti-aliased: widen the band past it and take
    # the fill color from clean background a few pixels further in.
    color = np.median(ring(depth + FRAME_EDGE_PX + 2).astype(np.float32), axis=0)
    depth += FRAME_EDGE_PX
    shutil.copy2(path, raw_copy)
    image[:depth], image[height - depth:] = color, color
    image[:, :depth], image[:, width - depth:] = color, color
    Image.fromarray(image, mode="RGB").save(path)
    return {"frame_px": depth, "frame_rgb": np.median(frame, axis=0).round().tolist(),
            "replaced_with_rgb": color.round().tolist(), "raw_output": str(raw_copy.resolve())}


LIMB_CHAINS = {"arm": ("upper_arm", "forearm_hand"), "leg": ("thigh", "shin", "foot")}
# (parent, child, axis start joint, joint) for the "past the joint belongs to the child" rule.
BONES = [(side + "_" + parent, side + "_" + child, side + "_" + start, side + "_" + joint)
         for side in ("near", "far")
         for parent, child, start, joint in (("upper_arm", "forearm_hand", "shoulder", "elbow"),
                                              ("thigh", "shin", "hip", "knee"),
                                              ("shin", "foot", "knee", "ankle"))]
# Left and right counterparts, with the bone each one runs along.
PAIRED_BONES = [(part, start, end) for part, start, end in (("upper_arm", "shoulder", "elbow"),
                                                             ("thigh", "hip", "knee"),
                                                             ("shin", "knee", "ankle"))]


def enforce_near_far_sides(labels: np.ndarray) -> tuple[np.ndarray, list[str]]:
    """Facing screen right, the near limbs are on screen-left. Swap a chain that is not."""
    index = {name: position for position, name in enumerate(PART_COLORS, start=1)}
    swapped = []
    for chain, members in LIMB_CHAINS.items():
        root = members[0]
        near = np.nonzero(labels == index["near_" + root])[1]
        far = np.nonzero(labels == index["far_" + root])[1]
        if len(near) and len(far) and near.mean() > far.mean():
            result = labels.copy()
            for member in members:
                result[labels == index["near_" + member]] = index["far_" + member]
                result[labels == index["far_" + member]] = index["near_" + member]
            labels = result
            swapped.append(chain)
    return labels, swapped


def _segment_distance(points: np.ndarray, start: np.ndarray, end: np.ndarray) -> np.ndarray:
    direction = end - start
    t = np.clip(((points - start) @ direction) / max(1e-6, float(direction @ direction)), 0.0, 1.0)
    return np.linalg.norm(points - (start + t[:, None] * direction), axis=1)


def correct_ownership_with_bones(labels: np.ndarray, joints: dict[str, Any]) -> tuple[np.ndarray, dict[str, int]]:
    """Use the skeleton to fix ownership the map got wrong.

    Pixels of a limb that lie past its end joint along the bone belong to the
    next part (toes the map gave to the shin are foot). A pixel much closer to
    the counterpart limb's bone than to its own belongs to the counterpart
    (shorts painted as one thigh are split between both).
    """
    index = {name: position for position, name in enumerate(PART_COLORS, start=1)}
    result = labels.copy()
    moved: dict[str, int] = {}
    center = {name: np.array(joint["center"], dtype=np.float32) for name, joint in joints.items()}
    for parent, child, start, joint in BONES:
        if start not in center or joint not in center:
            continue
        axis = center[joint] - center[start]
        length = float(np.linalg.norm(axis))
        if length < 1:
            continue
        ys, xs = np.nonzero(result == index[parent])
        points = np.stack((xs, ys), axis=1).astype(np.float32)
        beyond = ((points - center[joint]) @ (axis / length)) > BEYOND_JOINT_PX
        if beyond.any():
            result[ys[beyond], xs[beyond]] = index[child]
            moved[f"{parent} past {joint} -> {child}"] = int(beyond.sum())
    for part, start, end in PAIRED_BONES:
        bones = {}
        for side in ("near", "far"):
            if side + "_" + start in center and side + "_" + end in center:
                bones[side] = (center[side + "_" + start], center[side + "_" + end])
        if len(bones) < 2:
            continue
        for side, other in (("near", "far"), ("far", "near")):
            ys, xs = np.nonzero(result == index[side + "_" + part])
            points = np.stack((xs, ys), axis=1).astype(np.float32)
            own = _segment_distance(points, *bones[side])
            counterpart = _segment_distance(points, *bones[other])
            switch = (counterpart < COUNTERPART_BONE_RATIO * own) & (own > COUNTERPART_MIN_PX)
            if switch.any():
                result[ys[switch], xs[switch]] = index[other + "_" + part]
                moved[f"{side}_{part} nearer the {other} bone -> {other}_{part}"] = int(switch.sum())
    return result, moved


def upper_arm_top(mask: np.ndarray, elbow: list[float], share: float = 0.2) -> list[float]:
    """Center of the upper-arm pixels farthest from the elbow: the shoulder end."""
    ys, xs = np.nonzero(mask)
    points = np.stack((xs, ys), axis=1).astype(np.float64)
    distance = np.linalg.norm(points - np.array(elbow, dtype=np.float64), axis=1)
    far = points[distance >= np.quantile(distance, 1.0 - share)]
    return [round(float(far[:, 0].mean()), 2), round(float(far[:, 1].mean()), 2)]


def place_shoulders_without_dots(joints: dict[str, Any], part_masks: dict[str, np.ndarray]) -> None:
    """Without a usable dot, a shoulder is the upper arm's end away from the elbow.

    The middle of an arm-torso contact is the armpit side for an arm hanging
    beside the body, so it is not used for shoulders.
    """
    for side in ("near", "far"):
        shoulder, elbow = joints.get(f"{side}_shoulder"), joints.get(f"{side}_elbow")
        mask = part_masks.get(f"{side}_upper_arm")
        if shoulder and elbow and mask is not None and mask.any() and shoulder.get("method") == "contact center":
            shoulder["center"] = upper_arm_top(mask, elbow["center"])
            shoulder["method"] = "upper arm end away from the elbow"


def claim_sleeves(labels: np.ndarray, joints: dict[str, Any]) -> tuple[np.ndarray, dict[str, int]]:
    """Torso pixels lying along an upper arm's bone belong to the arm.

    Maps often paint a sleeve or shoulder pad as torso. A torso pixel between
    the shoulder and elbow, within the arm's width of that bone, and closer to
    it than to the spine, is arm.
    """
    index = {name: position for position, name in enumerate(PART_COLORS, start=1)}
    result = labels.copy()
    moved: dict[str, int] = {}
    center = {name: np.array(joint["center"], dtype=np.float64) for name, joint in joints.items()}
    if not all(key in center for key in ("near_shoulder", "far_shoulder", "near_hip", "far_hip")):
        return result, moved
    spine = ((center["near_shoulder"] + center["far_shoulder"]) / 2, (center["near_hip"] + center["far_hip"]) / 2)
    for side in ("near", "far"):
        shoulder, elbow = center.get(f"{side}_shoulder"), center.get(f"{side}_elbow")
        if shoulder is None or elbow is None:
            continue
        arm = np.zeros(labels.shape, dtype=np.uint8)
        arm[(labels == index[f"{side}_upper_arm"]) | (labels == index[f"{side}_forearm_hand"])] = 1
        if not arm.any():
            continue
        half_width = float(cv2.distanceTransform(arm, cv2.DIST_L2, 3).max()) * SLEEVE_WIDTH_SCALE
        ys, xs = np.nonzero(result == index["torso_pelvis"])
        points = np.stack((xs, ys), axis=1).astype(np.float64)
        axis = elbow - shoulder
        t = ((points - shoulder) @ axis) / max(1e-6, float(axis @ axis))
        near_arm = _segment_distance(points, shoulder, elbow)
        near_spine = _segment_distance(points, *spine)
        claim = (t > 0.0) & (t <= 1.0) & (near_arm <= half_width) & (near_arm < near_spine)
        if claim.any():
            result[ys[claim], xs[claim]] = index[f"{side}_upper_arm"]
            moved[f"torso along the {side} upper arm -> {side}_upper_arm"] = int(claim.sum())
    return result, moved


def place_neck(joints: dict[str, Any], part_masks: dict[str, np.ndarray]) -> str | None:
    """The neck sits above the middle of the shoulders, even when a beard or hair covers it."""
    if "near_shoulder" not in joints or "far_shoulder" not in joints:
        return None
    near = np.array(joints["near_shoulder"]["center"], dtype=np.float32)
    far = np.array(joints["far_shoulder"]["center"], dtype=np.float32)
    point = (near + far) / 2 - np.array([0.0, NECK_ABOVE_SHOULDERS * float(np.linalg.norm(near - far))])
    body = part_masks["head_neck"] | part_masks["torso_pelvis"]
    x, y = int(round(point[0])), int(round(point[1]))
    height, width = body.shape
    if not (0 <= x < width and 0 <= y < height and body[y, x]):
        ys, xs = np.nonzero(body)
        nearest = int(np.argmin((xs - point[0]) ** 2 + (ys - point[1]) ** 2))
        x, y = int(xs[nearest]), int(ys[nearest])
    previous = joints.get("neck", {})
    joints["neck"] = {"center": [float(x), float(y)], "connects": ["head_neck", "torso_pelvis"],
                      "method": "above the shoulders' midpoint", "model_dot": previous.get("model_dot"),
                      "distance_to_parts_px": {"head_neck": 0.0, "torso_pelvis": 0.0}}
    return None


def draw_final_pivots(labels: np.ndarray, joints: dict[str, Any], markers: list[dict[str, Any]],
                      output: Path) -> None:
    """The pivots the rig uses, labeled, with the model's unused dots crossed out in red."""
    image = np.zeros((*labels.shape, 3), dtype=np.uint8)
    image[:] = (30, 33, 40)
    for position, color in enumerate(PART_COLORS.values(), start=1):
        image[labels == position] = rgb(color)
    picture = Image.fromarray(image, mode="RGB")
    draw = ImageDraw.Draw(picture)
    used = {tuple(joint["model_dot"]) for joint in joints.values() if joint.get("model_dot")}
    for marker in markers:
        x, y = marker["center"]
        if tuple(marker["center"]) not in used:
            draw.line((x - 9, y - 9, x + 9, y + 9), fill=(255, 40, 40), width=4)
            draw.line((x - 9, y + 9, x + 9, y - 9), fill=(255, 40, 40), width=4)
    for name, joint in joints.items():
        x, y = joint["center"]
        draw.ellipse((x - 10, y - 10, x + 10, y + 10), fill=rgb(MARKER_HEX), outline=(0, 0, 0), width=3)
        draw.text((x + 13, y - 7), name, fill=(255, 255, 255), stroke_width=2, stroke_fill=(0, 0, 0))
    picture.save(output)


def snap_joints_to_contacts(joints: dict[str, Any], part_masks: dict[str, np.ndarray]
                            ) -> tuple[dict[str, Any], list[str]]:
    """Put every pivot on the line where its two parts actually touch.

    The model's dot only picks where along that contact line the pivot goes.
    A dot that is missing or far from the contact is replaced by the contact's
    most central point, so each joint always gets exactly one pivot.
    """
    kernel = np.ones((3, 3), dtype=np.uint8)
    result: dict[str, Any] = {}
    warnings: list[str] = []
    for name, first, second in JOINTS:
        a, b = part_masks[first], part_masks[second]
        contact = (a & cv2.dilate(b.astype(np.uint8), kernel).astype(bool)) | (
            b & cv2.dilate(a.astype(np.uint8), kernel).astype(bool))
        dot = joints.get(name)
        ys, xs = np.nonzero(contact)
        if not len(xs):
            if dot:
                result[name] = {**dot, "method": "model dot; parts do not touch"}
                warnings.append(f"{name}: {first} and {second} do not touch; kept the model's dot")
            else:
                warnings.append(f"{name}: no pivot, {first} and {second} do not touch and no dot was found")
            continue
        points = np.stack((xs, ys), axis=1).astype(np.float32)
        central = points[np.argmin(((points - points.mean(axis=0)) ** 2).sum(axis=1))]
        method = "contact center"
        chosen = central
        if dot:
            distances = np.sqrt(((points - np.array(dot["center"], dtype=np.float32)) ** 2).sum(axis=1))
            dx, dy = (int(round(value)) for value in dot["center"])
            inside = 0 <= dy < a.shape[0] and 0 <= dx < a.shape[1] and bool(a[dy, dx] or b[dy, dx])
            if float(distances.min()) <= MAX_DOT_TO_CONTACT_PX and inside:
                # A rotation point lies inside the limb, not on its outline.
                chosen = np.array(dot["center"], dtype=np.float32)
                method = "model dot inside the joint"
            elif float(distances.min()) <= MAX_DOT_TO_CONTACT_PX:
                chosen = points[int(np.argmin(distances))]
                method = "model dot snapped to contact"
            else:
                warnings.append(f"{name}: model dot was {distances.min():.0f}px from the {first}/{second} "
                                "contact; used the contact center")
        center = [round(float(chosen[0]), 2), round(float(chosen[1]), 2)]
        result[name] = {"center": center, "connects": [first, second], "method": method,
                        "model_dot": dot["center"] if dot else None, "contact_pixels": int(len(xs)),
                        "distance_to_parts_px": {first: 0.0, second: 0.0}}
    return result, warnings


def attach_held_item(parts: dict[str, Any], part_masks: dict[str, np.ndarray]) -> None:
    """A held item moves rigidly with the hand it touches most."""
    item = parts.get("held_item", {})
    if item.get("status") != "EXTRACTED":
        return
    kernel = np.ones((5, 5), dtype=np.uint8)
    grown = cv2.dilate(part_masks["held_item"].astype(np.uint8), kernel).astype(bool)
    contact = {hand: int((grown & part_masks[hand]).sum()) for hand in ("near_forearm_hand", "far_forearm_hand")}
    item["attached_to"] = max(contact, key=contact.get)
    item["hand_contact_pixels"] = contact


def add_joint_overlaps(parts: dict[str, Any], part_masks: dict[str, np.ndarray], joints: dict[str, Any],
                       source_rgba: np.ndarray, foreground: np.ndarray, part_dir: Path) -> list[dict[str, Any]]:
    """Extend the lower part of each joint under its neighbor, inside a circle.

    Ownership stays exclusive (saved as core images for repair detection), but
    the part drawn underneath also carries its neighbor's pixels near the joint,
    so a rotation shows overlapping art instead of a hard cut or a gap.
    """
    height, width = foreground.shape
    grown = {name: mask.copy() for name, mask in part_masks.items()}
    overlaps = []
    yy, xx = np.mgrid[0:height, 0:width]
    for joint_name, joint in joints.items():
        first, second = joint["connects"]
        if parts[first]["status"] != "EXTRACTED" or parts[second]["status"] != "EXTRACTED":
            continue
        cx, cy = joint["center"]
        near = (xx - cx) ** 2 + (yy - cy) ** 2 <= JOINT_PROBE_PX ** 2
        # Radius follows the child (the rotating limb or head), measured over a
        # wide probe so a pivot slightly off the boundary still finds its width.
        # Err on the side of larger overlaps.
        child_half_width = float(cv2.distanceTransform(part_masks[second].astype(np.uint8),
                                                       cv2.DIST_L2, 3)[near].max())
        radius = int(round(min(JOINT_OVERLAP_MAX_PX, max(JOINT_OVERLAP_MIN_PX,
                                                           JOINT_OVERLAP_SCALE * child_half_width))))
        overlaps.append({"joint": joint_name, "center": [cx, cy], "radius_px": radius,
                         "connects": [first, second]})
    # Near and far limbs are the same size; a partly hidden far limb looks
    # thinner, so each near/far pair shares the larger radius.
    by_name = {item["joint"]: item for item in overlaps}
    for item in overlaps:
        side, _, rest = item["joint"].partition("_")
        twin = by_name.get(("far_" if side == "near" else "near_") + rest) if side in ("near", "far") else None
        if twin:
            item["radius_px"] = max(item["radius_px"], twin["radius_px"])
    # Only the part drawn underneath extends under its neighbor. The part on top
    # stays exact, so no copied art is left floating on it when the joint moves.
    from render_whole_character_poses import DRAW_ORDER
    for item in overlaps:
        first, second = item["connects"]
        lower = first if DRAW_ORDER.index(first) < DRAW_ORDER.index(second) else second
        cx, cy = item["center"]
        disk = ((xx - cx) ** 2 + (yy - cy) ** 2 <= item["radius_px"] ** 2) & (part_masks[first] | part_masks[second])
        grown[lower] |= disk
        item["extended_part"] = lower
        item["shared_pixels"] = int(disk.sum())
    for name, mask in grown.items():
        if parts[name]["status"] != "EXTRACTED":
            continue
        core_path = part_dir / f"{name}.core.png"
        shutil.copy2(parts[name]["image"], core_path)
        ys, xs = np.where(mask)
        x0, y0, x1, y1 = int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)
        rgba = np.zeros_like(source_rgba)
        rgba[mask] = source_rgba[mask]
        Image.fromarray(rgba[y0:y1, x0:x1], mode="RGBA").save(parts[name]["image"])
        parts[name].update({"core_image": str(core_path.resolve()), "core_crop_origin": parts[name]["crop_origin"],
                            "page_bbox": [x0, y0, x1, y1], "crop_origin": [x0, y0],
                            "crop_size": [x1 - x0, y1 - y0], "foreground_pixels_with_overlap": int(mask.sum())})
    return overlaps


def draw_joint_overlaps(labels: np.ndarray, overlaps: list[dict[str, Any]], output: Path) -> None:
    image = np.zeros((*labels.shape, 3), dtype=np.uint8)
    image[:] = (30, 33, 40)
    for index, color in enumerate(PART_COLORS.values(), start=1):
        image[labels == index] = rgb(color)
    picture = Image.fromarray(image, mode="RGB")
    draw = ImageDraw.Draw(picture)
    for overlap in overlaps:
        x, y = overlap["center"]
        radius = overlap["radius_px"]
        draw.ellipse((x - radius, y - radius, x + radius, y + radius), outline=(255, 255, 255), width=3)
        draw.ellipse((x - 4, y - 4, x + 4, y + 4), fill=rgb(MARKER_HEX))
    picture.save(output)


def snap_labels_to_source(labels: np.ndarray, foreground: np.ndarray) -> tuple[np.ndarray, dict[str, int]]:
    """Give every source foreground pixel the nearest map label, then merge stray fragments.

    The map only guides ownership; part shapes always come from the real artwork,
    so a slightly misaligned map cannot fragment or crop a part.
    """
    part_ids = range(1, len(PART_COLORS) + 1)
    # Anti-aliased map edges blend part colors with the background and can land
    # on another part's color as a thin ring. Regions thinner than the kernel
    # are dropped here and their pixels take the nearest solid label instead.
    kernel = np.ones((EDGE_RING_PX, EDGE_RING_PX), dtype=np.uint8)
    solid = np.zeros_like(labels)
    for index in part_ids:
        solid[cv2.morphologyEx((labels == index).astype(np.uint8), cv2.MORPH_OPEN, kernel) > 0] = index
    labels = np.where(solid > 0, solid, labels)
    labels = np.where((labels > 0) & (solid == 0), 0, labels)
    distances = np.stack([cv2.distanceTransform((labels != index).astype(np.uint8), cv2.DIST_L2, 3)
                          for index in part_ids], axis=2)
    nearest = (np.argmin(distances, axis=2) + 1).astype(np.int16)
    snapped = np.where(foreground, nearest, 0).astype(np.int16)
    relabeled = int((foreground & (labels != snapped)).sum())
    merged = 0
    for index in part_ids:
        mask = (snapped == index).astype(np.uint8)
        count, components, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
        if count <= 2:
            continue
        areas = stats[1:, cv2.CC_STAT_AREA]
        limit = max(MIN_FRAGMENT_PX, int(areas.sum() * MIN_FRAGMENT_SHARE))
        for component in range(1, count):
            if component - 1 == int(np.argmax(areas)) or areas[component - 1] >= limit:
                continue
            region = components == component
            ring = cv2.dilate(region.astype(np.uint8), np.ones((3, 3), dtype=np.uint8)).astype(bool) & ~region
            neighbors = snapped[ring & (snapped > 0) & (snapped != index)]
            if len(neighbors):
                snapped[region] = np.bincount(neighbors).argmax()
                merged += int(region.sum())
    return snapped, {"relabeled_to_nearest_part": relabeled, "merged_fragment_pixels": merged}


def analyze_and_reconstruct(character_path: Path, map_path: Path, output_dir: Path,
                            pivot_map_path: Path | None = None) -> dict[str, Any]:
    source = open_rgb(character_path)
    resampled: dict[str, Any] = {}
    segmentation = open_guide_map(map_path, source.shape, "segmentation", resampled)
    height, width = source.shape[:2]
    bg_color, bg_tolerance, foreground = sample_background(source)
    if not foreground.any():
        raise ValueError("Original character has no detected foreground pixels")
    output_dir.mkdir(parents=True, exist_ok=True)
    labels, color_evidence = decode_segmentation(segmentation)
    if pivot_map_path:
        pivot_map = open_guide_map(pivot_map_path, source.shape, "pivots", resampled)
        markers = find_joint_markers(decode_segmentation(pivot_map)[0])
    else:
        markers = find_joint_markers(labels)
    labels_for_parts = extend_joint_disks(labels)
    decoded = np.zeros_like(segmentation)
    decoded[:] = rgb(BACKGROUND_HEX)
    for index, color in enumerate(PART_COLORS.values(), start=1):
        decoded[labels_for_parts == index] = rgb(color)
    decoded[labels_for_parts == -1] = (20, 20, 20)
    Image.fromarray(decoded, mode="RGB").save(output_dir / "segmentation-decoded.png")
    snapped, snap_evidence = snap_labels_to_source(labels_for_parts, foreground)
    snapped, swapped_sides = enforce_near_far_sides(snapped)
    # Pivots first, then use the skeleton to fix ownership, then pivots again
    # on the corrected parts.
    first_masks = {name: snapped == index for index, name in enumerate(PART_COLORS, start=1)}
    dots, joint_warnings = assign_joints(markers, first_masks)
    first_joints, _ = snap_joints_to_contacts(dots, first_masks)
    snapped, bone_moves = correct_ownership_with_bones(snapped, first_joints)
    snapped, sleeve_moves = claim_sleeves(snapped, first_joints)
    bone_moves.update(sleeve_moves)
    snapped, _ = snap_labels_to_source(snapped, foreground)
    part_masks = {name: snapped == index for index, name in enumerate(PART_COLORS, start=1)}
    joints, snap_warnings = snap_joints_to_contacts(dots, part_masks)
    place_shoulders_without_dots(joints, part_masks)
    place_neck(joints, part_masks)
    joint_warnings = [warning for warning in joint_warnings if "more than 24px" not in warning] + [
        warning for warning in snap_warnings if not warning.startswith("neck:")]
    if swapped_sides:
        joint_warnings.append("Map had near and far swapped for the " + " and ".join(swapped_sides)
                              + "; near limbs are the screen-left ones, so the labels were swapped")
    draw_final_pivots(snapped, joints, markers, output_dir / "pivots-final.png")
    owned = np.zeros_like(segmentation)
    owned[:] = rgb(BACKGROUND_HEX)
    for index, color in enumerate(PART_COLORS.values(), start=1):
        owned[snapped == index] = rgb(color)
    Image.fromarray(owned, mode="RGB").save(output_dir / "part-ownership.png")
    snap_evidence["near_far_swapped"] = swapped_sides
    snap_evidence["bone_corrections"] = bone_moves
    color_evidence["snapping"] = snap_evidence
    color_evidence["guide_maps_resampled"] = resampled
    assigned = np.zeros((height, width), dtype=bool)
    for mask in part_masks.values():
        assigned |= mask
    raw_assigned = (labels_for_parts > 0) & (labels_for_parts <= len(PART_COLORS))
    missing = foreground & ~raw_assigned
    extra = (~foreground) & (labels_for_parts > 0) & (labels_for_parts <= len(PART_COLORS))
    missing_count = int(missing.sum())
    unowned_count = int((foreground & ~assigned).sum())
    extra_count = int(extra.sum())
    foreground_count = int(foreground.sum())
    disagreement_fraction = (missing_count + extra_count) / max(1, foreground_count)

    edge_clearance = {
        "left": int(np.where(foreground.any(axis=0))[0].min()),
        "top": int(np.where(foreground.any(axis=1))[0].min()),
        "right": int(width - 1 - np.where(foreground.any(axis=0))[0].max()),
        "bottom": int(height - 1 - np.where(foreground.any(axis=1))[0].max()),
    }

    source_rgba = np.dstack((source, foreground.astype(np.uint8) * 255))
    source_rgba[~foreground, :3] = 0
    Image.fromarray(source_rgba, mode="RGBA").save(output_dir / "source-transparent.png")
    Image.fromarray((foreground.astype(np.uint8) * 255), mode="L").save(output_dir / "source-foreground-mask.png")

    part_dir = output_dir / "parts"
    part_dir.mkdir(exist_ok=True)
    reconstructed = np.zeros_like(source_rgba)
    parts: dict[str, Any] = {}
    for name, mask in part_masks.items():
        ys, xs = np.where(mask)
        if not len(xs):
            parts[name] = {"status": "ABSENT" if name in OPTIONAL_PARTS else "MISSING",
                           "foreground_pixels": 0}
            continue
        x0, y0, x1, y1 = int(xs.min()), int(ys.min()), int(xs.max() + 1), int(ys.max() + 1)
        rgba = np.zeros_like(source_rgba)
        rgba[mask] = source_rgba[mask]
        crop = Image.fromarray(rgba[y0:y1, x0:x1], mode="RGBA")
        path = part_dir / f"{name}.png"
        crop.save(path)
        reconstructed[mask] = source_rgba[mask]
        components, _, stats, _ = cv2.connectedComponentsWithStats(
            mask[y0:y1, x0:x1].astype(np.uint8), connectivity=8)
        primary = stats[1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))]
        primary_bbox_area = int(primary[cv2.CC_STAT_WIDTH] * primary[cv2.CC_STAT_HEIGHT])
        crop_bloat = (x1 - x0) * (y1 - y0) / max(1, primary_bbox_area)
        parts[name] = {"status": "EXTRACTED", "page_bbox": [x0, y0, x1, y1],
                       "crop_origin": [x0, y0], "crop_size": [x1 - x0, y1 - y0],
                       "foreground_pixels": int(mask.sum()), "image": str(path.resolve()), "pivots": {},
                       "fragmentation": {"component_count": components - 1,
                                         "largest_component_fraction": round(float(primary[cv2.CC_STAT_AREA]) / len(xs), 4),
                                         "crop_to_largest_bbox_area_ratio": round(crop_bloat, 2)}}

    attach_held_item(parts, part_masks)
    overlaps = add_joint_overlaps(parts, part_masks, joints, source_rgba, foreground, part_dir)
    draw_joint_overlaps(snapped, overlaps, output_dir / "joint-overlaps.png")
    for joint_name, definition in joints.items():
        x, y = definition["center"]
        for part_name in definition["connects"]:
            if parts[part_name]["status"] == "EXTRACTED":
                origin = parts[part_name]["crop_origin"]
                parts[part_name]["pivots"][joint_name] = {
                    "page": [x, y], "crop_local": [round(x - origin[0], 2), round(y - origin[1], 2)]
                }

    Image.fromarray(reconstructed, mode="RGBA").save(output_dir / "reconstructed.png")
    # A magnified comparison is a display artifact only. All source and part
    # files remain at their original pixel resolution.
    reconstructed_visible = Image.fromarray(reconstructed, mode="RGBA")
    magenta = Image.new("RGBA", (width, height), rgb(BACKGROUND_HEX) + (255,))
    magenta.alpha_composite(reconstructed_visible)
    magenta.convert("RGB").save(output_dir / "reconstructed-on-magenta.png")
    inspection = Image.new("RGB", (width * 3, height + 54), (30, 33, 40))
    for index, (label, image) in enumerate((
        ("Original PNG, unchanged", Image.fromarray(source, mode="RGB")),
        ("Reconstructed from isolated parts", reconstructed_visible),
        ("Mismatch: red = missing, yellow = map outside art", None),
    )):
        x = index * width
        ImageDraw.Draw(inspection).text((x + 8, 14), label, font=_font(), fill="white")
        if index == 0:
            inspection.paste(image, (x, 54))
        elif image is not None:
            background = Image.new("RGBA", (width, height), (39, 42, 49, 255))
            background.alpha_composite(image)
            inspection.paste(background.convert("RGB"), (x, 54))
    mismatch = np.empty_like(source)
    mismatch[:] = (39, 42, 49)
    mismatch[missing] = (245, 54, 54)
    mismatch[extra] = (255, 214, 10)
    inspection.paste(Image.fromarray(mismatch, mode="RGB"), (width * 2, 54))
    inspection.save(output_dir / "inspection.png")

    issues: list[str] = []
    for side, pixels in edge_clearance.items():
        if pixels < 8:
            issues.append(f"Original fighter has only {pixels}px of {side} canvas clearance; artwork may be clipped")
    if disagreement_fraction > 0.02:
        issues.append(f"Segmentation map differs from source silhouette by {disagreement_fraction:.2%} "
                      "of source foreground (maximum 2%); part shapes were snapped to the artwork")
    if any(part["status"] == "MISSING" for part in parts.values()):
        issues.append("At least one required body part is absent from the map")
    bloated = [name for name, part in parts.items() if part["status"] == "EXTRACTED"
               and part["fragmentation"]["crop_to_largest_bbox_area_ratio"] > 6]
    if bloated:
        issues.append("Distant fragments inflate the crop bounds of: " + ", ".join(bloated))
    if color_evidence["pixel_counts"]["unclassified"] > width * height * 0.005:
        issues.append("More than 0.5% of segmentation pixels do not match the specified palette")
    if len(markers) != len(JOINTS):
        issues.append(f"Expected 11 physical joint markers, found {len(markers)}")
    issues.extend(joint_warnings)
    report = {
        "status": "REVIEW_REQUIRED" if issues else "PASS",
        "canvas": [width, height],
        "source_background": {"sampled_rgb": [round(float(value), 1) for value in bg_color],
                              "distance_tolerance": round(bg_tolerance, 2), "requested_hex": BACKGROUND_HEX},
        "foreground_pixels": foreground_count,
        "source_edge_clearance_px": edge_clearance,
        "segmentation": color_evidence,
        "physical_joint_count": len(markers),
        "part_specific_pivot_count": sum(len(part.get("pivots", {})) for part in parts.values()),
        "joints": joints,
        "joint_overlaps": overlaps,
        "parts": parts,
        "reconstruction": {"pixel_identical_where_assigned": bool(np.array_equal(reconstructed[assigned], source_rgba[assigned])),
                           "missing_source_pixels": unowned_count,
                           "map_missing_source_pixels": missing_count,
                           "map_pixels_outside_source": extra_count,
                           "disagreement_fraction_of_source": round(disagreement_fraction, 6)},
        "issues": issues,
        "outputs": {name: str((output_dir / name).resolve()) for name in (
            "source-transparent.png", "source-foreground-mask.png", "segmentation-decoded.png",
            "part-ownership.png", "pivots-final.png", "joint-overlaps.png", "reconstructed.png",
            "reconstructed-on-magenta.png", "inspection.png")},
    }
    write_json(output_dir / "analysis.json", report)
    return report


def copy_unless_same(source: Path, target: Path) -> None:
    if source.resolve() != target.resolve():
        shutil.copy2(source, target)


def write_report(run_dir: Path) -> Path:
    from build_run_report import build
    return build(run_dir)


def call_vertex(args: argparse.Namespace, prompt: Path, output: Path, reference: Path | None = None,
                style_image: Path | None = None) -> None:
    command = [sys.executable, str(Path(__file__).with_name("generate_vertex_gemini_image.py")),
               "--prompt-file", str(prompt), "--output", str(output), "--model", args.model,
               "--response-json", str(output.with_suffix(".response.json")),
               "--location", args.location, "--aspect-ratio", aspect_ratio_for(reference) if reference else "2:3",
               "--image-size", args.image_size]
    if args.project:
        command.extend(("--project", args.project))
    if reference:
        command.extend(("--image", str(reference)))
    if style_image:
        command.extend(("--image-label", STYLE_IMAGE_LABEL, "--image", str(style_image)))
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError((result.stderr or result.stdout)[-4000:])


DEFAULT_STYLE_IMAGE = Path(__file__).resolve().parents[1] / "prompts/styles/arcade_reference.png"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--character-prompt-file", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--provider", choices=["vertex", "fixture"], default="vertex")
    parser.add_argument("--model", default="gemini-3-pro-image")
    parser.add_argument("--project")
    parser.add_argument("--location", default="global")
    parser.add_argument("--image-size", choices=["1K", "2K"], default="1K")
    parser.add_argument("--style-image", type=Path, default=DEFAULT_STYLE_IMAGE,
                        help="Image whose rendering style (never its features) the character copies")
    parser.add_argument("--no-style-image", action="store_true")
    parser.add_argument("--stop-after", choices=["segmentation", "detection", "repair", "godot"], default="repair",
                        help="repair ends with the assembled rest pose for human review; godot also exports a scene")
    parser.add_argument("--resume-character", type=Path)
    parser.add_argument("--resume-segmentation", type=Path)
    parser.add_argument("--resume-pivots", type=Path)
    parser.add_argument("--resume-repairs", type=Path,
                        help="Directory with PART.repair.png fixture images")
    parser.add_argument("--resume-from", type=Path,
                        help="Reuse character, segmentation and pivots from a previous run")
    parser.add_argument("--continue-run", action="store_true",
                        help="Continue an interrupted run in --output-dir, reusing the images it already has")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    if args.no_style_image:
        args.style_image = None
    source_run = args.output_dir if args.continue_run else args.resume_from
    if source_run:
        if args.continue_run and args.resume_from:
            parser.error("--continue-run cannot be combined with --resume-from")
        for name, file in (("resume_character", "character.png"), ("resume_segmentation", "segmentation.png"),
                           ("resume_pivots", "pivots.png")):
            if not getattr(args, name) and (source_run / file).is_file():
                setattr(args, name, source_run / file)
    for name in ("resume_character", "resume_segmentation", "resume_pivots"):
        path = getattr(args, name)
        if path and not path.is_file():
            parser.error(f"{name} does not exist: {path}")
    if args.resume_repairs and not args.resume_repairs.is_dir():
        parser.error(f"resume_repairs does not exist: {args.resume_repairs}")
    if args.style_image and not args.style_image.is_file():
        parser.error(f"style_image does not exist: {args.style_image}")
    if not args.character_prompt_file.is_file():
        parser.error("Character brief does not exist")
    if not args.continue_run and args.output_dir.exists() and any(args.output_dir.iterdir()):
        parser.error("Output directory already contains files; choose a fresh directory")
    args.output_dir.mkdir(parents=True, exist_ok=True)
    original_prompt = args.resume_character.parent / "character-prompt.txt" if args.resume_character else None
    if original_prompt and original_prompt.is_file():
        copy_unless_same(original_prompt, args.output_dir / "character-prompt.txt")
    else:
        write_character_prompt(args.output_dir / "character-prompt.txt",
                               args.character_prompt_file.read_text(encoding="utf-8"),
                               style_image=bool(args.style_image))
    write_segmentation_prompt(args.output_dir / "segmentation-prompt.txt")
    write_pivot_prompt(args.output_dir / "pivots-prompt.txt")
    plan = {"provider": args.provider, "model": args.model,
            "character_brief": str(args.character_prompt_file.resolve()),
            "style_image": str(args.style_image.resolve()) if args.style_image else None,
            "background": BACKGROUND_HEX, "joint_marker": MARKER_HEX,
            "physical_joints": len(JOINTS), "part_specific_pivots": 2 * len(JOINTS), "parts": PART_COLORS,
            "resume_character": str(args.resume_character.resolve()) if args.resume_character else None,
            "resume_segmentation": str(args.resume_segmentation.resolve()) if args.resume_segmentation else None,
            "resume_pivots": str(args.resume_pivots.resolve()) if args.resume_pivots else None,
            "resume_repairs": str(args.resume_repairs.resolve()) if args.resume_repairs else None,
            "continued_in_place": args.continue_run, "stop_after": args.stop_after,
            "stages": ["character", "segmentation", "pivots", "isolation", "repair_detection",
                       "repair", "assembly"]}
    write_json(args.output_dir / "plan.json", plan)
    if args.dry_run:
        print(json.dumps({"status": "DRY_RUN", **plan}, indent=2))
        return 0
    character = args.output_dir / "character.png"
    segmentation = args.output_dir / "segmentation.png"
    pivots = args.output_dir / "pivots.png"
    inspection = args.output_dir / "inspection"
    try:
        # 1. Character
        if args.resume_character:
            copy_unless_same(args.resume_character, character)
        elif args.provider == "vertex":
            call_vertex(args, args.output_dir / "character-prompt.txt", character, style_image=args.style_image)
        else:
            raise ValueError("Fixture provider requires --resume-character")
        if not args.resume_character or not (args.output_dir / "character-raw.png").is_file():
            frame = strip_uniform_frame(character, args.output_dir / "character-raw.png")
            if frame:
                plan["character_frame_removed"] = frame
                write_json(args.output_dir / "plan.json", plan)
        sample_background(open_rgb(character))
        # 2. Clean segmentation, without markers, so pivots cannot disturb part ownership
        if args.resume_segmentation:
            copy_unless_same(args.resume_segmentation, segmentation)
        elif args.provider == "vertex":
            call_vertex(args, args.output_dir / "segmentation-prompt.txt", segmentation, character)
        else:
            raise ValueError("Fixture provider requires --resume-segmentation")
        # 3. Pivots, marked on a copy of the clean segmentation
        if args.resume_pivots:
            copy_unless_same(args.resume_pivots, pivots)
        elif args.provider == "vertex":
            call_vertex(args, args.output_dir / "pivots-prompt.txt", pivots, segmentation)
        pivot_map = pivots if pivots.is_file() else None
        # 4. Part isolation
        report = analyze_and_reconstruct(character, segmentation, inspection, pivot_map)
        outcome = {**plan, "status": "AWAITING_HUMAN_REVIEW", "analysis_status": report["status"],
                   "character": str(character.resolve()), "segmentation": str(segmentation.resolve()),
                   "pivots": str(pivots.resolve()) if pivot_map else None,
                   "inspection": str((inspection / "analysis.json").resolve()), "issues": report["issues"]}
        complete = len(report["joints"]) == len(JOINTS) and all(
            part["status"] == "EXTRACTED" for name, part in report["parts"].items()
            if name not in OPTIONAL_PARTS)
        from review_whole_character_parts import build_review_sheet
        build_review_sheet(report, inspection / "parts-sheet.png")
        active_analysis = inspection / "analysis.json"
        if args.stop_after != "segmentation":
            # 5. Repair detection from part geometry, no LLM
            from detect_part_repairs import write_detection
            detection = write_detection(active_analysis, inspection / "repair-detection")
            outcome["parts_needing_repair"] = {name: entry["reason"] for name, entry
                                               in detection["parts_needing_repair"].items()}
            # 6. Repair, one call per flagged part with only that part
            if args.stop_after in ("repair", "godot") and complete:
                from repair_whole_character_parts import repair_flagged_parts
                repaired = repair_flagged_parts(active_analysis, detection, inspection / "repair", args,
                                                fixture_repair_dir=args.resume_repairs)
                outcome["repair_report"] = str((inspection / "repair/repair-report.json").resolve())
                outcome["repair_status"] = repaired["status"]
                outcome["rejected_repairs"] = repaired["rejected_parts"]
                active_analysis = Path(repaired["analysis"])
        # 7. Assembly for human verification
        if complete:
            from render_whole_character_poses import make_pose_previews
            poses_dir = inspection / ("repair/poses" if active_analysis != inspection / "analysis.json" else "poses")
            outcome["pose_sheet"] = make_pose_previews(active_analysis, poses_dir)["sheet"]
        else:
            outcome["assembly_reason"] = "All twelve required parts and eleven joints are required to assemble"
        if args.stop_after == "godot" and complete:
            from export_whole_character_godot import export_godot_scene
            scene = export_godot_scene(active_analysis, inspection / "whole_character_candidate.tscn",
                                       Path(__file__).resolve().parents[1])
            outcome["godot_inspection_scene"] = scene["scene"]
        write_json(args.output_dir / "workflow.json", outcome)
        outcome["report"] = str(write_report(args.output_dir))
        print(json.dumps({key: outcome.get(key) for key in (
            "status", "analysis_status", "report", "parts_needing_repair", "rejected_repairs", "issues")}, indent=2))
        return 0 if report["status"] == "PASS" else 2
    except (OSError, ValueError, RuntimeError) as exc:
        failure = {**plan, "status": "FAILED", "error": str(exc),
                   "character": str(character.resolve()) if character.is_file() else None,
                   "segmentation": str(segmentation.resolve()) if segmentation.is_file() else None}
        write_json(args.output_dir / "workflow.json", failure)
        failure["report"] = str(write_report(args.output_dir))
        print(json.dumps(failure, indent=2), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
