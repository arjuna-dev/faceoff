#!/usr/bin/env python3
"""Sprite animations for a fighter, from one base image, landing back in its rest pose.

Wraps the vendored game-sprite-pipeline (tools/sprites/vexjoy, MIT) into one
programmatic workflow:

  generate      one Vertex image call per animation state (identity-locked to the
                base image), chroma key, slicing and QA, done by the vendored
                sprite_pipeline.py
  import-grid   slice and key a grid made elsewhere (for example in ChatGPT)
  import-frames take an existing folder of keyed frames
  report        write report.html for a fighter's sprite set

Every path ends in the same export step. Frames are scaled so the character's
pixel mass matches the base image, and frame 1's feet and center are pinned to
the base image's feet and center, with every frame sharing that offset (jumps
stay airborne). The game can then draw the animation exactly where the rig's
rest pose stands and return to that pose afterwards. Output goes to
assets/fighters/<fighter>/sprites/ with an index.json manifest.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "tools/sprites/vexjoy/scripts"
DEFAULT_STATES = ROOT / "prompts/sprites/fighter_states.json"
BACKGROUND = (255, 0, 255)
GUIDE_LINE_MAX_PX = 3
GUIDE_LINE_MIN_LENGTH_PX = 24
# Every state's action text gets this, so animations begin and end in the rig's rest pose.
LANDING_RULE = ("The first and the last frame show the character in exactly the reference standing pose, "
                "so the animation starts from and lands back in that pose.")


def fighter_dir(fighter: str) -> Path:
    return ROOT / "assets/fighters" / fighter


def base_foreground(base: Path) -> np.ndarray:
    sys.path.insert(0, str(ROOT / "tools"))
    from whole_character_workflow import open_rgb, sample_background
    return sample_background(open_rgb(base))[2]


def drop_guide_lines(frame: Image.Image) -> Image.Image:
    """Remove thin straight fragments left by a generator's layout grid."""
    import cv2
    rgba = np.asarray(frame.convert("RGBA")).copy()
    count, labels, stats, _ = cv2.connectedComponentsWithStats((rgba[:, :, 3] > 0).astype(np.uint8), connectivity=8)
    for index in range(1, count):
        width, height = stats[index, cv2.CC_STAT_WIDTH], stats[index, cv2.CC_STAT_HEIGHT]
        if min(width, height) <= GUIDE_LINE_MAX_PX and max(width, height) >= GUIDE_LINE_MIN_LENGTH_PX:
            rgba[labels == index] = 0
    return Image.fromarray(rgba, mode="RGBA")


def _alpha(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("RGBA"))[:, :, 3] > 0


def _bottom_and_center(mask: np.ndarray) -> tuple[float, float]:
    ys, xs = np.nonzero(mask)
    return float(ys.max()), float(xs.mean())


