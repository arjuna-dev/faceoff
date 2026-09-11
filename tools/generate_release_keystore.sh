#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
keystore_path="${project_root}/keystores/faceoff-upload.keystore"
env_path="${project_root}/keystores/faceoff-upload.env"
alias_name="faceoff-upload"
key_name="Faceoff Upload Key"
force=0

usage() {
    cat <<'USAGE'
Usage: tools/generate_release_keystore.sh [options]

Creates a local Android upload keystore and a chmod 600 environment file used
by tools/export_android_release.sh. The keystore is ignored by git.
Options:
  --output PATH       Keystore path.
  --env-file PATH     Credential environment path.
  --alias NAME        Key alias (default: faceoff-upload).
  --name NAME         Certificate common name.
  --force             Replace an existing keystore and credential file.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || { echo "--output requires a value" >&2; exit 2; }
            keystore_path="$2"
            shift 2
            ;;
        --env-file)
            [[ $# -ge 2 ]] || { echo "--env-file requires a value" >&2; exit 2; }
            env_path="$2"
            shift 2
            ;;
        --alias)
            [[ $# -ge 2 ]] || { echo "--alias requires a value" >&2; exit 2; }
            alias_name="$2"
            shift 2
            ;;
        --name)
            [[ $# -ge 2 ]] || { echo "--name requires a value" >&2; exit 2; }
            key_name="$2"
            shift 2
            ;;
        --force)
            force=1
            shift
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

if [[ -e "$keystore_path" || -e "$env_path" ]] && [[ "$force" -ne 1 ]]; then
    echo "A release keystore or credential file already exists. Use --force only to replace both intentionally." >&2
    exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl is required to create a random keystore password." >&2
    exit 1
fi
keytool_bin="${KEYTOOL_BIN:-}"
if [[ -z "$keytool_bin" && -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/keytool" ]]; then
    keytool_bin="${JAVA_HOME}/bin/keytool"
fi
if [[ -z "$keytool_bin" ]]; then
    keytool_bin="$(command -v keytool || true)"
fi
[[ -n "$keytool_bin" && -x "$keytool_bin" ]] || { echo "keytool is required." >&2; exit 1; }

store_password="${FACE_OFF_RELEASE_PASSWORD:-$(openssl rand -hex 24)}"
mkdir -p "$(dirname "$keystore_path")" "$(dirname "$env_path")"
umask 077
rm -f "$keystore_path" "$env_path"
"$keytool_bin" -genkeypair -noprompt \
    -keystore "$keystore_path" \
    -storetype PKCS12 \
    -storepass "$store_password" \
    -keypass "$store_password" \
    -alias "$alias_name" \
    -keyalg RSA \
    -keysize 4096 \
    -validity 10000 \
    -dname "CN=${key_name}, OU=Mobile, O=Faceoff, L=Berlin, ST=Berlin, C=DE"

relative_keystore="${keystore_path#"${project_root}/"}"
cat > "$env_path" <<EOF_ENV
# Private upload-key credentials. Keep this file outside version control.
FACE_OFF_RELEASE_KEYSTORE=$relative_keystore
FACE_OFF_RELEASE_KEY_ALIAS=$alias_name
FACE_OFF_RELEASE_PASSWORD=$store_password
EOF_ENV
chmod 600 "$keystore_path" "$env_path"

echo "Created Android upload keystore: $keystore_path"
echo "Credentials saved to: $env_path"
echo "Back up both files securely. Google Play App Signing can protect the app signing key while this key remains the upload key."
