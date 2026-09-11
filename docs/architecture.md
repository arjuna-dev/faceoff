# Faceoff architecture

```text
Godot client
  ├─ UI / input / local prediction
  ├─ RagdollCharacter (deterministic connected 2D pose rig)
  ├─ ExpressionSystem (data-driven face/body effects)
  ├─ MediaRoom (mock now, LiveKit adapter later)
  ├─ FaceTracker (local smoothing + fallback)
  ├─ FaceoffNakamaMatch (auth, matchmaker, authoritative match)
  └─ FaceoffOnlineMatch (two-slot relay fallback)

Nakama - auth / party / matchmaking / chat / session credentials
   │
   ├── faceoff_match.lua - authoritative state, guard, hit, and health rules
   └── LiveKit room token - LiveKit media room
```

The local scene runs without a network dependency. When `ONLINE TEST` is joined with a `nakama://` URL, `NakamaSessionService` authenticates the device, joins the matchmaker, and enters a two-player authoritative Nakama match. The client sends position, pose, held limb targets, and hit intents. The Lua match validates input, owns health, checks forearm and shin shields, applies chip or full damage, accumulates guard strain, displaces a shield after a strong or repeated blow, and broadcasts authoritative health and pose snapshots. A `ws://` URL selects the two-slot relay for quick LAN tuning.

## Rendering model

Characters and presentation are fully 2D. The 2.5D arcade presentation is created with z-indexed segmented sprites, a generated Thailand marketplace stage, a perspective floor, and nearest-neighbor pixel rendering. Lightweight lantern, awning, dust, and steam loops provide motion without particle-heavy mobile costs. Ambient background motion can be disabled independently.

Clicking visible limb bounds selects that body; dragging moves a connected limb target in screen space. Up to five touch IDs can be active per fighter, with pointer ownership preventing a touch from controlling both characters. On release, the current parent-relative limb target remains held, so the pose persists while walking.

## Physics/animation hybrid

The character is deterministic and animation-led rather than physics-led. Walking writes authored gait targets to the legs while a grabbed limb keeps its manual target. A torso swipe starts an authored ballistic jump, and holding one foot above the hop threshold switches to one-foot hopping. Lifting both feet starts the authored fall and get-up loop.

Support is conditional rather than unconditional. Both feet must be meaningfully lifted for the fall timer, and hopping risk is near zero for a foot that only barely clears the floor. Clearance, lean, extended arms, and guard strain add a bounded probability at each completed hop step.

## Vertical slice modes

- Free Play Open Floor: social play, poses, expressions, no winner.
- Friendly Rumble: damage, endurance, hit impulse, and KO. No novelty score for sitting or posing.
- Pose Studio: a low-pressure pose sandbox where combat is not scored.

## Limb interaction

The selection cursor is visual only. Faceoff does not expose X/Y transform handles: the arena is already a 2D interaction plane, so mouse and touch positions are direct world-space targets. Keyboard nudges remain optional accessibility inputs.
