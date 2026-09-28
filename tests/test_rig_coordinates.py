"""Original measurements must survive import, compilation, and crop remapping."""
import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
from rig_atlas_import import map_point, marker_centers
from rig_coordinate_contract import audit_binding, order_markers, detect_grid_cells


class RigCoordinateTests(unittest.TestCase):
    def setUp(self) -> None:
        directory = ROOT / "assets/fighters/rigged/armk"
        self.binding = json.loads((directory / "source.json").read_text())
        self.original = json.loads((directory / "extracted_pivots.json").read_text())

    def test_different_gutter_bounds_never_resize_marker_coordinates(self) -> None:
        self.assertEqual(map_point([176.5, 441.5], [6, 386, 257, 752], [4, 382, 260, 755]), [176.5, 441.5])

    def test_complete_single_scanline_gutter_is_detected(self) -> None:
        from PIL import Image, ImageDraw
        image = Image.new("RGB", (1024, 1536), "magenta")
        draw = ImageDraw.Draw(image)
        draw.rectangle((0, 0, 1023, 1535), outline="white", width=6)
        for y in [385, 752, 1143]:
            draw.line((0, y, 1023, y), fill="white")
        for start, end, count in [(6,385,2),(386,752,4),(753,1143,2),(1144,1530,4)]:
            for column in range(1, count):
                x = 1024*column//count
                draw.rectangle((x-3,start,x+3,end-1),fill="white")
        self.assertEqual(len(detect_grid_cells(image)), 12)

    def test_thick_outer_frames_are_excluded_from_cell_contents(self) -> None:
        from PIL import Image, ImageDraw
        for thickness in [12,40,80]:
            with self.subTest(thickness=thickness):
                image = Image.new("RGB", (1024,1536), "magenta")
                draw = ImageDraw.Draw(image)
                draw.rectangle((0,0,1023,1535),outline="white",width=thickness)
                for y in [385,752,1143]:
                    draw.line((0,y,1023,y),fill="white",width=3)
                for start,end,count in [(thickness,384,2),(387,751,4),(754,1142,2),(1145,1536-thickness,4)]:
                    for column in range(1,count):
                        x=1024*column//count
                        draw.rectangle((x-3,start,x+3,end-1),fill="white")
                cells=detect_grid_cells(image)
                self.assertEqual(len(cells),12)
                self.assertEqual(cells[0]["rect"][1],thickness)
                self.assertEqual(cells[-1]["rect"][3],1536-thickness)

    def test_near_white_vertex_gutters_are_detected(self) -> None:
        from PIL import Image, ImageDraw
        image = Image.new("RGB", (1024,1536), "magenta")
        draw = ImageDraw.Draw(image)
        rule = (180,180,180)
        draw.rectangle((0,0,1023,1535),outline=rule,width=12)
        for y in [385,752,1143]:
            draw.line((0,y,1023,y),fill=rule,width=3)
        for start,end,count in [(12,384,2),(387,751,4),(754,1142,2),(1145,1524,4)]:
            for column in range(1,count):
                x=1024*column//count
                draw.line((x,start,x,end-1),fill=rule)
        self.assertEqual(len(detect_grid_cells(image)),12)
        # Saturated magenta does not qualify as a separator.
        draw.rectangle((255,387,257,750),fill="magenta")
        with self.assertRaisesRegex(ValueError,"vertical gutters"):
            detect_grid_cells(image)

    def test_magenta_tinted_vertex_gutters_are_detected(self) -> None:
        from PIL import Image, ImageDraw
        image = Image.new("RGB", (1024,1536), "magenta")
        draw = ImageDraw.Draw(image)
        rule = (255,145,255)
        draw.rectangle((0,0,1023,1535),outline=rule,width=12)
        for y in [385,752,1143]:
            draw.line((0,y,1023,y),fill=rule,width=3)
        for start,end,count in [(12,384,2),(387,751,4),(754,1142,2),(1145,1524,4)]:
            for column in range(1,count):
                x=1024*column//count
                draw.line((x,start,x,end-1),fill=rule,width=2)
        self.assertEqual(len(detect_grid_cells(image)),12)

    def test_outside_clean_cell_is_rejected_instead_of_repositioned(self) -> None:
        with self.assertRaisesRegex(ValueError, "regenerate instead of moving"):
            map_point([176.5, 441.5], [6, 386, 257, 752], [180, 382, 260, 755])

    def test_shoulders_and_hips_use_left_right_roles_despite_vertical_slop(self) -> None:
        payload = copy.deepcopy(self.original)
        points = [[725, 26], [626, 58], [820, 56], [640, 299], [810, 297]]
        payload["pivots"]["torso_and_pelvis"] = [{"center": point} for point in reversed(points)]
        self.assertEqual(marker_centers(payload)["torso_and_pelvis"], points)
        self.assertEqual([item["center"] for item in order_markers("torso_and_pelvis", payload["pivots"]["torso_and_pelvis"])], points)

    def test_all_22_original_markers_and_seven_calculated_points_match(self) -> None:
        result = audit_binding(self.binding, self.original)
        self.assertEqual(len(result), 29)
        self.assertEqual(sum(item["kind"] == "extracted" for item in result), 22)
        for item in result:
            rect = self.binding["parts"][item["part"]]["rect"]
            self.assertEqual(item["crop_local"], [item["page"][0]-rect[0], item["page"][1]-rect[1]])

    def test_binding_and_reference_changed_together_still_fail_original_extraction(self) -> None:
        self.binding["parts"]["left_shin"]["tip"][0] += 1
        for item in self.binding["coordinate_contract"]["points"]:
            if item["key"] == "left_shin.tip":
                item["page"][0] += 1
                item["crop_local"][0] += 1
        with self.assertRaisesRegex(ValueError, "original extracted marker"):
            audit_binding(self.binding, self.original)

    def test_calculated_torso_center_cannot_drift_from_marker_midpoint(self) -> None:
        self.binding["parts"]["torso"]["pivot"][0] += 1
        for item in self.binding["coordinate_contract"]["points"]:
            if item["key"] == "torso.pivot":
                item["page"][0] += 1
                item["crop_local"][0] += 1
        with self.assertRaisesRegex(ValueError, "shoulders midpoint"):
            audit_binding(self.binding, self.original)

    def test_preserved_compiler_rejects_missing_original_coordinate_reference(self) -> None:
        import build_rigged_sheet as builder
        del self.binding["coordinate_contract"]
        with self.assertRaisesRegex(ValueError, "Original marker coordinate contract is required"):
            builder.compile_sheet(ROOT / self.binding["source"], self.binding)

    def test_extra_original_marker_is_not_silently_ignored(self) -> None:
        self.original["pivots"]["viewer_left_forearm_and_hand"].append({"center": [100, 600]})
        with self.assertRaisesRegex(ValueError, "original marker count"):
            audit_binding(self.binding, self.original)

    def test_reference_key_must_match_the_actual_coordinate_field(self) -> None:
        self.binding["coordinate_contract"]["points"][0]["field"] = "tip"
        with self.assertRaisesRegex(ValueError, "incorrect coordinate field reference"):
            audit_binding(self.binding, self.original)


if __name__ == "__main__":
    unittest.main()
