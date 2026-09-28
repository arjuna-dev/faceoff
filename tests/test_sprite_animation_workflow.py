import json
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))

import sprite_animation_workflow as workflow  # noqa: E402


class SpriteAnimationWorkflowTests(unittest.TestCase):
    def test_frames_land_on_the_base_pose_and_share_one_origin(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)
            workflow.fighter_dir = lambda fighter: folder / fighter
            base = np.full((400, 300, 3), (255, 0, 255), dtype=np.uint8)
            base[100:380, 120:180] = (40, 90, 160)  # a 60x280 standing figure, feet at y=379
            base_path = folder / "base.png"
            Image.fromarray(base).save(base_path)
            frames = []
            for lift in (0, 20, 0):  # a small hop in the middle frame, at half the base scale
                frame = Image.new("RGBA", (100, 200), (0, 0, 0, 0))
                frame.paste((40, 90, 160, 255), (35, 50 - lift, 65, 190 - lift))
                frame.paste((200, 200, 200, 255), (0, 199, 100, 200))  # layout guide line
                frames.append(frame)
            entry = workflow.export_state(frames, [100, 100, 200], base_path, "hero", "hop", "test")
            self.assertAlmostEqual(entry["scale_from_source"], 2.0, places=2)
            index = json.loads((folder / "hero/sprites/index.json").read_text())
            self.assertEqual(index["base_bbox"], [120, 100, 180, 380])
            first = np.asarray(Image.open(folder / "hero/sprites" / entry["frames"][0]))[:, :, 3] > 0
            ys, xs = np.nonzero(first)
            ox, oy = entry["origin"]
            self.assertEqual(int(ys.max()) + oy, 379)  # feet on the base ground line
            self.assertAlmostEqual(float(xs.mean()) + ox, 149.5, delta=1.0)
            middle = np.asarray(Image.open(folder / "hero/sprites" / entry["frames"][1]))[:, :, 3] > 0
            self.assertEqual(int(np.nonzero(middle)[0].max()) + oy, 379 - 40)  # airborne frame stays airborne
            self.assertEqual(entry["frame_size"][0], 60)  # guide line removed from the shared crop
            self.assertEqual(entry["durations_ms"], [100, 100, 200])


if __name__ == "__main__":
    unittest.main()
