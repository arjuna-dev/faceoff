#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
release_env="${FACE_OFF_RELEASE_ENV_FILE:-${project_root}/keystores/faceoff-upload.env}"
if [[ ! -f "$release_env" ]]; then
    echo "Release credentials not found: $release_env" >&2
    echo "Run tools/generate_release_keystore.sh first." >&2
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
keytool_bin="${KEYTOOL_BIN:-$(command -v keytool || true)}"
[[ -x "$keytool_bin" ]] || { echo "keytool is required." >&2; exit 1; }
"$keytool_bin" -list -v -keystore "$keystore_path" -alias "$FACE_OFF_RELEASE_KEY_ALIAS" -storepass "$FACE_OFF_RELEASE_PASSWORD" |
    awk -F': ' '/Owner:|SHA256:|SHA1:/ {print}'
