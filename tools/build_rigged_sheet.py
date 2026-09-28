#!/usr/bin/env python3
"""Validate an entire chroma sheet BEFORE splitting or publishing any pixels.

Rectangles and joint coordinates live together in profile.json. No component
deletion, automatic limb detection, trimming, or silent clipping is allowed.
"""
import argparse
import hashlib
import json
import re
import tempfile
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

CANVAS_SIZE = (1024, 1536)
ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = ROOT / "assets/fighters/rigged/contract.json"


def contract():
    return json.loads(CONTRACT_PATH.read_text())


def category(name):
    return name.removeprefix("left_").removeprefix("right_")


def axis_width(mask, pivot, tip):
    ys, xs = np.where(mask)
    axis = np.subtract(tip, pivot).astype(float)
    axis /= np.linalg.norm(axis)
    across = (xs - pivot[0]) * -axis[1] + (ys - pivot[1]) * axis[0]
    return float(np.ptp(across) + 1)


def foreground(rgba):
    """Remove only border-connected magenta; preserve enclosed costume colors."""
    rgb = rgba[:, :, :3].astype(np.int16)
    r, g, b = rgb.transpose(2, 0, 1)
    candidate = ((r > 100) & (b > 100) & (g < 90)
                 & (abs(r - b) < 75)) | (rgba[:, :, 3] == 0)
    _, labels = cv2.connectedComponents(candidate.astype(np.uint8), connectivity=8)
    edge_labels = np.unique(np.concatenate((labels[0], labels[-1], labels[:, 0], labels[:, -1])))
    edge_labels = edge_labels[edge_labels != 0]
    return (rgba[:, :, 3] > 0) & ~np.isin(labels, edge_labels)


