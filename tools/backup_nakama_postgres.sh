#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose_file="${project_root}/docker-compose.production.yml"
env_file="${FACE_OFF_PRODUCTION_ENV_FILE:-${project_root}/.env.production}"

if [[ ! -f "$env_file" ]]; then
    echo "Production environment file not found: $env_file" >&2
    exit 1
fi
set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

: "${POSTGRES_DB:?POSTGRES_DB is required}"
: "${POSTGRES_USER:?POSTGRES_USER is required}"
: "${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
backup_dir="${BACKUP_DIR:-${project_root}/backups}"
retention_days="${BACKUP_RETENTION_DAYS:-14}"
if ! [[ "$retention_days" =~ ^[0-9]+$ ]]; then
    echo "BACKUP_RETENTION_DAYS must be a non-negative integer." >&2
    exit 1
fi

mkdir -p "$backup_dir"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_path="${backup_dir}/nakama-${timestamp}.dump.gz"
tmp_path="${output_path}.tmp.$$"
trap 'rm -f "$tmp_path"' EXIT

compose=(docker compose --env-file "$env_file" -f "$compose_file")
"${compose[@]}" exec -T -e "PGPASSWORD=${POSTGRES_PASSWORD}" postgres \
    pg_dump -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" --format=custom | gzip -9 > "$tmp_path"
chmod 600 "$tmp_path"
mv "$tmp_path" "$output_path"

find "$backup_dir" -type f -name 'nakama-*.dump.gz' -mtime "+${retention_days}" -delete

if [[ -n "${BACKUP_S3_URI:-}" ]]; then
    command -v aws >/dev/null 2>&1 || { echo "BACKUP_S3_URI is set but aws is not installed." >&2; exit 1; }
    aws s3 cp "$output_path" "${BACKUP_S3_URI%/}/$(basename "$output_path")" --only-show-errors
fi
if [[ -n "${BACKUP_GCS_URI:-}" ]]; then
    command -v gcloud >/dev/null 2>&1 || { echo "BACKUP_GCS_URI is set but gcloud is not installed." >&2; exit 1; }
    gcloud storage cp "$output_path" "${BACKUP_GCS_URI%/}/$(basename "$output_path")"
fi

echo "PostgreSQL backup: $output_path"
