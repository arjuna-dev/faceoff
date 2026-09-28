#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
godot_android_version="${GODOT_ANDROID_RUNTIME_VERSION:-4.5.2}"
release_env="${FACE_OFF_RELEASE_ENV_FILE:-${project_root}/keystores/faceoff-upload.env}"
mode="both"
export_dir="${FACE_OFF_EXPORT_DIR:-${project_root}/exports}"
endpoint=""
server_key="${FACE_OFF_NAKAMA_SERVER_KEY:-}"

usage() {
    cat <<'USAGE'
Usage: tools/export_android_release.sh [--apk-only|--aab-only] [--output-dir PATH] [--endpoint nakamas://HOST] [--server-key KEY]

Requires the ignored keystore environment file created by
tools/generate_release_keystore.sh. The AAB preset uses a Gradle build as
required for Google Play uploads. A Nakama endpoint must be supplied here,
through FACE_OFF_ONLINE_ENDPOINT, or already configured in project.godot.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apk-only)
            mode="apk"
            shift
            ;;
        --aab-only)
            mode="aab"
            shift
            ;;
        --output-dir)
            [[ $# -ge 2 ]] || { echo "--output-dir requires a value" >&2; exit 2; }
            export_dir="$2"
            shift 2
            ;;
        --endpoint)
            [[ $# -ge 2 ]] || { echo "--endpoint requires a value" >&2; exit 2; }
            endpoint="$2"
            shift 2
            ;;
        --server-key)
            [[ $# -ge 2 ]] || { echo "--server-key requires a value" >&2; exit 2; }
            server_key="$2"
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

configured_endpoint="$(sed -n 's/^online_endpoint="\([^"]*\)"/\1/p' "${project_root}/project.godot" | head -n 1)"
configured_server_key="$(sed -n 's/^online_server_key="\([^"]*\)"/\1/p' "${project_root}/project.godot" | head -n 1)"
endpoint_explicit=0
if [[ -n "$endpoint" ]]; then
    endpoint_explicit=1
elif [[ -n "${FACE_OFF_ONLINE_ENDPOINT:-}" ]]; then
    endpoint="${FACE_OFF_ONLINE_ENDPOINT}"
    endpoint_explicit=1
else
    endpoint="$configured_endpoint"
fi
if [[ -z "$server_key" ]]; then
    server_key="$configured_server_key"
fi
if [[ -z "$endpoint" ]]; then
    echo "A Nakama endpoint is required. Pass --endpoint nakamas://HOST or run tools/configure_production_client.sh first." >&2
    exit 1
fi
if [[ "$endpoint" != nakamas://* ]]; then
    echo "The release endpoint must start with nakamas:// for a TLS production build." >&2
    exit 1
fi
if [[ "$endpoint" == nakamas://* && -z "$server_key" ]]; then
    echo "A Nakama server key is required for nakamas:// releases. Pass --server-key or configure project.godot first." >&2
    exit 1
fi
if [[ "$endpoint_explicit" -eq 1 ]]; then
    if [[ -n "$server_key" ]]; then
        "${project_root}/tools/configure_online_endpoint.sh" "$endpoint" --server-key "$server_key"
    else
        "${project_root}/tools/configure_online_endpoint.sh" "$endpoint"
    fi
fi
if [[ ! -f "$release_env" ]]; then
    echo "Release credentials not found: $release_env" >&2
    echo "Run tools/generate_release_keystore.sh first, or set FACE_OFF_RELEASE_ENV_FILE." >&2
    exit 1
fi

set -a
# shellcheck disable=SC1090
source "$release_env"
set +a
: "${FACE_OFF_RELEASE_KEYSTORE:?FACE_OFF_RELEASE_KEYSTORE is required}"
: "${FACE_OFF_RELEASE_KEY_ALIAS:?FACE_OFF_RELEASE_KEY_ALIAS is required}"
: "${FACE_OFF_RELEASE_PASSWORD:?FACE_OFF_RELEASE_PASSWORD is required}"
keystore_path="$FACE_OFF_RELEASE_KEYSTORE"
if [[ "$keystore_path" != /* ]]; then
    keystore_path="${project_root}/${keystore_path}"
fi
[[ -f "$keystore_path" ]] || { echo "Release keystore not found: $keystore_path" >&2; exit 1; }
export GODOT_ANDROID_KEYSTORE_RELEASE_PATH="$keystore_path"
export GODOT_ANDROID_KEYSTORE_RELEASE_USER="$FACE_OFF_RELEASE_KEY_ALIAS"
export GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD="$FACE_OFF_RELEASE_PASSWORD"

mkdir -p "$export_dir"
export_dir="$(cd "$export_dir" && pwd)"
cd "$project_root"
"${project_root}/tools/prepare_android.sh"

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

package_release_artifact() {
    local output_path="$1"
    local assemble_task="$2"
    local output_dir="$(cd "$(dirname "$output_path")" && pwd)"
    local output_file="$(basename "$output_path")"
    local export_format="apk"
    if [[ "$assemble_task" == "bundleStandardRelease" ]]; then
        export_format="aab"
    fi
    local gradle_props=(
        "-Pexport_package_name=com.faceoff.arcade"
        "-Pexport_version_code=1"
        "-Pexport_version_name=0.1.0"
        "-Pexport_version_min_sdk=24"
        "-Pgodot_editor_version=${godot_android_version}.stable"
        "-Pexport_edition=standard"
        "-Pexport_build_type=release"
        "-Pexport_format=$export_format"
        "-Pexport_enabled_abis=arm64-v8a"
        "-Pexport_path=$output_dir"
        "-Pexport_filename=$output_file"
        "-Pperform_signing=true"
        "-Pperform_zipalign=true"
        "-Prelease_keystore_file=$keystore_path"
        "-Prelease_keystore_alias=$FACE_OFF_RELEASE_KEY_ALIAS"
        "-Prelease_keystore_password=$FACE_OFF_RELEASE_PASSWORD"
    )
    "${project_root}/tools/patch_android_invite_manifest.sh" release
    "${project_root}/android/build/gradlew" -p "${project_root}/android/build" "$assemble_task" --no-daemon "${gradle_props[@]}"
    "${project_root}/android/build/gradlew" -p "${project_root}/android/build" copyAndRenameBinary --no-daemon "${gradle_props[@]}"
    if [[ "$export_format" == "apk" ]]; then
        "${project_root}/tools/package_android_apk_16kb.sh" "$output_path" \
            --keystore "$keystore_path" \
            --alias "$FACE_OFF_RELEASE_KEY_ALIAS" \
            --password "$FACE_OFF_RELEASE_PASSWORD"
    else
        "${project_root}/tools/verify_android_16kb.sh" "$output_path"
    fi
}

if [[ "$mode" == "apk" || "$mode" == "both" ]]; then
    apk_path="${export_dir}/Faceoff-release.apk"
    "$godot_bin" --headless --path . --export-release "Android Release APK" "$apk_path"
    package_release_artifact "$apk_path" assembleStandardRelease
    for build_tools in "$sdk_root"/build-tools/*; do
        if [[ -x "$build_tools/apksigner" ]]; then
            "$build_tools/apksigner" verify "$apk_path"
            break
        fi
    done
    echo "Android release APK: $apk_path"
fi
if [[ "$mode" == "aab" || "$mode" == "both" ]]; then
    aab_path="${export_dir}/Faceoff-release.aab"
    if [[ ! -f "${project_root}/android/build/build.gradle" ]]; then
        "$godot_bin" --headless --path . --install-android-build-template --export-release "Android Release AAB" "$aab_path"
    else
        "$godot_bin" --headless --path . --export-release "Android Release AAB" "$aab_path"
    fi
    package_release_artifact "$aab_path" bundleStandardRelease
    jarsigner_bin="${JAVA_HOME}/bin/jarsigner"
    if [[ -x "$jarsigner_bin" ]]; then
        "$jarsigner_bin" -verify "$aab_path" >/dev/null 2>&1
    fi
    echo "Android release AAB: $aab_path"
fi
