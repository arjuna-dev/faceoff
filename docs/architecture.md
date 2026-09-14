# Faceoff architecture

```text
Godot client
  ├─ UI / input / local prediction
  ├─ RagdollCharacter (deterministic connected 2D pose rig)
  ├─ ExpressionSystem (data-driven face/body effects)
  ├─ MediaRoom (mock now, LiveKit adapter later)
  ├─ FaceTracker / VideoFaceController (local smoothing, crop, and fallback)
  ├─ FaceoffNakamaMatch (auth, matchmaker, authoritative match)
  └─ FaceoffOnlineMatch (two-slot relay fallback)

Nakama - auth / party / matchmaking / chat / session credentials
   │
   ├── faceoff_match.lua - authoritative state, guard, hit, and health rules
   └── LiveKit room token - LiveKit media room
```

## Product flow and service boundary

The intended application starts with social context and enters combat only when a contact accepts a call:

```text
Contacts / conversations
          │
          ├── text message and presence events ── Nakama
          │
          └── call invite and room identity ───── Nakama
                                                     │
                         ┌───────────────────────────┴───────────────────────────┐
                         │                                                       │
                  authoritative fighter state                            audio / video
                         │                                                       │
                       Nakama                                           LiveKit MediaRoom
                         │                                                       │
                         └──────────── in-game 2D call room ─────────────────────┘
```

Nakama owns accounts, contacts, conversations, presence, call signaling, party or match membership, and authoritative fighter state. The initial `FighterVoice` implementation sends bounded mono voice packets through the accepted match socket. A future dedicated media service will replace this initial voice transport and add room-scoped video. Camera access is disabled until real face video is available.

`SoloHome` opens over the arena with one controllable fighter and the primary Call a friend action. `ContactsHome` separates matched Faceoff friends from searchable Android All contacts. `FaceoffSocialController` owns phone sign-in, discovery, messages, invitation RPCs and persistent notifications. Verified inviters get a short-lived opaque invite handle that can prefill a recipient's phone after install; resolving it never authenticates the recipient. `FighterLobby` separates outgoing Cancel from incoming Accept/Decline. The server creates an invitation-restricted match after acceptance; `Main` waits for two-player readiness and a local slot, then both players choose and share a roster ID before displaying the arena. Only the assigned fighter accepts input. Demo is a separate local path. `AndroidContactsImporter` requests READ_CONTACTS after Invite friends, opens direct SMS, WhatsApp, or Telegram APK sharing through a restricted FileProvider, and receives `faceoff://invite/` links from Android. Source files live in `platform/android/` and are copied into Godot's generated build by `tools/prepare_android.sh`. See [social_play.md](social_play.md) for the current contract and deployment requirements.

On Android, `Main` requests portrait orientation and a 540x960 content scale for the contacts and lobby pages. It requests landscape orientation and a 960x540 content scale when the fight room becomes active. Desktop uses the same portrait navigation and landscape arena transition.

The local scene runs without a network dependency. When `ONLINE TEST` is joined with a `nakama://` URL, `NakamaSessionService` authenticates the device, joins the matchmaker, and enters a two-player authoritative Nakama match. Each client selects one fighter, sends the roster ID through the match, and waits for the other selection before arena input is enabled. The client then sends position, pose, held limb targets, and hit intents. The Lua match validates input, owns health, checks forearm and shin shields, applies chip or full damage, accumulates guard strain, displaces a shield after a strong or repeated blow, and broadcasts authoritative health and pose snapshots. A `ws://` URL selects the two-slot relay for quick LAN tuning.

## Rendering model

Characters and presentation are fully 2D. The 2.5D arcade presentation is created with z-indexed segmented sprites, a generated Thailand marketplace stage, a perspective floor, and nearest-neighbor pixel rendering. Lightweight lantern, awning, dust, and steam loops provide motion without particle-heavy mobile costs. Ambient background motion can be disabled independently.

Clicking visible limb bounds selects that body; dragging moves a connected limb target in screen space. Up to five touch IDs can be active per fighter, with pointer ownership preventing a touch from controlling both characters. On release, the current parent-relative limb target remains held, so the pose persists while walking.

## Video face pipeline

Face video is a presentation track attached to a fighter head, not gameplay state. The local adapter captures a camera frame, detects and smooths a face, crops it into a small processed texture, and gives that texture to `RagdollCharacter.set_video_face_texture`. The atlas renderer draws the texture over the facial area while preserving the authored hair and costume. The same processed frames can be supplied to `MediaRoom.replace_camera_track_with_processed_frames` for the remote caller. When the texture is cleared, the authored head asset returns automatically.

Raw camera frames and landmarks stay on the device. Nakama receives only the call, chat, presence, and compact fighter state required by the session. A native CameraFeed plus MediaPipe or equivalent adapter is still required for real device tracking; the desktop mock and fail-closed LiveKit adapter intentionally do not pretend to provide camera detection.

## Physics/animation hybrid

The character is deterministic and animation-led rather than physics-led. Walking writes authored gait targets to the legs while a grabbed limb keeps its manual target. A torso swipe starts an authored ballistic jump, and holding one foot above the hop threshold switches to one-foot hopping. Lifting both feet starts the authored fall and get-up loop.

Support is conditional rather than unconditional. Both feet must be meaningfully lifted for the fall timer, and hopping risk is near zero for a foot that only barely clears the floor. Clearance, lean, extended arms, and guard strain add a bounded probability at each completed hop step.

## Vertical slice modes

- Free Play Open Floor: social play, poses, expressions, no winner.
- Friendly Rumble: damage, endurance, hit impulse, and KO. No novelty score for sitting or posing.
- Pose Studio: a low-pressure pose sandbox where combat is not scored.

## Limb interaction

The selection cursor is visual only. Faceoff does not expose X/Y transform handles: the arena is already a 2D interaction plane, so mouse and touch positions are direct world-space targets. Keyboard nudges remain optional accessibility inputs.
