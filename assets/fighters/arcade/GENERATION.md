# Fighter artwork

## Oculon template ankle split and 78% adjustment, 2026-09-17

Template-only revision, not a runtime asset replacement. The built-in image
generator edited `builds/manual_oculon/oculon_template_chatgpt_ankle_v2.png`
using the exact saved prompt in
`builds/manual_oculon/oculon_template_boot_split_prompt.txt`. Both yellow boot
shafts/cuffs belong to the shin pieces; foot cells contain only the below-ankle
shoe portions, no calf, cuff or trousers, with flat soles and ankle markers.
Raw output: `builds/manual_oculon/oculon_template_boot_split_raw.png`.

`tools/resize_marked_oculon_template.py` retains only the generated bottom-row
cell contents and restores all other source artwork. It then applies an exact
uniform 0.78 affine scale about each non-torso cell's center with Pillow nearest
neighbor resampling. Markers scale with their pieces. Magenta cell backgrounds
are flattened, and light gutter fringes at crop perimeters are removed to avoid
introducing internal white rectangles. The torso/pelvis remains byte-for-byte
original, as do the white gutters and twelve cell rectangles.

Final template: `builds/manual_oculon/oculon_template_boot_split_78.png`.
Measured marker coordinates, transformations and checks:
`builds/manual_oculon/oculon_template_boot_split_78.json`. All 22 markers remain,
each within 1.1 pixels of its calculated transformed position; non-torso artwork
dimensions agree with 78% within two raster pixels. Visually inspected both the
boot split and final adjusted atlas. No angel regeneration, Godot rig changes,
production renderer review or export was performed for this template-only task.

## Armk proportion-preserving rig repair, 2026-09-16

No artwork was regenerated. The generic marked-atlas importer now preserves
source rectangles and marker coordinates. Armk's compiler preserves prepared
source pixels without resampling, and its Godot rig uses one shared uniform
pixel scale with source-derived bone lengths. Independent body-type width and
length fitting is disabled for this format. Existing normalized Batyr and
Oculon assets retain their legacy rendering.

Reviewed production evidence: `builds/fighters/armk_preserved/review_production/poses.png`
and `body-types.png` in the same directory. Pixel-equality, uniform scale,
orthogonality, marker attachment, native segment length, and equal forward
arm-reach checks pass. Deep knee bending and clothing overlap remain pose
refinement issues; this review accepts the scaling repair, not a perfect final
pose design.

## Current workflow: shared character contract, revision 3

See [the complete generation workflow](../../../docs/character-generation.md).

Batyr.png and Oculon.png are now compiled 1024x1536 sheets with identical named
rectangles and attachment coordinates. Their original repaired raw sources are
preserved. Source-specific anatomy is recorded in each fighter's source.json;
the compiler normalizes it into the shared contract. Never edit a compiled
profile or crop rectangles to conceal an image defect.

The repair moves joints into solid artwork, measures the torso from shoulders
to hips, preserves head proportions, uses a real assembled Bone2D reference pose,
and keeps source pixel scaling out of the bones. Neck and hip connections follow
the chest. Shin and boot share one cuff, and planted shoes have level soles.
The head combat target follows the visible head.

Both old head images also contained shoulders. Documented source outlines remove
only this duplicated bust area, with excluded pixels counted in rig.json. Complete
heads, hands and shoes remain. Normalization resamples artwork deliberately and
records that fact; normalized pixel counts are not claimed to equal raw counts.

Five generated guide PNGs, matching bindings and prompts are in
assets/fighters/rigged/templates. Their joint coordinates are identical; head,
torso and limb proportions differ. The same script creates every guide.

Verification includes pixel ownership and margins, opaque coverage at both ends
of every attachment, shared ankle connections, visible torso coverage at shoulders,
neck and hips, both facing directions, five builds, all thirteen acceptance poses,
and equal arm reach for every active visual style. Gameplay captures and review
evidence live in tests/rig-validation. Old captures elsewhere in tests are historical
and must not be used as acceptance evidence for this revision.

