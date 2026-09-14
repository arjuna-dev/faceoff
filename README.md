# Faceoff

Build and install commands:

```bash
# Android debug APK. Use the matching Godot 4.5.2 editor.
GODOT_BIN=/Applications/Godot-4.5.2.app/Contents/MacOS/Godot ./tools/export_android.sh

# Android release APK and Google Play App Bundle
GODOT_BIN=/Applications/Godot-4.5.2.app/Contents/MacOS/Godot ./tools/export_android_release.sh

# Export the iOS Xcode project
./tools/export_ios.sh --clean

# Export, then ask Xcode for an unsigned simulator build
./tools/export_ios.sh --clean --build-simulator

# Install and launch the Android debug APK on a connected device. The flag
# handles a previously installed APK signed with another development key.
./tools/install_android_debug.sh exports/Faceoff-debug.apk --replace-on-signature-mismatch
```

The iOS export needs a macOS machine with Xcode, an Apple Team ID in the `iOS Project` preset, and signing or provisioning configured in Xcode for a physical device. `--build-simulator` is useful for a local simulator build when the matching iOS simulator platform is installed.

Faceoff is a contacts-first messaging and calling app where calls happen inside a 2D arcade fighter. Menus and conversations use portrait orientation; accepted fighter calls and the offline demo use landscape. Combat uses manual limb dragging with animated, connected characters.

The app opens on the landscape **Chats** tab with a playable solo fighter on the left and searchable recent calls on the right. **Quick Fight** pairs the next two searching devices through guest Nakama accounts, so it needs no phone verification or SMS. The persistent bottom navigation contains Chats, Contacts, Settings, and Profile. Contacts, Settings, Profile, and invitations use portrait mode. Tapping a Faceoff contact switches to the arena and opens a right-side action terminal with **Start Fight** enabled; voice-only **Call** and **Message** are visible but disabled for now. Contacts also has a prominent **Invite Friends** action. The invitation screen imports every Android phone contact, opens a pre-addressed native SMS composer when a contact is tapped, and provides **Share Faceoff** for Android's normal share chooser. Signed-in inviters receive a short-lived opaque app link that prefills the recipient's phone after install, while the recipient still proves ownership with a fresh verification code. Phone-number sign-up lives in Profile and uses server-side Twilio Verify, configured for SMS by default with an optional WhatsApp channel. A targeted Start Fight request opens a real invitation lobby: only the recipient can accept, and both players must join before the arena opens. Online players control one fighter each.

Microphone preference is on by default for accepted calls. Face video is unavailable, so video controls are disabled and Android CAMERA permission is not requested. The production Nakama endpoint is configured at `nakamas://2-56-96-171.sslip.io`; phone sign-up additionally requires Twilio Verify credentials in the server deployment. A physical two-phone test is still needed for final audio, permissions, and latency tuning. See [social_play.md](docs/social_play.md) for configuration, tests, and current limitations.

The longer-term product includes video face replacement, richer messaging, and background incoming-call notifications. See [product_vision.md](docs/product_vision.md).

## Run

```bash
godot --path .
```

## Controls

- Chats: control one fighter immediately while searching recent calls, ordered by latest activity. Tap **Quick Fight** on both devices to enter guest matchmaking, or **Demo Fight** to play locally without an account or SMS.
- Contacts: open Faceoff friends or Invite Friends. Previously granted Android contact access is refreshed automatically. A short tap opens the selected contact beside the arena; dragging scrolls without activating it. **Start Fight** begins the targeted invitation flow.
- Invite Friends: tap a phone contact, or enter a number directly, to open the native SMS composer with the recipient and invite message filled in. When connected and verified, the message also carries a short-lived Faceoff link that prefills the number after install. The recipient must still complete phone verification. Share Faceoff chooses any compatible Android app.
- Fighter selection: choose a P1 and P2 card from the live Batyr, Kiro, Jade, and Oculon roster. The cards auto-advance from P1 to P2, and the tabs can switch the active side.
- Drag a hand to punch. Drag a foot or knee to kick.
- Drag the torso sideways to walk, or use `A / D` for player one.
- Drag the torso down to crouch. Raise it slowly to straighten the legs for longer reach. Swipe upward rapidly to jump; include sideways movement for a diagonal jump.
- Drag the head forward and down to bow, or backward and down to arch.
- Lifting both feet off the floor triggers a short fall and automatic get-up. One planted foot keeps the fighter supported. Falling disables movement and attacks until recovery, without costing HP.
- Released limbs hold their pose. Walking resumes the leg animation while keeping the arms extended. A foot held at least 52 pixels above the floor instead causes one-foot hopping, which moves at 320 pixels per second so a player can cross the arena with a committed hop. Each completed hop rolls for a fall only after the lifted foot has meaningful clearance: a foot barely above the floor is effectively 0% to 1%, while high clearance, lean, extended arms, and guard strain add controlled risk. A neutral high-leg hop is tuned near the original 1-in-20 fall scale. The HUD shows the current risk.
- Mouse controls the assigned fighter online, or either fighter in Demo. Touch supports up to five independent drags per fighter, with exclusive pointer ownership across players and cleanup on focus loss. Torso, hand and foot gestures can run concurrently. Mobile touch events are covered by automated control tests; physical-device feel still needs playtesting.
- `Space`: return your controllable fighter to guard (both in Demo).
- In Demo, `R` or Rematch resets health, positions, poses, and timer. Online rematches require ending the call and starting another.
- In Demo, `P` toggles practice with unlimited time and restarts.

