#!/usr/bin/env python3
"""Publish a whole-character workflow result as a playable fighter rig.

Reads the (repaired) analysis from tools/whole_character_workflow.py and writes
assets/fighters/rigged/<fighter>/ in the format SkeletonRigSkin loads, with
render_mode "whole_character":

- the twelve parts under the game's slot names (far limbs become "left",
  which the game draws behind the torso; near limbs become "right"),
- pivots and tips from the workflow's joints, in source-canvas pixels,
- torso landmarks (neck, shoulders, hips) for the game's shoulder and hip roots,
- optional attachments: a back accessory riding on the torso and a held item
  riding on its hand,
- pixel_scale chosen so the torso is as long as the other fighters' torsos,
- rig.json hashes, so a stale or hand-edited profile is rejected at load.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
RIG_ROOT = ROOT / "assets/fighters/rigged"
CONTRACT = RIG_ROOT / "contract.json"
# Game torso length (shoulders to hips) shared with the preserved-proportion rigs.
TARGET_TORSO_UNITS = 67.2
# The game's "left" limbs are the screen-left ones (behind, rooted at negative
# x when facing right), so the workflow's screen-left "near" limbs map there.
SLOTS = {
    "torso_pelvis": "torso", "head_neck": "head",
    "near_upper_arm": "left_upper_arm", "near_forearm_hand": "left_forearm",
    "far_upper_arm": "right_upper_arm", "far_forearm_hand": "right_forearm",
    "near_thigh": "left_thigh", "far_thigh": "right_thigh",
    "near_shin": "left_shin", "far_shin": "right_shin",
    "near_foot": "left_boot", "far_foot": "right_boot",
}
SIDES = ("near", "far")  # order of the torso's [left, right] landmarks
# A two-bone arm cannot fold tighter than |upper - forearm|. When the visible
# upper arm is much shorter (its top hidden in the torso), its true shoulder
# joint sits higher inside the body: move the pivot up the arm, not the art.
MIN_UPPER_TO_FOREARM = 0.85
ATTACHMENTS = {"back_accessory", "held_item"}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def part_mask(metadata: dict[str, Any]) -> tuple[np.ndarray, tuple[int, int]]:
    with Image.open(metadata["image"]) as image:
        alpha = np.asarray(image.convert("RGBA"))[:, :, 3] > 0
    return alpha, tuple(metadata["crop_origin"])


def far_end(metadata: dict[str, Any], start: list[float], share: float = 0.2) -> list[float]:
    """Center of the part's pixels farthest from `start`: a hand, or a head's crown."""
    alpha, (ox, oy) = part_mask(metadata)
    ys, xs = np.nonzero(alpha)
    points = np.stack((xs + ox, ys + oy), axis=1).astype(np.float64)
    distance = np.linalg.norm(points - np.array(start), axis=1)
    far = points[distance >= np.quantile(distance, 1.0 - share)]
    return [round(float(far[:, 0].mean()), 2), round(float(far[:, 1].mean()), 2)]


def sole_center(metadata: dict[str, Any]) -> list[float]:
    alpha, (ox, oy) = part_mask(metadata)
    ys, xs = np.nonzero(alpha)
    bottom = ys >= ys.max() - max(4, int((ys.max() - ys.min()) * 0.15))
    return [round(float(xs[bottom].mean() + ox), 2), round(float(ys.max() + oy - 2), 2)]


def width(metadata: dict[str, Any]) -> float:
    alpha, _ = part_mask(metadata)
    return round(2.0 * float(cv2.distanceTransform(alpha.astype(np.uint8), cv2.DIST_L2, 3).max()), 2)


def midpoint(a: list[float], b: list[float]) -> list[float]:
    return [round((a[0] + b[0]) / 2, 2), round((a[1] + b[1]) / 2, 2)]


def rect(metadata: dict[str, Any]) -> list[int]:
    x, y = metadata["crop_origin"]
    w, h = metadata["crop_size"]
    return [int(x), int(y), int(x + w), int(y + h)]


def export(analysis_path: Path, fighter: str, output: Path | None = None) -> Path:
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    parts, joints = analysis["parts"], {name: joint["center"] for name, joint in analysis["joints"].items()}
    for side in ("near", "far"):
        # Runs made before the workflow placed dot-less shoulders at the arm's top end.
        if analysis["joints"][f"{side}_shoulder"].get("method") == "contact center":
            joints[f"{side}_shoulder"] = far_end(parts[f"{side}_upper_arm"], joints[f"{side}_elbow"])
    missing = [name for name in SLOTS if parts.get(name, {}).get("status") != "EXTRACTED"]
    if missing or len(joints) != 11:
        raise ValueError(f"Need all twelve parts and eleven joints; missing parts {missing}, joints {len(joints)}")
    target = output or RIG_ROOT / fighter
    target.mkdir(parents=True, exist_ok=True)
    for side in SIDES:
        elbow = np.array(joints[f"{side}_elbow"])
        shoulder = np.array(joints[f"{side}_shoulder"])
        hand = np.array(far_end(parts[f"{side}_forearm_hand"], joints[f"{side}_elbow"]))
        upper, forearm = np.linalg.norm(shoulder - elbow), np.linalg.norm(hand - elbow)
        if upper > 0 and upper < MIN_UPPER_TO_FOREARM * forearm:
            shoulder = elbow + (shoulder - elbow) / upper * MIN_UPPER_TO_FOREARM * forearm
            joints[f"{side}_shoulder"] = [round(float(shoulder[0]), 2), round(float(shoulder[1]), 2)]
    shoulders = [joints[f"{side}_shoulder"] for side in SIDES]
    hips = [joints[f"{side}_hip"] for side in SIDES]
    axes = {
        "torso_pelvis": (midpoint(*shoulders), midpoint(*hips)),
        "head_neck": (joints["neck"], far_end(parts["head_neck"], joints["neck"])),
    }
    for side in ("near", "far"):
        axes[f"{side}_upper_arm"] = (joints[f"{side}_shoulder"], joints[f"{side}_elbow"])
        axes[f"{side}_forearm_hand"] = (joints[f"{side}_elbow"],
                                        far_end(parts[f"{side}_forearm_hand"], joints[f"{side}_elbow"]))
        axes[f"{side}_thigh"] = (joints[f"{side}_hip"], joints[f"{side}_knee"])
        axes[f"{side}_shin"] = (joints[f"{side}_knee"], joints[f"{side}_ankle"])
        axes[f"{side}_foot"] = (joints[f"{side}_ankle"], sole_center(parts[f"{side}_foot"]))
    profile_parts = {}
    for name, slot in SLOTS.items():
        pivot, tip = axes[name]
        if pivot == tip:
            tip = [tip[0], tip[1] + 1.0]
        shutil.copy2(parts[name]["image"], target / f"{slot}.png")
        profile_parts[slot] = {"rect": rect(parts[name]), "pivot": pivot, "tip": tip,
                               "source_slot": slot, "source_width": width(parts[name]), "workflow_part": name}
    profile_parts["torso"].update({"neck": joints["neck"], "shoulders": shoulders, "hips": hips})
    attachments = {}
    for name in ATTACHMENTS:
        metadata = parts.get(name, {})
        if metadata.get("status") != "EXTRACTED":
            continue
        parent = "torso" if name == "back_accessory" else SLOTS[metadata.get("attached_to", "near_forearm_hand")]
        shutil.copy2(metadata["image"], target / f"{name}.png")
        attachments[name] = {"parent": parent, "rect": rect(metadata), "image": f"{name}.png",
                             # Back accessories sit behind everything; a held item just behind its hand.
                             "layer": "back" if name == "back_accessory" else "behind_parent"}
    torso_length = float(np.linalg.norm(np.subtract(*axes["torso_pelvis"])))
    profile = {"schema_version": 3, "fighter_id": fighter, "body_type": "standard",
               "render_mode": "whole_character", "pixel_scale": round(TARGET_TORSO_UNITS / torso_length, 6),
               "source_canvas": analysis["canvas"], "parts": profile_parts, "attachments": attachments,
               "source_analysis": str(analysis_path.resolve().relative_to(ROOT))
               if analysis_path.resolve().is_relative_to(ROOT) else analysis_path.name}
    profile_path = target / "profile.json"
    profile_path.write_text(json.dumps(profile, indent=2) + "\n", encoding="utf-8")
    # The fighter-select card shows this head.
    shutil.copy2(parts["head_neck"]["image"], target / "head.png")
    manifest = {"version": 3, "fighter_id": fighter, "workflow": "whole_character", "canvas": analysis["canvas"],
                "profile_sha256": sha256(profile_path), "contract_sha256": sha256(CONTRACT),
                "note": "Candidate from tools/whole_character_workflow.py; not part of the v3 atlas review."}
    (target / "rig.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("analysis", type=Path, help="inspection/repair/repaired-analysis.json or inspection/analysis.json")
    parser.add_argument("--fighter", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    print(export(args.analysis, args.fighter, args.output))
