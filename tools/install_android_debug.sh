#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
adb_bin="${ADB_BIN:-adb}"
apk_path="${1:-${project_root}/exports/Faceoff-debug.apk}"
replace_on_mismatch=0

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
Usage: tools/install_android_debug.sh [APK_PATH] [--replace-on-signature-mismatch]

Installs and launches the Faceoff Android debug APK. The normal install keeps
the existing app data. If the installed app was signed with another key, pass
--replace-on-signature-mismatch to remove that package and install this APK.
That replacement deletes the app's local data.
USAGE
  exit 0
fi

if [[ "${1:-}" == "--replace-on-signature-mismatch" ]]; then
  apk_path="${project_root}/exports/Faceoff-debug.apk"
fi

if [[ "${2:-}" == "--replace-on-signature-mismatch" ]]; then
  replace_on_mismatch=1
elif [[ "${1:-}" == "--replace-on-signature-mismatch" ]]; then
  replace_on_mismatch=1
fi

package_name="${FACE_OFF_ANDROID_PACKAGE:-com.faceoff.arcade}"
if ! command -v "$adb_bin" >/dev/null 2>&1; then
  echo "adb is required. Connect an Android device and install Android Platform Tools." >&2
  exit 1
fi
if [[ ! -f "$apk_path" ]]; then
  echo "APK not found: $apk_path" >&2
  exit 1
fi

adb_run() {
  if [[ -n "${ANDROID_SERIAL:-}" ]]; then
    "$adb_bin" -s "$ANDROID_SERIAL" "$@"
  else
    "$adb_bin" "$@"
  fi
}

device_state="$(adb_run get-state 2>/dev/null || true)"
if [[ "$device_state" != "device" ]]; then
  echo "No ready Android device found. Check USB debugging and run: $adb_bin devices" >&2
  exit 1
fi

install_output=""
install_status=0
set +e
install_output="$(adb_run install -r "$apk_path" 2>&1)"
install_status=$?
set -e
printf '%s\n' "$install_output"

if [[ "$install_status" -ne 0 && "$install_output" == *"INSTALL_FAILED_UPDATE_INCOMPATIBLE"* ]]; then
  if [[ "$replace_on_mismatch" -ne 1 ]]; then
    echo "The installed package uses another signing key and was left untouched." >&2
    echo "Rerun with --replace-on-signature-mismatch to reinstall and delete its local data." >&2
    exit 1
  fi
  echo "Replacing the differently signed package. Its local app data will be deleted." >&2
  adb_run uninstall "$package_name"
  adb_run install "$apk_path"
elif [[ "$install_status" -ne 0 ]]; then
  exit "$install_status"
fi

adb_run shell am force-stop "$package_name"
adb_run shell monkey -p "$package_name" 1