def prepare(source, profile):
    required = {"head", "torso"} | {side + "_" + part for side in ("left", "right")
                                    for part in ("upper_arm", "forearm", "thigh", "shin", "boot")}
    if set(profile["parts"]) != required:
        raise ValueError("Expected exactly twelve named body parts; missing or unknown parts")
    image = Image.fromarray(source) if isinstance(source, np.ndarray) else Image.open(source).convert("RGBA")
    if image.size != CANVAS_SIZE:
        raise ValueError(f"Expected {CANVAS_SIZE}, got {image.size}. Normalize the reference and coordinates explicitly first.")
    rgba = np.array(image)
    mask = foreground(rgba)
    owned = np.zeros(mask.shape, dtype=bool)
    parts = {}
    for name, definition in profile["parts"].items():
        x0, y0, x1, y1 = definition["rect"]
        if not (0 <= x0 < x1 <= 1024 and 0 <= y0 < y1 <= 1536):
            raise ValueError(f"{name}: invalid rectangle")
        if owned[y0:y1, x0:x1].any():
            raise ValueError(f"{name}: overlapping rectangles")
        owned[y0:y1, x0:x1] = True
        part_mask = mask[y0:y1, x0:x1]
        excluded = 0
        if "outline" in definition:
            if name != "head" or not definition.get("outline_reason"):
                raise ValueError("Only an explicitly documented head/bust ownership mask is supported")
            polygon = np.array(definition["outline"],dtype=np.int32)-[x0,y0]
            ownership = np.zeros(part_mask.shape,dtype=np.uint8)
            cv2.fillPoly(ownership,[polygon.astype(np.int32)],1)
            excluded = int((part_mask & (ownership==0)).sum())
            part_mask &= ownership>0
        ys, xs = np.where(part_mask)
        if not len(xs):
            raise ValueError(f"{name}: empty rectangle")
        margin = min(xs.min(), ys.min(), x1-x0-1-xs.max(), y1-y0-1-ys.max())
        minimum_margin = 1 if profile.get("render_mode") == "preserve_proportions" else 4
        if margin < minimum_margin:
            edges = {"left": int(xs.min()), "top": int(ys.min()),
                     "right": int(x1-x0-1-xs.max()), "bottom": int(y1-y0-1-ys.max())}
            failing_edge = min(edges, key=edges.get)
            if failing_edge == "left":
                sample = int(np.argmin(xs))
            elif failing_edge == "right":
                sample = int(np.argmax(xs))
            elif failing_edge == "top":
                sample = int(np.argmin(ys))
            else:
                sample = int(np.argmax(ys))
            page_pixel = [int(x0+xs[sample]), int(y0+ys[sample])]
            raise ValueError(f"{name}: artwork touches crop boundary (margin {margin}px; "
                             f"need {minimum_margin}px); edge clearances {edges}; "
                             f"nearest {failing_edge} foreground pixel at page {page_pixel}; refusing to clip")
        for key in ("pivot", "tip", "neck"):
            if key not in definition:
                continue
            x, y = definition[key]
            if not np.isfinite([x,y]).all() or not (x0 <= x < x1 and y0 <= y < y1):
                raise ValueError(f"{name}: {key} outside rectangle")
        for key in ("shoulders", "hips"):
            if key not in definition:
                continue
            points = definition[key]
            if not isinstance(points, list) or len(points) != 2:
                raise ValueError(f"{name}: {key} must contain two landmarks")
            for point in points:
                x, y = point
                if not np.isfinite([x,y]).all() or not (x0 <= x < x1 and y0 <= y < y1):
                    raise ValueError(f"{name}: {key} landmark outside rectangle")
        if definition["pivot"] == definition["tip"]:
            raise ValueError(f"{name}: zero length joint axis")
        if name.endswith("boot") and profile.get("schema_version",0) >= 3:
            a = np.subtract(definition["pivot"],[x0,y0]).astype(float)
            axis = np.subtract(definition["tip"],definition["pivot"]).astype(float)
            length = np.linalg.norm(axis)
            axis /= length
            points = np.column_stack((xs,ys))-a
            sole = points[(points @ axis) >= length*0.65]
            right = sole @ np.array([axis[1],-axis[0]])
            if not len(right) or right.max() < max(8,abs(right.min())*1.2):
                raise ValueError(f"{name}: toe must extend to the right of the heel in side view")
        if profile.get("schema_version", 0) >= 3:
            distance = cv2.distanceTransform(part_mask.astype(np.uint8), cv2.DIST_L2, 5)
            for key in ("pivot", "tip"):
                x, y = definition[key]
                if not np.isfinite([x, y]).all():
                    raise ValueError(f"{name}: non-finite {key}")
                radius = float(distance[int(y-y0), int(x-x0)])
                if radius < 10:
                    raise ValueError(f"{name}: {key} has only {radius:.1f}px of opaque joint coverage; need 10px")
        parts[name] = {"rect": [x0,y0,x1,y1], "texture": name+".png",
                       "margin": int(margin), "pixels": int(part_mask.sum()), "excluded_duplicate_bust_pixels":excluded}
    lost = int((mask & ~owned).sum())
    if lost:
        raise ValueError(f"{lost} foreground pixels outside rectangles; refusing to discard artwork")
    rgba[:, :, 3] = mask.astype(np.uint8) * 255
    rgba[~mask, :3] = 0
    return rgba, parts


