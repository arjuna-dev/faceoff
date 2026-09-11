# Production Nakama deployment

This repository contains a production-shaped Docker Compose stack for a single host. It runs PostgreSQL and Nakama on a private Docker network and exposes only Caddy on ports 80 and 443. Caddy terminates TLS and forwards both the Nakama HTTP API and realtime WebSocket connection to Nakama.

The public endpoint used by the game is `nakamas://<your-domain>`. The current client maps that scheme to HTTPS for authentication and WSS for the realtime socket, including the default TLS port 443.

## Prepare the host

Use a Linux Docker host with a static public IP. Create a DNS A or AAAA record for the chosen hostname, for example `play.example.com`, pointing to that IP. Do not expose PostgreSQL or Nakama ports directly to the Internet.

Copy the repository to the host, then create fresh secrets:

```bash
./tools/generate_production_secrets.sh \
  --domain play.example.com \
  --email ops@example.com
```

The script writes `.env.production` with mode 600. It refuses to overwrite an existing file unless `--force` is supplied, so a deliberate rotation is explicit. Keep a recovery copy of the database password and all Nakama signing keys in a password manager before starting the service.

The generated `NAKAMA_SERVER_KEY` is intentionally used by the client build as well as the server. It is an application protocol key, not a database password, but changing it requires a new client build. Configure it from the production environment file before exporting Android:

```bash
./tools/configure_production_client.sh --env-file .env.production
```

Start the stack after DNS has propagated:

```bash
./tools/deploy_nakama.sh --env-file .env.production --observability
```

Caddy obtains and renews the certificate automatically through ACME. The client endpoint is:

```text
nakamas://play.example.com
```

The Nakama console is not published by the production compose file. If it is needed for administration, use an SSH tunnel to the private host or add a separately authenticated administration proxy.

## Firewall

Run the policy helper on the Linux host:

```bash
./tools/configure_ufw.sh
sudo ./tools/configure_ufw.sh --apply
```

Only SSH, HTTP, HTTPS, and optional HTTP/3 over UDP are allowed. PostgreSQL, Nakama HTTP, and the Nakama console remain private to Docker.

## Backups

The backup helper creates a compressed PostgreSQL dump, applies the configured retention period, and can copy the result to S3 or Google Cloud Storage when `BACKUP_S3_URI` or `BACKUP_GCS_URI` is set in `.env.production`:

```bash
./tools/backup_nakama_postgres.sh
```

For a systemd host, copy the units from `deploy/systemd/` to `/etc/systemd/system/`, enable the timer, and verify one restore drill before launch:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now faceoff-postgres-backup.timer
systemctl list-timers faceoff-postgres-backup.timer
```

A backup is useful only if it can be restored. Keep at least one off-host copy and periodically restore it into a disposable PostgreSQL instance.

## Monitoring and scaling

Nakama exposes Prometheus metrics on the private Docker port 9100. The optional Prometheus service is started with `--observability` and binds its UI to localhost port 9090. Use an SSH tunnel for access:

```bash
ssh -L 9090:127.0.0.1:9090 user@host
```

Alert on container restarts, Nakama matchmaker failures, socket disconnects, database health, disk usage, and certificate expiry. Caddy and Nakama logs are available with:

```bash
docker compose --env-file .env.production -f docker-compose.production.yml logs -f caddy nakama
```

A second Nakama container can be started with `./tools/deploy_nakama.sh --scale 2`. Each container uses its own Docker hostname as the Nakama node name and shares PostgreSQL. For sustained public traffic, put an external load balancer in front of multiple nodes and use a managed PostgreSQL service or a tested high-availability database plan. Test matchmaking and reconnect behavior after scaling before opening the service to players.

## Secret rotation

Do not rotate Nakama session encryption keys while old sessions need to remain valid. Schedule a maintenance window, stop the game clients, run the generator with `--force`, restart the stack, and require users to authenticate again. Rotate the database password and server key together by updating `.env.production` and restarting Nakama. Never commit `.env.production`, keystores, or backups.

The authoritative match handler follows Nakama's server match lifecycle and keeps health, guard displacement, and damage outcomes on the server. The current prototype still accepts client hit intents after packet validation. Full server-side pose collision simulation and competitive anti-cheat hardening are later production work.
