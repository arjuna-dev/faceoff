# Faceoff product direction

Faceoff is a social calling product with a 2D fighting game as its call room. The fighter is the shared visual surface for a conversation, so a call feels like meeting someone in a small arcade cabinet instead of switching between a chat app and a game.

## Initial experience

The app opens on a contacts and conversations screen. Each row shows the contact name, presence, last message, and a call action. Selecting a contact opens a lightweight conversation view with text chat and a prominent button to start an in-game call. A call invite opens the same fighter room for both people. Ending the room returns to the conversation and records the call in history.

The current contact list uses phone imports and server discovery without local sample contacts. The production contact model should support account identity, friend requests, blocking, presence, unread counts, message history, and call history. Nakama is the system of record for those low-bandwidth social events and for the two-player match session.

## Call room

The in-game room combines:

- A two-player 2D arcade fighter with manual limb dragging.
- Text chat and call status without leaving the room.
- Microphone and camera controls with explicit opt-in permissions.
- A stable fallback to authored sprite faces when video is off or unavailable.
- A call summary when the room ends, including duration and match result when combat was enabled.

The fighter remains deterministic and server-authoritative for combat. Audio and video transport are handled by a media service such as LiveKit. Nakama provides the authenticated room identity, party or match membership, call signaling, chat, and authoritative gameplay state.

## Video face replacement

Video face mode is an opt-in presentation layer. The intended pipeline is:

1. Capture a local camera frame after the user grants camera permission.
2. Run face detection and approved landmark or expression tracking locally.
3. Use the smoothed face rectangle to crop, resize, and optionally palette-reduce a small face texture.
4. Apply that processed texture to the local fighter head and publish the processed video track to the call room.
5. Apply the remote processed texture to the other fighter head. If tracking is lost, keep the last texture for the grace period, then fall back to authored art.

Raw camera frames, raw landmarks, and reusable media credentials must not be sent through Nakama. The native camera and face-landmark adapter is still a platform milestone. The shared code already exposes `VideoFaceController`, `FaceTracker`, `MediaRoom.replace_camera_track_with_processed_frames`, and `RagdollCharacter.set_video_face_texture` so that adapter can be added without changing combat or networking code.

## Delivery order

1. Playable solo-fighter home, separate Faceoff friends and searchable Android All contacts screens, channel-first APK invitations, phone-number SMS verification, and an invitation lobby with distinct outgoing and incoming controls. Implemented locally; production rollout requires SMS credentials and the updated server modules.
2. Initial Nakama contact discovery, persistent messages and call signaling are implemented. Rich presence, call history and background push remain planned.
3. In-game call room with MockMediaRoom controls and text chat.
4. Native camera capture and face-landmark adapter on Android, then desktop and iOS.
5. LiveKit processed-video publication, remote face textures, permission UX, and quality fallback.
6. Playtest tuning for privacy, latency, face readability, and the transition between conversation and fighter room.
