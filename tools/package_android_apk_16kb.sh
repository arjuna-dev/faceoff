#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apk_path="${1:-}"
shift || true
keystore_path=""
key_alias=""
key_password=""

usage() {
  cat <<'USAGE'
Usage: tools/package_android_apk_16kb.sh APK_PATH [options]

Re-aligns native APK entries to 16 KB boundaries and signs the result.
Options:
  --keystore PATH   Signing keystore. Defaults to the Android debug keystore.
  --alias ALIAS     Signing key alias.
  --password VALUE  Signing key password.
USAGE
}

if [[ -z "$apk_path" || "$apk_path" == "-h" || "$apk_path" == "--help" ]]; then
  usage
  exit 2
fi
[[ -f "$apk_path" ]] || { echo "Android APK not found: $apk_path" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keystore)
      [[ $# -ge 2 ]] || { echo "--keystore requires a value" >&2; exit 2; }
      keystore_path="$2"
      shift 2
      ;;
    --alias)
      [[ $# -ge 2 ]] || { echo "--alias requires a value" >&2; exit 2; }
      key_alias="$2"
      shift 2
      ;;
    --password)
      [[ $# -ge 2 ]] || { echo "--password requires a value" >&2; exit 2; }
      key_password="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$keystore_path" && -z "$key_alias" && -z "$key_password" ]]; then
  keystore_path="${FACE_OFF_DEBUG_KEYSTORE:-$HOME/.android/debug.keystore}"
  key_alias="${FACE_OFF_DEBUG_KEY_ALIAS:-androiddebugkey}"
  key_password="${FACE_OFF_DEBUG_KEY_PASSWORD:-android}"
elif [[ -z "$keystore_path" || -z "$key_alias" || -z "$key_password" ]]; then
  echo "--keystore, --alias, and --password must be supplied together." >&2
  exit 2
fi
[[ -f "$keystore_path" ]] || { echo "Signing keystore not found: $keystore_path" >&2; exit 1; }

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -d "$HOME/Library/Android/sdk" ]]; then
  sdk_root="$HOME/Library/Android/sdk"
fi
[[ -d "$sdk_root" ]] || { echo "Android SDK is required for 16 KB APK packaging." >&2; exit 1; }

zipalign_bin=""
apksigner_bin=""
for build_tools_dir in "$sdk_root"/build-tools/*; do
  if [[ -x "$build_tools_dir/zipalign" ]]; then
    zipalign_bin="$build_tools_dir/zipalign"
  fi
  if [[ -x "$build_tools_dir/apksigner" ]]; then
    apksigner_bin="$build_tools_dir/apksigner"
  fi
done
[[ -n "$zipalign_bin" ]] || { echo "zipalign was not found in the Android SDK." >&2; exit 1; }
[[ -n "$apksigner_bin" ]] || { echo "apksigner was not found in the Android SDK." >&2; exit 1; }

package_dir="$(mktemp -d "${TMPDIR:-/tmp}/faceoff-android-16kb-package.XXXXXX")"
trap 'rm -rf "$package_dir"' EXIT
aligned_apk="$package_dir/aligned.apk"
"$zipalign_bin" -P 16 -f 4 "$apk_path" "$aligned_apk"
"$apksigner_bin" sign \
  --ks "$keystore_path" \
  --ks-key-alias "$key_alias" \
  --ks-pass "pass:$key_password" \
  --key-pass "pass:$key_password" \
  "$aligned_apk"
mv "$aligned_apk" "$apk_path"
"$apksigner_bin" verify "$apk_path"
"$project_root/tools/verify_android_16kb.sh" "$apk_path"

echo "Android 16 KB APK packaged: $apk_path"
