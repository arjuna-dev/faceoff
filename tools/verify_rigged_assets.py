#!/usr/bin/env python3
"""Reject stale, partially built, incorrectly bound or unreviewed fighter assets."""
import argparse
import json
import hashlib
from pathlib import Path
import sys
ROOT = Path(__file__).resolve().parents[1]
RIG_ROOT = ROOT / "assets/fighters/rigged"
RUNTIME_FILES = ["scripts/characters/skeleton_rig_skin.gd", "scripts/characters/ragdoll_character.gd",
                 "assets/fighters/rigged/contract.json", "tests/rig_pose_cases.gd"]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def runtime_signature():
    return digest(b"".join((ROOT/p).read_bytes() for p in RUNTIME_FILES))


def verify(directory, require_review=False, rebuild=True):
    profile = json.loads((directory/"profile.json").read_text())
    manifest = json.loads((directory/"rig.json").read_text())
    binding_path = directory/"source.json"
    binding = json.loads(binding_path.read_text())
    if binding.get("render_mode") == "preserve_proportions":
        from rig_coordinate_contract import audit_binding
        coordinate_contract = binding.get("coordinate_contract", {})
        marker_path = directory / coordinate_contract.get("marker_json", "extracted_pivots.json")
        if digest(marker_path.read_bytes()) != coordinate_contract.get("marker_json_sha256"):
            raise ValueError(f"{directory.name}: original extracted marker JSON changed")
        audit_binding(binding, json.loads(marker_path.read_text()))
        if profile.get("coordinate_contract") != coordinate_contract:
            raise ValueError(f"{directory.name}: compiled coordinate reference differs from source")
    source = ROOT/binding["source"]
    expected = {"source_sha256":digest(source.read_bytes()),
                "binding_sha256":digest(binding_path.read_bytes()),
                "contract_sha256":digest((RIG_ROOT/"contract.json").read_bytes()),
                "profile_sha256":digest((directory/"profile.json").read_bytes())}
    for key,value in expected.items():
        if manifest.get(key) != value:
            raise ValueError(f"{directory.name}: stale {key}; rebuild and review")
    if rebuild:
        import build_rigged_sheet as builder
        import numpy as np
        from PIL import Image
        sheet, rebuilt = builder.compile_sheet(source, binding)
        if profile != rebuilt:
            raise ValueError(f"{directory.name}: compiled profile differs from source binding")
    for name,part in profile["parts"].items():
        path = directory/(name+".png")
        if manifest.get("textures_sha256",{}).get(name) != digest(path.read_bytes()):
            raise ValueError(f"{directory.name}: {name} texture was changed outside the compiler")
        x0,y0,x1,y1 = part["rect"]
        if rebuild and not np.array_equal(np.array(Image.open(path)),sheet[y0:y1,x0:x1]):
            raise ValueError(f"{directory.name}: {name} does not reproduce from its source")
    if digest((ROOT/manifest["sheet"]).read_bytes()) != manifest.get("sheet_sha256"):
        raise ValueError(f"{directory.name}: published sheet differs from compiled textures")
    if require_review:
        review = json.loads((directory/"review.json").read_text())
        if review.get("runtime_sha256") != runtime_signature() or review.get("rig_sha256") != digest((directory/"rig.json").read_bytes()):
            raise ValueError(f"{directory.name}: visual review is stale")
        if review.get("decision") != "accepted" or not review.get("reviewer") or not review.get("captures"):
            raise ValueError(f"{directory.name}: visual review required")
        for path, sha in review["captures"].items():
            if digest((ROOT/path).read_bytes()) != sha:
                raise ValueError(f"{directory.name}: reviewed capture changed: {path}")
    return {"fighter":profile["fighter_id"], "hashes_current":True, "rebuild_checked":rebuild, "visual_review_current":require_review}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories", nargs="*", type=Path)
    parser.add_argument("--require-review", action="store_true")
    parser.add_argument("--hash-only", action="store_true", help="Export preflight, using only Python's standard library")
    args = parser.parse_args()
    directories = args.directories or [p.parent for p in sorted(RIG_ROOT.glob("*/source.json"))]
    try:
        if not directories:
            raise ValueError("No compiled fighter bindings found")
        print(json.dumps([verify(p,args.require_review,not args.hash_only) for p in directories],indent=2))
    except (ValueError, KeyError, OSError) as error:
        print(f"Rig validation failed: {error}",file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
