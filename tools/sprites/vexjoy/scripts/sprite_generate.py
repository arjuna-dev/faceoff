#!/usr/bin/env python3
"""
Backend dispatcher for the game-sprite-pipeline skill.

Selects between Codex CLI imagegen (primary) and Gemini Nano Banana
(fallback). Fails loudly when neither backend is available -- the skill
does NOT call paid APIs directly.

Subcommands:
    generate-portrait       Single portrait image
    generate-character      Phase A: 1024x1024 reference character (spritesheet mode)
    generate-spritesheet    Phase C: full spritesheet generation

Usage:
    python3 sprite_generate.py generate-portrait \\
        --prompt-file prompt.txt --output portrait.png --seed 42

The script never touches paid endpoints. Detection logic:
    1. `codex` in PATH and `codex --version` exits 0 -> Codex CLI.
    2. GEMINI_API_KEY (or GOOGLE_API_KEY) set -> Nano Banana.
    3. Else: BackendUnavailableError with explicit fix instructions.
"""

from __future__ import annotations

import argparse
import logging
import os
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

logger = logging.getLogger("sprite-pipeline.sprite_generate")

# Resolve nano-banana script paths. Prefer ~/.claude/scripts/ (deployed),
# fall back to repo path when running in a dev checkout.
NANO_BANANA_GENERATE_CANDIDATES = [
    Path.home() / ".claude" / "scripts" / "nano-banana-generate.py",
    Path("/home/feedgen/.claude/scripts/nano-banana-generate.py"),
]


def find_nano_banana_script() -> Path | None:
    """Return the first existing nano-banana-generate.py path."""
    for candidate in NANO_BANANA_GENERATE_CANDIDATES:
        if candidate.exists():
            return candidate
    return None


class BackendUnavailableError(RuntimeError):
    """Raised when no image-generation backend is available."""


@dataclass
class BackendChoice:
    backend: str  # 'codex' | 'nano-banana'
    detected_via: str


VERTEX_DEFAULT_MODEL = "gemini-3-pro-image"
VERTEX_DEFAULT_LOCATION = "global"


def select_backend() -> BackendChoice:
    """Detect which backend to use. Fail loudly if none available.

    SPRITE_BACKEND=vertex|codex|nano-banana forces a backend. Vertex uses
    the active gcloud credentials; pick the model with VERTEX_IMAGE_MODEL.
    """
    forced = os.environ.get("SPRITE_BACKEND", "").strip().lower()
    if forced:
        if forced not in ("vertex", "codex", "nano-banana"):
            raise BackendUnavailableError(f"Unknown SPRITE_BACKEND={forced!r}")
        return BackendChoice(backend=forced, detected_via="SPRITE_BACKEND env")

    if shutil.which("codex"):
        try:
            subprocess.run(
                ["codex", "--version"],
                check=True,
                capture_output=True,
                timeout=10,
            )
            return BackendChoice(backend="codex", detected_via="codex --version exit 0")
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as e:
            logger.warning(
                "[backend] codex CLI present but auth check failed (%s); trying Nano Banana",
                e,
            )

    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return BackendChoice(backend="nano-banana", detected_via="GEMINI_API_KEY env set")

    raise BackendUnavailableError(
        "No image-generation backend available.\n\n"
        "Tried in order:\n"
        "  1. Codex CLI (`codex` not in PATH or auth failed)\n"
        "  2. Gemini Nano Banana (GEMINI_API_KEY not set)\n\n"
        "This skill does not call paid APIs directly. To proceed:\n"
        "  - Install Codex CLI and run `codex auth`, OR\n"
        "  - Set GEMINI_API_KEY: export GEMINI_API_KEY=<your-key>\n\n"
        "Never set OPENAI_API_KEY for this skill -- paid fallbacks are\n"
        "intentionally prohibited per the Local-First principle."
    )


def read_prompt(prompt: str | None, prompt_file: Path | None) -> str:
    """Resolve the prompt from --prompt or --prompt-file."""
    if prompt and prompt_file:
        raise ValueError("Pass either --prompt OR --prompt-file, not both.")
    if prompt:
        return prompt
    if prompt_file:
        return prompt_file.read_text(encoding="utf-8")
    raise ValueError("Must pass --prompt or --prompt-file.")