The export scripts reject stale sources, compiled images, metadata or visual
reviews. The end-user AI service is still future work; the callable local workflow
now supports candidate imports, rejection feedback, real captures and recorded
human or LLM visual acceptance. Kiro and Jade retain the previous atlas renderer.

## Historical atlas workflow

Generated using ChatGPT image generation in the in-app browser, then edited in place to remove the background. Runtime sources are paired 1536 by 1024 atlases. UV patches in `scripts/characters/arcade_skin.gd` map each source onto the connected gameplay rig.

## Original prompt

Use case: stylized-concept. Asset type: production 2D fighting game character art atlas on a genuinely transparent background. Two full body original fighters side by side, both facing RIGHT in three-quarter side view, separate with generous empty space, no overlap. Left fighter: bulky fierce adult Tatar warrior, muscular arms, pointed steel cap with fur ear flaps, thick moustache and short beard, intricate teal lamellar cuirass, tawny fur collar, burgundy split coat, leather bracers and heavy boots. Right fighter: lean young adult bald Buddhist kungfu monk, clean shaven, saffron orange one-shoulder robe, wooden prayer beads, exposed muscular shoulder, ivory forearm and shin training wraps, dark slippers. Visual benchmark: hand-pixelled Street Fighter II arcade sprite sophistication, realistic muscular anatomy, rich clustered five-tone shading, dark colored outlines, sharp small pixels, polished 1990s Capcom-style sprite rendering. NOT flat vector shapes, NOT tiny low-detail chibi, NOT modern smooth painted concept art. Full bodies of identical height aligned at same ground level. Production neutral A pose: upright straight torsos, both legs straight and slightly apart, arms down and spread away from torso at about 30 degrees, elbows nearly straight, fists at hip height away from body, each arm and leg clearly separated by transparent space for rigging. Head face clearly visible. No fighting guard, no hands over chest, no flexed elbows, no text, no labels, no shadows, no ground, no scene. Image landscape 1536 by 1024. Keep all feet, headgear, hands fully in frame, roughly 80 pixels transparent margin all sides. Each figure ~800 pixels tall. Transparent background.

## Final edit prompt

Use case background-extraction. Edit target is this production two-fighter sprite atlas. Preserve the two fighter subjects, pixels, detailed shading, exact scale, positions, dimensions, anatomy and poses. Remove ALL background, colored glow, vignette, floor, cast shadow. Export with a genuine transparent alpha background, every pixel outside the two fighters must be fully transparent, including the empty gaps between limbs. If alpha export is unavailable, use perfectly flat solid RGB 255,0,255 magenta with no shading instead. Do not change the fighters or add anything.

## Jade and Oculon replacement atlas

Source file: `jade-oculon-atlas.png`. It keeps the same 1536 by 1024 canvas, left and right source slots, facing direction, neutral A-pose, ground alignment, and empty gap as the live atlas. Jade occupies the left warrior slot. Oculon occupies the right monk slot. `FighterRoster` selects this atlas for the two new profiles, while the existing `fighters-atlas.png` remains the source for Batyr and Kiro.

Generated in the in-app ChatGPT browser with the current `fighters-atlas.png` and `tests/fighter-preview.png` attached as references. Final generation brief: edit the two existing source slots in place, replace the left fighter with an athletic adult Chinese woman in a long plain elegant jade-green and cream hanfu, and replace the right fighter with an adult shirtless cyclops man with exactly one central eye, green pants, and bright yellow boots. Match the existing source-art treatment with crisp clustered arcade sprite shading, dark hard outlines, no smooth concept-art rendering, and no extra subjects. The resulting atlas was edited in-app to remove all generated background glow, then verified as a 1536 by 1024 RGBA PNG before being copied into the runtime asset directory.

## Jade and Oculon rig repair

