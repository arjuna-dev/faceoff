# LiveKit integration plan

The game code only depends on `MediaRoom`. `MockMediaRoom` is used by the editor/headless prototype and keeps audio/video off by default. `LiveKitMediaRoom` is the fail-closed native adapter seam; it reports a permission/integration error until a validated platform bridge is installed. A production adapter must implement the same methods for joining a room, publishing microphone/camera tracks, replacing a camera track with processed frames, remote-track state, device enumeration, volume/mute, connection quality, and reconnection.

The local room name is designed to come from the Nakama match/session identifier. Nakama should issue a short-lived room token scoped to that room; the client must never receive a reusable server secret.

## Native adapter gate

Before selecting a native Godot extension, verify its license, active maintenance, Godot 4.3 compatibility, Windows/macOS/Android/iOS coverage, audio capture, video frame access, and custom video-source support. The current vertical slice intentionally does not claim those checks are complete. The mock is the safe fallback for unsupported builds.

## User flow

1. Microphone and camera are off by default.
2. The player can enable them before matchmaking, in a lobby, or during a session.
3. Camera permission is requested only after the player activates camera.
4. Local preview and face-tracking state are separate from publication.
5. Losing tracking uses a short grace period, then returns to the character sprite or portrait fallback.

## Face processing contract

`FaceTracker` takes candidate face rectangles/confidence values from a local adapter, chooses the largest valid face, smooths center/scale, and emits a bounded visual state. Raw landmarks do not cross the multiplayer boundary. The native adapter will later crop, downscale, optionally palette-reduce, and provide processed frames through `replace_camera_track_with_processed_frames`.