def compile_sheet(source, binding):
    """Map reviewed source landmarks into one shared, vertical, named layout.

    Resampling is explicit. Every foreground pixel is checked against its
    destination rectangle before warping. No fitting by clipping or deletion.
    """
    rgba, _ = prepare(source, binding)
    if binding.get("render_mode") == "preserve_proportions":
        from rig_coordinate_contract import audit_binding
        reference = binding.get("coordinate_contract", {})
        if not reference:
            raise ValueError("Original marker coordinate contract is required for preserved rigs")
        marker_path = (ROOT / binding["source"]).parent / reference["marker_json"]
        if digest(marker_path.read_bytes()) != reference["marker_json_sha256"]:
            raise ValueError("Original extracted marker file changed")
        audit_binding(binding, json.loads(marker_path.read_text()))
        scale = float(binding.get("pixel_scale", 0))
        if not np.isfinite(scale) or scale <= 0:
            raise ValueError("Preserved artwork requires one positive pixel_scale")
        compiled = {"schema_version": 3, "fighter_id": binding["fighter_id"],
                    "body_type": binding.get("body_type", "standard"),
                    "render_mode": "preserve_proportions", "pixel_scale": scale,
                    "parts": {}}
        if "coordinate_contract" in binding:
            compiled["coordinate_contract"] = binding["coordinate_contract"]
        for name, part in binding["parts"].items():
            x0, y0, x1, y1 = part["rect"]
            mask = rgba[y0:y1, x0:x1, 3] > 0
            compiled["parts"][name] = {
                **part, "source_slot": name,
                "source_width": axis_width(mask, np.subtract(part["pivot"], [x0, y0]),
                                           np.subtract(part["tip"], [x0, y0]))}
        return rgba, compiled
    spec = contract()
    shape = spec["body_types"][binding.get("body_type", "standard")]
    output = np.zeros_like(rgba)
    compiled = {"schema_version": 3, "fighter_id": binding["fighter_id"],
                "body_type": binding.get("body_type", "standard"), "parts": {}}
    for name in spec["part_order"]:
        part = binding["parts"][name]
        slot = spec["slots"][name]
        x0,y0,x1,y1 = part["rect"]
        pixels = rgba[y0:y1,x0:x1]
        mask = pixels[:,:,3] > 0
        a = np.subtract(part["pivot"], [x0,y0]).astype(float)
        b = np.subtract(part["tip"], [x0,y0]).astype(float)
        u = (b-a) / np.linalg.norm(b-a)
        v = np.array([-u[1], u[0]])
        d0 = np.array(slot["pivot"], dtype=float)
        d1 = np.array(slot["tip"], dtype=float)
        du = (d1-d0) / np.linalg.norm(d1-d0)
        dv = np.array([-du[1], du[0]])
        kind = category(name)
        target_length = {"head":shape["head_length"], "torso":67, "upper_arm":48,
                         "forearm":50, "thigh":64, "shin":32, "boot":shape["boot_length"]}[kind]
        width = axis_width(mask, a, b)
        dest_width = shape[kind] * np.linalg.norm(d1-d0) / target_length
        matrix = np.outer(du,u) * (np.linalg.norm(d1-d0)/np.linalg.norm(b-a)) + np.outer(dv,v) * (dest_width/width)
        offset = d0 - matrix @ a
        ys,xs = np.where(mask)
        mapped = np.column_stack((xs,ys)) @ matrix.T + offset
        r = slot["rect"]
        if ((mapped.min(axis=0) < np.array(r[:2])+5).any()
                or (mapped.max(axis=0) > np.array(r[2:])-6).any()):
            raise ValueError(f"{name}: normalized bounds {mapped.min(axis=0).round(1)} to {mapped.max(axis=0).round(1)} exceed slot {r}; correct landmarks or template, never crop")
        transform = np.column_stack((matrix, offset - np.array(r[:2])))
        warped = cv2.warpAffine(pixels, transform, (r[2]-r[0],r[3]-r[1]), flags=cv2.INTER_NEAREST)
        output[r[1]:r[3],r[0]:r[2]] = warped
        compiled_part = {**slot, "source_slot":name, "source_width":dest_width}
        if name == "torso" and "neck" in part:
            source_neck = np.subtract(part["neck"], [x0, y0]).astype(float)
            mapped_neck = source_neck @ matrix.T + offset
            compiled_part["neck"] = mapped_neck.round(6).tolist()
        if name == "torso":
            for landmark_name in ("shoulders", "hips"):
                if landmark_name not in part:
                    continue
                mapped_landmarks = []
                for landmark in part[landmark_name]:
                    source_landmark = np.subtract(landmark, [x0, y0]).astype(float)
                    mapped_landmark = source_landmark @ matrix.T + offset
                    mapped_landmarks.append(mapped_landmark.round(6).tolist())
                compiled_part[landmark_name] = mapped_landmarks
        compiled["parts"][name] = compiled_part
    # The actual resampled pixels must still enclose each joint and leave gaps.
    prepare(output, compiled)
    return output, compiled


