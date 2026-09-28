#!/usr/bin/env python3
"""Offline stages for an LLM-driven character workflow. No editor clicks required.

init -> build -> check -> capture/inspect -> accept
Generation providers supply the raw PNG. A failed build never publishes a rig.
The LLM may correct source.json from the image or regenerate, then retry.
"""
import argparse
import json
from pathlib import Path
import sys
import os
import subprocess
from run_godot_check import run as run_godot
import build_rigged_sheet as builder
import verify_rigged_assets as verification


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command",required=True)
    init = sub.add_parser("init",help="Create a candidate binding from the shared template")
    init.add_argument("--fighter-id",required=True)
    init.add_argument("--body-type",choices=list(builder.contract()["body_types"]),default="standard")
    init.add_argument("--source",type=Path,required=True)
    init.add_argument("--markers",type=Path,required=True,help="Original 22-marker extraction JSON")
    init.add_argument("--marked-source",type=Path,required=True,help="Matching authoritative marked atlas")
    init.add_argument("--directory",type=Path,required=True)
    init.add_argument("--pixel-scale",type=float,help="One uniform scale for the complete character")
    build = sub.add_parser("build",help="Compile the binding and whole image, or return a rejection")
    build.add_argument("directory",type=Path)
    build.add_argument("--sheet",type=Path,help="Defaults to DIRECTORY/sheet.png")
    check = sub.add_parser("check",help="Check reproducibility and stale inputs")
    check.add_argument("directory",type=Path)
    check.add_argument("--require-review",action="store_true")
    for name in ("test","capture"):
        stage = sub.add_parser(name,help="Check the production renderer using Godot")
        stage.add_argument("--godot",default=os.environ.get("GODOT_BIN","godot"))
        stage.add_argument("--directory",type=Path,help="Optional candidate rig; omit for Batyr and Oculon")
        stage.add_argument("--output-dir",type=Path,default=Path("tests/rig-validation"))
    accept = sub.add_parser("accept",help="Record a completed visual review, after inspecting captures")
    accept.add_argument("directory",type=Path)
    accept.add_argument("--reviewer",required=True)
    accept.add_argument("--notes",required=True)
    accept.add_argument("--capture-dir",type=Path,required=True)
    args = parser.parse_args()
    try:
        if args.command == "init":
            path = args.directory/"source.json"
            if path.exists():
                raise ValueError("source.json already exists; edit or choose a fresh candidate directory")
            command = [sys.executable, str(Path(__file__).with_name("rig_atlas_import.py")),
                       "--source", str(args.source), "--markers", str(args.markers),
                       "--marked-source", str(args.marked_source), "--fighter-id", args.fighter_id,
                       "--body-type", args.body_type, "--directory", str(args.directory)]
            if args.pixel_scale is not None:
                command.extend(["--pixel-scale", str(args.pixel_scale)])
            imported = subprocess.run(command, capture_output=True, text=True)
            if imported.returncode:
                raise ValueError("Marker import failed: " + (imported.stderr or imported.stdout)[-4000:])
            result = {"binding": str(path), "next": "build, then audit coordinates and inspect rendered poses"}
        elif args.command == "build":
            path = args.directory/"source.json"
            binding = json.loads(path.read_text())
            source = builder.ROOT/binding["source"]
            result = builder.publish(source,path,args.directory,args.sheet or args.directory/"sheet.png")
        elif args.command == "check":
            result = verification.verify(args.directory,args.require_review)
        elif args.command in ("test","capture"):
            output = args.output_dir.resolve()
            output.mkdir(parents=True,exist_ok=True)
            script = "tests/test_skeleton_rig.gd" if args.command == "test" else "tests/capture_rigged_fighters.gd"
            command = [args.godot,"--path",str(builder.ROOT),"--script",script]
            command += ["--headless"] if args.command == "test" else ["--audio-driver","Dummy","--rendering-method","gl_compatibility"]
            command += ["--"]
            if args.directory:
                relative = args.directory.resolve().relative_to(builder.ROOT)
                command.append("--rig-dir=res://"+str(relative))
            report_path = output/"mechanics.json"
            command.append("--report="+str(report_path) if args.command == "test" else "--output-dir="+str(output))
            if args.command == "test":
                # An interrupted or failed process must not leave an old PASS.
                report_path.write_text(json.dumps({"passed":False,"process_checked":False})+"\n")
            else:
                (output/"capture.json").write_text(json.dumps({"complete":False})+"\n")
            run_godot(command)
            if args.command == "test":
                report = json.loads(report_path.read_text())
                report["process_checked"] = True
                report_path.write_text(json.dumps(report,indent=2)+"\n")
            result = {"stage":args.command,"passed":True,"output":str(output)}
        else:
            verification.verify(args.directory)
            fighter_id = json.loads((args.directory/"profile.json").read_text())["fighter_id"]
            rig_hash = builder.digest((args.directory/"rig.json").read_bytes())
            for name in ("capture.json","mechanics.json"):
                evidence = json.loads((args.capture_dir/name).read_text())
                if evidence.get("runtime_sha256") != verification.runtime_signature() or evidence.get("rigs",{}).get(fighter_id) != rig_hash:
                    raise ValueError(f"{name} is stale or belongs to another candidate")
                if len(evidence.get("poses",[])) != 13 or len(evidence.get("body_types",[])) != 5 or evidence.get("facings") != [-1,1]:
                    raise ValueError(f"{name} does not cover the required poses, types and facings")
                if name == "mechanics.json" and (evidence.get("passed") is not True or evidence.get("process_checked") is not True):
                    raise ValueError("Mechanical rig checks have not passed")
                if name == "capture.json" and (evidence.get("complete") is not True or evidence.get("renderer") not in ("gl_compatibility","mobile","forward_plus")):
                    raise ValueError("Real graphics captures required")
            captures = {}
            for name in ("poses.png","body-types.png","capture.json","mechanics.json"):
                path = args.capture_dir/name
                relative = path.resolve().relative_to(builder.ROOT)
                captures[str(relative)] = builder.digest(path.read_bytes())
            result = {"decision":"accepted","reviewer":args.reviewer,"notes":args.notes,
                      "rig_sha256":rig_hash,
                      "runtime_sha256":verification.runtime_signature(),"captures":captures}
            (args.directory/"review.json").write_text(json.dumps(result,indent=2)+"\n")
        print(json.dumps(result,indent=2))
        return 0
    except (ValueError,KeyError,OSError,RuntimeError,TypeError) as error:
        print(json.dumps({"status":"rejected","reason":str(error),
                          "next":"Correct the source binding or regenerate using the marked guide. Never crop to pass validation."}),file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