def export_state(frames: list[Image.Image], durations: list[int], base: Path, fighter: str, state: str,
                 source: str, label: str | None = None) -> dict[str, Any]:
    """Align frames to the base image's rest pose and write them with a manifest entry."""
    if not frames:
        raise ValueError(f"{state}: no frames to export")
    if len(durations) != len(frames):
        durations = (durations + [durations[-1] if durations else 150] * len(frames))[:len(frames)]
    frames = [drop_guide_lines(frame) for frame in frames]
    foreground = base_foreground(base)
    height, width = foreground.shape
    masses = [int(_alpha(frame).sum()) for frame in frames]
    if min(masses) == 0:
        raise ValueError(f"{state}: a frame is empty after keying")
    scale = float(np.sqrt(foreground.sum() / np.median(masses)))
    scaled = [frame.convert("RGBA").resize((max(1, round(frame.width * scale)), max(1, round(frame.height * scale))),
                                           Image.Resampling.NEAREST) for frame in frames]
    base_bottom, base_center = _bottom_and_center(foreground)
    first_bottom, first_center = _bottom_and_center(_alpha(scaled[0]))
    offset = (round(base_center - first_center), round(base_bottom - first_bottom))
    # Shared crop so every frame keeps the same origin in base-canvas coordinates.
    boxes = []
    for frame in scaled:
        x0, y0, x1, y1 = frame.getbbox()
        boxes.append((x0 + offset[0], y0 + offset[1], x1 + offset[0], y1 + offset[1]))
    ux0, uy0 = min(box[0] for box in boxes), min(box[1] for box in boxes)
    ux1, uy1 = max(box[2] for box in boxes), max(box[3] for box in boxes)
    target = fighter_dir(fighter) / "sprites" / state
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)
    files = []
    for index, frame in enumerate(scaled):
        canvas = Image.new("RGBA", (ux1 - ux0, uy1 - uy0), (0, 0, 0, 0))
        canvas.alpha_composite(frame, (offset[0] - ux0, offset[1] - uy0))
        path = target / f"frame_{index:02d}.png"
        canvas.save(path)
        files.append(f"{state}/{path.name}")
    preview = []
    for frame in scaled:
        canvas = Image.new("RGBA", (width, height), (40, 42, 50, 255))
        canvas.alpha_composite(frame, offset)
        preview.append(canvas.convert("RGB").resize((width // 3, height // 3), Image.Resampling.NEAREST))
    preview[0].save(target / "preview.gif", save_all=True, append_images=preview[1:], duration=durations, loop=0)
    entry = {"state": state, "label": label or state.replace("-", " ").upper(), "frames": files,
             "durations_ms": durations, "origin": [ux0, uy0], "frame_size": [ux1 - ux0, uy1 - uy0],
             "scale_from_source": round(scale, 4), "source": source, "preview": f"{state}/preview.gif"}
    update_index(fighter, base, foreground, entry)
    return entry


def update_index(fighter: str, base: Path, foreground: np.ndarray, entry: dict[str, Any]) -> Path:
    directory = fighter_dir(fighter) / "sprites"
    directory.mkdir(parents=True, exist_ok=True)
    index_path = directory / "index.json"
    index = json.loads(index_path.read_text(encoding="utf-8")) if index_path.is_file() else {}
    ys, xs = np.nonzero(foreground)
    index.update({
        "fighter": fighter,
        "base_image": os.path.relpath(base.resolve(), directory.resolve()),
        "base_canvas": [int(foreground.shape[1]), int(foreground.shape[0])],
        "base_bbox": [int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1],
        "note": "Frames and origin are in base-canvas pixels; the base bbox bottom is the ground line.",
    })
    animations = [item for item in index.get("animations", []) if item["state"] != entry["state"]]
    index["animations"] = sorted(animations + [entry], key=lambda item: item["state"])
    index_path.write_text(json.dumps(index, indent=2) + "\n", encoding="utf-8")
    return index_path


def load_frames(directory: Path) -> list[Image.Image]:
    paths = sorted(directory.glob("*.png"))
    if not paths:
        raise ValueError(f"No PNG frames in {directory}")
    return [Image.open(path).convert("RGBA") for path in paths]


def vendor_python() -> str:
    return sys.executable


def generate(args: argparse.Namespace) -> int:
    states = json.loads(args.states.read_text(encoding="utf-8"))
    if args.only:
        states = [row for row in states if row["state"] in args.only]
    for row in states:
        if LANDING_RULE not in row["action"]:
            row["action"] = row["action"].rstrip(".") + ". " + LANDING_RULE
    args.output_dir.mkdir(parents=True, exist_ok=True)
    states_file = args.output_dir / "states.json"
    states_file.write_text(json.dumps(states, indent=2) + "\n", encoding="utf-8")
    description = args.description_file.read_text(encoding="utf-8").strip()
    command = [vendor_python(), str(VENDOR / "sprite_pipeline.py"), "--per-row", "--preset", "custom",
               "--states", str(states_file.resolve()), "--base-image", str(args.base_image.resolve()),
               "--description", description + " Side view facing right.", "--style", args.style,
               "--name", args.fighter, "--cell-size", str(args.cell_size), "--qa-artifacts",
               "--output-dir", str(args.output_dir.resolve())]
    env = {**os.environ, "SPRITE_BACKEND": "vertex", "VERTEX_IMAGE_MODEL": args.model}
    with (args.output_dir / "pipeline.log").open("w") as log:
        result = subprocess.run(command, cwd=VENDOR, env=env, stdout=log, stderr=subprocess.STDOUT)
    # Exit 2 means a verifier gate failed but files were written; export what exists.
    exported = []
    for index, row in enumerate(states):
        matches = sorted(args.output_dir.glob(f"row_*_{row['state']}/frames_nobg"))
        if not matches:
            print(f"{row['state']}: no frames produced", file=sys.stderr)
            continue
        export_state(load_frames(matches[0]), row.get("timing", []), args.base_image, args.fighter,
                     row["state"], f"generated:{args.model}")
        exported.append(row["state"])
    print(json.dumps({"pipeline_exit": result.returncode, "exported": exported,
                      "report": str(write_report(args.fighter, args.output_dir))}, indent=2))
    return 0 if exported else 1


def import_grid(args: argparse.Namespace) -> int:
    work = args.output_dir
    command = [vendor_python(), str(VENDOR / "import_external_grid.py"), "--input", str(args.input.resolve()),
               "--grid", args.grid, "--frames", str(args.frames), "--state", args.state,
               "--name", args.fighter, "--output-dir", str(work.resolve())]
    if args.timing:
        command += ["--timing", args.timing]
    subprocess.run(command, cwd=VENDOR, check=True)
    timing = [int(value) for value in args.timing.split(",")] if args.timing else [150] * args.frames
    entry = export_state(load_frames(work / args.state / "nobg"), timing, args.base_image, args.fighter,
                         args.state, args.source)
    print(json.dumps(entry, indent=2))
    return 0


def import_frames(args: argparse.Namespace) -> int:
    timing = [int(value) for value in args.timing.split(",")] if args.timing else []
    entry = export_state(load_frames(args.frames_dir), timing, args.base_image, args.fighter, args.state,
                         args.source)
    print(json.dumps(entry, indent=2))
    return 0


def write_report(fighter: str, run_dir: Path | None = None) -> Path:
    """One page: every animation's preview, frames and, for generated rows, the exact prompt."""
    directory = fighter_dir(fighter) / "sprites"
    index = json.loads((directory / "index.json").read_text(encoding="utf-8"))
    output = (run_dir or directory) / "report.html"

    def rel(path: Path) -> str:
        return html.escape(os.path.relpath(path.resolve(), output.parent.resolve()))

    sections = []
    for entry in index["animations"]:
        frames = "".join(f'<img class="frame" src="{rel(directory / name)}">' for name in entry["frames"])
        prompt = ""
        if run_dir:
            for path in sorted(run_dir.glob(f"row_*_{entry['state']}/row_prompt.txt")):
                prompt = f"<details><summary>Prompt sent</summary><pre>{html.escape(path.read_text())}</pre></details>"
        sections.append(
            f"<section><h2>{html.escape(entry['label'])} <small>{html.escape(entry['source'])}</small></h2>"
            f'<img class="preview" src="{rel(directory / entry["preview"])}">'
            f"<p>{len(entry['frames'])} frames · {sum(entry['durations_ms'])} ms · "
            f"timings {entry['durations_ms']}</p><div class=\"frames\">{frames}</div>{prompt}</section>")
    page = f"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Sprites {html.escape(fighter)}</title>
<style>
:root {{ --bg:#f6f6f4; --panel:#fff; --ink:#1d1f23; --muted:#626873; --line:#dcdcd6; --code:#f1f1ee; }}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg:#15171b; --panel:#1e2126; --ink:#e8e8e6; --muted:#9aa0aa; --line:#30343b; --code:#23262c; }} }}
body {{ margin:0; background:var(--bg); color:var(--ink); font:15px/1.5 -apple-system, system-ui, sans-serif; }}
main {{ max-width:1200px; margin:auto; padding:16px; }}
section {{ background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:16px; margin:16px 0; }}
small {{ color:var(--muted); font-weight:400; }}
.preview {{ max-width:100%; width:420px; border-radius:6px; image-rendering:pixelated; }}
.frames {{ display:flex; flex-wrap:wrap; gap:8px; }}
.frame {{ height:140px; background:#888; border-radius:4px; image-rendering:pixelated; }}
pre {{ background:var(--code); padding:10px; border-radius:6px; white-space:pre-wrap; font-size:12.5px; }}
</style></head><body><main><h1>{html.escape(fighter)} sprite animations</h1>
<p>Each animation starts and lands in the rig's rest pose (base image); frames are aligned to it.</p>
{''.join(sections)}</main></body></html>"""
    output.write_text(page, encoding="utf-8")
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--fighter", required=True)
    common.add_argument("--base-image", type=Path, help="Defaults to assets/fighters/<fighter>/base.png")
    gen = sub.add_parser("generate", parents=[common])
    gen.add_argument("--description-file", type=Path, required=True)
    gen.add_argument("--states", type=Path, default=DEFAULT_STATES)
    gen.add_argument("--only", nargs="*", help="Generate only these states")
    gen.add_argument("--model", default="gemini-3-pro-image")
    gen.add_argument("--style", default="arcade-cps2")
    gen.add_argument("--cell-size", type=int, default=256)
    gen.add_argument("--output-dir", type=Path, required=True)
    grid = sub.add_parser("import-grid", parents=[common])
    grid.add_argument("--input", type=Path, required=True)
    grid.add_argument("--grid", required=True, help="CxR, e.g. 3x2")
    grid.add_argument("--frames", type=int, required=True)
    grid.add_argument("--state", required=True)
    grid.add_argument("--timing")
    grid.add_argument("--source", default="external")
    grid.add_argument("--output-dir", type=Path, required=True)
    frames = sub.add_parser("import-frames", parents=[common])
    frames.add_argument("--frames-dir", type=Path, required=True)
    frames.add_argument("--state", required=True)
    frames.add_argument("--timing")
    frames.add_argument("--source", default="external")
    report = sub.add_parser("report", parents=[common])
    report.add_argument("--run-dir", type=Path)
    args = parser.parse_args()
    if args.base_image is None:
        args.base_image = fighter_dir(args.fighter) / "base.png"
    if not args.base_image.is_file():
        parser.error(f"base image does not exist: {args.base_image}")
    if args.command == "generate":
        return generate(args)
    if args.command == "import-grid":
        return import_grid(args)
    if args.command == "import-frames":
        return import_frames(args)
    print(write_report(args.fighter, args.run_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
