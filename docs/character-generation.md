# Character generation and rigging

## Whole-character candidate workflow

The one-script entry point for the newer complete-fighter experiment is
`tools/whole_character_workflow.py`. To pause after extraction, assembly and
five pose previews, run:

```sh
python3 tools/whole_character_workflow.py \
  --character-prompt-file prompts/characters/armk_whole.txt \
  --output-dir builds/generated/armk_whole_trial \
  --stop-after poses
```

Use `--stop-after review` for one additional Vertex text-model call that
receives the original figure, a labeled twelve-part sheet on green, and the
saved original creation prompt. Its structured `broken_parts` verdict and
short visual reasons per flagged part are written to
`inspection/part-review/review.json`.
`--stop-after repair` makes two Vertex image calls for each flagged part. The
first receives the centered part on exact `#00FF00` green and the original
character and paints only irregular missing-art shapes `#FF00FF` magenta. Each
part has a predefined ownership prompt, such as torso/pelvis/wings with no
arms or head. The script extracts this shape mask and applies it to the exact
original centered part, preserving every other pixel even if the model redraws
its raw response. The second call receives this exact magenta-marked image,
the original character and the saved character creation prompt, and fills
only magenta. A failed mask gate stops the run before the second call.
The reusable stage prompts live in `prompts/workflows/`. Provider output must
have the same canvas dimensions; it is applied only inside the magenta mask, so
the source PNG and every other part remain unchanged. Raw provider images,
prompts, masks, repaired parts and repaired pose previews remain under
`inspection/repair/`. The default `--stop-after godot` also writes an editable
native `Skeleton2D` candidate scene from the repaired parts. Repair and scene
outputs still require human review and do not promote the fighter into the
production v3 rig.

The script makes one Vertex request for the complete figure and one request
with that figure attached for a flat twelve-color segmentation map. It uses
`#FF00FF` for the background and `#00FFFF` for joints. Eleven physical joint
locations in the assembled figure map to 22 part-specific pivot references.
The script detects the source image's actual magenta tone at the canvas edge,
removes connected and enclosed background pixels, extracts original colored
pixels under each segmentation region, and saves crops with their original page
origins and crop-local pivot coordinates. `inspection/reconstructed.png` is the
same parts composited at their original page coordinates with no scaling.
`inspection/inspection.png` compares the unmodified original PNG, reconstruction
on gray, and missing or extra mask pixels. Red appears only in the mismatch
panel; the original may already contain magenta-tinted edge pixels.
`inspection/analysis.json` records clipping, palette deviations, joint
placement and silhouette disagreement. The workflow also saves five unscaled,
rigid articulation previews and joint overlays in `inspection/poses/`, plus
`inspection/poses/pose-sheet.png` for side-by-side review. These show pivot
alignment and reveal missing artwork when a limb moves; they cannot reconstruct
pixels that were hidden in the original complete figure. If the model adds a
small number of extra cyan markers, the closest eleven anatomical matches may
still generate diagnostic poses, but the extra markers remain a review failure.
A review failure keeps
these artifacts but cannot be treated as an accepted rig. `--resume-character`,
`--resume-segmentation`, and `--resume-review` reprocess selected saved results
in a new output directory without repeating the corresponding provider calls.
`--resume-from builds/generated/previous_run` is shorthand for all available
saved stages; it still requires a fresh `--output-dir` so the reviewed run is
not overwritten. Resumed runs copy the previous character-creation prompt when
available, so repair context matches the art that was actually generated.

This is a candidate workflow under visual review. The atlas workflow below is
retained for existing fighters and older candidates while the whole-character
method is evaluated.

The current format is **one character, twelve separate parts, 1024x1536**.
Batyr and Oculon use this format through Godot's `Skeleton2D` and `Bone2D`.
Kiro and Jade retain their previous artwork and renderer until their replacement
art has passed the same checks. Adding a new character must not change the solver.

New imports use `render_mode: "preserve_proportions"`. Their source rectangles,
markers, and pixel dimensions are authoritative. Compilation slices the original
RGBA pixels without resampling or fitting individual widths into a body template.
One `pixel_scale` converts the complete character into game units. The runtime
uses source-derived bone lengths, rigid rotations and translations, and that same
uniform scale for every sprite in every pose. Body-type selections do not reshape
these assets. `init` and `rig_atlas_import.py` both accept `--pixel-scale` to adjust
the complete character's size together.

