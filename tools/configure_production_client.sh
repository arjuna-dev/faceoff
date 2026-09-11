#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
env_file="${FACE_OFF_PRODUCTION_ENV_FILE:-${project_root}/.env.production}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || { echo "--env-file requires a value" >&2; exit 2; }
            env_file="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'USAGE'
Usage: tools/configure_production_client.sh [--env-file .env.production]

Reads NAKAMA_DOMAIN and NAKAMA_SERVER_KEY from the private production
environment file and writes the matching nakamas:// endpoint and client key to
project.godot. The key is required by Nakama authentication and is embedded in
release client builds.
USAGE
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

if [[ ! -f "$env_file" ]]; then
    echo "Production environment file not found: $env_file" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a
: "${NAKAMA_DOMAIN:?NAKAMA_DOMAIN is required}"
: "${NAKAMA_SERVER_KEY:?NAKAMA_SERVER_KEY is required}"
if [[ "$NAKAMA_DOMAIN" == "play.example.com" || "$NAKAMA_DOMAIN" == *"://"* || "$NAKAMA_DOMAIN" == */* || "$NAKAMA_DOMAIN" == *" "* ]]; then
    echo "NAKAMA_DOMAIN must be a real DNS hostname without a scheme or path." >&2
    exit 1
fi
if [[ "$NAKAMA_SERVER_KEY" == dev* || "$NAKAMA_SERVER_KEY" == local-* || "$NAKAMA_SERVER_KEY" == replace-* ]]; then
    echo "NAKAMA_SERVER_KEY still contains a development value." >&2
    exit 1
fi

"${project_root}/tools/configure_online_endpoint.sh" "nakamas://${NAKAMA_DOMAIN}" --server-key "$NAKAMA_SERVER_KEY"
