#!/usr/bin/env python3
"""Export a native editable Godot Skeleton2D scene from whole-image pivots.

This is an inspection candidate, not a production v3 rig or accepted fighter.
"""

from __future__ import annotations

import json
import math
from pathlib import Path
from typing import Any

from render_whole_character_poses import KINEMATIC_ORDER, OPTIONAL_PARTS, PARENTS, draw_order, parent_of


def number(value: float) -> str:
    return f"{value:.6f}".rstrip("0").rstrip(".") if value else "0"


def vector(x: float, y: float) -> str:
    return f"Vector2({number(x)}, {number(y)})"


def export_godot_scene(analysis_path: Path, output_path: Path, project_root: Path) -> dict[str, Any]:
    report = json.loads(analysis_path.read_text(encoding="utf-8"))
    if len(report["joints"]) != 11 or any(
            part["status"] != "EXTRACTED" for name, part in report["parts"].items()
            if name not in OPTIONAL_PARTS):
        raise ValueError("Native scene requires twelve extracted parts and eleven joints")
    order = [name for name in KINEMATIC_ORDER
             if report["parts"].get(name, {}).get("status") == "EXTRACTED"]
    # Same back-to-front order as the pose previews.
    layers = draw_order(report)
    # Layers start at 0 and stay relative to the rig node, so the back layers
    # never sink behind whatever the rig is placed on.
    z_index = {name: index for index, name in enumerate(layers)}
    try:
        output_path.resolve().relative_to(project_root.resolve())
    except ValueError as error:
        raise ValueError("Godot scene must be inside the project") from error
    lines = [f"[gd_scene load_steps={len(order) + 1} format=3]", ""]
    for index, name in enumerate(order, start=1):
        image = Path(report["parts"][name]["image"]).resolve()
        try:
            relative = image.relative_to(project_root.resolve())
        except ValueError as error:
            raise ValueError(f"Part image is outside the Godot project: {image}") from error
        lines.extend([f'[ext_resource type="Texture2D" path="res://{relative.as_posix()}" id="{index}"]', ""])
    lines.extend(['[node name="WholeCharacterCandidate" type="Node2D"]',
                  'editor_description = "Inspection candidate. Rotate native bones to review joints; do not promote without repair and v3 validation."',
                  "", '[node name="Skeleton2D" type="Skeleton2D" parent="."]', ""])
    joints = report["joints"]
    hips = [(joints["near_hip"]["center"][axis] + joints["far_hip"]["center"][axis]) / 2
            for axis in (0, 1)]
    anchors: dict[str, list[float]] = {"torso_pelvis": hips}
    paths: dict[str, str] = {}
    for index, name in enumerate(order, start=1):
        if name == "torso_pelvis":
            parent_path = "Skeleton2D"
            anchor = hips
            delta = anchor
            target = joints["neck"]["center"]
        elif parent_of(report, name)[1] is None:
            parent_name = parent_of(report, name)[0]
            parent_path = paths[parent_name]
            anchor = anchors[parent_name]
            delta = [0.0, 0.0]
            target = [anchor[0], anchor[1] + 30]
        else:
            parent_name, joint = PARENTS[name]
            parent_path = paths[parent_name]
            anchor = joints[joint]["center"]
            parent_anchor = anchors[parent_name]
            delta = [anchor[0] - parent_anchor[0], anchor[1] - parent_anchor[1]]
            children = [key for key, value in PARENTS.items() if value[0] == name and value[1]]
            target = joints[PARENTS[children[0]][1]]["center"] if children else [anchor[0], anchor[1] + 30]
        anchors[name] = anchor
        bone_name = name.title().replace("_", "") + "Bone"
        path = parent_path + "/" + bone_name
        paths[name] = path
        length = max(1.0, math.dist(anchor, target))
        lines.extend([f'[node name="{bone_name}" type="Bone2D" parent="{parent_path}"]',
                      f'editor_description = "Source pivot: {name}. No individual part scaling."',
                      f'position = {vector(*delta)}',
                      f'rest = Transform2D(1, 0, 0, 1, {number(delta[0])}, {number(delta[1])})',
                      'auto_calculate_length_and_angle = false',
                      f'length = {number(length)}', 'bone_angle = 0.0', ""])
        part = report["parts"][name]
        origin = part["crop_origin"]
        size = part["crop_size"]
        center = [origin[0] + size[0] / 2, origin[1] + size[1] / 2]
        position = [center[0] - anchor[0], center[1] - anchor[1]]
        lines.extend([f'[node name="{name.title().replace("_", "")}Sprite" type="Sprite2D" parent="{path}"]',
                      'texture_filter = 1', f'z_index = {z_index[name]}',
                      f'position = {vector(*position)}', f'texture = ExtResource("{index}")', ""])
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(lines), encoding="utf-8")
    return {"scene": str(output_path.resolve()), "kind": "native_inspection_candidate",
            "bones": len(order), "pixel_scale": 1.0,
            "note": "Source crop positions and pivots are preserved. Not a production v3 import."}
