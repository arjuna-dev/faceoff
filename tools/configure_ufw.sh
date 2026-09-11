#!/usr/bin/env bash
set -euo pipefail

apply=0
if [[ "${1:-}" == "--apply" ]]; then
    apply=1
elif [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    cat <<'USAGE'
Usage: tools/configure_ufw.sh [--apply]

Without --apply, prints the production firewall policy. With --apply, runs it
on a Linux host using UFW. SSH remains open so the operator is not locked out.
USAGE
    exit 0
elif [[ $# -gt 0 ]]; then
    echo "Unknown argument: $1" >&2
    exit 2
fi

if [[ "$apply" -eq 1 ]]; then
    [[ "$(id -u)" -eq 0 ]] || { echo "Run --apply as root on the production host." >&2; exit 1; }
    command -v ufw >/dev/null 2>&1 || { echo "UFW is not installed on this host." >&2; exit 1; }
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp comment 'SSH administration'
    ufw allow 80/tcp comment 'ACME HTTP and redirect'
    ufw allow 443/tcp comment 'Nakama HTTPS and WebSocket TLS'
    ufw allow 443/udp comment 'Caddy HTTP/3'
    ufw delete allow 5432/tcp >/dev/null 2>&1 || true
    ufw delete allow 7350/tcp >/dev/null 2>&1 || true
    ufw delete allow 7351/tcp >/dev/null 2>&1 || true
    ufw --force enable
    ufw status verbose
    exit 0
fi

cat <<'POLICY'
UFW production policy:
  allow 22/tcp   SSH administration
  allow 80/tcp   ACME HTTP and redirect
  allow 443/tcp  Nakama HTTPS and WebSocket TLS
  allow 443/udp  Caddy HTTP/3
  deny  5432/tcp PostgreSQL is private to Docker
  deny  7350/tcp Nakama is behind Caddy
  deny  7351/tcp Nakama console is private to Docker

Run this script with --apply on the Linux production host.
POLICY
