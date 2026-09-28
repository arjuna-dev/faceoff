---
name: game-sprite-pipeline
description: Use when generating animated game sprite sheets with AI. Per-row fighter/RPG strips via Vertex Gemini, plus importing ChatGPT grids.
---
# Game sprite pipeline (vexjoy-agent port + Vertex backend)

Turns one character image into animated sprite rows (idle, dash, jump, hit-stun, ...):
per-row generation with an identity lock, magenta chroma-key, shared-scale anchoring,
QA contact sheet + per-state GIFs.

Upstream: notque/vexjoy-agent skills/game/game-dev (MIT, see LICENSE.vexjoy, UPSTREAM_COMMIT).
Deep docs: references/game-sprite-pipeline.md (phases, presets, verifier gates, bg removal).

## Setup (once)

    cd ~/.hermes/skills/creative/game-sprite-pipeline
    uv venv .venv && uv pip install --python .venv/bin/python pillow numpy pytest
    (cd scripts && ../.venv/bin/python -m pytest -q)     # expect 126 passed

Vertex needs `gcloud auth login` + a project with the Gemini image models enabled.

## 1. Generate a full row set on Vertex

    cd ~/.hermes/skills/creative/game-sprite-pipeline/scripts
    SPRITE_BACKEND=vertex VERTEX_IMAGE_MODEL=gemini-3-pro-image \
    ../.venv/bin/python sprite_pipeline.py --per-row --preset fighter \
      --base-image BASE.png --description "<full visual description, facing right>" \
      --style arcade-cps2 --name hero --cell-size 256 --qa-artifacts --output-dir OUT

- `--preset fighter` = idle 6, dash-right 8, dash-left 8, taunt 4, jump 5, hit-stun 8, charge 6, rush 6, special 6 (57).
  Others: rpg-character, platformer, pet; or `--preset custom --states rows.json` with
  `[{"state","frames","action","timing"?}]`.
- `--base-image` is used verbatim as the identity lock. Best input: pixel-art character already on flat magenta #FF00FF.
- Match `--style` to the base art (styles in scripts/sprite_prompt.py STYLE_PRESETS).
- Runs ~10 min for 57 frames. Launch in the background; two models can run in parallel.
- Exit 2 = a verifier gate failed; files are still written. Read the failures JSON at the end of the log (often just `verify_padding`).

Outputs: OUT/qa/contact_sheet.png, OUT/qa/previews/<state>.gif, OUT/out/<name>_sheet.png,
OUT/row_NN_<state>/frames_nobg/*.png. Always inspect the contact sheet and GIFs visually before judging.

## 2. Import grids made in ChatGPT (or any tool)

Some states come out better in ChatGPT. Give the user a copy-paste prompt (template below),
then import what they save:

    ../.venv/bin/python import_external_grid.py --input charge.png --grid 3x2 --frames 6 \
      --state charge --name hero --output-dir OUT/external --timing 150,150,150,150,150,260 \
      --compare-row OUT/row_06_charge --compare-label "Gemini 3 Pro" --label ChatGPT

Writes frames/, a strip, a GIF and a side-by-side `<name>_<state>_compare.png`.

ChatGPT prompt template (user attaches BASE.png):

    Using the attached character as an exact reference, create a sprite sheet of a <STATE> animation
    for a 2D fighting game, in the same <style> pixel-art style.
    Layout: one image, a <C>x<R> grid of equal square cells, <N> frames in reading order
    (left to right, top to bottom). <Unused cells stay empty.>
    Frames: 1 ... 2 ... (one concrete pose per frame; exaggerate key poses).
    Rules: same character in every frame (identical proportions, outfit, props, colours). Faces right
    in every frame. Always holds <prop> in the same hand as in the reference. Same size every frame,
    feet on the same ground line (except airborne frames). Everything, including effects, fits inside
    each cell with a margin. Solid flat magenta (#FF00FF) background, no grid lines, numbers, text or shadows.

## Local changes vs upstream

- scripts/sprite_generate.py: `vertex` backend (gcloud token, `VERTEX_IMAGE_MODEL`, `VERTEX_LOCATION`
  default global, `VERTEX_PROJECT`), `SPRITE_BACKEND` override, 429/5xx retry (`VERTEX_MAX_ATTEMPTS`).
  Strips are requested as a near-square grid and repacked to N x 1 because Gemini caps aspect at 21:9.
- scripts/sprite_pipeline.py: `--base-image`, `--states`. scripts/sprite_prompt.py: `--preset custom`.
- scripts/import_external_grid.py: new.

## Findings (magician test, Sep 2026)

- Available models: `gemini-3-pro-image` and `gemini-3.1-flash-image` on global only; `-preview` names and us-central1 return 404. 2.5-flash-image works but is older; skip it.
- gemini-3-pro-image: lively motion (real jump tuck, dashes, fireball), but it swaps the prop hand between frames and malforms big projectile VFX. Default choice.
- gemini-3.1-flash-image: better identity consistency, but most states are near-idle (the jump isn't a jump). Not recommended.
- ChatGPT, fed the same base: the user rated it best for charge (aura build-up) and worse than Pro for jump and hit-stun. Mixing sources per state is fine.
- Neither Gemini model mirrors dash-left (both face right); consider mirroring dash-right.
- Large effects (special beams, peak auras) cross cell edges and get clipped or bleed into neighbours; ask for effects to stay tight to the body.
- Faint grid lines from the layout guide can survive into Pro frames.
