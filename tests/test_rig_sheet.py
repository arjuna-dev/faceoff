"""Regression coverage for the exact silent clipping failure."""
import importlib.util
import json
from pathlib import Path
import unittest
import tempfile
import sys

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"tools"))
spec = importlib.util.spec_from_file_location("build_rigged_sheet", ROOT / "tools/build_rigged_sheet.py")
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class SheetTests(unittest.TestCase):
    def setUp(self):
        self.profile = json.loads((ROOT / "assets/fighters/rigged/oculon/source.json").read_text())
        self.source = ROOT / "assets/fighters/arcade/Oculon-rig-repaired-raw.png"

    def test_complete_foreground_is_preserved(self):
        for name in ("Batyr", "Oculon"):
            source = ROOT / f"assets/fighters/arcade/{name}-rig-repaired-raw.png"
            profile = json.loads((ROOT / f"assets/fighters/rigged/{name.lower()}/source.json").read_text())
            sheet, slots = builder.prepare(source, profile)
            self.assertEqual(int(builder.foreground(np.array(Image.open(source).convert('RGBA'))).sum()), sum(s['pixels']+s['excluded_duplicate_bust_pixels'] for s in slots.values()))
            normalized, compiled = builder.compile_sheet(source, profile)
            np.testing.assert_array_equal(normalized, np.array(Image.open(ROOT / f"assets/fighters/arcade/{name}.png")))
            self.assertEqual(compiled, json.loads((ROOT/f"assets/fighters/rigged/{name.lower()}/profile.json").read_text()))
            self.assertGreaterEqual(min(s['margin'] for s in slots.values()), 4)

    def test_old_knuckle_cut_is_rejected(self):
        self.profile['parts']['left_forearm']['rect'][3] = 704
        with self.assertRaisesRegex(ValueError, 'crop boundary'):
            builder.prepare(self.source, self.profile)

    def test_toe_cut_is_rejected(self):
        self.profile['parts']['left_boot']['rect'][2] = 480
        with self.assertRaisesRegex(ValueError, 'crop boundary'):
            builder.prepare(self.source, self.profile)

    def test_overlapping_rectangles_are_rejected(self):
        self.profile['parts']['left_forearm']['rect'][0] = 240
        with self.assertRaisesRegex(ValueError, 'overlapping'):
            builder.prepare(self.source, self.profile)

    def test_unassigned_foreground_is_rejected(self):
        del self.profile['parts']['head']
        with self.assertRaisesRegex(ValueError, 'twelve named'):
            builder.prepare(self.source, self.profile)

    def test_joint_in_transparent_space_is_rejected(self):
        # Old right elbow was numerically in its cell, but outside the artwork.
        self.profile['parts']['right_upper_arm']['tip'] = [978,672]
        with self.assertRaisesRegex(ValueError, 'opaque joint coverage'):
            builder.prepare(self.source,self.profile)

    def test_backward_boot_is_rejected(self):
        rgba = np.array(Image.open(self.source).convert('RGBA'))
        part = self.profile['parts']['left_boot']
        x0,y0,x1,y1 = part['rect']
        rgba[y0:y1,x0:x1] = rgba[y0:y1,x0:x1][:,::-1]
        for field in ('pivot','tip'):
            part[field][0] = x0+x1-1-part[field][0]
        with self.assertRaisesRegex(ValueError,'toe must extend'):
            builder.prepare(rgba,self.profile)

    def test_failed_build_preserves_previous_assets(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            previous = directory/'rig.json'
            previous.write_text('previous working rig')
            self.profile['parts']['left_forearm']['rect'][3] = 704
            binding = directory/'source.json'
            binding.write_text(json.dumps(self.profile))
            with self.assertRaises(ValueError):
                builder.publish(self.source,binding,directory,directory/'sheet.png')
            self.assertEqual(previous.read_text(),'previous working rig')
            self.assertFalse((directory/'sheet.png').exists())

    def test_shared_slots_and_landmarks(self):
        profiles = [json.loads((ROOT/f'assets/fighters/rigged/{name}/profile.json').read_text()) for name in ('batyr','oculon')]
        for name,slot in builder.contract()['slots'].items():
            for profile in profiles:
                for field in ('rect','pivot','tip'):
                    self.assertEqual(profile['parts'][name][field],slot[field])

    def test_five_templates_preserve_joint_coordinates(self):
        shapes = builder.contract()['body_types']
        self.assertEqual(len(shapes),5)
        # Different per-region proportions, not a uniform horizontal scale.
        self.assertNotEqual(shapes['small']['head']/shapes['heavy']['head'], shapes['small']['torso']/shapes['heavy']['torso'])
        for name in shapes:
            path = ROOT/f'assets/fighters/rigged/templates/{name}.json'
            profile = json.loads(path.read_text())
            self.assertEqual(profile['body_type'],name)
            for part,slot in builder.contract()['slots'].items():
                self.assertEqual(profile['parts'][part]['pivot'],slot['pivot'])

    def test_stale_texture_is_rejected(self):
        import verify_rigged_assets as validator
        from unittest.mock import patch
        original = validator.digest
        changed_texture = (ROOT/'assets/fighters/rigged/oculon/right_forearm.png').read_bytes()
        # Simulates an interrupted build with one texture from another revision.
        with patch.object(validator,'digest',side_effect=lambda data: 'stale' if data == changed_texture else original(data)):
            with self.assertRaisesRegex(ValueError,'right_forearm texture'):
                validator.verify(ROOT/'assets/fighters/rigged/oculon')

    def test_enclosed_magenta_costume_is_not_erased(self):
        rgba = np.full((20,20,4), [255,0,255,255], dtype=np.uint8)
        rgba[4:16,4:16] = [10,10,10,255]
        rgba[8:12,8:12] = [255,0,255,255]
        mask = builder.foreground(rgba)
        self.assertTrue(mask[8:12,8:12].all())
        self.assertFalse(mask[0].any())

    def test_preserved_sheet_keeps_every_source_pixel_and_landmark(self):
        binding = json.loads((ROOT/'assets/fighters/rigged/armk/source.json').read_text())
        source = ROOT/binding['source']
        binding['render_mode'] = 'preserve_proportions'
        binding['pixel_scale'] = 0.25
        original, _ = builder.prepare(source, binding)
        sheet, compiled = builder.compile_sheet(source, binding)
        np.testing.assert_array_equal(sheet, original)
        for name, part in binding['parts'].items():
            for field in ('rect', 'pivot', 'tip', 'neck', 'shoulders', 'hips'):
                if field in part:
                    self.assertEqual(compiled['parts'][name][field], part[field])
        self.assertEqual(compiled['pixel_scale'], 0.25)

    def test_preserved_one_pixel_clearance_is_accepted_without_erasing_pixels(self):
        binding = json.loads((ROOT/'assets/fighters/rigged/armk/source.json').read_text())
        rgba = np.array(Image.open(ROOT/binding['source']).convert('RGBA'))
        x0,y0,_,_ = binding['parts']['head']['rect']
        rgba[y0+1,x0+1] = [200,100,50,255]
        prepared, parts = builder.prepare(rgba,binding)
        self.assertEqual(parts['head']['margin'],1)
        np.testing.assert_array_equal(prepared[y0+1,x0+1], rgba[y0+1,x0+1])

    def test_zero_clearance_reports_offending_edge_and_page_pixel(self):
        binding = json.loads((ROOT/'assets/fighters/rigged/armk/source.json').read_text())
        rgba = np.array(Image.open(ROOT/binding['source']).convert('RGBA'))
        x0,y0,_,_ = binding['parts']['head']['rect']
        rgba[y0+1,x0] = [200,100,50,255]
        with self.assertRaisesRegex(ValueError, r"need 1px.*'left': 0.*page \["+str(x0)+", "+str(y0+1)+r"\]"):
            builder.prepare(rgba,binding)


if __name__ == '__main__':
    unittest.main()