Each fighter has 100 HP. Damage scales with measured fist, foot or knee speed: hands range from 5.5 to 18 HP and legs from 7.7 to 25.2 HP, with a 15% head-hit bonus. A stroke requires 18 pixels of actual endpoint travel and at least 55 pixels per second. Swept contact catches fast strikes and resolves the first obstacle. Release and drag again, or reverse into a new deliberate stroke to strike again.

Forearms and lower legs physically intercept attacks, reducing the defender's damage to exactly 1 HP, or 1% of the 100 HP bar, regardless of the incoming strike speed. A strike above 850 pixels/second or accumulated guard strain of 32 displaces that limb and opens the guard for 0.45 seconds. Strain recovers at 9 points per second. Body-driven fist contact from manual head or torso movement uses the same damage rules. Idle animation and a stationary held limb do not cause repeated damage.

Zero HP ends the round; the 90-second timer awards the round by remaining health. The new balance and damage values are initial tuning values for playtesting.

## Local services

The official Nakama Godot SDK is vendored in `addons/com.heroiclabs.nakama`. `nakama/modules/social.lua` handles verified phone accounts, contact discovery, messaging and invitation state. `faceoff_match.lua` assigns player slots and owns state validation, guard checks, damage and health. Quick Fight uses the same authoritative match through Nakama's two-player matchmaker, while targeted contact fights use a restricted invitation match.

```bash
cp .env.example .env
docker compose -f docker_compose.yml up -d postgres nakama
```

If port 7350 is already in use, choose another host port without changing Nakama's internal port:

```bash
NAKAMA_PORT=7352 NAKAMA_CONSOLE_PORT=7353 docker compose -f docker_compose.yml up -d postgres nakama
```

Use `nakama://127.0.0.1:7352` in the game for that example. Stop with `docker compose -f docker_compose.yml down`. Reset local Nakama data with `docker compose -f docker_compose.yml down -v`. Inspect logs with `docker compose -f docker_compose.yml logs -f nakama`.

## Android debug APK

The repository includes an `Android Debug` export preset with Internet, Contacts, and microphone permissions, no camera permission, sensor orientation, arm64 output, nearest filtered textures, and the `com.faceoff.arcade` package id. Navigation pages request portrait mode at runtime; accepting a call requests landscape for the arena. Android exports require the matching Godot 4.5.2 editor and Android templates, JDK 17, the Android SDK, and an installed Android NDK. The export scripts download and verify the official 16 KB-aligned Godot runtime, then verify the final APK or AAB.

To reproduce it after installing Godot 4.5.2 and configuring the SDK and debug keystore in Godot Editor Settings, run:

```bash
GODOT_BIN=/Applications/Godot-4.5.2.app/Contents/MacOS/Godot ./tools/export_android.sh
./tools/verify_android_16kb.sh exports/Faceoff-debug.apk
./tools/install_android_debug.sh exports/Faceoff-debug.apk --replace-on-signature-mismatch
```

The APK is a debuggable build for sideloaded testing, so Android may show its standard debuggable-app notice. The 16 KB compatibility warning should not appear. For a non-debuggable build to share with a tester, use the signed release APK command in [android_release.md](docs/android_release.md). The production path is checked in as `docker-compose.production.yml`: it keeps PostgreSQL and Nakama on a private Docker network, puts Caddy in front for automatic ACME TLS, and can start Prometheus metrics with `./tools/deploy_nakama.sh --observability`. Follow [production_deployment.md](docs/production_deployment.md) for DNS, firewall, backup, secret rotation, and scaling setup. Follow [android_release.md](docs/android_release.md) to create the upload key, prefill a `nakamas://...` endpoint, export the signed APK/AAB, and finish Google Play App Signing.
The Android preset is arm64-only. The preparation script keeps the verified full runtime cache and derives an arm64-only AAR for Gradle so unused native ABIs do not consume build space.

## Validation

```bash
godot --headless --path . --editor --quit
godot --headless --path . -s tests/test_core.gd
godot --headless --path . -s tests/test_puppet_smoke.gd
godot --headless --path . -s tests/test_fighter_balance.gd
godot --headless --path . -s tests/test_combat_v3.gd
godot --headless --path . -s tests/test_contacts_home.gd
godot --headless --path . -s tests/test_android_contacts.gd
godot --headless --path . -s tests/test_solo_home.gd
godot --headless --path . --quit-after 4
# Real renderer capture for Jade and Oculon visual regression checks
godot --path . -s tests/capture_new_fighters.gd --audio-driver Dummy --rendering-method gl_compatibility
```

The relay probe requires a running `server/headless_server.gd`; its two-client command is in [online_android_test.md](/Users/alejandrocamus/Documents/Faceoff/docs/online_android_test.md).

With Docker running, the real backend probe covers device auth, matchmaking, state replication, speed-based unblocked damage, guard chip damage, and server guard displacement:

```bash
NAKAMA_PORT=7352 godot --headless --path . --script res://tests/nakama_probe.gd
```

See `docs/technology_decisions.md`, `docs/architecture.md`, and `docs/livekit_integration.md` for the boundary between the working local slice and the next native/network milestones.
