#!/usr/bin/env python3
"""Build a labeled twelve-part sheet and request one structured Vertex review."""

from __future__ import annotations

import base64
import json
import subprocess
import time
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen
from typing import Any

from PIL import Image, ImageDraw, ImageFont


CELL = (440, 560)
COLUMNS = 4
GREEN = (0, 255, 0, 255)
PROMPT_PATH = Path(__file__).resolve().parents[1] / "prompts/workflows/whole_character_part_review.txt"


def build_review_sheet(analysis: dict[str, Any], output: Path) -> Path:
    parts = analysis["parts"]
    rows = -(-len(parts) // COLUMNS)
    sheet = Image.new("RGB", (CELL[0] * COLUMNS, CELL[1] * rows), (27, 30, 37))
    draw = ImageDraw.Draw(sheet)
    for index, (name, metadata) in enumerate(parts.items()):
        column, row = index % COLUMNS, index // COLUMNS
        x0, y0 = column * CELL[0], row * CELL[1]
        draw.rectangle((x0 + 8, y0 + 34, x0 + CELL[0] - 8, y0 + CELL[1] - 10),
                       fill=(0, 255, 0), outline=(210, 210, 210), width=2)
        draw.text((x0 + 12, y0 + 8), f"{index + 1:02d} {name}",
                  fill="white", font=ImageFont.load_default())
        if metadata["status"] != "EXTRACTED":
            draw.text((x0 + 20, y0 + 60), metadata["status"], fill="red")
            continue
        part = Image.open(metadata["image"]).convert("RGBA")
        scale = min(1.0, (CELL[0] - 32) / part.width, (CELL[1] - 82) / part.height)
        if scale < 1:
            part = part.resize((max(1, round(part.width * scale)),
                                max(1, round(part.height * scale))), Image.Resampling.NEAREST)
        target = Image.new("RGBA", part.size, GREEN)
        target.alpha_composite(part)
        sheet.paste(target.convert("RGB"),
                    (x0 + (CELL[0] - part.width) // 2,
                     y0 + 38 + (CELL[1] - 52 - part.height) // 2))
        draw.text((x0 + 12, y0 + CELL[1] - 29),
                  f"source crop {metadata['crop_size'][0]} x {metadata['crop_size'][1]} px",
                  fill="white", font=ImageFont.load_default())
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)
    return output


def review_prompt(character_prompt: str, names: list[str]) -> str:
    return (PROMPT_PATH.read_text(encoding="utf-8")
            .replace("__PART_NAMES__", ", ".join(names))
            .replace("__CHARACTER_PROMPT__", character_prompt))


def parse_review(text: str, names: list[str]) -> dict[str, Any]:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = "\n".join(cleaned.splitlines()[1:-1]).strip()
    payload = json.loads(cleaned)
    if not isinstance(payload, dict) or not isinstance(payload.get("broken_parts"), list):
        raise ValueError("Reviewer did not return a broken_parts array")
    seen = set()
    for item in payload["broken_parts"]:
        boxes = item.get("repair_boxes") if isinstance(item, dict) else None
        if boxes is None and isinstance(item, dict) and item.get("repair_box") is not None:
            boxes = [item["repair_box"]]
        invalid_box = boxes is not None and (
            not isinstance(boxes, list) or not boxes or len(boxes) > 6
            or any(not isinstance(box, list) or len(box) != 4
                   or not all(type(value) is int and 0 <= value <= 1000 for value in box)
                   or box[0] >= box[2] or box[1] >= box[3]
                   for box in boxes))
        if (not isinstance(item, dict) or item.get("part") not in names
                or not isinstance(item.get("reason"), str) or invalid_box):
            raise ValueError(f"Invalid review item: {item}")
        if item["part"] in seen:
            raise ValueError(f"Duplicate review item: {item['part']}")
        seen.add(item["part"])
        if boxes is not None:
            item["repair_boxes"] = boxes
    return {"broken_parts": payload["broken_parts"]}


def _inline_image(path: Path) -> dict[str, Any]:
    return {"inlineData": {"mimeType": "image/png",
                           "data": base64.b64encode(path.read_bytes()).decode("ascii")}}


def call_vertex_review(prompt: str, character: Path, sheet: Path, output_dir: Path,
                       model: str, project: str, location: str) -> dict[str, Any]:
    token = subprocess.run(["gcloud", "auth", "print-access-token"], capture_output=True,
                           text=True, check=True).stdout.strip()
    if not token:
        raise RuntimeError("gcloud returned no access token")
    host = "aiplatform.googleapis.com" if location == "global" else f"{location}-aiplatform.googleapis.com"
    url = f"https://{host}/v1/projects/{project}/locations/{location}/publishers/google/models/{model}:generateContent"
    payload = {"contents": [{"role": "user", "parts": [
        {"text": prompt}, _inline_image(character), _inline_image(sheet)]}],
        "generationConfig": {"responseModalities": ["TEXT"], "temperature": 0}}
    (output_dir / "review.request.json").write_text(json.dumps({
        "model": model, "generation_config": payload["generationConfig"],
        "parts": [{"text": prompt}, {"image": str(character.resolve())}, {"image": str(sheet.resolve())}]},
        indent=2) + "\n", encoding="utf-8")
    request = Request(url, data=json.dumps(payload).encode("utf-8"), method="POST",
                      headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    for delay in (15, 45, 90, None):
        try:
            with urlopen(request, timeout=300) as response:
                raw = json.loads(response.read())
            break
        except HTTPError as exc:
            # Rate limits and transient server errors are retried with backoff.
            if exc.code not in (429, 500, 502, 503, 504) or delay is None:
                raise RuntimeError(f"Vertex review failed with HTTP {exc.code}") from exc
            time.sleep(delay)
    (output_dir / "vertex-response.json").write_text(json.dumps(raw, indent=2) + "\n", encoding="utf-8")
    texts = [part["text"] for candidate in raw.get("candidates", [])
             for part in candidate.get("content", {}).get("parts", []) if "text" in part]
    if not texts:
        raise ValueError("Vertex review returned no text")
    return parse_review("\n".join(texts), list(json.loads((output_dir / "part-ids.json").read_text())))


def review_parts(analysis_path: Path, character: Path, character_prompt_path: Path,
                 output_dir: Path, *, provider: str, model: str, project: str | None,
                 location: str, resume_review: Path | None = None) -> dict[str, Any]:
    analysis = json.loads(analysis_path.read_text(encoding="utf-8"))
    output_dir.mkdir(parents=True, exist_ok=True)
    sheet = build_review_sheet(analysis, output_dir / "parts-review-sheet.png")
    names = list(analysis["parts"])
    (output_dir / "part-ids.json").write_text(json.dumps(names, indent=2) + "\n", encoding="utf-8")
    saved_prompt = resume_review.parent / "review-prompt.txt" if resume_review else None
    prompt = (saved_prompt.read_text(encoding="utf-8") if saved_prompt and saved_prompt.is_file()
              else review_prompt(character_prompt_path.read_text(encoding="utf-8"), names))
    (output_dir / "review-prompt.txt").write_text(prompt, encoding="utf-8")
    if resume_review:
        verdict = parse_review(resume_review.read_text(encoding="utf-8"), names)
    elif provider == "vertex":
        if not project:
            project = subprocess.run(["gcloud", "config", "get-value", "project"],
                                     capture_output=True, text=True, check=True).stdout.strip()
        if not project or project == "(unset)":
            raise ValueError("No Vertex project configured")
        verdict = call_vertex_review(prompt, character, sheet, output_dir, model, project, location)
    else:
        raise ValueError("Fixture provider requires --resume-review for the review stage")
    result = {"status": "BROKEN_PARTS_FOUND" if verdict["broken_parts"] else "NO_CLEAR_BREAKS",
              "sheet": str(sheet.resolve()), "provider": "fixture" if resume_review else provider,
              "model": model if not resume_review else None, **verdict}
    (output_dir / "review.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return result
