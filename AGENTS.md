# Faceoff engineering guardrails

## Android back navigation

- Keep `config/quit_on_go_back=false` in `project.godot`. Android back must be routed through `Main._notification()` and `_back_navigation()` instead of terminating the process automatically.
- Every visible top-level screen must have an explicit previous-screen branch in `_back_navigation()`. Back from a nested screen returns to the screen that opened it.
- Preserve the entry point for fighter selection and the arena with `fighter_select_return` and `arena_return`. Do not hardcode Contacts as the destination when a flow can also start from solo home.
- The solo home is the navigation root. Back on that first screen must open `exit_confirmation`; it must never call `SceneTree.quit()` directly.
- On mobile, handle `NOTIFICATION_WM_CLOSE_REQUEST` through the same exit confirmation because some Android host paths report back as a close request.
- Keep regression coverage in `tests/test_puppet_smoke.gd` for both nested-screen back navigation and the root-screen exit warning.

## Fighter reach

- Front and rear arms must have the same forward combat reach measured from the torso shoulder axis. Visual depth ordering must not reduce the rear arm's usable range.
- Any change to shoulder offsets, arm roots, or IK reach must exercise both `left_forearm` and `right_forearm` for every active visual style.

## Fighter asset workflow

- Read `docs/character-generation.md` before changing fighter generation or rigging. It describes the live v3 workflow; older atlas notes and captures are historical.
- `assets/fighters/rigged/contract.json` owns the shared 1024x1536 layout, names, joint coordinates, hierarchy and five body templates. Edit source bindings in `source.json`, never compiled `profile.json` or sliced PNGs.
- Use `tools/rig_workflow.py` to build, test, capture and record review. A numeric PASS is insufficient: inspect the actual production-renderer pose and body-type images before accepting.
- Reject Godot script errors even if the process exits zero. `tools/run_godot_check.py` performs this check.
- Never silently crop foreground to fit a cell or accept joints in transparent space. The two migrated head/bust ownership masks are explicit and counted, not a generic cleanup heuristic.
- Keep unreviewed candidates under `builds/`. Standard exports must pass `tools/verify_rigged_assets.py --hash-only --require-review`; source, runtime or capture changes invalidate the review.
- Kiro and Jade retain their old atlas path until replacement artwork passes the v3 workflow. Do not infer that every fighter has migrated because Batyr and Oculon have.
