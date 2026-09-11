#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${project_root}/docker-compose.production.yml"
env_file="${FACE_OFF_PRODUCTION_ENV_FILE:-${project_root}/.env.production}"
domain="${NAKAMA_DOMAIN:-}"
email="${ACME_EMAIL:-}"
observability=0
scale=""
no_up=0

usage() {
    cat <<'USAGE'
Usage: tools/deploy_nakama.sh --domain play.example.com --email ops@example.com [options]

Run this on the Docker host after DNS points the hostname to the host.
Options:
  --env-file PATH       Use a different production environment file.
  --domain HOST         Public TLS hostname. Required on first run.
  --email ADDRESS       ACME certificate notification address. Required on first run.
  --observability       Start the local Prometheus metrics service.
  --scale N             Start N Nakama containers on the shared database.
  --no-up               Validate configuration without starting services.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --env-file)
            [[ $# -ge 2 ]] || { echo "--env-file requires a value" >&2; exit 2; }
            env_file="$2"
            shift 2
            ;;
        --domain)
            [[ $# -ge 2 ]] || { echo "--domain requires a value" >&2; exit 2; }
            domain="$2"
            shift 2
            ;;
        --email)
            [[ $# -ge 2 ]] || { echo "--email requires a value" >&2; exit 2; }
            email="$2"
            shift 2
            ;;
        --observability)
            observability=1
            shift
            ;;
        --scale)
            [[ $# -ge 2 ]] || { echo "--scale requires a value" >&2; exit 2; }
            scale="$2"
            shift 2
            ;;
        --no-up)
            no_up=1
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

if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required." >&2
    exit 1
fi
if [[ ! -f "$env_file" ]]; then
    if [[ -z "$domain" || -z "$email" ]]; then
        echo "No $env_file found. Supply --domain and --email so production secrets can be generated." >&2
        exit 1
    fi
    NAKAMA_DOMAIN="$domain" ACME_EMAIL="$email" FACE_OFF_PRODUCTION_ENV_FILE="$env_file" "${project_root}/tools/generate_production_secrets.sh"
fi

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

domain="${NAKAMA_DOMAIN:-}"
email="${ACME_EMAIL:-}"
if [[ -z "$domain" || "$domain" == "play.example.com" || "$domain" == *"://"* || "$domain" == */* || "$domain" == *" "* ]]; then
    echo "NAKAMA_DOMAIN must be a real DNS hostname without a scheme or path." >&2
    exit 1
fi
if [[ -z "$email" || "$email" == "ops@example.com" || "$email" != *@*.* ]]; then
    echo "ACME_EMAIL must be a real email address." >&2
    exit 1
fi
for required in POSTGRES_PASSWORD NAKAMA_SERVER_KEY NAKAMA_SESSION_ENCRYPTION_KEY NAKAMA_REFRESH_ENCRYPTION_KEY NAKAMA_RUNTIME_HTTP_KEY NAKAMA_CONSOLE_SIGNING_KEY NAKAMA_CONSOLE_PASSWORD; do
    value="${!required:-}"
    if [[ -z "$value" || "$value" == replace-* || "$value" == local-* || "$value" == dev* ]]; then
        echo "$required is missing or still contains a development value." >&2
        exit 1
    fi
done
if [[ -n "${NAKAMA_NODE_NAME:-}" && "${#NAKAMA_NODE_NAME}" -gt 8 ]]; then
    echo "NAKAMA_NODE_NAME must be 8 characters or fewer so scaled nodes retain unique suffixes." >&2
    exit 1
fi

compose=(docker compose --env-file "$env_file" -f "$compose_file")
if [[ "$observability" -eq 1 ]]; then
    compose+=(--profile observability)
fi
"${compose[@]}" config --quiet
echo "Production compose configuration is valid for nakamas://${domain}."
if [[ "$no_up" -eq 1 ]]; then
    exit 0
fi

services=(postgres nakama caddy)
if [[ "$observability" -eq 1 ]]; then
    services+=(prometheus)
fi
if [[ -n "$scale" ]]; then
    if ! [[ "$scale" =~ ^[1-9][0-9]*$ ]]; then
        echo "--scale must be a positive integer." >&2
        exit 2
    fi
    "${compose[@]}" up -d --scale "nakama=${scale}" "${services[@]}"
else
    "${compose[@]}" up -d "${services[@]}"
fi
"${compose[@]}" ps
echo "Nakama endpoint: nakamas://${domain}"
echo "Configure the client with: ./tools/configure_online_endpoint.sh nakamas://${domain}"
echo "The DNS A/AAAA record and host firewall must allow TCP 80 and 443 before Caddy can obtain its certificate."
