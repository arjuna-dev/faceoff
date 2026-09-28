# Sprite animations

Fighters are cut-out rigs the player poses by dragging limbs. On top of that, a
fighter can own a set of hand-drawn-looking sprite animations (charge, hit
stun, jump, ...). When something triggers one:

1. the fighter resets to its rest pose,
2. the rig is hidden and the sprite animation plays exactly where the rest pose stands,
3. the rig reappears in the rest pose, ready for the player again.

This only works if every animation starts from and lands in the rig's rest
pose. The workflow below guarantees the alignment in code and asks the image
model for it in the prompt.

## Making animations: `tools/sprite_animation_workflow.py`

The workflow wraps the vendored game-sprite-pipeline
(`tools/sprites/vexjoy/`, MIT, see its `SKILL.md`, `LICENSE.vexjoy` and
`UPSTREAM_COMMIT`). All paths end in the same export step.

Generate states with Vertex (one image call per state, identity-locked to the base image):

    builds/rig-venv/bin/python tools/sprite_animation_workflow.py generate \
      --fighter magician --description-file prompts/characters/magician.txt \
      --states prompts/sprites/fighter_states.json --only charge jump \
      --output-dir builds/sprites/magician_<date>

- `--base-image` defaults to `assets/fighters/<fighter>/base.png`, the same image the rig is built from.
- Each state's action text gets a landing rule appended: the first and last frame show the reference standing pose.
- The vendored pipeline does chroma keying, slicing, shared-scale anchoring and QA. Its outputs stay in `--output-dir` (`qa/contact_sheet.png`, `row_NN_<state>/row_prompt.txt`, raw grids).
- Exit code 2 from the pipeline means a verifier gate failed; frames are still exported, so inspect them.

Import a grid made elsewhere, for example in ChatGPT:

    builds/rig-venv/bin/python tools/sprite_animation_workflow.py import-grid \
      --fighter magician --input charge.png --grid 3x2 --frames 6 --state charge \
      --timing 150,150,150,150,150,260 --source chatgpt --output-dir builds/sprites/magician_import

Import frames that are already keyed (one PNG per frame, sorted by name):

    builds/rig-venv/bin/python tools/sprite_animation_workflow.py import-frames \
      --fighter magician --state jump --frames-dir <dir> --timing 140,140,140,140,280 --source gemini-3-pro-image

Write the review page:

    builds/rig-venv/bin/python tools/sprite_animation_workflow.py report --fighter magician [--run-dir <generate output>]

### ChatGPT prompt template

Attach the base image and fill in the blanks:

    Using the attached character as an exact reference, create a sprite sheet of a <STATE> animation
    for a 2D fighting game, in the same pixel-art style.
    Layout: one image, a <C>x<R> grid of equal square cells, <N> frames in reading order
    (left to right, top to bottom). Unused cells stay empty.
    Frames: 1 ... 2 ... (one concrete pose per frame; exaggerate key poses).
    The first and the last frame show the character in exactly the reference standing pose.
    Rules: same character in every frame (identical proportions, outfit, props, colours). Faces right
    in every frame. Always holds <prop> in the same hand as in the reference. Same size every frame,
    feet on the same ground line (except airborne frames). Everything, including effects, fits inside
    each cell with a margin. Solid flat magenta (#FF00FF) background, no grid lines, numbers, text or shadows.

## Export format

`assets/fighters/<fighter>/sprites/`:

- `index.json`: `base_canvas`, `base_bbox` (the base character's box; its bottom is the ground line), and one entry per animation with `frames`, `durations_ms`, `origin` and `frame_size`. All coordinates are base-image pixels.
- `<state>/frame_NN.png`: every frame of a state shares one crop, so `origin` is the same for all of them.
- `<state>/preview.gif` and `report.html` are for review only.

Alignment, done in code so it does not depend on the model:
- Frames are scaled so the character's pixel mass matches the base image, with nearest-neighbour to keep the pixel art sharp.
- Frame 1's feet and horizontal center are pinned to the base image's. Every frame shares that offset, so airborne frames stay airborne.
- Thin, long line fragments left by a generator's layout grid are removed.

## In the game

- `CharacterProfile.sprite_set` names the folder under `res://assets/fighters/`. Empty means the fighter has no animations of its own.
- `scripts/characters/sprite_animation_player.gd` (`SpriteAnimationPlayer`) plays one animation at a fighter's feet. It scales the base character to the fighter's rest height and mirrors for left-facing fighters.
- `scripts/main.gd`: the arena's bottom bar has an **ACTION!** button. It fans out one button per animation; choosing one runs the reset, play, land sequence above. The rig's input and combat are disabled while the sprite plays. REMATCH or leaving the arena cancels a running animation.
- `export_presets.cfg` includes `assets/fighters/*/sprites/index.json`.
- Tests: `tests/test_sprite_actions.gd` (in CI). Screenshots: `tests/capture_sprite_actions.gd` (needs a real viewport).

Current limitations:
- The magician is not a playable fighter yet. Until then `DEMO_SPRITE_SET` in `main.gd` lends the magician's animations to any fighter without its own set, so the flow can be tried in any fight.
- Animations are local only. The remote player keeps seeing the rig in its rest pose. Syncing them would mean adding an `action` field to `RagdollCharacter.get_network_state()`.

## Magician animations in the project

| state | frames | source |
|---|---|---|
| charge | 6 | ChatGPT grid (the user rated it best for the aura build-up) |
| hit-stun | 8 | ChatGPT grid |
| jump | 5 | gemini-3-pro-image row from the vendored pipeline |

Findings from the pipeline's magician test (see `tools/sprites/vexjoy/SKILL.md`):
- gemini-3-pro-image gives lively motion but can swap the prop hand between frames.
- gemini-3.1-flash-image keeps identity better but moves too little.
- Mixing sources per state is fine.
