# Two-player Android test

Faceoff has two network transports in the game scene:

- `nakama://HOST:7350` uses the real Nakama client, anonymous device authentication, matchmaker, and the authoritative Lua match handler.
- `ws://HOST:9100` uses the small Godot relay. It is useful when tuning locally, but it is not the public anti-cheat boundary.

## Nakama local test

Start PostgreSQL and Nakama from the project root:

```bash
docker compose -f docker_compose.yml up -d postgres nakama
```

The compose file mounts `nakama/modules` into Nakama's runtime path. The logs should include `Lua runtime modules loaded`, `faceoff_match.lua`, and `Startup done`.

If another local stack already owns ports 7350 and 7351, map different host ports:

```bash
NAKAMA_PORT=7352 NAKAMA_CONSOLE_PORT=7353 docker compose -f docker_compose.yml up -d postgres nakama
```

Enter `nakama://127.0.0.1:7352` in the game in that case. On two Android devices, replace `127.0.0.1` with the computer's LAN address. The first two authenticated devices are matched into one authoritative `faceoff_match`. Each device owns its local drag input and sends validated state and hit intents. The Lua match validates the packet, maintains health, checks forearm and shin shields, applies chip damage, accumulates guard strain, displaces a shield after a strong or repeated blow, and routes authoritative results and snapshots to both clients.

Each client includes the attacking limb and measured endpoint speed. Nakama recomputes the impact damage from that speed for current clients, while older packets without the optional limb field remain capped and compatible with the probe and relay.

The headless integration probe exercises this path without a phone:

```bash
NAKAMA_PORT=7352 godot --headless --path . --script res://tests/nakama_probe.gd
```

It should print `NAKAMA PROBE PASS` and include `guard_chip=1.0`.

## Relay fallback

Run the relay on a computer reachable from both devices:

```bash
FACE_OFF_SERVER_PORT=9100 godot --headless --path . --script res://server/headless_server.gd
```

For a same Wi-Fi test, find the computer's LAN address. On macOS this is usually:

```bash
ipconfig getifaddr en0
```

Allow TCP port `9100` through the computer firewall. Enter `ws://COMPUTER_LAN_IP:9100` in the game and tap `JOIN` on both devices. A quick desktop relay smoke test is:

```bash
godot --headless --path . --script res://tests/online_probe.gd -- --url=ws://127.0.0.1:9100 --label=one --duration=8
godot --headless --path . --script res://tests/online_probe.gd -- --url=ws://127.0.0.1:9100 --label=two --duration=8
```

## Android export

The checked-in `export_presets.cfg` contains the `Android Debug` preset with Internet permission and arm64 output. Configure Godot 4.3 to use JDK 17, the Android SDK, and the installed 4.3 export templates, then run:

```bash
./tools/export_android.sh
```

Install `exports/Faceoff-debug.apk` on both devices. `adb devices` must show a device before using one-click deployment. The current workspace has a valid signed debug APK, but no Android device is attached for an install or touch-feel check.

## Production deployment checklist

Before public online play, follow [production_deployment.md](production_deployment.md) to deploy Nakama and PostgreSQL, put the realtime endpoint behind TLS, replace `devserverkey` and the insecure local secrets, add monitoring and backups, and configure a release keystore. The mobile client should use `nakamas://...` for the HTTPS/WSS endpoint. The repository includes the production compose stack and release export scripts; Google Play account setup and the public DNS/host are still external operations.
