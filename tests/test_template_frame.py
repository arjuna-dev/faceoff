import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"tools"))
from add_template_frame import frame_image, run


class TemplateFrameTests(unittest.TestCase):
    def test_source_pixels_and_proportions_share_one_uniform_transform(self):
        image = Image.open(ROOT/"builds/manual_oculon/oculon_template_boot_split_78.png").convert("RGB")
        framed,offset = frame_image(image)
        self.assertEqual(framed.size,image.size)
        expected = image.transform(image.size,Image.Transform.AFFINE,
                                   (1/.99,0,-offset[0]/.99,0,1/.99,-offset[1]/.99),
                                   resample=Image.Resampling.NEAREST,fillcolor="white")
        np.testing.assert_array_equal(np.asarray(framed),np.asarray(expected))
        self.assertTrue(np.all(np.asarray(framed)[:7]==255))
        self.assertTrue(np.all(np.asarray(framed)[-7:]==255))

    def test_new_extraction_retains_all_22_markers_and_original_is_unchanged(self):
        source=ROOT/"builds/manual_oculon/oculon_template_boot_split_78.png"
        original=source.read_bytes()
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)/"framed.png"
            result=run(source,output,.99)
            self.assertEqual(result["marker_count"],22)
            self.assertEqual(json.loads(output.with_suffix(".pivots.json").read_text())["marker_count"],22)
            self.assertEqual(source.read_bytes(),original)
            with self.assertRaisesRegex(ValueError,"not overwritten"):
                run(source,output,.99)


if __name__ == "__main__":
    unittest.main()
