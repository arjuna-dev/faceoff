#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
godot_android_version="${GODOT_ANDROID_RUNTIME_VERSION:-4.5.2}"
output_path="${1:-${project_root}/exports/Faceoff-debug.apk}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: tools/export_android.sh [OUTPUT_APK]

Exports the signed Android debug APK using the Android Debug preset.
EOF
  exit 0
fi

godot_version_output=""
if ! godot_version_output="$("$godot_bin" --version 2>&1)"; then
  echo "Unable to run the Godot editor at '$godot_bin'." >&2
  echo "$godot_version_output" >&2
  exit 1
fi
godot_binary_version="$(printf '%s\n' "$godot_version_output" | awk 'NR == 1 { split($1, parts, /\./); if (parts[3] ~ /^[0-9]+$/) print parts[1] "." parts[2] "." parts[3]; else print parts[1] "." parts[2] }')"
if [[ "$godot_binary_version" != "$godot_android_version" ]]; then
  echo "Godot ${godot_android_version} is required for Android 16 KB exports; found ${godot_binary_version:-unknown}." >&2
  echo "Set GODOT_BIN to the matching Godot ${godot_android_version} editor." >&2
  matching_editor="/Applications/Godot-${godot_android_version}.app/Contents/MacOS/Godot"
  if [[ -x "$matching_editor" ]]; then
    echo "A matching editor was found at '$matching_editor'." >&2
  fi
  exit 1
fi
export GODOT_ANDROID_TEMPLATE_VERSION="$godot_android_version"
export FACEOFF_ANDROID_ABIS="${FACEOFF_ANDROID_ABIS:-arm64-v8a}"

"${RIG_PYTHON:-python3}" "$project_root/tools/verify_rigged_assets.py" --hash-only --require-review

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
output_dir="$(cd "$(dirname "$output_path")" && pwd)"
output_file="$(basename "$output_path")"
output_path="$output_dir/$output_file"
cd "$project_root"
"${project_root}/tools/prepare_android.sh"
"$godot_bin" --headless --path . --export-debug "Android Debug" "$output_path"

# Godot regenerates the debug variant manifest during export. Patch the
# generated variant, then package once more with the same Gradle project so
# the invite deep link is present in the APK itself.
"${project_root}/tools/patch_android_invite_manifest.sh" debug

sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
if [[ -z "$sdk_root" && -d "$(cd ~ && pwd)/Library/Android/sdk" ]]; then
  sdk_root="$(cd ~ && pwd)/Library/Android/sdk"
fi
if [[ -z "$sdk_root" || ! -d "$sdk_root" ]]; then
  echo "Android SDK is required for the final Gradle packaging step." >&2
  exit 1
fi
export ANDROID_SDK_ROOT="$sdk_root"
export ANDROID_HOME="$sdk_root"
gradle_props=(
  "-Pexport_package_name=com.faceoff.arcade"
  "-Pexport_version_code=1"
  "-Pexport_version_name=0.1.0"
  "-Pexport_version_min_sdk=24"
  "-Pgodot_editor_version=${godot_android_version}.stable"
  "-Pexport_edition=standard"
  "-Pexport_build_type=debug"
  "-Pexport_format=apk"
  "-Pexport_enabled_abis=arm64-v8a"
  "-Pexport_path=$output_dir"
  "-Pexport_filename=$output_file"
  "-Pperform_signing=true"
  "-Pperform_zipalign=true"
)
"${project_root}/android/build/gradlew" -p "${project_root}/android/build" assembleStandardDebug --no-daemon "${gradle_props[@]}"
"${project_root}/android/build/gradlew" -p "${project_root}/android/build" copyAndRenameBinary --no-daemon "${gradle_props[@]}"
"${project_root}/tools/package_android_apk_16kb.sh" "$output_path"

echo "Android debug APK: $output_path"
