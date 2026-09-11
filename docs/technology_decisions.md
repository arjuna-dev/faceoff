# Faceoff technology decisions

Date: 2026-07-17

## Chosen foundation

- Godot **4.3 stable** - installed in the workspace and validated against the playable scene and headless test suite.
- GDScript for the shared game/client/server prototype code.
- 2D deterministic pose rig with depth-lane presentation. There is no simulated Z axis or physics simulation in the current gameplay slice.
- Nakama **3.40.0** for device authentication, session, matchmaking, and the authoritative combat match. The local compose stack loads the vendored Lua match module.
- PostgreSQL **16.4** for local Nakama development.
- LiveKit Server **v1.13.3** as the local media-service target. The project currently ships the shared `MediaRoom` API plus `MockMediaRoom`; no native LiveKit GDExtension is claimed as working yet.
- MediaPipe Face Landmarker (adapter not bundled in this milestone). `FaceTracker` defines the largest-face selection, smoothing, grace-period fallback, and approved-expression boundary that a native adapter must call.

## Why the physics model is local-first

The project starts with a local playable slice so body feel can be tuned before networking. The Nakama match handler now owns the network boundary: clients send compact state and hit intents, the server validates them and owns health and guard outcomes, and the character API stays unchanged. The 2D puppet is a deterministic connected pose rig with authored movement and fall loops, so no physics simulation is required for the online match.

## Cross-platform policy

The shared project uses the GL Compatibility renderer, input actions, runtime UI, and an orthographic scene so the same project can target Android, iOS, Windows, and macOS. Platform-specific microphone/camera/LiveKit implementations must sit behind `MediaRoom` adapters.

## Sources checked

- Godot 4.3 runtime: `godot --version` in this workspace.
- Heroic Labs Nakama Docker install and release notes: https://heroiclabs.com/docs/nakama/getting-started/install/docker/ and https://heroiclabs.com/docs/nakama/getting-started/release-notes/
- LiveKit release history: https://github.com/livekit/livekit/releases
