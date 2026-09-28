#!/usr/bin/env python3
"""Import a sprite grid made elsewhere (e.g. ChatGPT) into pipeline-style frames.

Slices a cols x rows grid, keys out magenta with the pipeline's chroma engine,
normalises frames to a shared scale on CELL x CELL (bottom-anchored, keeping
relative height so jumps stay airborne), and writes frames, a strip and a GIF.
Optionally builds a side-by-side comparison against a pipeline row.

    python3 import_external_grid.py --input jump.png --grid 3x2 --frames 5 \
        --state jump --output-dir OUT [--timing 140,140,140,140,280] \
        [--compare-row RUN_DIR/row_04_jump --compare-label "Gemini 3 Pro"]
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import sprite_bg  # noqa: E402


def slice_and_key(src: Path, cols: int, rows: int, frames: int, work: Path, threshold: int) -> list[Image.Image]:
    img = Image.open(src).convert("RGB")
    cw, ch = img.width / cols, img.height / rows
    (work / "raw").mkdir(parents=True, exist_ok=True)
    (work / "nobg").mkdir(parents=True, exist_ok=True)
    keyed = []
    for i in range(frames):
        x, y = (i % cols) * cw, (i // cols) * ch
        raw = work / "raw" / f"frame_{i:02d}.png"
        img.crop((round(x), round(y), round(x + cw), round(y + ch))).save(raw)
        dst = work / "nobg" / raw.name
        sprite_bg.remove_bg_chroma(raw, dst, threshold)
        keyed.append(Image.open(dst).convert("RGBA"))
    return keyed


def normalise(frames: list[Image.Image], cell: int) -> list[Image.Image]:
    boxes = [f.getbbox() or (0, 0, 1, 1) for f in frames]
    scale = (cell * 0.92) / max(max(b[2] - b[0] for b in boxes), max(b[3] - b[1] for b in boxes))
    floor = max(b[3] for b in boxes)
    out = []
    for f, b in zip(frames, boxes):
        crop = f.crop(b)
        crop = crop.resize((max(1, round(crop.width * scale)), max(1, round(crop.height * scale))), Image.NEAREST)
        canvas = Image.new("RGBA", (cell, cell), (0, 0, 0, 0))
        y = round(cell - 6 - (floor - b[3]) * scale - crop.height)
        canvas.alpha_composite(crop, ((cell - crop.width) // 2, max(0, y)))
        out.append(canvas)
    return out


def save_gif(frames: list[Image.Image], timing: list[int], path: Path) -> None:
    flat = []
    for f in frames:
        c = Image.new("RGBA", f.size, (40, 40, 48, 255))
        c.alpha_composite(f)
        flat.append(c.convert("RGB"))
    flat[0].save(path, save_all=True, append_images=flat[1:], duration=timing, loop=0)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True, type=Path)
    ap.add_argument("--grid", required=True, help="CxR, e.g. 3x2")
    ap.add_argument("--frames", required=True, type=int)
    ap.add_argument("--state", required=True)
    ap.add_argument("--output-dir", required=True, type=Path)
    ap.add_argument("--name", default="sprite")
    ap.add_argument("--cell-size", type=int, default=256)
    ap.add_argument("--timing", help="Comma-separated ms per frame (default 150 each)")
    ap.add_argument("--chroma-threshold", type=int, default=30)
    ap.add_argument("--compare-row", type=Path, help="Pipeline row dir containing frames_nobg/")
    ap.add_argument("--compare-label", default="pipeline")
    ap.add_argument("--label", default="external")
    a = ap.parse_args()

    cols, rows = (int(v) for v in a.grid.lower().split("x"))
    if a.frames > cols * rows:
        ap.error("--frames exceeds grid cells")
    timing = [int(t) for t in a.timing.split(",")] if a.timing else [150] * a.frames
    out = a.output_dir / a.state
    frames = normalise(slice_and_key(a.input, cols, rows, a.frames, out, a.chroma_threshold), a.cell_size)

    (out / "frames").mkdir(parents=True, exist_ok=True)
    strip = Image.new("RGBA", (a.cell_size * len(frames), a.cell_size))
    for i, f in enumerate(frames):
        f.save(out / "frames" / f"{a.name}_{a.state}_{i:02d}.png")
        strip.alpha_composite(f, (i * a.cell_size, 0))
    strip.save(out / f"{a.name}_{a.state}_strip.png")
    save_gif(frames, timing, out / f"{a.name}_{a.state}.gif")

    if a.compare_row:
        ref = normalise(
            [Image.open(p).convert("RGBA") for p in sorted((a.compare_row / "frames_nobg").glob("*.png"))],
            a.cell_size,
        )
        save_gif(ref, timing[: len(ref)], out / f"{a.name}_{a.state}_{a.compare_label.replace(' ', '_')}.gif")
        rows_ = [(f"{a.state} - {a.compare_label}", ref), (f"{a.state} - {a.label}", frames)]
        w = a.cell_size * max(len(fr) for _, fr in rows_)
        sheet = Image.new("RGBA", (w, 2 * (a.cell_size + 24)), (40, 40, 48, 255))
        d = ImageDraw.Draw(sheet)
        for r, (lab, fr) in enumerate(rows_):
            y = r * (a.cell_size + 24)
            d.text((6, y + 5), lab, fill=(255, 255, 255))
            for i, f in enumerate(fr):
                sheet.alpha_composite(f, (i * a.cell_size, y + 24))
        sheet.convert("RGB").save(out / f"{a.name}_{a.state}_compare.png")

    print(f"{a.state}: {len(frames)} frames -> {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