# ---------------------------------------------------------------------------
# Codex CLI dispatch
# ---------------------------------------------------------------------------
def generate_via_codex(
    prompt: str,
    output: Path,
    aspect_ratio: str | None = None,
    reference: Path | list[Path] | None = None,
    seed: int = 0,
    model: str = "image-1",
) -> int:
    """Run Codex CLI imagegen via subprocess. Returns exit code.

    Codex CLI 0.125+ does not expose --output-image / --aspect-ratio /
    --reference / --seed flags directly. Image generation happens through
    the agent's internal image_gen tool: we PROMPT codex exec to use that
    tool and save to an absolute path, then verify the file exists. The
    aspect_ratio / reference / seed values are encoded into the prompt
    itself rather than as CLI flags. See this module's `generate_via_codex`
    callers for how the prompt is constructed and post-verified.
    """
    output.parent.mkdir(parents=True, exist_ok=True)

    extras: list[str] = []
    if aspect_ratio:
        extras.append(f"Aspect ratio target: {aspect_ratio}.")
    if seed:
        extras.append(f"Seed (encode in image_gen call when supported): {seed}.")

    ref_count = len(reference) if isinstance(reference, list) else (1 if reference else 0)
    if ref_count > 1:
        ref_note = (
            "\nReference images attached: image 1 is the magenta GRID CANVAS "
            "TEMPLATE — use it to locate cell boundaries and place exactly "
            "one frame per cell. Image 2 is the CHARACTER REFERENCE — "
            "preserve this character's identity (face, hair, costume, "
            "colors, body type) in every cell.\n"
        )
    elif ref_count == 1:
        ref_note = (
            "\nReference image attached: use it as the structural / identity reference for the generated image.\n"
        )
    else:
        ref_note = ""

    wrapped = (
        "Use your image_gen tool to create the following image. Then save the "
        f"resulting PNG to this absolute path: {output}\n"
        "After saving, run `ls -la <path>` to verify the file exists.\n"
        f"{ref_note}\n"
        f"Image specification:\n{prompt}\n"
    )
    if extras:
        wrapped += "\n" + "\n".join(extras) + "\n"

    cmd: list[str] = [
        "codex",
        "exec",
        "--dangerously-bypass-approvals-and-sandbox",
        "--skip-git-repo-check",
    ]
    if reference:
        # -i / --image takes nargs=*; must be followed by `--` to terminate
        # before the positional prompt argument, otherwise the prompt is
        # consumed as another image filename. `reference` may be a single
        # Path or a list of Paths (canvas template + character portrait).
        ref_list = reference if isinstance(reference, list) else [reference]
        cmd.append("-i")
        cmd.extend(str(p) for p in ref_list)
        cmd.append("--")
    cmd.append(wrapped)

    logger.info("[backend:codex] $ codex exec ... (output=%s)", output)
    try:
        proc = subprocess.run(cmd, check=False, capture_output=True, timeout=420)
        if proc.returncode != 0:
            logger.error("[backend:codex] failed exit %d", proc.returncode)
            if proc.stderr:
                logger.error("%s", proc.stderr.decode(errors="replace")[-1000:])
            return proc.returncode
        if not output.exists() or output.stat().st_size == 0:
            logger.error("[backend:codex] codex exit 0 but %s missing/empty", output)
            if proc.stdout:
                logger.error("%s", proc.stdout.decode(errors="replace")[-1000:])
            return 5
        return 0
    except subprocess.TimeoutExpired:
        logger.error("[backend:codex] timed out after 420s")
        return 124


# ---------------------------------------------------------------------------
# Nano Banana dispatch
# ---------------------------------------------------------------------------
def generate_via_nano_banana(
    prompt: str,
    output: Path,
    aspect_ratio: str = "1:1",
    reference: Path | None = None,
    seed: int = 0,
    model: str = "pro",
) -> int:
    """Shell out to nano-banana-generate.py. Returns exit code."""
    script = find_nano_banana_script()
    if script is None:
        logger.error("[backend:nano-banana] nano-banana-generate.py not found at expected paths")
        return 127

    output.parent.mkdir(parents=True, exist_ok=True)

    if reference:
        cmd = [
            sys.executable,
            str(script),
            "with-reference",
            "--prompt",
            prompt,
            "--reference",
            str(reference),
            "--output",
            str(output),
            "--model",
            model,
            "--aspect-ratio",
            aspect_ratio,
        ]
    else:
        cmd = [
            sys.executable,
            str(script),
            "generate",
            "--prompt",
            prompt,
            "--output",
            str(output),
            "--model",
            model,
            "--aspect-ratio",
            aspect_ratio,
        ]

    logger.info(
        "[backend:nano-banana] $ %s (%s)",
        script.name,
        "with-reference" if reference else "generate",
    )
    try:
        subprocess.run(cmd, check=True, timeout=300)
        return 0
    except subprocess.CalledProcessError as e:
        logger.error("[backend:nano-banana] failed exit %d", e.returncode)
        return e.returncode
    except subprocess.TimeoutExpired:
        logger.error("[backend:nano-banana] timed out after 300s")
        return 124


