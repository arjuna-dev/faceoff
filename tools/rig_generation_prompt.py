#!/usr/bin/env python3
"""Print the generation contract from the SAME profile used for splitting."""
import argparse
import json
from pathlib import Path
from PIL import Image, ImageDraw
import build_rigged_sheet as builder


def prompt(profile):
    lines = [
        "Generate one character in one 1024x1536 portrait image using the attached template.",
        "Preserve the exact image dimensions and the size and placement of every body section.",
        "Replace the sample character while preserving all marked attachment centers exactly.",
        "Use flat #ff00ff outside the character. Do not use this color in the costume.",
        "Keep every limb visibly separated. No clothing may connect independently moving limbs.",
        "Return without visible guide markers, dots, frames, text, shadows, or labels.",
        "Draw complete knuckles, hands, toes, heels, cuffs, and soles. Never cut them off.",
        "Both boots face RIGHT in side profile, heels left and toes right, with horizontal soles.",
        "The game mirrors the entire character when facing left; do not mirror individual shoes.",
        "Torso stops at shoulder sockets. Do not include upper arms on the torso.",
        "Stay inside each rectangle with at least 8 pixels of empty background around the art.",
        "Coordinates below use a top-left origin; right and bottom bounds are exclusive.",
        "The first point is the attachment center, the second is its other end. These points are INSIDE the art, not on a cut edge.",
        "Leave solid artwork around every marked point: at least 10 pixels in all directions. Rounded overlapping ends hide seams when joints bend.",
        "Head: neck center to upper skull, with room for a normal-sized face. Torso: shoulder line to belt center, NOT neck opening to belt.",
        "Upper arms: shoulder to elbow. Forearms include complete fists: elbow to fist center. Thighs: hip to knee. Shins: knee to boot cuff. Boots: cuff to sole center, not toe.",
        "All limb axes are vertical in the sheet. The game rotates them into a fighting pose. Left/right identify the two limb chains; never exchange their labeled cells.",
        "Long cloth, hair and accessories must remain within their owning part. Avoid tails beyond knees, shoulder anatomy on the head, or upper arms already painted on the chest.",
    ]
    for name, part in profile["parts"].items():
        lines.append(f"{name}: rectangle {part['rect']}; pivot {part['pivot']}; tip {part['tip']}.")
    return "\n\n".join(lines) + "\n"


def templates(reference, profile, output_dir):
    """Produce five marked image inputs and matching machine-readable bindings."""
    spec = builder.contract()
    output_dir.mkdir(parents=True, exist_ok=True)
    for body_type in spec["body_types"]:
        binding = {**profile, "body_type":body_type}
        sheet, normalized = builder.compile_sheet(reference, binding)
        guide = Image.new("RGBA", builder.CANVAS_SIZE, "#ff00ff")
        guide.alpha_composite(Image.fromarray(sheet))
        draw = ImageDraw.Draw(guide)
        for name, part in normalized["parts"].items():
            x0,y0,x1,y1 = part["rect"]
            draw.rectangle((x0,y0,x1-1,y1-1), outline="#333333", width=1)
            draw.text((x0+4,y0+4), name, fill="white", stroke_width=1, stroke_fill="black")
            for point, color in [(part["pivot"],"#00ffff"),(part["tip"],"#ffff00")]:
                x,y = point
                draw.ellipse((x-7,y-7,x+7,y+7), fill="black")
                draw.line((x-6,y,x+6,y), fill=color, width=2)
                draw.line((x,y-6,x,y+6), fill=color, width=2)
        guide.convert("RGB").save(output_dir/(body_type+".png"))
        normalized["fighter_id"] = "replace_me"
        normalized["source"] = "path/to/generated-unmarked-sheet.png"
        (output_dir/(body_type+".json")).write_text(json.dumps(normalized,indent=2)+"\n")
        text = f"Body type: {body_type}. Match the attached sample's proportions.\n\n" + prompt(normalized)
        (output_dir/(body_type+".prompt.txt")).write_text(text)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", type=Path)
    parser.add_argument("--templates", type=Path, help="Write five image guides, bindings and prompts")
    parser.add_argument("--reference", type=Path, help="Canonical unmarked sample sheet")
    args = parser.parse_args()
    profile = json.loads(args.profile.read_text())
    if args.templates:
        if not args.reference:
            parser.error("--templates requires --reference")
        templates(args.reference, profile, args.templates)
    else:
        print(prompt(profile), end="")
