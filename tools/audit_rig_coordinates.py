#!/usr/bin/env python3
"""Audit original extraction -> source -> compiled -> cropped texture coordinates."""
import argparse
import json
from pathlib import Path

from rig_coordinate_contract import audit_binding, point_at
from verify_rigged_assets import verify


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    directory = args.directory
    try:
        verify(directory)
        binding = json.loads((directory / "source.json").read_text())
        profile = json.loads((directory / "profile.json").read_text())
        contract = binding["coordinate_contract"]
        original = json.loads((directory / contract["marker_json"]).read_text())
        points = audit_binding(binding, original)
        from PIL import Image
        for item in points:
            part, field, index = item["part"], item["field"], item["index"]
            if point_at(profile["parts"], part, field, index) != item["page"]:
                raise ValueError(f"{item['key']}: compiled coordinates differ from original reference")
            rect = profile["parts"][part]["rect"]
            size = Image.open(directory / (part + ".png")).size
            if list(size) != [rect[2]-rect[0], rect[3]-rect[1]]:
                raise ValueError(f"{part}: cropped texture dimensions differ from source rectangle")
            item["compiled_matches"] = True
            item["sprite_centered_local"] = [item["crop_local"][0]-size[0]/2, item["crop_local"][1]-size[1]/2]
        if profile["pixel_scale"] != binding["pixel_scale"]:
            raise ValueError("Compiled pixel scale differs from source")
        result = {"status": "PASS", "directory": str(directory.resolve()),
                  "extracted_count": 22, "calculated_count": 7,
                  "pixel_scale": profile["pixel_scale"], "points": points}
    except (ValueError, KeyError, OSError) as exc:
        result = {"status": "FAILED", "error": str(exc)}
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, indent=2)+"\n")
    printed = {key: value for key, value in result.items() if key != "points"} if args.output else result
    print(json.dumps(printed, indent=2))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
