#!/usr/bin/env python3
"""Rigid, unscaled pose previews from whole-character extraction metadata.

These are articulation diagnostics, not Godot animations. Occluded source art
cannot be recovered by rotating its visible pixels.
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont


# back_accessory has no joint of its own: it moves rigidly with the torso.
PARENTS = {
    "back_accessory": ("torso_pelvis", None),
    "head_neck": ("torso_pelvis", "neck"),
    "far_upper_arm": ("torso_pelvis", "far_shoulder"),
    "far_forearm_hand": ("far_upper_arm", "far_elbow"),
    "near_upper_arm": ("torso_pelvis", "near_shoulder"),
    "near_forearm_hand": ("near_upper_arm", "near_elbow"),
    "far_thigh": ("torso_pelvis", "far_hip"),
    "far_shin": ("far_thigh", "far_knee"),
    "far_foot": ("far_shin", "far_ankle"),
    "near_thigh": ("torso_pelvis", "near_hip"),
    "near_shin": ("near_thigh", "near_knee"),
    "near_foot": ("near_shin", "near_ankle"),
}
# Back to front. The far arm sits behind the torso and the far leg; a back
# accessory (wings, cape) sits behind everything.
DRAW_ORDER = (
    "back_accessory", "far_upper_arm", "far_forearm_hand", "far_foot", "far_shin",
    "far_thigh", "torso_pelvis", "head_neck", "near_thigh", "near_shin", "near_foot",
    "near_upper_arm", "near_forearm_hand",
)
OPTIONAL_PARTS = {"back_accessory", "held_item"}
SHEET_COLUMNS = 5
KINEMATIC_ORDER = (
    "torso_pelvis", "back_accessory", "head_neck", "far_upper_arm", "far_forearm_hand",
    "near_upper_arm", "near_forearm_hand", "far_thigh", "far_shin", "far_foot",
    "near_thigh", "near_shin", "near_foot", "held_item",
)


def parent_of(report: dict[str, Any], name: str) -> tuple[str, str | None]:
    """A held item rides rigidly on the hand holding it; everything else is fixed."""
    if name == "held_item":
        return report["parts"]["held_item"].get("attached_to", "near_forearm_hand"), None
    return PARENTS[name]


def draw_order(report: dict[str, Any]) -> list[str]:
    """Back to front, with a held item just behind the hand gripping it."""
    order = [name for name in DRAW_ORDER]
    item = report["parts"].get("held_item", {})
    if item.get("status") == "EXTRACTED":
        order.insert(order.index(parent_of(report, "held_item")[0]), "held_item")
    return order
POSES = {
    "rest": {"angles": {}},
    "guard": {"angles": {"near_upper_arm": -65, "near_forearm_hand": -55,
                         "far_upper_arm": 65, "far_forearm_hand": 55}},
    "reach": {"angles": {"near_upper_arm": -55, "near_forearm_hand": 55,
                         "far_upper_arm": 25, "far_forearm_hand": -25}},
    "crouch": {"angles": {"torso_pelvis": 12, "head_neck": -12,
                          "near_thigh": -40, "near_shin": 75, "near_foot": -35,
                          "far_thigh": 35, "far_shin": -65, "far_foot": 30,
                          "near_upper_arm": -30, "far_upper_arm": 25},
               "offset": (0, 70)},
    "high_kick": {"angles": {"torso_pelvis": -10, "head_neck": 10,
                             "near_thigh": -100, "near_shin": 35, "near_foot": 65,
                             "far_thigh": 10, "far_shin": -10}},
    # Angles are clockwise degrees relative to the parent. From a hanging rest,
    # negative swings a limb forward (screen right), positive swings it back.
    "victory": {"angles": {"near_upper_arm": -165, "near_forearm_hand": -20,
                           "far_upper_arm": 160, "far_forearm_hand": 25, "head_neck": -10}},
    "uppercut": {"angles": {"torso_pelvis": -8, "head_neck": 8, "near_upper_arm": -150,
                            "near_forearm_hand": -45, "far_upper_arm": 35, "far_forearm_hand": 60,
                            "near_thigh": -25, "near_shin": 30, "far_thigh": 15}},
    "flying_kick": {"angles": {"torso_pelvis": -18, "head_neck": 12, "near_thigh": -85,
                               "near_shin": -5, "near_foot": 15, "far_thigh": 55, "far_shin": 70,
                               "near_upper_arm": 55, "near_forearm_hand": 40, "far_upper_arm": -60,
                               "far_forearm_hand": -30},
                    "offset": (0, -140)},
    "splits": {"angles": {"near_thigh": -88, "near_foot": -20, "far_thigh": 88, "far_foot": 20,
                          "near_upper_arm": -100, "far_upper_arm": 100},
               "offset": (0, 330)},
    "handstand": {"angles": {"torso_pelvis": 180, "head_neck": 15, "near_upper_arm": 172,
                             "far_upper_arm": -172, "near_thigh": -25, "near_shin": 40,
                             "far_thigh": 20, "far_shin": -35}},
    "t_pose": {"angles": {"near_upper_arm": -90, "far_upper_arm": 90}},
    "chicken_dance": {"angles": {"near_upper_arm": 35, "near_forearm_hand": -150,
                                 "far_upper_arm": -35, "far_forearm_hand": 150, "head_neck": 22,
                                 "near_thigh": -35, "near_shin": 70, "near_foot": -30, "torso_pelvis": 6}},
    "noodle": {"angles": {"torso_pelvis": 10, "head_neck": -35, "near_upper_arm": 95,
                          "near_forearm_hand": 95, "far_upper_arm": -95, "far_forearm_hand": -95,
                          "near_thigh": 30, "near_shin": -60, "near_foot": 40, "far_thigh": -30,
                          "far_shin": 60, "far_foot": -40}},
}


def translate(x: float, y: float) -> np.ndarray:
    return np.array([[1., 0., x], [0., 1., y], [0., 0., 1.]])


def rotate(degrees: float) -> np.ndarray:
    radians = math.radians(degrees)
    cosine, sine = math.cos(radians), math.sin(radians)
    return np.array([[cosine, -sine, 0.], [sine, cosine, 0.], [0., 0., 1.]])


def point(matrix: np.ndarray, xy: list[float] | tuple[float, float]) -> list[float]:
    position = matrix @ np.array([xy[0], xy[1], 1.])
    return [float(position[0]), float(position[1])]


def build_transforms(report: dict[str, Any], pose: dict[str, Any]) -> dict[str, np.ndarray]:
    joints = report["joints"]
    angles = pose.get("angles", {})
    midpoint = [(joints["near_hip"]["center"][axis] + joints["far_hip"]["center"][axis]) / 2
                for axis in (0, 1)]
    offset = pose.get("offset", (0, 0))
    transforms = {}
    root = "torso_pelvis"
    transforms[root] = (translate(*offset) @ translate(*midpoint)
                        @ rotate(angles.get(root, 0)) @ translate(-midpoint[0], -midpoint[1]))
    for name in KINEMATIC_ORDER[1:]:
        if report["parts"].get(name, {}).get("status") != "EXTRACTED" and name in OPTIONAL_PARTS:
            continue
        parent, joint = parent_of(report, name)
        if joint is None:
            transforms[name] = transforms[parent]
            continue
        center = joints[joint]["center"]
        transforms[name] = (transforms[parent] @ translate(*center)
                            @ rotate(angles.get(name, 0)) @ translate(-center[0], -center[1]))
    return transforms


def fit_shift(report: dict[str, Any], transforms: dict[str, np.ndarray], padding: int,
              output_size: tuple[int, int], margin: int = 20) -> tuple[float, float]:
    """Shift a whole pose back inside the canvas when a limb would leave it."""
    corners = []
    for name, part in report["parts"].items():
        if part.get("status") != "EXTRACTED" or name not in transforms:
            continue
        x, y = part["crop_origin"]
        w, h = part["crop_size"]
        corners += [point(transforms[name], xy) for xy in ((x, y), (x + w, y), (x, y + h), (x + w, y + h))]
    xs = [xy[0] + padding for xy in corners]
    ys = [xy[1] + padding for xy in corners]
    shift = []
    for low, high, size in ((min(xs), max(xs), output_size[0]), (min(ys), max(ys), output_size[1])):
        if low < margin:
            shift.append(margin - low)
        elif high > size - margin:
            shift.append(max(margin - low, size - margin - high))
        else:
            shift.append(0.0)
    return float(shift[0]), float(shift[1])


def render_pose(report: dict[str, Any], pose: dict[str, Any], padding: int = 300
                ) -> tuple[Image.Image, dict[str, Any]]:
    width, height = report["canvas"]
    output_size = (width + 2 * padding, height + 2 * padding)
    transforms = build_transforms(report, pose)
    fit = fit_shift(report, transforms, padding, output_size)
    if fit != (0.0, 0.0):
        transforms = {name: translate(*fit) @ matrix for name, matrix in transforms.items()}
    canvas = Image.new("RGBA", output_size, (0, 0, 0, 0))
    for name in draw_order(report):
        part = report["parts"].get(name, {"status": "ABSENT"})
        if part["status"] != "EXTRACTED":
            if name in OPTIONAL_PARTS:
                continue
            raise ValueError(f"Cannot pose missing part {name}")
        crop = np.asarray(Image.open(part["image"]).convert("RGBA"))
        matrix = (translate(padding, padding) @ transforms[name]
                  @ translate(*part["crop_origin"]))
        warped = cv2.warpAffine(crop, matrix[:2], output_size,
                                flags=cv2.INTER_NEAREST,
                                borderMode=cv2.BORDER_CONSTANT,
                                borderValue=(0, 0, 0, 0))
        canvas.alpha_composite(Image.fromarray(warped, mode="RGBA"))
    positions = {}
    largest_gap = 0.0
    for name, joint in report["joints"].items():
        first, second = joint["connects"]
        first_xy = point(transforms[first], joint["center"])
        second_xy = point(transforms[second], joint["center"])
        gap = math.dist(first_xy, second_xy)
        largest_gap = max(largest_gap, gap)
        positions[name] = [round(first_xy[0] + padding, 2), round(first_xy[1] + padding, 2)]
    return canvas, {"joint_positions": positions, "fit_shift_px": [round(fit[0], 1), round(fit[1], 1)],
                    "max_parent_child_joint_gap_px": round(largest_gap, 6)}


def make_pose_previews(analysis_path: Path, output_dir: Path) -> dict[str, Any]:
    report = json.loads(analysis_path.read_text(encoding="utf-8"))
    if any(part["status"] != "EXTRACTED" for name, part in report["parts"].items()
           if name not in OPTIONAL_PARTS):
        raise ValueError("Pose previews require all twelve required parts")
    if len(report["joints"]) != 11:
        raise ValueError("Pose previews require all eleven mapped joints")
    output_dir.mkdir(parents=True, exist_ok=True)
    pose_data = {}
    thumbnails = []
    for name, definition in POSES.items():
        image, metrics = render_pose(report, definition)
        clean_path = output_dir / f"{name}.png"
        image.save(clean_path)
        annotated = Image.new("RGBA", image.size, (40, 42, 50, 255))
        annotated.alpha_composite(image)
        draw = ImageDraw.Draw(annotated)
        for xy in metrics["joint_positions"].values():
            x, y = xy
            draw.ellipse((x - 5, y - 5, x + 5, y + 5),
                         fill=(0, 255, 255, 255), outline=(0, 0, 0, 255), width=2)
        annotated_path = output_dir / f"{name}-joints.png"
        annotated.convert("RGB").save(annotated_path)
        thumbnail = annotated.convert("RGB")
        thumbnail.thumbnail((400, 520), Image.Resampling.LANCZOS)
        thumbnails.append((name, thumbnail))
        pose_data[name] = {"angles_degrees_clockwise": definition.get("angles", {}),
                           "root_offset_px": definition.get("offset", (0, 0)),
                           "native_rgba": str(clean_path.resolve()),
                           "joint_overlay": str(annotated_path.resolve()), **metrics}
    columns = min(SHEET_COLUMNS, len(thumbnails))
    rows = -(-len(thumbnails) // columns)
    sheet = Image.new("RGB", (400 * columns, 564 * rows), (27, 30, 37))
    label = ImageDraw.Draw(sheet)
    for index, (name, thumb) in enumerate(thumbnails):
        x, y = (index % columns) * 400, (index // columns) * 564
        label.text((x + 12, y + 10), name.replace("_", " ").title(),
                   fill="white", font=ImageFont.load_default())
        sheet.paste(thumb, (x + (400 - thumb.width) // 2, y + 36))
    sheet_path = output_dir / "pose-sheet.png"
    sheet.save(sheet_path)
    result = {"note": "Rigid no-scale articulation diagnostic; hidden pixels are not reconstructed.",
              "source_canvas": report["canvas"], "padding_px": 300,
              "native_canvas": list(image.size), "sheet": str(sheet_path.resolve()),
              "poses": pose_data}
    (output_dir / "pose-report.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("analysis", type=Path)
    parser.add_argument("output_dir", type=Path)
    args = parser.parse_args()
    report = make_pose_previews(args.analysis, args.output_dir)
    print(json.dumps({"pose_sheet": report["sheet"], "pose_count": len(report["poses"])}, indent=2))


if __name__ == "__main__":
    main()
