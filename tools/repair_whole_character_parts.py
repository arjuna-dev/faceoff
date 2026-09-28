#!/usr/bin/env python3
"""Complete occluded rig parts with one magenta-fill call per part.

Only the part itself is sent: its pixels at their original page position on a
flat green background, with the hidden area (from detect_part_repairs) painted
magenta. The prompt is built from detection alone: it names which parts
covered this one. Code keeps every original pixel and accepts new art only
inside the magenta area, so no other body part can be added.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import cv2
import numpy as np
from PIL import Image

from review_whole_character_parts import build_review_sheet
from whole_character_workflow import aspect_ratio_for
from render_whole_character_poses import make_pose_previews


ROOT = Path(__file__).resolve().parents[1]
PROMPTS = ROOT / "prompts/workflows"
MAGENTA = (255, 0, 255)
GREEN = (0, 255, 0)
GUIDANCE = json.loads((PROMPTS / "whole_character_part_guidance.json").read_text(encoding="utf-8"))
# New strokes may blend this far past the marked area into the part's outline.
EDGE_BAND_PX = 4
# The model may shift the whole image slightly; search this far for alignment.
MAX_SHIFT_PX = 8
MAX_ALIGNED_DIFFERENCE = 45.0


def repair_canvas(part: Image.Image, origin: tuple[int, int], fill: np.ndarray,
                  canvas_size: tuple[int, int], output: Path) -> np.ndarray:
    """Part at its page position on green, with the area to complete in magenta."""
    canvas = np.full((canvas_size[1], canvas_size[0], 3), GREEN, dtype=np.uint8)
    canvas[fill] = MAGENTA
    rgba = np.asarray(part.convert("RGBA"))
    x, y = origin
    visible = rgba[:, :, 3] > 0
    canvas[y:y + rgba.shape[0], x:x + rgba.shape[1]][visible] = rgba[:, :, :3][visible]
    output.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(canvas, mode="RGB").save(output)
    return canvas


READABLE = {"head_neck": "head and neck", "torso_pelvis": "torso", "back_accessory": "back accessory",
            "near_forearm_hand": "near forearm and hand", "far_forearm_hand": "far forearm and hand"}


def readable(name: str) -> str:
    return READABLE.get(name, name.replace("_", " "))


def build_repair_prompt(part: str, item: dict[str, Any], canvas_size: tuple[int, int]) -> str:
    """Build the repair prompt from detection alone: which parts covered this one, and where."""
    target = readable(part)
    covers = [name for name in item.get("covered_by", {}) if name != "enclosed gaps"]
    lines = [f"This is the {target} of a 2D cut-out game character ({GUIDANCE[part]}), on a flat green "
             "#00FF00 background. Solid magenta #FF00FF marks where other body parts were in front of it:"]
    lines += [f"- magenta where the {readable(name)} covered the {target}" for name in covers]
    if "enclosed gaps" in item.get("covered_by", {}):
        lines.append(f"- magenta in gaps enclosed by the {target}")
    lines += ["",
              f"Remove all the magenta, leaving behind it the {target}: continue the {target}'s own shapes, "
              "colors, outlines and shading. Where the " + target + " does not reach, leave green background.",
              "Do not draw the " + " or the ".join(readable(name) for name in covers) + "; they are separate rig pieces."
              if covers else "Do not draw any other body part.",
              f"Keep every other pixel unchanged. Return the same {canvas_size[0]} x {canvas_size[1]} image."]
    return "\n".join(lines) + "\n"


def is_magenta(rgb: np.ndarray) -> np.ndarray:
    red, green, blue = (rgb[:, :, index].astype(np.int16) for index in range(3))
    return (red > 140) & (blue > 140) & (red - green > 80) & (blue - green > 80)


def is_green(rgb: np.ndarray) -> np.ndarray:
    red, green, blue = (rgb[:, :, index].astype(np.int16) for index in range(3))
    return (green > 140) & (green - red > 80) & (green - blue > 80)


def best_alignment(generated: np.ndarray, reference: np.ndarray,
                   own: np.ndarray) -> tuple[tuple[int, int], float]:
    """Find the integer shift that best maps generated pixels onto the original part."""
    ys, xs = np.nonzero(own)
    step = max(1, len(xs) // 40000)
    ys, xs = ys[::step], xs[::step]
    target = reference[ys, xs].astype(np.int16)
    height, width = own.shape
    best = ((0, 0), float("inf"))
    for dy in range(-MAX_SHIFT_PX, MAX_SHIFT_PX + 1):
        for dx in range(-MAX_SHIFT_PX, MAX_SHIFT_PX + 1):
            sy = np.clip(ys + dy, 0, height - 1)
            sx = np.clip(xs + dx, 0, width - 1)
            difference = float(np.abs(generated[sy, sx].astype(np.int16) - target).mean())
            if difference < best[1]:
                best = ((dx, dy), difference)
    return best


def apply_repair(part: Image.Image, origin: tuple[int, int], generated_path: Path,
                 own: np.ndarray, fill: np.ndarray, sent: np.ndarray, canvas_size: tuple[int, int],
                 pivots: dict[str, Any], output_path: Path, mask_path: Path) -> dict[str, Any]:
    with Image.open(generated_path) as raw:
        returned_size = raw.size
        if raw.size != canvas_size:
            # The model returns fixed sizes per aspect ratio. Only new pixels are
            # taken from this image; original part pixels are never resampled.
            if abs(raw.width / raw.height - canvas_size[0] / canvas_size[1]) > 0.02:
                raise ValueError(f"Repair output {raw.size} has a different aspect ratio than {canvas_size}")
            raw = raw.resize(canvas_size, Image.Resampling.LANCZOS)
        generated = np.asarray(raw.convert("RGB"))
    (dx, dy), difference = best_alignment(generated, sent, own)
    if difference > MAX_ALIGNED_DIFFERENCE:
        raise ValueError(f"Repair redrew the existing part (mean difference {difference:.1f} after best "
                         f"shift {dx},{dy}); expected only the magenta area to change")
    shifted = np.roll(generated, shift=(-dy, -dx), axis=(0, 1))
    kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * EDGE_BAND_PX + 1,) * 2)
    allowed = (cv2.dilate(fill.astype(np.uint8), kernel) > 0) & ~own
    painted = ~is_magenta(shifted) & ~is_green(shifted)
    new_art = allowed & painted
    # Keep only additions touching the existing part, never detached islands.
    _, labels = cv2.connectedComponents((new_art | own).astype(np.uint8), connectivity=8)
    new_art &= np.isin(labels, np.unique(labels[own]))
    outside = int((painted & ~own & ~allowed).sum())
    left_magenta = int((fill & is_magenta(shifted)).sum())
    gained = int(new_art.sum())
    if gained == 0:
        raise ValueError("Repair added no artwork to the magenta area")
    rgba = np.asarray(part.convert("RGBA"))
    x, y = origin
    result = np.zeros((canvas_size[1], canvas_size[0], 4), dtype=np.uint8)
    result[new_art, :3] = shifted[new_art]
    result[new_art, 3] = 255
    visible = rgba[:, :, 3] > 0
    result[y:y + rgba.shape[0], x:x + rgba.shape[1]][visible] = rgba[visible]
    Image.fromarray((new_art.astype(np.uint8) * 255), mode="L").save(mask_path)
    alpha = result[:, :, 3] > 0
    ys, xs = np.nonzero(alpha)
    x0, y0, x1, y1 = int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1
    Image.fromarray(result[y0:y1, x0:x1], mode="RGBA").save(output_path)
    return {"added_foreground_pixels": gained, "marked_pixels": int(fill.sum()),
            "marked_pixels_left_empty": left_magenta, "ignored_paint_outside_marked_area": outside,
            "alignment_shift_px": [dx, dy], "aligned_mean_difference": round(difference, 2),
            "model_output_size": list(returned_size),
            "crop_origin": [x0, y0], "crop_size": [x1 - x0, y1 - y0],
            "output": str(output_path.resolve()), "accepted_mask": str(mask_path.resolve())}


def call_vertex_image(args: Any, prompt_path: Path, part_input: Path, output: Path) -> None:
    command = [sys.executable, str(Path(__file__).with_name("generate_vertex_gemini_image.py")),
               "--prompt-file", str(prompt_path), "--image", str(part_input),
               "--output", str(output), "--response-json", str(output.with_suffix(".response.json")),
               "--model", args.model, "--location", args.location,
               "--aspect-ratio", aspect_ratio_for(part_input), "--image-size", args.image_size]
    if args.project:
        command.extend(("--project", args.project))
    for _ in range(2):
        result = subprocess.run(command, capture_output=True, text=True)
        if not result.returncode:
            return
    raise RuntimeError((result.stderr or result.stdout)[-4000:])


def repair_flagged_parts(analysis_path: Path, detection: dict[str, Any], output_dir: Path, args: Any,
                         fixture_repair_dir: Path | None = None) -> dict[str, Any]:
    from detect_part_repairs import page_masks
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    flagged = detection["parts_needing_repair"]
    output_dir.mkdir(parents=True, exist_ok=True)
    canvas_size = tuple(analysis["canvas"])
    masks = page_masks(analysis)
    results = []
    for name, item in flagged.items():
        metadata = analysis["parts"][name]
        part = Image.open(metadata["image"]).convert("RGBA")
        origin = tuple(metadata["crop_origin"])
        own = masks[name]
        fill = np.asarray(Image.open(item["fill_mask"]).convert("L")) > 0
        target_dir = output_dir / name
        target_dir.mkdir(exist_ok=True)
        repair_input = target_dir / "repair-input.png"
        sent = repair_canvas(part, origin, fill, canvas_size, repair_input)
        prompt_path = target_dir / "repair-prompt.txt"
        prompt_path.write_text(build_repair_prompt(name, item, canvas_size), encoding="utf-8")
        raw = target_dir / "repair-raw.png"
        record = {"part": name, "reason": item["reason"], "repair_input": str(repair_input.resolve()),
                  "repair_raw": str(raw.resolve()), "repair_prompt": str(prompt_path.resolve())}
        try:
            if fixture_repair_dir:
                fixture = fixture_repair_dir / f"{name}.repair.png"
                if not fixture.is_file():
                    raise ValueError(f"Missing fixture repair: {fixture}")
                shutil.copy2(fixture, raw)
            elif args.provider == "vertex":
                call_vertex_image(args, prompt_path, repair_input, raw)
            else:
                raise ValueError("Fixture provider requires --resume-repairs for flagged parts")
            applied = apply_repair(part, origin, raw, own, fill, sent, canvas_size, metadata["pivots"],
                                   target_dir / "repaired-part.png", target_dir / "accepted-fill-mask.png")
        except (ValueError, RuntimeError) as exc:
            # Keep the unrepaired part; a human decides whether to retry it.
            results.append({**record, "status": "REJECTED", "error": str(exc)[-600:]})
            continue
        metadata["image"] = applied["output"]
        metadata["crop_origin"] = applied["crop_origin"]
        metadata["crop_size"] = applied["crop_size"]
        metadata["page_bbox"] = [*applied["crop_origin"],
                                 applied["crop_origin"][0] + applied["crop_size"][0],
                                 applied["crop_origin"][1] + applied["crop_size"][1]]
        for pivot in metadata["pivots"].values():
            pivot["crop_local"] = [round(pivot["page"][0] - applied["crop_origin"][0], 2),
                                   round(pivot["page"][1] - applied["crop_origin"][1], 2)]
        results.append({**record, "status": "REPAIRED", **applied})
    repaired_analysis = output_dir / "repaired-analysis.json"
    repaired_analysis.write_text(json.dumps(analysis, indent=2) + "\n", encoding="utf-8")
    poses = make_pose_previews(repaired_analysis, output_dir / "poses")
    sheet = build_review_sheet(analysis, output_dir / "repaired-parts-sheet.png")
    result = {"status": "REPAIRED_PENDING_HUMAN_REVIEW" if flagged else "NO_REPAIR_NEEDED",
              "rejected_parts": [entry["part"] for entry in results if entry["status"] == "REJECTED"],
              "parts": results, "analysis": str(repaired_analysis.resolve()),
              "parts_sheet": str(sheet.resolve()), "pose_sheet": poses["sheet"]}
    (output_dir / "repair-report.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result
