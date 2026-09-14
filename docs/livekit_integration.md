# LiveKit integration plan

The game code only depends on `MediaRoom`. `MockMediaRoom` is used by the editor/headless prototype and keeps audio/video off by default. `LiveKitMediaRoom` is the fail-closed native adapter seam; it reports a permission/integration error until a validated platform bridge is installed. A production adapter must implement the same methods for joining a room, publishing microphone/camera tracks, replacing a camera track with processed frames, remote-track state, device enumeration, volume/mute, connection quality, and reconnection.

The local room name is designed to come from the Nakama match/session identifier. Nakama should issue a short-lived room token scoped to that room; the client must never receive a reusable server secret.

## Native adapter gate

Before selecting a native Godot extension, verify its license, active maintenance, Godot 4.3 compatibility, Windows/macOS/Android/iOS coverage, audio capture, video frame access, and custom video-source support. The current vertical slice intentionally does not claim those checks are complete. The mock is the safe fallback for unsupported builds.

## In-game call flow

1. A contact opens a conversation and sends or accepts a call invite.
2. Nakama creates the party or match identity and returns a short-lived media-room token.
3. The fighter room joins Nakama and LiveKit using that identity. Microphone and camera remain off until the player opts in.
4. Camera permission is requested only after the player activates camera. Local preview and face-tracking state are separate from publication.
5. Ending the room returns to the conversation and writes call history through Nakama.

## Face processing contract

`VideoFaceController` connects a local detector to `FaceTracker`, `FaceTextureProcessor`, a fighter head, and an optional `MediaRoom`. `FaceTracker` takes candidate face rectangles/confidence values from the detector, chooses the largest valid face, smooths center/scale, and emits a bounded visual state. The controller keeps the last texture during the grace period, then clears it so the authored sprite or portrait is shown. Raw landmarks do not cross the multiplayer boundary.

The intended publication path is:

```text
CameraFeed -> local face detector -> FaceTracker -> processed face texture
                                      ├── RagdollCharacter head
                                      └── LiveKit processed video track
```

The current repository includes the shared texture hook and processing contract, but it does not bundle a native CameraFeed or MediaPipe bridge. `LiveKitMediaRoom` therefore fails closed until a platform adapter supplies camera frames and a validated LiveKit video source.
