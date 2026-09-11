#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
godot_bin="${GODOT_BIN:-godot}"
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
cd "$project_root"
if [[ "$mode" == "apk" || "$mode" == "both" ]]; then
    apk_path="${export_dir}/Faceoff-release.apk"
    "$godot_bin" --headless --path . --export-release "Android Release APK" "$apk_path"
    sdk_root="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
    if [[ -n "$sdk_root" ]]; then
        for build_tools in "$sdk_root"/build-tools/*; do
            if [[ -x "$build_tools/apksigner" ]]; then
                "$build_tools/apksigner" verify "$apk_path"
                break
            fi
        done
    fi
    echo "Android release APK: $apk_path"
fi
if [[ "$mode" == "aab" || "$mode" == "both" ]]; then
    aab_path="${export_dir}/Faceoff-release.aab"
    if [[ ! -f "${project_root}/android/build/build.gradle" ]]; then
        "$godot_bin" --headless --path . --install-android-build-template --export-release "Android Release AAB" "$aab_path"
    else
        "$godot_bin" --headless --path . --export-release "Android Release AAB" "$aab_path"
    fi
    jarsigner_bin="${JAVA_HOME}/bin/jarsigner"
    if [[ -x "$jarsigner_bin" ]]; then
        "$jarsigner_bin" -verify "$aab_path" >/dev/null 2>&1
    fi
    echo "Android release AAB: $aab_path"
fi