Armk uses this preserved format. The canonical normalization and body-type width
fitting described below are retained only for the earlier Batyr/Oculon assets.
Do not route new marked-atlas imports through those legacy affine transforms.

## Existing atlas generation workflow

The atlas generation entry point is
`tools/character_generation_workflow.py`. Vertex Gemini through the local
`gcloud` login is its default provider, using `gemini-3-pro-image` unless
`--model` overrides it. The script owns the complete state machine and writes
the provider result and validation evidence under its output directory. Do not
generate a character manually and then start at import.

```sh
python3 tools/character_generation_workflow.py \
  --template builds/templates/geometric_dummy_v1.png \
  --character-prompt-file prompts/characters/armk.txt \
  --output-dir builds/generated/angel
```

It validates the marked template, generates and validates a marked character,
measures and stores the accepted output's marker coordinates in
`marked_pivots.json`, generates the marker-free image from the accepted
marked image, and validates that cleanup did not change the cell layout or
artwork outside the marker disks. Any failed stage is a hard stop. When
`--import-directory` and `--fighter-id` are supplied, the script then imports the
accepted pair, compiles all twelve textures, and audits the complete coordinate
chain automatically. The image gates must pass before these stages run.
The marked and cleanup gates run the compiler's border-connected chroma
segmentation inside every detected cell and reject artwork with less than one
pixel of clearance. The marked gate also rejects an extreme head footprint that
fills the cell, but never resizes it. Clipped art is a hard failure before
coordinates are stored or a cleanup request is spent. The workflow never sends
a failed image back to the provider for automatic correction; inspect the
rejection, adjust the input prompt or source decision explicitly, and start a
new run with a new output directory.
If Vertex returns its portrait-sized 848x1264 response, the workflow records
the raw image and applies one global nearest-neighbor normalization to
1024x1536 before validation; it never independently resizes body parts.
The `fixture` provider and `--dry-run` are for tests and planning; `vertex` is
the default.

For a visual source-proportion check, add `--assembly-preview`:

```sh
python3 tools/character_generation_workflow.py \
  --template builds/templates/geometric_dummy_v1.png \
  --character-prompt-file prompts/characters/armk.txt \
  --output-dir builds/generated/armk_review \
  --assembly-preview
```

After the marked and marker-free stages pass, this writes
`assembly-preview/assembly-preview.png`, a transparent assembled figure,
`assembly-preview-debug.png`, the same figure with measured axes and joints,
and `assembly-preview.json`, which reports each part's foreground bounds,
source axis, torso ratios, and ratios against the geometric template. It only
translates crops so the measured joints meet. It does not resize, rotate,
stretch, squash, crop, or otherwise repair any part. The default comparison
template is the unlabelled `builds/templates/geometric_dummy_v1.png`; use
`--assembly-reference-template` to override it.

This preview is the first proportion gate before Godot. It separates three
questions that were previously easy to conflate: whether the generated part
is too large in its cell, whether the measured joints attach it to the right
neighbor, and whether the torso axis has the intended upright Street Fighter
style posture. The preview preserves the accepted torso axis and reports its
angle; it does not silently impose a new pose.

The current generation guide is `builds/templates/geometric_dummy_v1.png`. It is
built deterministically by `tools/build_geometric_rig_template.py` from the
standard cell layout and 22 coordinates. No previous character artwork is copied.
It contains only flat geometric placeholders: light gray upper-body ownership,
a second gray lower-torso and leg-garment ownership chain, and dark gray footwear.
These colors and silhouettes are semantic guides, not anatomy or character traits.
Its `.pivots.json` is freshly extracted from the generated PNG and its `.build.json`
records provenance. The older Oculon and anatomical mannequin templates are
historical and must not be used for new characters.
The gutter detector follows complete outer-border bands of any thickness.
It accepts compressed neutral near-white rules with all RGB channels at least 170,
plus pale-magenta white rules with red and blue at least 240 and green at least
120, while still requiring continuous gutter coverage and the exact 2/4/2/4 layout.

