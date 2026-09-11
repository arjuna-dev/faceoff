#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
output_path="${1:-${project_root}/exports/Faceoff-debug.apk}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: tools/export_android.sh [OUTPUT_APK]

Exports the signed Android debug APK using the Android Debug preset.
EOF
  exit 0
fi

is_jdk17() {
  [[ -x "$1/bin/java" ]] && "$1/bin/java" -version 2>&1 | grep -Eq 'version "17([.\"])'
}

if ! is_jdk17 "${JAVA_HOME:-}"; then
  for candidate in \
    "/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/usr/local/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home" \
    "/opt/java/openjdk" \
    "/usr/lib/jvm/java-17-openjdk" \
    /usr/lib/jvm/java-17-openjdk-*; do
    if is_jdk17 "$candidate"; then
      export JAVA_HOME="$candidate"
      break
    fi
  done
fi

if ! is_jdk17 "${JAVA_HOME:-}"; then
  echo "JDK 17 is required. Set JAVA_HOME to an installed JDK 17 before exporting." >&2
  exit 1
fi

mkdir -p "$(dirname "$output_path")"
cd "$project_root"
"$godot_bin" --headless --path . --export-debug "Android Debug" "$output_path"

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -d "$(cd ~ && pwd)/Library/Android/sdk" ]]; then
  sdk_root="$(cd ~ && pwd)/Library/Android/sdk"
fi
if [[ -n "$sdk_root" && -x "$sdk_root/build-tools/36.0.0/apksigner" ]]; then
  "$sdk_root/build-tools/36.0.0/apksigner" verify "$output_path"
fi

echo "Android debug APK: $output_path"
