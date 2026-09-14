# Android release and Google Play signing

The project has separate signed release presets for an APK and an Android App Bundle (AAB). All Android presets use the Gradle template so the `FaceoffContacts` bridge and its opt-in Contacts and microphone permissions are included. Camera permission is intentionally absent until face replacement is implemented. The AAB preset uses a Gradle build, which is the format required for new Google Play uploads.

## Create the upload key

Run this once on a trusted workstation:

```bash
./tools/generate_release_keystore.sh
```

The command creates:

- `keystores/faceoff-upload.keystore`
- `keystores/faceoff-upload.env`

Both paths are ignored by git and are written with mode 600. Back up the keystore and password in a password manager. Losing the upload key makes future Play uploads difficult to recover.

Print the certificate fingerprints needed by Play Console with:

```bash
./tools/release_certificate_fingerprint.sh
```

## Configure the production endpoint

After the Nakama DNS name and server key are known, prefill the in-game online field and matching Nakama client key for release builds:

```bash
./tools/configure_production_client.sh --env-file .env.production
```

The setting can still be changed in the online field during testing. The `nakamas://` scheme selects HTTPS and WSS and uses port 443 when no port is specified.

## Build release artifacts

Godot 4.5.2, its matching Android export templates, the Android SDK, an installed Android NDK, and JDK 17 are required. The editor and native Godot Android runtime must use the same version. The export scripts reject mixed versions because they can pass static checks and still crash at runtime.

On macOS, with the Godot 4.5.2 app installed as `/Applications/Godot-4.5.2.app`, run:

```bash
GODOT_BIN=/Applications/Godot-4.5.2.app/Contents/MacOS/Godot ./tools/export_android_release.sh
```

The outputs are:

- `exports/Faceoff-release.apk` for direct device testing
- `exports/Faceoff-release.aab` for Google Play

The script injects the ignored keystore credentials through Godot's release export environment variables, reapplies the `faceoff://invite` activity filter after Godot regenerates its variant manifest, packages native libraries on 16 KB boundaries, and verifies the APK with `apksigner`. It verifies the AAB's native ELF alignment with `tools/verify_android_16kb.sh` and its signature with `jarsigner`.
If the Gradle template is not present in the project, run `tools/prepare_android.sh` with Godot's matching `android_source.zip` available. The script caches the official Godot 4.5.2 runtime and refuses a checksum mismatch.
The checked-in export presets target arm64 only. `prepare_android.sh` keeps the verified full runtime as the source cache and derives an arm64-only AAR for Gradle, which avoids expanding unused ABI libraries on machines with limited free space.

## Google Play setup

In Google Play Console:

1. Create the Faceoff app with package name `com.faceoff.arcade`.
2. Open App integrity and choose Google Play App Signing.
3. Let Google generate the app signing key, or import a protected signing key if one already exists.
4. Register the certificate from the upload keystore when prompted.
5. Upload `exports/Faceoff-release.aab` to an internal testing track.
6. Install the Play-distributed build on two test devices and verify TLS matchmaking, multitouch, reconnect, backgrounding, and account persistence.
7. Promote the tested bundle through closed testing before production.

The repository includes a manual GitHub Actions workflow at `.github/workflows/android-release.yml`. Store the upload keystore as the `FACEOFF_UPLOAD_KEYSTORE_BASE64` repository secret, the alias/password as `FACEOFF_UPLOAD_KEY_ALIAS` and `FACEOFF_UPLOAD_KEY_PASSWORD`, and the production Nakama key as `FACEOFF_NAKAMA_SERVER_KEY`. Supply the `nakamas://...` endpoint when dispatching the workflow. The workflow produces the AAB as an artifact; Play Console still controls the app signing identity and release promotion.

For the base64 secret value, use the platform-appropriate command without committing the result:

```bash
base64 < keystores/faceoff-upload.keystore | tr -d '\n'
```

Google Play signing is an account-level operation and cannot be completed from this repository without access to the Play Console account. The generated file is an upload key, not a copy of Google's protected app signing key.

### Native social bridge

Custom source files live in `platform/android/`. Both export scripts run
`tools/prepare_android.sh` to copy the bridge, manifest, restricted APK-sharing
FileProvider and XML paths into Godot's generated Android build directory.
The generated `android/` directory is not the source of truth. Install Godot 4.5.2
export templates for a clean checkout, or point `GODOT_ANDROID_SOURCE` at its
`android_source.zip`.

The debug APK intentionally remains debuggable and can show Android's separate
debuggable-app notice. The release APK is non-debuggable and is the appropriate
artifact to send to a tester who should not see that notice. Both artifacts are
checked for 16 KB ELF and, for APKs, ZIP alignment.

The APK declares INTERNET, READ_CONTACTS and RECORD_AUDIO only. Face video is
not enabled and CAMERA permission is absent. Phone authentication and real
invitations also require the server rollout described in [social_play.md](social_play.md).
