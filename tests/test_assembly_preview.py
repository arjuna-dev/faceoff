import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

from build_assembly_preview import build_preview  # noqa: E402


class AssemblyPreviewTests(unittest.TestCase):
    def test_preview_attaches_parts_without_resizing(self) -> None:
        template = ROOT / "builds/templates/geometric_dummy_v1.png"
        template_pivots = ROOT / "builds/templates/geometric_dummy_v1.pivots.json"
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            marked = directory / "marked.png"
            marker_free = directory / "marker-free.png"
            source = np.asarray(Image.open(template).convert("RGB")).copy()
            Image.fromarray(source).save(marked)
            cyan = (source[:, :, 0] <= 40) & (source[:, :, 1] >= 220) & (source[:, :, 2] >= 220)
            source[cyan] = (255, 0, 255)
            Image.fromarray(source).save(marker_free)

            report = build_preview(
                marked,
                marker_free,
                template_pivots,
                directory / "preview",
                template,
            )

            self.assertEqual(report["mode"], "source_proportions_no_resizing")
            self.assertTrue((directory / "preview/assembly-preview.png").is_file())
            self.assertTrue((directory / "preview/assembly-preview-debug.png").is_file())
            self.assertTrue((directory / "preview/assembly-preview.json").is_file())
            self.assertEqual(set(report["metrics"]), {
                "head", "torso", "left_upper_arm", "left_forearm",
                "right_upper_arm", "right_forearm", "left_thigh",
                "right_thigh", "left_shin", "right_shin", "left_boot",
                "right_boot",
            })
            self.assertGreater(report["metrics"]["head"]["axis_length_px"], 0)
            self.assertAlmostEqual(report["torso_axis_angle_degrees_image_space"], 90.0, delta=2.0)
            written = json.loads((directory / "preview/assembly-preview.json").read_text())
            self.assertEqual(written["outputs"]["assembled"], str((directory / "preview/assembly-preview.png").resolve()))


if __name__ == "__main__":
    unittest.main()
