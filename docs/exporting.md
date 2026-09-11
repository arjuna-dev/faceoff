# Exporting Faceoff

The project is configured around Godot 4.3 stable, the GL Compatibility renderer, input actions, and a low-resolution 2D scene. That keeps the shared gameplay code portable across the four requested targets:

- Windows Desktop
- macOS
- Android
- iOS

Install the matching Godot export templates, open the project, and create one editor export preset per target. Set the application identifier and signing credentials in the target preset; keep those values out of the repository.

## Mobile settings

- Keep portrait/landscape behavior aligned with the project’s landscape presentation.
- Enable the camera and microphone permissions only in the platform export settings and request them after the user presses the corresponding controls.
- Use the `MediaRoom` platform adapter for device enumeration and permission errors.
- Keep touch UI enabled; the virtual pad and action buttons are part of the game scene.

## Desktop settings

- Use the GL Compatibility renderer for broad GPU coverage.
- Keep camera/microphone features optional. A user can play with them disabled.
- Use the mock media room until a native LiveKit adapter has been validated on the target OS.

This workspace validates the shared project and headless tests. It contains a reproducible signed Android debug preset at `export_presets.cfg` and `tools/export_android.sh` for sideloaded LAN playtesting. It also contains signed release APK and AAB presets, `tools/generate_release_keystore.sh`, and `tools/export_android_release.sh`; see [android_release.md](android_release.md) for the upload-key and Google Play flow. iOS packages and native LiveKit/MediaPipe builds still need their platform SDKs and extensions installed.