def digest(data):
    return hashlib.sha256(data).hexdigest()


def publish(source, binding_path, output_dir, output_sheet, normalize=True):
    """Validate the whole candidate before writing, then publish manifest last.

    The manifest hashes make interrupted/mixed builds fail the export check.
    Failed validation leaves all previously published files untouched.
    """
    binding = json.loads(binding_path.read_text())
    fighter_id = binding.get("fighter_id", "")
    if not re.fullmatch(r"[a-z][a-z0-9_]{0,63}", fighter_id):
        raise ValueError("fighter_id must contain only lowercase letters, digits and underscores")
    sheet, slots = prepare(source, binding)
    excluded = sum(p["excluded_duplicate_bust_pixels"] for p in slots.values())
    profile = binding
    if normalize:
        sheet, profile = compile_sheet(source, binding)
        _, slots = prepare(sheet, profile)
    profile_bytes = (json.dumps(profile, indent=2)+"\n").encode()
    report = {"version":3 if normalize else 2, "fighter_id":fighter_id, "canvas":list(CANVAS_SIZE),
              "source":str(source), "source_sha256":digest(source.read_bytes()),
              "binding_sha256":digest(binding_path.read_bytes()), "contract_sha256":digest(CONTRACT_PATH.read_bytes()),
              "profile_sha256":digest(profile_bytes), "foreground_pixels":int((sheet[:,:,3]>0).sum()),
              "cropped_foreground_pixels":0, "resampled":normalize and binding.get("render_mode") != "preserve_proportions", "slots":slots, "textures_sha256":{}}
    report["excluded_duplicate_bust_pixels"] = excluded
    try:
        report["sheet"] = str(output_sheet.resolve().relative_to(ROOT))
    except ValueError:
        report["sheet"] = str(output_sheet.resolve())
    output_dir.mkdir(parents=True, exist_ok=True)
    output_sheet.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="rig-build-", dir=output_dir.parent) as temporary:
        staged = Path(temporary)
        for name, slot in slots.items():
            x0,y0,x1,y1 = slot["rect"]
            Image.fromarray(sheet[y0:y1,x0:x1]).save(staged / (name+".png"))
            report["textures_sha256"][name] = digest((staged/(name+".png")).read_bytes())
        Image.fromarray(sheet).save(staged/"sheet.png")
        report["sheet_sha256"] = digest((staged/"sheet.png").read_bytes())
        (staged/"profile.json").write_bytes(profile_bytes)
        (staged/"rig.json").write_text(json.dumps(report,indent=2)+"\n")
        for name in slots:
            (staged/(name+".png")).replace(output_dir/(name+".png"))
        (staged/"sheet.png").replace(output_sheet)
        (staged/"profile.json").replace(output_dir/"profile.json")
        (staged/"rig.json").replace(output_dir/"rig.json")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--fighter-id", required=True)
    parser.add_argument("--output-sheet", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--normalize", action="store_true", help="Compile source.json into the shared v3 layout")
    args = parser.parse_args()
    profile_path = args.profile or args.output_dir / "profile.json"
    profile = json.loads(profile_path.read_text())
    if profile.get("fighter_id") != args.fighter_id:
        raise ValueError("Fighter id does not match binding")
    if args.check:
        (compile_sheet if args.normalize else prepare)(args.source, profile)
        report = {"valid":True, "fighter_id":args.fighter_id, "wrote_files":False}
    else:
        report = publish(args.source, profile_path, args.output_dir, args.output_sheet, args.normalize)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