The replacement atlas originally loaded through the wrong deformation masks: Jade inherited Batyr's source polygons and Oculon inherited Kiro's. The live renderer now has dedicated `jade_*` and `oculon_*` source polygons, landmarks, breadth values, draw order, and arm-root offsets in `scripts/characters/arcade_skin.gd`. Jade's skirt is split across overlapping hip and leg regions so walking and kicks do not pull one continuous garment across both joints.

The atlas was alpha-cleaned with a 2% source-alpha cutoff, preserving the authored pixels while removing one-pixel glow residue at the canvas edge and center slot gap. It passes `inspect_atlas.py` against the proven atlas contract. OpenGL gameplay captures reviewed during the repair: `tests/jade-oculon-neutral.png`, `tests/jade-punch.png`, `tests/oculon-face-kick.png`, `tests/jade-crouch-walk.png`, and `tests/oculon-punch.png`.

## Jade and Oculon rig-ready v2

Source file: `jade-oculon-atlas-v2.png`. The built-in image generation tool created this replacement from the proven Batyr/Kiro atlas, its gameplay capture, and the first Jade/Oculon atlas. The production brief preserved both character identities while requiring upright bodies, nearly straight arms separated from the torso, visible joint landmarks, independently separated legs, a center-split costume below Jade's waist, a clear split in Oculon's pants, and the established detailed 1990s arcade rendering.

Final generation prompt: Create a replacement production atlas for the live Faceoff UV-warped IK rig, using the proven Batyr/Kiro atlas as the layout and quality reference, the gameplay capture as the runtime-scale reference, and the existing Jade/Oculon atlas only for character identity. Keep a 1536 by 1024 landscape canvas with Jade alone in the left slot and Oculon alone in the right slot, both full body, facing right in three-quarter side view, aligned to the same ground line, with a wide empty center gap and generous transparent margins. Jade is an athletic adult Chinese woman in a jade-green and cream martial hanfu. Split all cloth below her waist into clearly separate left and right panels so each leg can deform independently. Oculon is a muscular adult cyclops with exactly one central eye, a bare torso, green split trousers, and bright yellow boots. Give both fighters an upright neutral rigging pose with straight torsos, straight separated legs, arms held away from the torso, nearly straight elbows, visible fists, and clear shoulder, elbow, wrist, hip, knee, ankle, neck, and head landmarks. No sleeve, hand, weapon, hair, cloth, or leg may overlap another independently moving body region. Match detailed hand-pixelled 1990s arcade fighter art with dark colored outlines, crisp small pixels, clustered multitone shading, readable anatomy, and Street Fighter II era sprite density. No fighting guard, crossed limbs, cropped extremities, text, labels, floor, shadows, scenery, glow, haze, or extra subjects.

Final background extraction prompt: Preserve the fighters, exact canvas dimensions, positions, scale, anatomy, costume details, pixel edges, and shading. Remove every background, floor, cast shadow, glow, haze, and colored fringe. Return a genuine RGBA image with fully transparent pixels everywhere outside the two fighters and between every separated limb, including the complete center gap. Do not repaint, move, resize, crop, smooth, or add anything.

A separate background-extraction pass produced RGBA output. The final source alpha was hardened at 50% to remove the generated glow completely, and the center separation band was cleared. `inspect_atlas.py` passes dimensions, RGBA alpha, transparent edges, and center separation.

The runtime now maps the v2 source with new shoulder, elbow, wrist, hip, knee, ankle, torso, and head landmarks. Sleeve pixels are owned only by arm patches. Jade's left and right dress panels are owned by their respective leg chains. Oculon's torso excludes both upper arms, and his trousers and boots use separate left and right leg patches. Reviewed real-renderer captures include `tests/jade-oculon-neutral.png`, both `tests/jade-punch.png` and `tests/jade-left-punch.png`, `tests/jade-walk-held-arm.png`, `tests/jade-low-kick.png`, `tests/oculon-face-kick.png`, `tests/jade-crouch-walk.png`, `tests/jade-bow.png`, `tests/jade-arch.png`, `tests/oculon-jump.png`, `tests/jade-one-foot-hop.png`, `tests/oculon-fall.png`, `tests/oculon-get-up.png`, and the contact sheet `tests/jade-oculon-pose-matrix.png`.

