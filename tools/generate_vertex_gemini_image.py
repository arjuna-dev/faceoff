#!/usr/bin/env python3
"""Generate one image with Gemini on Vertex AI using the local gcloud login.

This keeps image generation reproducible without storing an API key in the
repository. The bearer token comes from `gcloud auth print-access-token`.
"""

from __future__ import annotations

import argparse
import base64
import json
import time
import mimetypes
import os
from pathlib import Path
import subprocess
import sys
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


def _mime_type(path: Path) -> str:
    guessed, _ = mimetypes.guess_type(path.name)
    return guessed or "image/png"


def _access_token() -> str:
    result = subprocess.run(
        ["gcloud", "auth", "print-access-token"],
        check=True,
        capture_output=True,
        text=True,
    )
    token = result.stdout.strip()
    if not token:
        raise RuntimeError("gcloud returned an empty access token")
    return token


def _endpoint(project: str, location: str, model: str) -> str:
    host = "aiplatform.googleapis.com" if location == "global" else f"{location}-aiplatform.googleapis.com"
    return (
        f"https://{host}/v1/projects/{project}/locations/{location}"
        f"/publishers/google/models/{model}:generateContent"
    )


def _image_part(path: Path) -> dict[str, dict[str, str]]:
    return {
        "inlineData": {
            "mimeType": _mime_type(path),
            "data": base64.b64encode(path.read_bytes()).decode("ascii"),
        }
    }


def _extract_image(response: dict) -> bytes:
    for candidate in response.get("candidates", []):
        content = candidate.get("content", {})
        for part in content.get("parts", []):
            inline_data = part.get("inlineData") or part.get("inline_data")
            if inline_data and inline_data.get("data"):
                return base64.b64decode(inline_data["data"])
    raise RuntimeError(
        "Vertex returned no inline image. Response summary: "
        + json.dumps(response, ensure_ascii=False)[:2000]
    )


# Rate limits and transient server errors are retried with backoff.
RETRYABLE_HTTP = {429, 500, 502, 503, 504}
RETRY_DELAYS_SECONDS = (15, 45, 90)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", default=os.environ.get("GOOGLE_CLOUD_PROJECT"))
    parser.add_argument("--location", default=os.environ.get("GOOGLE_CLOUD_LOCATION", "global"))
    parser.add_argument("--model", default="gemini-3-pro-image")
    parser.add_argument("--prompt-file", type=Path, required=True)
    parser.add_argument("--image", type=Path, action="append", default=[])
    parser.add_argument("--image-label", action="append", default=[],
                        help="Text sent right before the matching --image; the prompt then goes last")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--response-json", type=Path)
    parser.add_argument("--aspect-ratio")
    parser.add_argument("--image-size", choices=["512", "1K", "2K", "4K"])
    args = parser.parse_args()

    if not args.project:
        result = subprocess.run(
            ["gcloud", "config", "get-value", "project"],
            check=True,
            capture_output=True,
            text=True,
        )
        args.project = result.stdout.strip()
    if not args.project or args.project == "(unset)":
        parser.error("--project is required when gcloud has no active project")
    if not args.prompt_file.is_file():
        parser.error(f"prompt file does not exist: {args.prompt_file}")
    missing = [str(path) for path in args.image if not path.is_file()]
    if missing:
        parser.error("reference image does not exist: " + ", ".join(missing))

    if args.image_label and len(args.image_label) != len(args.image):
        parser.error("--image-label must be given once per --image")
    prompt_text = {"text": args.prompt_file.read_text(encoding="utf-8")}
    if args.image_label:
        # Labeling each image in place tells the model which one to edit.
        parts: list[dict] = []
        for label, path in zip(args.image_label, args.image):
            parts.extend(({"text": label}, _image_part(path)))
        parts.append(prompt_text)
    else:
        parts = [prompt_text]
        parts.extend(_image_part(path) for path in args.image)
    generation_config: dict = {"responseModalities": ["IMAGE"]}
    image_config: dict = {}
    if args.aspect_ratio:
        image_config["aspectRatio"] = args.aspect_ratio
    if args.image_size:
        image_config["imageSize"] = args.image_size
    if image_config:
        generation_config["imageConfig"] = image_config

    # Record the exact ordered request (text and image paths) for inspection.
    layout = []
    if args.image_label:
        for label, path in zip(args.image_label, args.image):
            layout.extend(({"text": label}, {"image": str(path.resolve())}))
        layout.append({"text": prompt_text["text"]})
    else:
        layout = [{"text": prompt_text["text"]}, *({"image": str(path.resolve())} for path in args.image)]
    request_record = args.output.with_name(args.output.stem + ".request.json")
    request_record.parent.mkdir(parents=True, exist_ok=True)
    request_record.write_text(json.dumps({"model": args.model, "generation_config": generation_config,
                                          "parts": layout}, indent=2) + "\n", encoding="utf-8")

    payload = {
        "contents": [{"role": "user", "parts": parts}],
        "generationConfig": generation_config,
    }
    request = Request(
        _endpoint(args.project, args.location, args.model),
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {_access_token()}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    response = None
    for attempt, delay in enumerate(RETRY_DELAYS_SECONDS + (None,)):
        try:
            with urlopen(request, timeout=300) as response_stream:
                response = json.loads(response_stream.read())
            break
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            if exc.code in RETRYABLE_HTTP and delay is not None:
                print(f"Vertex HTTP {exc.code}; retrying in {delay}s", file=sys.stderr)
                time.sleep(delay)
                continue
            print(f"Vertex request failed with HTTP {exc.code}: {body[:4000]}", file=sys.stderr)
            return 2
        except URLError as exc:
            if delay is not None:
                print(f"Vertex request failed ({exc}); retrying in {delay}s", file=sys.stderr)
                time.sleep(delay)
                continue
            print(f"Vertex request failed: {exc}", file=sys.stderr)
            return 2

    if args.response_json:
        args.response_json.parent.mkdir(parents=True, exist_ok=True)
        args.response_json.write_text(json.dumps(response, indent=2), encoding="utf-8")
    image_bytes = _extract_image(response)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(image_bytes)
    print(f"Saved {args.output} from {args.model} in project {args.project} ({args.location})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
