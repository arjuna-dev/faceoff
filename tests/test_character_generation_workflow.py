import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / "tools" / "character_generation_workflow.py"
TEMPLATE = ROOT / "builds" / "templates" / "geometric_dummy_v1.png"
IDENTITY = ROOT / "prompts" / "characters" / "armk.txt"


class CharacterGenerationWorkflowTests(unittest.TestCase):
    def _fixtures(self, directory: Path) -> tuple[Path, Path]:
        marked = directory / "marked-fixture.png"
        clean = directory / "clean-fixture.png"
        source = np.asarray(Image.open(TEMPLATE).convert("RGB")).copy()
        marked_image = Image.fromarray(source)
        marked_image.save(marked)
        cyan = (source[:, :, 0] <= 40) & (source[:, :, 1] >= 220) & (source[:, :, 2] >= 220)
        source[cyan] = (255, 0, 255)
        Image.fromarray(source).save(clean)
        return marked, clean

    def _run(self, output: Path, marked: Path, clean: Path, extra_args: list[str] | None = None) -> subprocess.CompletedProcess:
        return subprocess.run(
            [
                sys.executable,
                str(WORKFLOW),
                "--template", str(TEMPLATE),
                "--character-prompt-file", str(IDENTITY),
                "--output-dir", str(output),
                "--provider", "fixture",
                "--fixture-marked", str(marked),
                "--fixture-unmarked", str(clean),
                *(extra_args or []),
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )

    def test_complete_workflow_stores_markers_before_clean_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            output = directory / "run"
            result = self._run(output, marked, clean, ["--assembly-preview"])
            self.assertEqual(result.returncode, 0, result.stderr)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertEqual(workflow["status"], "PASS")
            self.assertEqual(workflow["marker_free"]["cyan_markers_remaining"], 0)
            self.assertTrue((output / "assembly-preview/assembly-preview.png").is_file())
            self.assertEqual(
                workflow["assembly_preview"]["mode"],
                "source_proportions_no_resizing",
            )
            pivots = json.loads((output / "marked_pivots.json").read_text())
            self.assertEqual(pivots["marker_count"], 22)
            self.assertTrue((output / "marked.png").is_file())
            self.assertTrue((output / "marker-free.png").is_file())
            prompt = (output / "marked-01" / "marked-prompt.txt").read_text()
            for requirement in [
                "NOTHING MAY BE CLIPPED", "Show every part completely",
                "deliberately featureless structural diagram",
                "Every character must", "Never render an uncovered crotch or pelvis",
                "beautiful", "fluffy", "bandana",
            ]:
                self.assertIn(requirement, prompt)
            self.assertNotIn("The torso/pelvis piece includes the jeans waistband", prompt)
            for forbidden in ["upper edges begin below", "lower tips end above", "at least 12 pixels", "Fold wings", "at least 10 pixels", "Retain its anatomical silhouettes"]:
                self.assertNotIn(forbidden, prompt)

    def test_generated_marker_coordinates_are_authoritative(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            image = Image.open(marked).convert("RGB")
            draw = ImageDraw.Draw(image)
            # Move the viewer-left shoulder marker by 12 pixels while keeping
            # it on the same torso artwork and inside the same cell.
            draw.rectangle((613, 120, 641, 147), fill=(180, 180, 180))
            draw.ellipse((629, 124, 649, 144), fill=(0, 255, 255), outline=(20, 20, 20), width=2)
            image.save(marked)
            source = np.asarray(image).copy()
            cyan = (source[:, :, 0] <= 40) & (source[:, :, 1] >= 220) & (source[:, :, 2] >= 220)
            source[cyan] = (255, 0, 255)
            Image.fromarray(source).save(clean)

            output = directory / "run"
            result = self._run(
                output,
                marked,
                clean,
                [
                    "--resume-marked", str(marked),
                    "--resume-marker-free", str(clean),
                    "--skip-artwork-drift-check",
                ],
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertEqual(workflow["status"], "PASS")
            self.assertEqual(
                workflow["marked"]["marker_coordinates_source"],
                "detected from accepted marked output",
            )
            self.assertNotIn("marker_deltas_px", workflow["marked"])
            pivots = json.loads((output / "marked_pivots.json").read_text())
            torso_centers = [item["center"] for item in pivots["pivots"]["torso_and_pelvis"]]
            self.assertEqual(torso_centers[1], [639.0, 134.0])

    def test_oversized_head_is_rejected_without_resizing(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            source = np.asarray(Image.open(marked).convert("RGB")).copy()
            oversized = Image.fromarray(source)
            ImageDraw.Draw(oversized).rectangle((42, 34, 428, 500), fill=(55, 60, 68))
            # Restore all cyan markers after painting the oversized silhouette.
            cyan = (source[:, :, 0] <= 40) & (source[:, :, 1] >= 220) & (source[:, :, 2] >= 220)
            painted = np.asarray(oversized).copy()
            painted[cyan] = source[cyan]
            oversized = Image.fromarray(painted)
            oversized.save(marked)
            output = directory / "run"
            result = self._run(output, marked, clean, ["--resume-marked", str(marked)])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("artwork footprint", result.stderr)
            self.assertFalse((output / "marked_pivots.json").exists())

    def test_oversized_marker_disk_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            image = Image.open(marked).convert("RGB")
            ImageDraw.Draw(image).ellipse((190, 305, 275, 390), fill=(0, 255, 255), outline=(20, 20, 20), width=2)
            image.save(marked)
            output = directory / "run"
            result = self._run(output, marked, clean, ["--resume-marked", str(marked)])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("small marker disk", result.stderr)
            self.assertFalse((output / "marked_pivots.json").exists())

    def test_unmarked_fixture_cannot_pass_marked_stage(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            output = directory / "run"
            result = self._run(output, clean, clean)
            self.assertNotEqual(result.returncode, 0)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertEqual(workflow["status"], "FAILED")
            self.assertIn("22 cyan markers", workflow["error"])
            self.assertFalse((output / "marked_pivots.json").exists())
            self.assertFalse(list(output.glob("marker-free-*")))

    def test_clipped_marked_art_stops_before_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            image = Image.open(marked).convert("RGB")
            # The detected torso cell begins at page y=4 in this fixture.
            ImageDraw.Draw(image).rectangle((500,4,510,24),fill="black")
            image.save(marked)
            output = directory / "run"
            result = self._run(output,marked,clean)
            self.assertNotEqual(result.returncode,0)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertIn("artwork touches",workflow["error"])
            self.assertIn("crop boundary",workflow["error"])
            self.assertFalse((output / "marked_pivots.json").exists())
            self.assertFalse(list(output.glob("marker-free-*")))
            self.assertTrue((output / "marked-01" / "rejection.json").is_file())
            self.assertFalse((output / "marked-02").exists())

    def test_resumed_marked_result_is_revalidated_before_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            output = directory / "valid"
            result = self._run(output, marked, clean, ["--resume-marked", str(marked)])
            self.assertEqual(result.returncode,0,result.stderr)
            evidence = json.loads((output / "workflow.json").read_text())
            self.assertEqual(evidence["marked"]["reused_provider_result"],str(marked.resolve()))
            self.assertTrue((output / "marked_pivots.json").is_file())
            invalid = directory / "invalid"
            result = self._run(invalid,marked,clean,["--resume-marked",str(clean)])
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((invalid / "marked_pivots.json").exists())
            self.assertFalse(list(invalid.glob("marker-free-*")))

    def test_resumed_cleanup_keeps_coordinate_order_and_removal_gate(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            output = directory / "valid"
            result = self._run(output,marked,clean,["--resume-marked",str(marked),"--resume-marker-free",str(clean)])
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertTrue((output / "marked_pivots.json").exists())
            evidence = json.loads((output / "workflow.json").read_text())
            self.assertEqual(evidence["marker_free"]["reused_provider_result"],str(clean.resolve()))
            invalid = directory / "invalid"
            result = self._run(invalid,marked,clean,["--resume-marked",str(marked),"--resume-marker-free",str(marked)])
            self.assertNotEqual(result.returncode,0)
            self.assertTrue((invalid / "marked_pivots.json").exists())
            self.assertFalse((invalid / "marker-free.png").exists())

    def test_cleanup_may_repaint_outer_horizontal_frame_when_parts_remain_clear(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            source = np.asarray(Image.open(clean).convert("RGB")).copy()
            # Vertex can repaint only the decorative top and bottom frame while
            # preserving the internal separators and every safe part crop.
            for rows in (slice(0, 16), slice(source.shape[0] - 16, source.shape[0])):
                light = np.all(source[rows] >= 170, axis=2)
                source[rows][light] = (255, 0, 255)
            Image.fromarray(source).save(clean)
            output = directory / "run"
            result = self._run(
                output,
                marked,
                clean,
                ["--resume-marked", str(marked), "--resume-marker-free", str(clean),
                 "--skip-artwork-drift-check", "--layout-tolerance", "16"],
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertEqual(workflow["status"], "PASS")
            self.assertGreaterEqual(
                min(edge for part in workflow["marker_free"]["part_edge_clearances_px"].values()
                    for edge in part.values()),
                1,
            )

    def test_marked_output_may_repaint_outer_frame_when_parts_remain_clear(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            source = np.asarray(Image.open(marked).convert("RGB")).copy()
            for rows in (slice(0, 16), slice(source.shape[0] - 16, source.shape[0])):
                light = np.all(source[rows] >= 170, axis=2)
                source[rows][light] = (255, 0, 255)
            Image.fromarray(source).save(marked)
            output = directory / "run"
            result = self._run(output, marked, clean)
            self.assertEqual(result.returncode, 0, result.stderr)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertEqual(workflow["status"], "PASS")

    def test_full_import_compiles_and_audits_original_coordinates(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            output = directory / "run"
            rig = directory / "rig"
            result = self._run(output, marked, clean, ["--import-directory", str(rig), "--fighter-id", "workflow_test"])
            self.assertEqual(result.returncode, 0, result.stderr)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertTrue(workflow["import"]["compiled"])
            audit = json.loads((output / "coordinate_audit.json").read_text())
            self.assertEqual(audit["status"], "PASS")
            self.assertEqual(len(audit["points"]), 29)
            self.assertTrue((rig / "extracted_pivots.json").is_file())
            self.assertEqual(len(list(rig.glob("left_*.png"))), 5)

    def test_extra_wrist_marker_reports_its_cell_and_stops_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            image = Image.open(marked).convert("RGB")
            ImageDraw.Draw(image).ellipse((395, 610, 405, 620), fill=(0, 255, 255))
            image.save(marked)
            output = directory / "run"
            result = self._run(output, marked, clean)
            self.assertNotEqual(result.returncode, 0)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertIn('"viewer_left_forearm_and_hand": {"expected": 1, "found": 2', workflow["error"])
            self.assertFalse((output / "marked_pivots.json").exists())
            self.assertFalse(list(output.glob("marker-free-*")))

    def test_vertex_portrait_canvas_is_normalized_before_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            small_marked = directory / "marked-848x1264.png"
            small_clean = directory / "clean-848x1264.png"
            Image.open(marked).resize((848, 1264), Image.Resampling.LANCZOS).save(small_marked)
            Image.open(clean).resize((848, 1264), Image.Resampling.LANCZOS).save(small_clean)
            output = directory / "run"
            result = self._run(output, small_marked, small_clean)
            self.assertEqual(result.returncode, 0, result.stderr)
            workflow = json.loads((output / "workflow.json").read_text())
            self.assertTrue(workflow["marked"]["normalization"]["normalized"])
            self.assertEqual(workflow["marked"]["normalization"]["raw_canvas"], [848, 1264])

    def test_explicit_skip_does_not_measure_or_reject_artwork_drift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            image = Image.open(clean).convert("RGB")
            draw = ImageDraw.Draw(image)
            for left, right in [(40,240),(280,490),(535,745),(790,990)]:
                draw.rectangle((left,560,right,760), fill="yellow")
            image.save(clean)
            rejected = self._run(directory / "strict", marked, clean)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn("artwork drift", rejected.stderr)
            output = directory / "skip"
            accepted = self._run(output, marked, clean, ["--skip-artwork-drift-check"])
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            evidence = json.loads((output / "workflow.json").read_text())
            self.assertFalse(evidence["artwork_drift_check_enabled"])
            self.assertEqual(evidence["marker_free"]["artwork_drift_check"], "skipped_by_request")
            self.assertIsNone(evidence["marker_free"]["changed_ratio_outside_marker_disks"])

    def test_skip_keeps_marker_removal_check(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            result = self._run(directory / "run", marked, marked, ["--skip-artwork-drift-check"])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("cyan markers remain", result.stderr)

    def test_skip_keeps_layout_check(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked, clean = self._fixtures(directory)
            image = Image.open(clean).convert("RGB")
            ImageDraw.Draw(image).rectangle((0,598,1023,605),fill="white")
            image.save(clean)
            result = self._run(directory / "run", marked, clean, ["--skip-artwork-drift-check"])
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("layout", result.stderr)


if __name__ == "__main__":
    unittest.main()