## Rig-first v3 repair

Runtime files: `fighters-atlas-v2.png` for Batyr and the repaired Kiro, plus `jade-oculon-atlas-v3.png` for Jade and Oculon. The former atlases remain in the repository as rollback sources.

The new source method treats each figure as a rigging plate rather than a complete illustration. Each torso stops at readable shoulder seams, every arm is a complete shoulder-to-elbow-to-fist chain, and chest pixels may not cover either upper arm. Jade now has short independent coat panels over fitted trousers instead of cloth spanning both leg chains. Oculon's trousers have explicit left and right ownership. The runtime uses equal forward arm-root positions for front and rear arms, with depth communicated by draw order and vertical offset rather than by sacrificing rear-arm reach.

Final Kiro repair prompt: Keep Batyr, the left fighter, unchanged. Repair and redraw only Kiro, the bald monk on the right, so his anatomy and depth order are unambiguous for rigging. His torso and viewer-facing pectoral must end cleanly at the shoulder socket. Each upper arm must begin at its shoulder, never appear attached after or in front of the pectoral, and remain visually distinct from the torso. Preserve the exact 1536 by 1024 landscape canvas, right slot position, facing-right convention, ground line, scale, wide center gap, and generous outer margins. Kiro stands upright in a neutral production A-pose with a straight torso, straight separated legs, arms angled slightly away from the torso, nearly straight elbows, visible fists, and clearly readable joint landmarks. Match the detailed hand-pixelled 1990s arcade treatment. Preserve Kiro's bald monk identity, prayer beads, orange robes, white wraps, and black shoes. No fighting guard, crossed limbs, foreshortening, chest anatomy covering a shoulder, cropped extremities, background, shadow, glow, or scenery.

Final Jade and Oculon repair prompt: Redraw Jade and Oculon as clean rig-first source figures whose body regions remain anatomically coherent when separately deformed. Do not merely repaint the existing shapes. Each fighter must have a coherent torso, head, and two complete arms attached at clear shoulder sockets. Neither chest may wrap over an arm. Preserve the exact 1536 by 1024 canvas, slot positions, facing-right convention, ground line, scale, center gap, and outer margins. Both fighters stand in a neutral production A-pose with straight separated legs, arms slightly away from the torso, nearly straight elbows, visible fists, and clear joint landmarks. Preserve Jade as an athletic adult Chinese woman with black tied hair and jade-green, cream, and gold martial hanfu. Replace all cloth below her belt with two short independent split panels ending above the knees over fitted cream trousers. Preserve Oculon as a muscular adult cyclops with exactly one central eye, a bare torso, green split trousers, hand wraps, and yellow boots. Match detailed hand-pixelled 1990s arcade art. No fighting guard, crossed limbs, foreshortening, overlapping moving regions, detached hair, cropped extremities, background, shadow, glow, or scenery.

The built-in generator returned a rendered checkerboard in RGB after the transparency edit. A controlled follow-up replaced only the background with a flat magenta chroma field. Final cleanup used `magick INPUT -alpha on -fuzz 14% -transparent 'rgb(242,8,243)' fighters-atlas-v2.png` and `magick INPUT -alpha on -fuzz 14% -transparent 'rgb(242,8,244)' jade-oculon-atlas-v3.png`. This produced binary RGBA while preserving the exact canvas and clearing the center gap. Both final atlases pass `inspect_atlas.py --require-binary-alpha` with zero partial-alpha, edge-alpha, and center-gap pixels.

Real OpenGL captures were regenerated after the atlas, mapping, guard, and reach changes. Reviewed evidence is `tests/fighter-preview.png`, every Jade and Oculon pose listed above, and the regenerated `tests/jade-oculon-pose-matrix.png`.
