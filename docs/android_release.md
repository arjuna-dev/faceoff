# Android release and Google Play signing

The project has separate signed release presets for an APK and an Android App Bundle (AAB). The AAB preset uses a Gradle build, which is the format required for new Google Play uploads.

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

Godot 4.3, its Android export templates, the Android SDK, and JDK 17 are required:

```bash
./tools/export_android_release.sh
```

The outputs are:

- `exports/Faceoff-release.apk` for direct device testing
- `exports/Faceoff-release.aab` for Google Play

The script injects the ignored keystore credentials through Godot's release export environment variables, verifies the APK with `apksigner`, and verifies the AAB signature with `jarsigner`.
If the Gradle template is not present in the project, the script installs Godot's matching Android build template automatically before the AAB export.

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
