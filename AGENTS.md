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