Use `--resume-marked PATH` to reuse a saved marked provider output after a
validation implementation fix. The script normalizes and revalidates that image
against the current template before recording coordinates or requesting cleanup.
Evidence identifies the reused input; no marked-image gate is skipped. Keep the
original failed run and use a new output directory for the resumed run.
`--resume-marker-free PATH` similarly revalidates saved cleanup output, only
after the marked image has passed and its measured coordinates are stored.
Compressed rules may have only one near-white core scanline in either direction.

For an explicitly requested experimental run, `--skip-artwork-drift-check`
disables only the cleanup pixel-change measurement and rejection. Evidence records
`artwork_drift_check: "skipped_by_request"`; no pixel-change ratio is calculated.
Canvas, cell layout, marker removal, original coordinate references, compiler and
Godot checks remain enabled. This flag is not the default and does not replace
visual review or prove that cleanup preserved the anatomy beneath the saved points.

Every preserved rig carries the accepted marked image's `extracted_pivots.json`
and a `coordinate_contract` in its source and compiled profiles. Its 22 extracted
points are measured from that accepted image and become the authoritative page
coordinates for that character. The seven calculated
points are the two torso midpoints and the head, forearm and foot axis tips.
Crop-local coordinates subtract only the part rectangle's top-left position.
Different gutter bounds never cause a per-cell coordinate translation or scale.
Left/right shoulder and hip roles are ordered by horizontal position within
their anatomical pair, even when the two markers differ slightly in height.
The compiler, export checker, and Godot reject missing or mismatched references.

Audit an existing candidate independently:

```sh
python3 tools/audit_rig_coordinates.py --directory builds/fighters/new_fighter \
  --output builds/fighters/new_fighter/coordinate_audit.json
```

Godot checks all 29 rendered points against their referenced coordinates and
connected joints, plus the native skeleton rest links and axes. The world-space
comparison permits 0.001 game units for floating-point precision, while stored
page and crop-local coordinates must match exactly. Preserved head axes follow
the measured source axis relative to the torso, including the requested pose
rotation; they are not replaced with a hard-coded vertical vector.

## What is shared

`assets/fighters/rigged/contract.json` defines the named cells, joint coordinates,
bone hierarchy, reference pose, and five sets of body proportions. Both compiled
character sheets have exactly the same cells and attachment coordinates, including
the bottom row: left shin, left boot, right shin, right boot.

The five templates are small, lean, standard, broad and heavy. They vary the head,
chest, arms, thighs, calves and boots separately. Combat height and arm segment
lengths stay the same. These are proportion guides for generation, not five new
hand-painted character designs. The sample guide art comes from Oculon.

The game computes the pose. Bones use game distances and local parent/child
transforms, with an assembled reference pose. Only image attachments convert from
source pixels to game distances. Consequently, source image resolution and packing
cannot change a bone's length or another part's scale. Width is independent of
length, so a crouch does not also make the chest narrow.

For marked-atlas imports, each arm root is the corresponding extracted torso
shoulder marker transformed with the torso sprite's rotation and shared pixel
scale. The native skeleton rest pose uses the same landmarks and source segment
lengths. No coverage search moves these authored shoulder roots.
Both arms use a shared torso-centered combat target circle. Forearm held targets
and pointer controls use that center, while the elbow solver starts at each
distinct anatomical shoulder. Its radius fits within both arms' native lengths,
up to the game's 97-unit limit, preserving equal forward reach without stretching
artwork. Older normalized assets retain their established shoulder offsets.
Feet draw under shins, shins under thighs, and both legs draw over the torso in
every pose. The rear arm stays behind the torso and the front arm stays in front.
The neck and hips follow the chest during crouching and leaning. Shin and boot
share one cuff point; planted soles stay level, and raised feet turn with the leg.
The head's combat target follows the visible head.

## Generation prompt inputs

The identity prompt file describes only the character and art direction. It must
not contain stage instructions about adding or removing markers. The executable
workflow adds those instructions separately for the marked and marker-free calls.
The marked stage requires exactly 22 cyan markers in the correct cells and
semantic roles, but does not reject a valid joint merely because its generated
pixel coordinate differs from the geometric template. The detected output
coordinate is stored and passed through the rig. The template coordinates remain
visible in the attached guide image as placement and proportion guidance; they
are not a second source of truth or a post-generation rejection check. Marker
disks must remain small and the grid must remain intact.
The old `tools/rig_generation_prompt.py` is a legacy binding/template helper; it
is not a generation entry point and must not be used to bypass the workflow.

