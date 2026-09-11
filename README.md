# Faceoff

A local 2D arcade fighter with connected pixel-styled characters and manual drag combat. The fighters use deterministic idle and walking loops, with inverse kinematics for posing. There are no rigid bodies or physical joints in gameplay. Jumps follow an authored ballistic arc. Unsupported falls use a deterministic landing and get-up animation. Batyr is a bulky Tatar warrior in fur-trimmed lamellar armor; Kiro is a young bald Buddhist kungfu monk in saffron robes and training wraps. Both use generated, richly shaded arcade sprite artwork mapped onto the live IK rig with overlapping alpha patches. The 1536x1024 source atlas preserves costume and anatomy detail during movement.

## Run

```bash
godot --path .
```

## Controls

- Drag a hand to punch. Drag a foot or knee to kick.
- Drag the torso sideways to walk, or use `A / D` for player one.
- Drag the torso down to crouch. Raise it slowly to straighten the legs for longer reach. Swipe upward rapidly to jump; include sideways movement for a diagonal jump.
- Drag the head forward and down to bow, or backward and down to arch.
- Lifting both feet off the floor triggers a short fall and automatic get-up. One planted foot keeps the fighter supported. Falling disables movement and attacks until recovery, without costing HP.
- Released limbs hold their pose. Walking resumes the leg animation while keeping the arms extended. A foot held at least 52 pixels above the floor instead causes one-foot hopping, which moves at 320 pixels per second so a player can cross the arena with a committed hop. Each completed hop rolls for a fall only after the lifted foot has meaningful clearance: a foot barely above the floor is effectively 0% to 1%, while high clearance, lean, extended arms, and guard strain add controlled risk. A neutral high-leg hop is tuned near the original 1-in-20 fall scale. The HUD shows the current risk.
- Mouse controls either fighter. Touch supports up to five independent drags per fighter, with exclusive pointer ownership across players and cleanup on focus loss. Torso, hand and foot gestures can run concurrently. Mobile touch events are covered by automated control tests; physical-device feel still needs playtesting.
- `Space`: return both fighters to their guard stance.
- `R` or the Rematch button: reset health, positions, poses, and timer.
- `P`: toggle practice with unlimited time and restart.

Each fighter has 100 HP. Damage scales with measured fist, foot or knee speed: hands range from 5.5 to 18 HP and legs from 7.7 to 25.2 HP, with a 15% head-hit bonus. A stroke requires 18 pixels of actual endpoint travel and at least 55 pixels per second. Swept contact catches fast strikes and resolves the first obstacle. Release and drag again, or reverse into a new deliberate stroke to strike again.

Forearms and lower legs physically intercept attacks, reducing the defender's damage to exactly 1 HP, or 1% of the 100 HP bar, regardless of the incoming strike speed. A strike above 850 pixels/second or accumulated guard strain of 32 displaces that limb and opens the guard for 0.45 seconds. Strain recovers at 9 points per second. Body-driven fist contact from manual head or torso movement uses the same damage rules. Idle animation and a stationary held limb do not cause repeated damage.

Zero HP ends the round; the 90-second timer awards the round by remaining health. The new balance and damage values are initial tuning values for playtesting.

This remains a local two-fighter sandbox by default: either fighter is manually controllable, with no automatic enemy attacks. An `ONLINE TEST` field and `JOIN` button can use the included two-slot WebSocket relay or the Nakama backend. Enter `ws://...:9100` for the relay, `nakama://HOST:7350` for local Nakama, or `nakamas://HOST` for a TLS deployment. See [online_android_test.md](docs/online_android_test.md) for both paths.

## Local services

Nakama is wired end to end for local development and production deployment. The official Nakama Godot SDK is vendored in `addons/com.heroiclabs.nakama`, anonymous device authentication creates a session, the matchmaker pairs two players, and `nakama/modules/faceoff_match.lua` owns state validation, guard checks, guard strain and displacement, damage, health, and hit routing. LiveKit remains an optional media service and is not required for combat.

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

The repository includes an `Android Debug` export preset with Internet permission, landscape orientation, arm64 output, nearest filtered textures, and the `com.faceoff.arcade` package id. Godot 4.3 Android export requires JDK 17, the Android SDK, and the matching Godot templates. On this machine the generated and signed APK is [exports/Faceoff-debug.apk](/Users/alejandrocamus/Documents/Faceoff/exports/Faceoff-debug.apk).

To reproduce it after configuring the SDK and debug keystore in Godot Editor Settings, run:

```bash
./tools/export_android.sh
```

The APK is a debug build for sideloaded testing. The production path is checked in as `docker-compose.production.yml`: it keeps PostgreSQL and Nakama on a private Docker network, puts Caddy in front for automatic ACME TLS, and can start Prometheus metrics with `./tools/deploy_nakama.sh --observability`. Follow [production_deployment.md](docs/production_deployment.md) for DNS, firewall, backup, secret rotation, and scaling setup. Follow [android_release.md](docs/android_release.md) to create the upload key, prefill a `nakamas://...` endpoint, export the signed APK/AAB, and finish Google Play App Signing.

## Validation

```bash
godot --headless --path . --editor --quit
godot --headless --path . -s tests/test_core.gd
godot --headless --path . -s tests/test_puppet_smoke.gd
godot --headless --path . -s tests/test_fighter_balance.gd
godot --headless --path . -s tests/test_combat_v3.gd
godot --headless --path . --quit-after 4
```

The relay probe requires a running `server/headless_server.gd`; its two-client command is in [online_android_test.md](/Users/alejandrocamus/Documents/Faceoff/docs/online_android_test.md).

With Docker running, the real backend probe covers device auth, matchmaking, state replication, speed-based unblocked damage, guard chip damage, and server guard displacement:

```bash
NAKAMA_PORT=7352 godot --headless --path . --script res://tests/nakama_probe.gd
```

See `docs/technology_decisions.md`, `docs/architecture.md`, and `docs/livekit_integration.md` for the boundary between the working local slice and the next native/network milestones.
