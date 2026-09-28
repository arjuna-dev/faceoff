# Whole-character rigs in the game

`tools/whole_character_workflow.py` turns one character image into twelve parts,
eleven pivots, optional attachments and a report (see the run's `report.html`).
`tools/export_whole_character_rig.py` publishes an accepted run as a playable
fighter rig:

    builds/rig-venv/bin/python tools/export_whole_character_rig.py \
      builds/generated/<run>/inspection/repair/repaired-analysis.json --fighter <id>

It writes `assets/fighters/rigged/<id>/` with `render_mode: "whole_character"`:

- The twelve part PNGs under the game's slot names. The game's "left" limbs are
  the screen-left ones (drawn behind, rooted at negative x when facing right),
  so the workflow's screen-left "near" limbs map to `left_*`.
- Pivots and tips in source-canvas pixels, and torso landmarks (neck,
  shoulders, hips) that root the arms, legs and head.
- `pixel_scale` so the torso (shoulders to hips) is 67.2 game units, like the
  other preserved-proportion rigs. Limbs keep their drawn proportions, so a
  short-armed character really has a shorter reach.
- When a visible upper arm is much shorter than its forearm (its top hidden in
  the torso), the shoulder pivot moves up the arm to 85% of the forearm length.
  A two-bone arm cannot fold tighter than the difference of its bones, and both
  arms must reach the same forward target (the equal-reach guardrail).
- Attachments: a back accessory rides on the torso behind every limb; a held
  item rides rigidly on the hand holding it, just behind that hand.
- `rig.json` holds the profile and contract hashes; `SkeletonRigSkin` rejects a
  stale or hand-edited profile.

To make it playable, add `data/<id>.tres` (`visual_style = "<id>"`, and
`sprite_set` if it has sprite animations), then add the id to
`FighterRoster.IDS`/`PROFILES`/`RIGGED_HEADS`, `NetworkProtocol.VALID_FIGHTERS`
and the Nakama module's `VALID_FIGHTERS`.

Checks: `tests/test_whole_character_rig.gd` (the magician loads, fights on both
sides, drags, and the staff follows its hand), `tests/test_exported_rig.gd`,
and the roster-wide reach check in `tests/test_puppet_smoke.gd`. Screenshots:
`tests/capture_magician_fight.gd` (needs a real viewport).

These rigs are candidates outside the v3 atlas review
(`tools/verify_rigged_assets.py` only checks folders with `source.json`).

Known behavior to decide on:
- A held item rotates with its forearm. That suits a sword; a staff may look
  better staying upright.