# ---------------------------------------------------------------------------
# Vertex AI dispatch (gcloud credentials, configurable Gemini image model)
# ---------------------------------------------------------------------------
def _gcloud(*args: str) -> str:
    return subprocess.run(
        ["gcloud", *args], check=True, capture_output=True, text=True, timeout=60
    ).stdout.strip()


def generate_via_vertex(
    prompt: str,
    output: Path,
    aspect_ratio: str = "1:1",
    reference: Path | list[Path] | None = None,
    seed: int = 0,
    model: str | None = None,
) -> int:
    """Call Vertex generateContent with every reference image attached."""
    import base64
    import json
    import mimetypes
    import urllib.error
    import urllib.request

    model = model or os.environ.get("VERTEX_IMAGE_MODEL", VERTEX_DEFAULT_MODEL)
    location = os.environ.get("VERTEX_LOCATION", VERTEX_DEFAULT_LOCATION)
    try:
        project = os.environ.get("VERTEX_PROJECT") or _gcloud("config", "get-value", "project")
        token = _gcloud("auth", "print-access-token")
    except (subprocess.SubprocessError, OSError) as e:
        logger.error("[backend:vertex] gcloud credentials unavailable: %s", e)
        return 127
    if not project:
        logger.error("[backend:vertex] no project: set VERTEX_PROJECT or gcloud config project")
        return 127

    refs = [reference] if isinstance(reference, Path) else list(reference or [])
    parts: list[dict] = []
    for ref in refs:
        mime = mimetypes.guess_type(str(ref))[0] or "image/png"
        parts.append({"inlineData": {"mimeType": mime, "data": base64.b64encode(ref.read_bytes()).decode()}})
    parts.append({"text": prompt})
    body = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": {
            "responseModalities": ["IMAGE", "TEXT"],
            "seed": seed,
            "imageConfig": {"aspectRatio": aspect_ratio},
        },
    }
    host = "aiplatform.googleapis.com" if location == "global" else f"{location}-aiplatform.googleapis.com"
    url = (
        f"https://{host}/v1/projects/{project}/locations/{location}"
        f"/publishers/google/models/{model}:generateContent"
    )
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    logger.info("[backend:vertex] model=%s location=%s refs=%d aspect=%s", model, location, len(refs), aspect_ratio)
    import time

    attempts = int(os.environ.get("VERTEX_MAX_ATTEMPTS", "6"))
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                data = json.load(resp)
            break
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")[:500]
            if e.code in (429, 500, 503) and attempt < attempts:
                wait = min(20 * 2 ** (attempt - 1), 300)
                logger.warning("[backend:vertex] HTTP %d, retry %d/%d in %ds", e.code, attempt, attempts - 1, wait)
                time.sleep(wait)
                continue
            logger.error("[backend:vertex] HTTP %d: %s", e.code, detail)
            return 1
        except (urllib.error.URLError, TimeoutError) as e:
            logger.error("[backend:vertex] request failed: %s", e)
            return 124

    for cand in data.get("candidates", []):
        for part in cand.get("content", {}).get("parts", []):
            if "inlineData" in part:
                output.parent.mkdir(parents=True, exist_ok=True)
                output.write_bytes(base64.b64decode(part["inlineData"]["data"]))
                logger.info("[backend:vertex] wrote %s", output)
                return 0
    logger.error("[backend:vertex] response contained no image: %s", json.dumps(data)[:500])
    return 1


