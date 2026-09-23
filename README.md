# 007resort-infrastructure

Configuration templates, environment templates, scripts and runbooks for the
**007 Resort & Spa Integrated Facility Operations Platform**.

> Status: **scripts and runbooks written against the documented Laravel layout; dry-run and lint tested, not yet run on
> real Windows Server / VPS hardware.** Runbooks and network design are **DRAFT** pending architecture approval.
>
> **This repository contains NO secrets.** Only placeholders and templates.

The backend is **Laravel (PHP 8.4) + MySQL 8.4 + Redis** running as two nodes from one codebase
(`APP_NODE=local|cloud`, ADR-0012/0013/0014). This repo makes both nodes installable and self-recovering by script.

## Topology summary

### Local node - on-site, Windows Server (SERVER VLAN)

- IIS + PHP FastCGI serving the Laravel API, **MySQL 8.4**, **Redis-compatible** service (Memurai), all bound so that
  only the property VLANs can reach HTTP (80/443) and Reverb (8085); MySQL/Redis are localhost-only.
- **NSSM Windows services** (auto-start, restart on failure): queue worker, sync worker, Reverb WebSocket server;
  Task Scheduler runs `artisan schedule:run` every minute; nightly `mysqldump` to the NAS with retention.
- Authoritative for on-site operations; keeps trading during an internet outage
  (see [internet outage runbook](runbooks/internet-outage.md)). **Sync is outbound-only** to the Cloud node; no inbound internet.

### Cloud node - Ubuntu VPS

- nginx + PHP-FPM 8.4, MySQL 8.4 and Redis on localhost, Supervisor for queue/sync/Reverb, cron scheduler, certbot TLS,
  nginx WebSocket proxy for Reverb, ufw 22/80/443 + fail2ban, atomic release deploys with rollback, nightly encrypted
  off-server backup (rclone) and a monthly automated restore test.

```
 [POS/Tablets/KDS/Phones]                  [Staff workstations]
            | HTTP :80/:443, WS :8085             | admin-web
            v                                     v
   +-------------- SERVER VLAN (Local node, Windows) --------------+
   |  IIS+PHP -> Laravel (APP_NODE=local)   MySQL 8.4   Redis       |
   |  R007-Queue  R007-Sync  R007-Reverb   Task Scheduler   NAS <- nightly backup |
   +---------------------------+------------------------------------+
                               | outbound HTTPS only (sync, heartbeat, off-site backup)
                               v
   +------------------ CLOUD VPS (Ubuntu) ---------------------------+
   |  nginx -> PHP-FPM -> Laravel (APP_NODE=cloud)  MySQL  Redis       |
   |  Supervisor: queue, sync, reverb    cron: schedule:run             |
   +-------------------------------------------------------------------+
```

## Contents

| Path | What |
| --- | --- |
| [`scripts/windows/`](scripts/windows/) | **Local node**: `install.ps1`, `update.ps1` (deploy/rollback), `status.ps1`, `uninstall.ps1`, `backup-mysql.ps1`, `restore-mysql.ps1`, `cleanup-logs.ps1` |
| [`scripts/dev/local-node.sh`](scripts/dev/local-node.sh) | **Demo Local node on macOS/Linux**: `up` / `stop` / `status` / `logs` / `url` (serve on 0.0.0.0:8080, queue, scheduler, Reverb, LAN URL + QR) |
| [`scripts/vps/`](scripts/vps/) | **Cloud node**: `bootstrap.sh`, `provision-stack.sh`, `deploy.sh` (installed as `r007-deploy`), `backup.sh`, `restore-test.sh` |
| [`.github/workflow-templates/`](.github/workflow-templates/) | Templates to copy into `007resort-api`: build release packages, SSH deploy to the VPS (secrets never committed) |
| [`compose/dev/`](compose/dev/) | Docker Compose for local development: MySQL 8.4, Redis 7, Mailpit, optional Reverb (`--profile reverb`) |
| [`env/`](env/) | `local.env.example`, `cloud.env.example` - Laravel `.env` templates (placeholders only) |
| [`mysql/conf.d/r007.cnf`](mysql/conf.d/r007.cnf) | Baseline MySQL settings: utf8mb4, UTC, strict sql_mode, InnoDB, ROW binlog for PITR |
| [`network/`](network/) | Logical network segmentation (VLANs, allowed flows, Wi-Fi, DHCP) |
| [`runbooks/`](runbooks/) | [Server installation](runbooks/server-installation.md), [backup & restore](runbooks/backup-and-restore.md), [internet outage](runbooks/internet-outage.md), [device onboarding](runbooks/device-registration.md), [node credential rotation](runbooks/node-credential-rotation.md), [incident response](runbooks/incident-response.md), [demo-day checklist](runbooks/demo-day-checklist.md) |

## Quick start

```bash
# Demo Local node on a Mac/Linux laptop (Homebrew MySQL 8.4 + Redis running; 007resort-api checked out next to this repo)
scripts/dev/local-node.sh up          # migrate + demo seed + serve/queue/scheduler/Reverb, prints the LAN URL and QR
scripts/dev/local-node.sh status ; scripts/dev/local-node.sh stop

# Dependencies in Docker instead (MySQL 8.4 + Redis + Mailpit [+ Reverb])
cp compose/dev/.env.example compose/dev/.env
docker compose -f compose/dev/docker-compose.yml --env-file compose/dev/.env up -d
```

Production installs: see [server installation](runbooks/server-installation.md). Every script has `--dry-run` / `-DryRun`.

## Rules

- **No secrets committed** - ever. Passwords, keys, tokens, certificates and real `.env` files
  are git-ignored and scanned for by gitleaks in CI.
- Secrets are **generated on the server** or typed at a secure prompt, and live only in the protected `.env` / option files
  (Windows ACL Administrators/SYSTEM + service accounts; Linux mode 600) - never in scripts, parameters, logs or CI output.
- Only the Laravel API (`007resort-api`) owns and migrates the MySQL schema; PHP web apps call the API.
- All timestamps are stored in **UTC**; money is stored/transported as exact decimals.

## CI

`.github/workflows/ci.yml`: docker compose validation (+ `reverb` profile), yamllint + actionlint (workflows **and** templates),
shellcheck + `bash -n` + dry-run smoke tests for the bash scripts, PSScriptAnalyzer (errors and warnings, see
`PSScriptAnalyzerSettings.psd1`) + a PowerShell dry-run smoke test, gitleaks secret scan.

## Related

- Architecture, ADRs and domain docs: [prinzderick/007resort-docs](https://github.com/prinzderick/007resort-docs)
- [prinzderick/007resort-api](https://github.com/prinzderick/007resort-api),
  [prinzderick/007resort-admin-web](https://github.com/prinzderick/007resort-admin-web),
  [prinzderick/007resort-booking-web](https://github.com/prinzderick/007resort-booking-web)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