Reusable character prompts are stored in `prompts/characters/`. The current angel
prompt is `prompts/characters/armk.txt`; prompts in `builds/` describe historical
runs. The shared stage prompt requires complete silhouettes with no clipping and
background clearance, without prescribing wing upper/lower edges or folding.
Template joint coordinates and segment lengths are structural constraints;
sample clothing silhouettes and folds are not. Preserved rigs require at least one
pixel of source-art clearance; the older normalized rigs retain their four-pixel
requirement. Error messages report clearance per edge and an offending foreground
pixel in page coordinates. Zero-clearance art is still rejected, even if the other
three edges have generous clearance. Importer seam padding retains its four-pixel
margin and does not move measured coordinates.

Regenerate the five guides after changing the contract or sample:

```sh
python3 tools/rig_generation_prompt.py assets/fighters/rigged/oculon/profile.json \
  --reference assets/fighters/arcade/Oculon.png \
  --templates assets/fighters/rigged/templates
```

## Compile and review a candidate

Install the offline compiler dependencies in a Python environment:

```sh
python3 -m pip install -r tools/requirements-rig.txt
```

Generate, import, compile, and audit a new candidate in one invocation:

```sh
python3 tools/character_generation_workflow.py \
  --template builds/templates/geometric_dummy_v1.png \
  --character-prompt-file prompts/characters/armk.txt \
  --output-dir builds/generated/new_fighter \
  --import-directory builds/fighters/new_fighter --fighter-id new_fighter
```

Rebuild an already imported candidate after a deliberate source revision:

```sh
python3 tools/rig_workflow.py build builds/fighters/new_fighter
```

`source.json` records the source rectangles and exact extracted/calculated joint
centers. `init` also requires the original marker JSON and matching marked image;
it no longer supplies default coordinates. When validation fails, inspect the
raw images and mapping, then fix the implementation or regenerate the artwork.
Do not move measured points or shrink a crop through a hand or shoe to make a test
pass. A changed marked source requires a fresh extraction and coordinate contract.

The compiler produces `profile.json`, twelve textures, a canonical `sheet.png`, and
`rig.json` containing hashes and pixel accounting. It first validates the complete
candidate, stages its output, and writes the manifest last. A rejected candidate
does not overwrite working assets. An interrupted publication is detected by the
hash checks. Preserved imports slice the prepared source pixels unchanged.
Only the older normalized assets use deliberate rotation/resampling. No foreground
is silently cropped.

Run checks and captures with the same Godot editor used for shipping:

```sh
export GODOT_BIN=/Applications/Godot-4.5.2.app/Contents/MacOS/Godot
"$GODOT_BIN" --headless --path . --editor --import
python3 tools/rig_workflow.py test --directory builds/fighters/new_fighter \
  --output-dir builds/fighters/new_fighter/review
python3 tools/rig_workflow.py capture --directory builds/fighters/new_fighter \
  --output-dir builds/fighters/new_fighter/review
```

Captures require a real graphics renderer. On a Linux worker, use a graphics
session such as `xvfb-run`; a headless dummy viewport is not visual evidence.
The candidate is loaded directly by the production renderer without adding its
name to game code or replacing either production fighter.

Inspect `poses.png`, `body-types.png`, and individual pose captures. Reject gaps,
wrong proportions, cropped extremities, inverted feet, duplicate body regions,
or costume pieces that look disconnected. The thirteen poses include both punches,
walking, two kicks, crouching, both torso leans, jumping, hopping, falling and
getting up. Numeric coverage tests exercise all five builds in both directions.
`shoulder-diagnostics.png` overlays a cyan ring at each transformed torso shoulder
marker and a yellow cross at the actual upper-arm pivot. They must coincide.
`coordinate-diagnostics.png` does the same for all 29 source and calculated points.
Mechanical and capture JSON also record the coordinates, attachment error, and
source-derived shoulder separation. The regression checks compare the arms to
the rendered torso landmarks, rather than only checking internally chosen roots.

After the visual inspection, record the actual reviewer and observations:

```sh
python3 tools/rig_workflow.py accept builds/fighters/new_fighter \
  --capture-dir builds/fighters/new_fighter/review \
  --reviewer "reviewing person or LLM" --notes "Specific observations from the images"
python3 tools/rig_workflow.py check builds/fighters/new_fighter --require-review
```

Acceptance requires current successful mechanical evidence and real capture
metadata. It cannot turn failed tests into an accepted rig. The workflow also
rejects Godot script exceptions even when Godot exits with status zero.

For an LLM service, these are callable stages with JSON success/rejection results.
The provider is called once per stage, and deterministic validation either
accepts or rejects that result. A rejected result remains rejected until a
person explicitly starts a new generation with an updated prompt or source
decision. A visual LLM is suitable for a separately requested inspection step;
it must not invent or move measured coordinates to hide a failed attachment.
Do not claim success merely because an image was generated.

The Vertex provider API orchestration and single-call stage execution are
implemented in `tools/character_generation_workflow.py`; the script is the
reusable local generation/import/validation entry point. An end-user creation
UI is not part of this repository. It has been tested with the two repaired
fighters and a new-ID import of template-compatible art, not a statistical
batch of new AI characters.
Arbitrary costumes and non-humanoid bodies remain outside the twelve-part
contract.

## Production assets and export checks

### Editable native inspection scene

Export a script-free scene from the production renderer's current candidate:

```sh
python3 tools/run_godot_check.py /Applications/Godot-4.5.2.app/Contents/MacOS/Godot \
  --headless --path . --script tools/export_rig_inspection.gd -- \
  --rig-dir=res://builds/fighters/new_fighter \
  --output=res://builds/fighters/new_fighter/inspection.tscn
```

The exporter copies native Skeleton2D, Bone2D and Sprite2D nodes and verifies
their serialized transforms, z indices and texture paths against the renderer.
It supplies GameGuard, RearArmOnly and SourceRest visibility presets. Only one
should be visible at once. Hide torsoSprite, not torsoBone, to reveal occluded
descendants. This scene is editable in Godot but is a sandbox; edits do not update
the measured source.json or procedural game poses automatically.

The former anatomical neutral dummy at
`builds/generated/neutral_dummy_20260918_v1/marked.png` is historical. It was
replaced because even a featureless mannequin can leak body, clothing and gender
assumptions into generated characters. New work uses the deterministic geometric
template above.

Rebuild the current fighters from their preserved raw images:

```sh
python3 tools/rig_workflow.py build assets/fighters/rigged/batyr --sheet assets/fighters/arcade/Batyr.png
python3 tools/rig_workflow.py build assets/fighters/rigged/oculon --sheet assets/fighters/arcade/Oculon.png
python3 tools/verify_rigged_assets.py
python3 tools/rig_workflow.py test
python3 tools/rig_workflow.py capture
```

Then inspect and accept each production directory using `tests/rig-validation` as
its capture directory. There is intentionally no automatic acceptance on build.

The standard Android and iOS export scripts run a standard-library-only hash and
review check before packaging. Changed source art, joint data, textures, pose code,
or reviewed captures invalidate acceptance. CI additionally reconstructs the
textures from source. Running Godot's export button directly bypasses the shell
preflight; use the scripts for validated builds.

Export presets include the shared contract and per-character JSON files. They
exclude candidate builds and marked templates. Textures use Godot's imported
resource loading, which works inside exported packages. Invalid compiled metadata
is rejected with a warning; existing roster fighters can use their retained old
atlas rather than render partially loaded parts.

## Existing art migration notes

The previous source files placed some elbow points outside the visible arms and
scaled the chest from its neck opening. Those were numeric coordinates with no
anatomical validation. The old tests repeated those same assumptions.

The new source bindings are individually reviewed, then compiled into the shared
layout. This is why the original raw images can have different packing while the
new `Batyr.png` and `Oculon.png` have identical packing and joint centers.

Both old head pieces included a duplicate shoulder bust. Their explicitly recorded
head outlines remove that duplicated anatomy while retaining the full head and
neck. The manifest counts these excluded pixels separately. This is not a general
permission to delete unexplained pixels or trim extremities. Future generation
guides already show a head without the duplicated shoulders.

Spine, DragonBones and Rive are not dependencies. The repaired binding contract,
validation and AI review remain necessary with any rendering library. A different
renderer can be added later using the same named parts and pose data.
