#!/usr/bin/env python3
"""Uniformly shrink a marked template onto white, retaining its canonical canvas."""
import argparse
import hashlib
import json
import math
from pathlib import Path

from PIL import Image

from character_generation_workflow import _markers, _marker_json, _open_rgb


def frame_image(image: Image.Image, scale: float = 0.99) -> tuple[Image.Image, list[float]]:
    if not 0 < scale < 1:
        raise ValueError("Scale must be strictly between zero and one")
    dx = image.width * (1-scale)/2
    dy = image.height * (1-scale)/2
    framed = image.convert("RGB").transform(
        image.size, Image.Transform.AFFINE,
        (1/scale, 0, -dx/scale, 0, 1/scale, -dy/scale),
        resample=Image.Resampling.NEAREST, fillcolor=(255,255,255),
    )
    return framed, [dx,dy]


def run(source: Path, output: Path, scale: float) -> dict:
    pivots_path = output.with_suffix(".pivots.json")
    report_path = output.with_suffix(".frame.json")
    if any(path.exists() for path in [output, pivots_path, report_path]):
        raise ValueError("Choose fresh output paths; existing templates are not overwritten")
    original_hash = hashlib.sha256(source.read_bytes()).hexdigest()
    original = _open_rgb(source)
    _, old_markers = _markers(original, "original template")
    framed, offset = frame_image(original, scale)
    cells, new_markers = _markers(framed, "framed template")
    records = []
    for cell in cells:
        name = cell["name"]
        for index, (before, after) in enumerate(zip(old_markers[name],new_markers[name])):
            # Pillow samples pixel centers. Preserve the continuous global
            # transform and report the newly measured raster centers separately.
            expected = [scale*(before["center"][axis]+0.5)+offset[axis]-0.5 for axis in (0,1)]
            actual = after["center"]
            error = math.dist(expected,actual)
            if error > 2:
                raise ValueError(f"{name} marker {index}: unexpected raster remap error {error}")
            records.append({"cell":name,"index":index,"original":before["center"],
                            "continuous_expected":expected,"measured":actual,"raster_error_px":error})
    result = {"source":str(source.resolve()),"source_sha256":original_hash,
              "output":str(output.resolve()),"canvas":list(framed.size),
              "uniform_scale":scale,"offset_xy":offset,"resampling":"nearest_neighbor",
              "border_color":"#FFFFFF","marker_count":len(records),"markers":records,
              "original_unchanged":hashlib.sha256(source.read_bytes()).hexdigest()==original_hash}
    output.parent.mkdir(parents=True,exist_ok=True)
    framed.save(output)
    _marker_json(pivots_path,output,cells,new_markers)
    report_path.write_text(json.dumps(result,indent=2)+"\n")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source",type=Path,required=True)
    parser.add_argument("--output",type=Path,required=True)
    parser.add_argument("--scale",type=float,default=0.99)
    args = parser.parse_args()
    result = run(args.source,args.output,args.scale)
    print(json.dumps({key:value for key,value in result.items() if key!="markers"},indent=2))


if __name__ == "__main__":
    main()