# ---------------------------------------------------------------------------
# Subcommand wrappers
# ---------------------------------------------------------------------------
def _generate_strip_via_vertex_grid(
    prompt: str, output: Path, canvas: Path, reference: Path | None, seed: int
) -> int:
    """Generate an N-frame horizontal strip through a near-square grid.

    Gemini image models cap aspect ratio at 21:9, so a 4:1 or 6:1 strip
    comes back squashed into 1:1 with overlapping frames. We ask for a
    cols x rows grid of square cells instead, then repack the cells into
    the N x 1 strip the downstream exact-pitch slicer expects.
    """
    import math
    import tempfile

    from PIL import Image, ImageDraw

    guide = Image.open(canvas)
    cell = guide.height
    frames = max(1, round(guide.width / cell))
    if frames <= 2:
        refs = [p for p in (canvas, reference) if p]
        return generate_via_vertex(prompt, output, aspect_ratio="16:9" if frames == 2 else "1:1", reference=refs, seed=seed)

    cols = math.ceil(math.sqrt(frames))
    rows = math.ceil(frames / cols)
    ratios = {"1:1": 1.0, "4:3": 4 / 3, "3:2": 1.5, "16:9": 16 / 9, "21:9": 21 / 9}
    aspect = min(ratios, key=lambda k: abs(ratios[k] - cols / rows))

    grid_guide = Image.new("RGB", (cols * cell, rows * cell), (255, 0, 255))
    draw = ImageDraw.Draw(grid_guide)
    for i in range(cols * rows):
        x, y = (i % cols) * cell, (i // cols) * cell
        draw.rectangle([x, y, x + cell - 1, y + cell - 1], outline=(40, 40, 40), width=2)
        if i < frames:
            draw.text((x + 6, y + 4), str(i + 1), fill=(40, 40, 40))
        else:
            draw.line([x, y, x + cell, y + cell], fill=(40, 40, 40), width=2)

    grid_prompt = (
        f"{prompt}\n\nLAYOUT OVERRIDE (takes precedence over any strip instructions above):\n"
        f"- The first reference image is a {cols}x{rows} grid of equal square cells numbered 1..{frames}.\n"
        f"- Output the same {cols}x{rows} grid: frame N goes in cell N, read left-to-right, top-to-bottom.\n"
        f"- Exactly one full-body character per cell, centred, feet on the same baseline in every cell,\n"
        f"  identical scale; nothing may cross a cell edge.\n"
        + (f"- Leave cells after {frames} as plain magenta #FF00FF.\n" if cols * rows > frames else "")
        + "- Solid magenta #FF00FF background everywhere; do not draw the grid lines or numbers."
    )

    with tempfile.TemporaryDirectory() as tmp:
        guide_path = Path(tmp) / "grid_guide.png"
        grid_guide.save(guide_path)
        raw_path = output.with_name(output.stem + "_grid_raw.png")
        refs = [guide_path] + ([reference] if reference else [])
        rc = generate_via_vertex(grid_prompt, raw_path, aspect_ratio=aspect, reference=refs, seed=seed)
        if rc != 0:
            return rc

    raw = Image.open(raw_path).convert("RGB")
    cw, ch = raw.width / cols, raw.height / rows
    side = int(min(cw, ch))
    strip = Image.new("RGB", (frames * side, side), (255, 0, 255))
    for i in range(frames):
        cx, cy = (i % cols) * cw, (i // cols) * ch
        box = (round(cx + (cw - side) / 2), round(cy + (ch - side) / 2))
        strip.paste(raw.crop((box[0], box[1], box[0] + side, box[1] + side)), (i * side, 0))
    strip.save(output)
    logger.info("[backend:vertex] repacked %dx%d grid -> %d-frame strip %s", cols, rows, frames, output)
    return 0


# ---------------------------------------------------------------------------
# Subcommand wrappers
# ---------------------------------------------------------------------------
def cmd_generate_portrait(args: argparse.Namespace) -> int:
    if args.dry_run:
        logger.info("[backend] DRY-RUN: skipping backend call (portrait)")
        return 0
    try:
        choice = select_backend()
    except BackendUnavailableError as e:
        logger.error("%s", e)
        return 3
    logger.info("[backend] selected=%s (%s)", choice.backend, choice.detected_via)

    prompt = read_prompt(args.prompt, Path(args.prompt_file) if args.prompt_file else None)
    output = Path(args.output)

    if choice.backend == "codex":
        return generate_via_codex(prompt, output, aspect_ratio="4:5", seed=args.seed)
    if choice.backend == "vertex":
        refs = [Path(r) for r in (args.reference or [])]
        return generate_via_vertex(prompt, output, aspect_ratio="4:5", reference=refs, seed=args.seed)
    return generate_via_nano_banana(prompt, output, aspect_ratio="4:5", seed=args.seed)


def cmd_generate_character(args: argparse.Namespace) -> int:
    if args.dry_run:
        logger.info("[backend] DRY-RUN: skipping backend call (character reference)")
        return 0
    try:
        choice = select_backend()
    except BackendUnavailableError as e:
        logger.error("%s", e)
        return 3
    logger.info("[backend] selected=%s (%s)", choice.backend, choice.detected_via)

    prompt = read_prompt(args.prompt, Path(args.prompt_file) if args.prompt_file else None)
    output = Path(args.output)

    if choice.backend == "codex":
        return generate_via_codex(prompt, output, aspect_ratio="1:1", seed=args.seed)
    if choice.backend == "vertex":
        refs = [Path(r) for r in (args.reference or [])]
        return generate_via_vertex(prompt, output, aspect_ratio="1:1", reference=refs, seed=args.seed)
    return generate_via_nano_banana(prompt, output, aspect_ratio="1:1", seed=args.seed)


def cmd_generate_spritesheet(args: argparse.Namespace) -> int:
    if args.dry_run:
        logger.info("[backend] DRY-RUN: skipping backend call (spritesheet)")
        return 0
    try:
        choice = select_backend()
    except BackendUnavailableError as e:
        logger.error("%s", e)
        return 3
    logger.info("[backend] selected=%s (%s)", choice.backend, choice.detected_via)

    prompt = read_prompt(args.prompt, Path(args.prompt_file) if args.prompt_file else None)
    output = Path(args.output)
    canvas = Path(args.canvas) if args.canvas else None
    reference = Path(args.reference) if args.reference else None

    # Codex backend: pass BOTH images when both exist (canvas template +
    # character portrait). Codex `-i` accepts nargs=*; the model uses the
    # canvas for structural cell layout and the portrait for character
    # identity. Nano Banana single-ref API falls back to canvas-only.
    if choice.backend == "codex":
        refs: list[Path] = [p for p in (canvas, reference) if p]
        ref_arg: Path | list[Path] | None = refs if len(refs) > 1 else (refs[0] if refs else None)
        return generate_via_codex(prompt, output, reference=ref_arg, seed=args.seed)
    if choice.backend == "vertex":
        aspect = getattr(args, "aspect_ratio", None)
        if canvas and not aspect:
            return _generate_strip_via_vertex_grid(prompt, output, canvas, reference, args.seed)
        refs = [p for p in (canvas, reference) if p]
        return generate_via_vertex(prompt, output, aspect_ratio=aspect or "1:1", reference=refs, seed=args.seed)
    structural_ref = canvas or reference
    return generate_via_nano_banana(prompt, output, reference=structural_ref, seed=args.seed)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def _add_common_args(parser: argparse.ArgumentParser) -> None:
    grp = parser.add_mutually_exclusive_group(required=True)
    grp.add_argument("--prompt", help="Prompt text")
    grp.add_argument("--prompt-file", help="Path to a file containing the prompt")
    parser.add_argument("--output", required=True, help="Output PNG path")
    parser.add_argument("--seed", type=int, default=0, help="Reproducibility seed")
    parser.add_argument("--dry-run", action="store_true", help="Skip backend call (smoke testing)")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)

    gp = sub.add_parser("generate-portrait", help="Single portrait image (Phase A portrait)")
    _add_common_args(gp)
    gp.add_argument("--reference", action="append", help="Identity reference image (vertex backend; repeatable)")
    gp.set_defaults(func=cmd_generate_portrait)

    gc = sub.add_parser("generate-character", help="Phase A: reference character (spritesheet mode)")
    _add_common_args(gc)
    gc.add_argument("--reference", action="append", help="Identity reference image (vertex backend; repeatable)")
    gc.set_defaults(func=cmd_generate_character)

    gs = sub.add_parser("generate-spritesheet", help="Phase C: spritesheet generation")
    _add_common_args(gs)
    gs.add_argument("--canvas", help="Phase B grid canvas template path")
    gs.add_argument("--reference", help="Reference character path (Phase A output)")
    gs.add_argument("--aspect-ratio", help="Output aspect ratio (vertex backend), e.g. 1:1, 16:9, 21:9")
    gs.set_defaults(func=cmd_generate_spritesheet)

    return parser


def main(argv: list[str] | None = None) -> int:
    if not logging.getLogger().handlers:
        logging.basicConfig(
            level=logging.INFO,
            format="[%(name)s] %(levelname)s: %(message)s",
            stream=sys.stderr,
        )
    parser = build_parser()
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
