import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from whole_character_workflow import (  # noqa: E402
    BACKGROUND_HEX,
    JOINTS,
    PART_COLORS,
    analyze_and_reconstruct,
    rgb,
    write_character_prompt,
    write_pivot_prompt,
    write_segmentation_prompt,
    strip_uniform_frame,
    snap_joints_to_contacts,
    attach_held_item,
    correct_ownership_with_bones,
    enforce_near_far_sides,
)
from detect_part_repairs import detect  # noqa: E402
from repair_whole_character_parts import (  # noqa: E402
    GREEN, MAGENTA, apply_repair, build_repair_prompt, repair_canvas,
)
from render_whole_character_poses import DRAW_ORDER, draw_order, parent_of  # noqa: E402

PART_COLOR = (110, 125, 146)


class WholeCharacterWorkflowTests(unittest.TestCase):
    def test_character_prompt_uses_open_stance_and_arcade_pixel_art(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "prompt.txt"
            brief = (ROOT / "prompts/characters/armk_whole.txt").read_text()
            write_character_prompt(path, brief)
            prompt = path.read_text()
            self.assertIn("blue-and-white fabric bandana", prompt)
            self.assertIn("Both arms hang down, slightly open", prompt)
            self.assertIn("Ideally no body part overlaps another", prompt)
            self.assertIn("hand-pixelled 1990s arcade fighter sprite art", prompt)
            self.assertIn("slight and fine", prompt)
            self.assertNotIn("STYLE REFERENCE", prompt)
            write_character_prompt(path, brief, style_image=True)
            self.assertIn("Replicate only that style", path.read_text())

    def test_workflow_prompts_are_character_agnostic(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            write_character_prompt(folder / "character.txt", "BRIEF", style_image=True)
            write_segmentation_prompt(folder / "segmentation.txt")
            write_pivot_prompt(folder / "pivots.txt")
            guidance = json.loads((ROOT / "prompts/workflows/whole_character_part_guidance.json").read_text())
            back_example = guidance.pop("back_accessory")
            texts = [path.read_text().replace("BRIEF", "").replace(back_example, "")
                     for path in folder.iterdir()]
            texts += [build_repair_prompt("torso_pelvis", {"covered_by": {"near_upper_arm": 10}}, (848, 1264)),
                      *guidance.values()]
            # Only the back accessory description may name example categories.
            for text in texts:
                for word in ("wings?", "bandanas?", "jeans", "sneakers?", "tattoos?", "angels?"):
                    self.assertIsNone(re.search(rf"\b{word}\b", text.lower()), word)
            self.assertNotIn("#00FFFF", (folder / "segmentation.txt").read_text())
            self.assertIn("#00FFFF", (folder / "pivots.txt").read_text())

    def test_repair_prompt_names_each_occluding_part(self) -> None:
        prompt = build_repair_prompt("torso_pelvis", {"covered_by": {
            "near_upper_arm": 500, "head_neck": 200, "enclosed gaps": 40}}, (848, 1264))
        self.assertIn("- magenta where the near upper arm covered the torso", prompt)
        self.assertIn("- magenta where the head and neck covered the torso", prompt)
        self.assertIn("- magenta in gaps enclosed by the torso", prompt)
        self.assertIn("Remove all the magenta, leaving behind it the torso", prompt)
        self.assertIn("Do not draw the near upper arm or the head and neck", prompt)

    def test_far_arm_draws_behind_torso_and_far_leg_and_back_accessory_is_lowest(self) -> None:
        self.assertEqual(DRAW_ORDER[0], "back_accessory")
        for part in ("far_upper_arm", "far_forearm_hand"):
            self.assertLess(DRAW_ORDER.index(part), DRAW_ORDER.index("far_thigh"))
            self.assertLess(DRAW_ORDER.index(part), DRAW_ORDER.index("torso_pelvis"))

    def test_pivots_snap_to_the_contact_line_and_every_joint_gets_one(self) -> None:
        masks = {name: np.zeros((200, 200), dtype=bool) for name in PART_COLORS}
        masks["torso_pelvis"][60:140, 60:140] = True
        masks["head_neck"][20:60, 80:120] = True       # touches the torso along y=59/60
        masks["near_upper_arm"][70:130, 140:160] = True  # touches the torso along x=139/140
        dots = {"neck": {"center": [100.0, 52.0], "connects": ["head_neck", "torso_pelvis"]},
                "near_shoulder": {"center": [190.0, 10.0], "connects": ["torso_pelvis", "near_upper_arm"]}}
        joints, warnings = snap_joints_to_contacts(dots, masks)
        self.assertEqual(joints["neck"]["method"], "model dot inside the joint")
        self.assertEqual(joints["neck"]["center"], [100.0, 52.0])
        self.assertEqual(joints["near_shoulder"]["method"], "contact center")
        self.assertIn(joints["near_shoulder"]["center"][0], (139.0, 140.0))
        self.assertTrue(any("near_elbow" in warning for warning in warnings))

    def test_skeleton_fixes_toes_on_the_shin_and_shorts_painted_as_one_thigh(self) -> None:
        index = {name: position for position, name in enumerate(PART_COLORS, start=1)}
        labels = np.zeros((300, 300), dtype=np.int16)
        labels[100:200, 40:160] = index["near_thigh"]    # shorts over both legs, all near thigh
        labels[200:280, 60:90] = index["near_shin"]
        labels[280:295, 60:130] = index["near_shin"]     # toes past the ankle, painted as shin
        labels[286:295, 50:60] = index["near_foot"]
        labels[200:280, 120:150] = index["far_shin"]
        joints = {name: {"center": center} for name, center in {
            "near_hip": [75, 100], "near_knee": [75, 200], "near_ankle": [75, 280],
            "far_hip": [135, 100], "far_knee": [135, 200], "far_ankle": [135, 280]}.items()}
        fixed, moved = correct_ownership_with_bones(labels, joints)
        self.assertEqual(fixed[290, 120], index["near_foot"])
        self.assertEqual(fixed[150, 150], index["far_thigh"])
        self.assertEqual(fixed[150, 60], index["near_thigh"])
        self.assertTrue(any("past near_ankle" in key for key in moved))

    def test_near_limbs_are_the_screen_left_ones(self) -> None:
        index = {name: position for position, name in enumerate(PART_COLORS, start=1)}
        labels = np.zeros((100, 200), dtype=np.int16)
        labels[:, 150:170] = index["near_thigh"]
        labels[:, 20:40] = index["far_thigh"]
        labels[:, 60:80] = index["near_upper_arm"]
        labels[:, 120:140] = index["far_upper_arm"]
        fixed, swapped = enforce_near_far_sides(labels)
        self.assertEqual(swapped, ["leg"])
        self.assertEqual(fixed[0, 25], index["near_thigh"])
        self.assertEqual(fixed[0, 65], index["near_upper_arm"])

    def test_held_item_rides_on_the_hand_it_touches_and_draws_behind_it(self) -> None:
        masks = {name: np.zeros((100, 100), dtype=bool) for name in PART_COLORS}
        masks["held_item"][10:90, 48:52] = True
        masks["far_forearm_hand"][40:50, 40:60] = True
        masks["near_forearm_hand"][0:5, 0:5] = True
        parts = {name: {"status": "EXTRACTED"} for name in PART_COLORS}
        attach_held_item(parts, masks)
        self.assertEqual(parts["held_item"]["attached_to"], "far_forearm_hand")
        report = {"parts": parts}
        self.assertEqual(parent_of(report, "held_item"), ("far_forearm_hand", None))
        order = draw_order(report)
        self.assertEqual(order.index("held_item") + 1, order.index("far_forearm_hand"))

    def test_model_drawn_frame_is_replaced_with_background_and_raw_kept(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            image = np.full((300, 200, 3), rgb(BACKGROUND_HEX), dtype=np.uint8)
            image[100:200, 60:140] = PART_COLOR
            image[:6], image[-6:], image[:, :6], image[:, -6:] = 255, 255, 255, 255
            path = folder / "character.png"
            Image.fromarray(image).save(path)
            result = strip_uniform_frame(path, folder / "raw.png")
            self.assertEqual(result["frame_px"], 9)
            cleaned = np.asarray(Image.open(path))
            self.assertEqual(tuple(cleaned[0, 0]), rgb(BACKGROUND_HEX))
            np.testing.assert_array_equal(cleaned[100:200, 60:140], image[100:200, 60:140])
            self.assertTrue((folder / "raw.png").is_file())
            self.assertIsNone(strip_uniform_frame(path, folder / "raw2.png"))

    def test_detection_flags_split_parts_holes_and_wrapped_neighbors(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            canvas = (200, 200)
            layout = {
                "far_thigh": [(20, 20, 60, 70), (20, 120, 60, 170)],  # split by near_thigh, drawn in front
                "near_thigh": [(10, 70, 70, 120)],
                "torso_pelvis": [(100, 20, 180, 180)],
                "near_forearm_hand": [(115, 55, 165, 105)],  # entirely in front of the torso
                "head_neck": [(100, 0, 180, 20)],  # the torso is drawn behind the head, never in front
            }
            parts = {}
            for name, rects in layout.items():
                mask = np.zeros((canvas[1], canvas[0]), dtype=bool)
                for x0, y0, x1, y1 in rects:
                    mask[y0:y1, x0:x1] = True
                if name == "torso_pelvis":
                    mask[55:105, 115:165] = False
                    mask[140:160, 130:150] = False  # a see-through gap, not missing art
                ys, xs = np.nonzero(mask)
                crop = np.zeros((ys.max() - ys.min() + 1, xs.max() - xs.min() + 1, 4), dtype=np.uint8)
                crop[mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]] = (*PART_COLOR, 255)
                path = folder / f"{name}.png"
                Image.fromarray(crop, mode="RGBA").save(path)
                parts[name] = {"status": "EXTRACTED", "image": str(path),
                               "crop_origin": [int(xs.min()), int(ys.min())]}
            found = detect({"canvas": list(canvas), "parts": parts})
            self.assertIn("split into 2 pieces by near_thigh", found["far_thigh"]["reason"])
            self.assertIn("near_forearm_hand", found["torso_pelvis"]["reason"])
            self.assertTrue(found["torso_pelvis"]["fill"][80, 140])
            self.assertFalse(found["torso_pelvis"]["fill"][150, 140])
            self.assertTrue(found["far_thigh"]["fill"][95, 40])
            self.assertNotIn("near_thigh", found)
            self.assertNotIn("head_neck", found)

    def test_repair_keeps_original_pixels_and_fills_only_marked_area(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            canvas = (256, 384)
            origin = (60, 80)
            part = Image.new("RGBA", (80, 100), (*PART_COLOR, 255))
            ImageDraw.Draw(part).rectangle((0, 40, 30, 70), fill=(0, 0, 0, 0))
            visible = np.asarray(part)[:, :, 3] > 0
            own = np.zeros((canvas[1], canvas[0]), dtype=bool)
            own[80:180, 60:140] = visible
            fill = np.zeros_like(own)
            fill[120:151, 60:91] = True  # the notch another part covered
            sent = repair_canvas(part, origin, fill, canvas, folder / "input.png")
            self.assertEqual(tuple(sent[0, 0]), GREEN)
            self.assertEqual(tuple(sent[130, 70]), MAGENTA)
            model = sent.copy()
            model[120:151, 60:91] = PART_COLOR  # completes the notch
            model[300:340, 100:140] = (200, 30, 30)  # an invented limb in open space
            generated = folder / "generated.png"
            Image.fromarray(np.roll(model, shift=(2, 3), axis=(0, 1))).save(generated)
            evidence = apply_repair(part, origin, generated, own, fill, sent, canvas, {},
                                    folder / "repaired.png", folder / "mask.png")
            self.assertEqual(evidence["alignment_shift_px"], [3, 2])
            self.assertGreater(evidence["added_foreground_pixels"], 800)
            self.assertGreater(evidence["ignored_paint_outside_marked_area"], 1000)
            repaired = np.asarray(Image.open(folder / "repaired.png"))
            self.assertEqual(evidence["crop_origin"], list(origin))
            self.assertEqual(repaired.shape[:2], (100, 80))
            np.testing.assert_array_equal(repaired[visible], np.asarray(part)[visible])

    def test_parts_reconstruct_at_original_coordinates_and_share_joints(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            size = (256, 384)
            source = Image.new("RGB", size, rgb(BACKGROUND_HEX))
            segmentation = Image.new("RGB", size, rgb(BACKGROUND_HEX))
            source_draw = ImageDraw.Draw(source)
            mask_draw = ImageDraw.Draw(segmentation)
            rectangles = {
                "head_neck": (101, 42, 155, 94),
                "torso_pelvis": (95, 95, 161, 210),
                # Facing screen right, the near limbs are the screen-left ones.
                "far_upper_arm": (162, 110, 183, 155),
                "far_forearm_hand": (184, 156, 207, 208),
                "near_upper_arm": (73, 110, 94, 155),
                "near_forearm_hand": (49, 156, 72, 208),
                "far_thigh": (129, 211, 160, 260),
                "far_shin": (129, 261, 160, 310),
                "far_foot": (129, 311, 180, 328),
                "near_thigh": (95, 211, 126, 260),
                "near_shin": (95, 261, 126, 310),
                "near_foot": (75, 311, 126, 328),
            }
            for name, rect in rectangles.items():
                source_draw.rectangle(rect, fill=PART_COLOR)
                mask_draw.rectangle(rect, fill=rgb(PART_COLORS[name]))
            # A hole in the torso artwork that the map still paints as torso.
            source_draw.rectangle((115, 145, 135, 165), fill=rgb(BACKGROUND_HEX))
            clean_segmentation = segmentation.copy()
            joints = [
                (128, 95), (162, 121), (183, 155), (94, 121), (73, 155),
                (145, 210), (145, 260), (145, 310), (110, 210), (110, 260), (110, 310),
            ]
            pivot_map = clean_segmentation.copy()
            pivot_draw = ImageDraw.Draw(pivot_map)
            for x, y in joints:
                pivot_draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=rgb("#00FFFF"))
            character_path = folder / "character.png"
            segmentation_path = folder / "segmentation.png"
            pivots_path = folder / "pivots.png"
            source.save(character_path)
            clean_segmentation.save(segmentation_path)
            pivot_map.save(pivots_path)

            report = analyze_and_reconstruct(character_path, segmentation_path, folder / "inspection",
                                             pivots_path)

            self.assertEqual(report["physical_joint_count"], len(JOINTS))
            self.assertEqual(report["part_specific_pivot_count"], 22)
            self.assertEqual(report["status"], "PASS", report["issues"])
            self.assertEqual(report["reconstruction"]["missing_source_pixels"], 0)
            self.assertEqual(set(report["parts"]), set(PART_COLORS))
            original = np.asarray(Image.open(folder / "inspection/source-transparent.png"))
            reconstructed = np.asarray(Image.open(folder / "inspection/reconstructed.png"))
            np.testing.assert_array_equal(original, reconstructed)
            self.assertEqual(
                report["parts"]["head_neck"]["pivots"]["neck"]["page"],
                report["parts"]["torso_pelvis"]["pivots"]["neck"]["page"],
            )
            self.assertEqual(report["parts"]["back_accessory"]["status"], "ABSENT")
            # Both parts of a joint share the artwork inside its overlap circle.
            hip = next(item for item in report["joint_overlaps"] if item["joint"] == "near_hip")
            self.assertGreater(hip["shared_pixels"], 0)
            thigh = report["parts"]["near_thigh"]
            self.assertEqual(report["joints"]["neck"]["method"], "above the shoulders' midpoint")
            torso_core_top = report["parts"]["torso_pelvis"]["core_crop_origin"][1]
            # Only the part drawn underneath (the torso, below the thigh) extends.
            self.assertEqual(hip["extended_part"], "torso_pelvis")
            torso = report["parts"]["torso_pelvis"]
            self.assertGreater(torso["crop_origin"][1] + torso["crop_size"][1], 211)
            self.assertEqual(thigh["crop_origin"][1], 211)
            self.assertEqual(torso_core_top, 95)

            # Full CLI run on fixtures: isolation, detection, repair stage, assembly and report.
            run = folder / "run"
            completed = subprocess.run(
                [sys.executable, str(ROOT / "tools/whole_character_workflow.py"),
                 "--character-prompt-file", str(ROOT / "prompts/characters/armk_whole.txt"),
                 "--output-dir", str(run), "--provider", "fixture",
                 "--resume-character", str(character_path),
                 "--resume-segmentation", str(segmentation_path),
                 "--resume-pivots", str(pivots_path)],
                cwd=ROOT, capture_output=True, text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            workflow = json.loads((run / "workflow.json").read_text())
            self.assertEqual(workflow["status"], "AWAITING_HUMAN_REVIEW")
            # The torso's enclosed background gap is see-through, not missing art.
            self.assertEqual(workflow["parts_needing_repair"], {})
            repair_report = json.loads((run / "inspection/repair/repair-report.json").read_text())
            self.assertEqual(repair_report["status"], "NO_REPAIR_NEEDED")
            pose_report = json.loads((run / "inspection/repair/poses/pose-report.json").read_text())
            self.assertEqual(len(pose_report["poses"]), 13)
            self.assertEqual(pose_report["poses"]["rest"]["fit_shift_px"], [0.0, 0.0])
            for pose in pose_report["poses"].values():
                self.assertLess(pose["max_parent_child_joint_gap_px"], 0.001)
            page = (run / "report.html").read_text()
            for step in ("Character generation", "Segmentation", "Pivots", "Part isolation",
                         "Repair detection", "Part repair", "Assembly for human verification"):
                self.assertIn(step, page)
            self.assertIn("joint-overlaps.png", page)

            # Extra dots are rejected for acceptance, but the eleven valid
            # anatomical pairs still support diagnostic poses.
            for x, y in ((204, 200), (53, 200)):
                pivot_draw.ellipse((x - 2, y - 2, x + 2, y + 2), fill=rgb("#00FFFF"))
            pivot_map.save(pivots_path)
            with_extras = analyze_and_reconstruct(character_path, segmentation_path,
                                                  folder / "inspection-with-extras", pivots_path)
            self.assertEqual(with_extras["physical_joint_count"], 13)
            self.assertEqual(len(with_extras["joints"]), 11)
            self.assertEqual(with_extras["status"], "REVIEW_REQUIRED")


if __name__ == "__main__":
    unittest.main()
