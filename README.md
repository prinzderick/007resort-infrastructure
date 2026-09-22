# otueke-infrastructure

Configuration templates, environment templates, scripts and runbooks for the
**Otueke Integrated Facility Operations Platform**.

> Status: **Phase 0 - scaffolding.** Runbooks and network design are **DRAFT** pending
> architecture approval.
>
> **This repository contains NO secrets.** Only placeholders and templates.

## Topology summary

### On-site (local-first)

- **Windows local application server** (SERVER VLAN):
  - **Otueke API** (ASP.NET Core) running as a Windows service - the single "brain" and the
    only owner of the MySQL schema; authoritative for on-site operations.
  - **MySQL 8.4** (local database, nightly full backup + binlog PITR).
  - **Redis** (optional; caching / real-time fan-out).
  - **otueke-admin-web** (local management UI).
- **LAN / Wi-Fi clients** (POS/OPERATIONS and STAFF VLANs): 10 POS terminals, 18 tablets,
  4 KDS screens, back-office workstations, receipt/kitchen printers, scanners.
- Keeps trading during an internet outage (see [internet outage runbook](runbooks/internet-outage.md)).

### Cloud

- **Otueke API in cloud mode** + **managed MySQL 8.4**.
- **otueke-booking-web** - public website and online booking portal.
- **otueke-admin-web (remote)** - management access off-site.
- **Sync is initiated OUTBOUND from the site** to the cloud API. The site server and database are
  **never exposed to the internet** (no port forwarding / inbound NAT).

```
 [POS/Tablets/KDS/Printers]      [Staff workstations]
            |  API only                 | admin-web only
            v                           v
   +--------------------- SERVER VLAN ---------------------+
   |  Otueke API (Windows service)  <->  MySQL 8.4          |
   |  Redis (opt.)   otueke-admin-web (local)   NAS backups |
   +---------------------------+---------------------------+
                               | outbound HTTPS only (sync, offsite backups)
                               v
   +------------------------ CLOUD ------------------------+
   |  Otueke API (cloud mode)  <->  managed MySQL 8.4       |
   |  otueke-booking-web (public)   otueke-admin-web (remote)|
   +-------------------------------------------------------+
```

## Contents

| Path | What |
| --- | --- |
| [`compose/dev/`](compose/dev/) | Docker Compose for **local development** dependencies (MySQL 8.4, Redis 7, optional Mailpit) |
| [`mysql/conf.d/otueke.cnf`](mysql/conf.d/otueke.cnf) | Baseline MySQL settings: utf8mb4, UTC, strict sql_mode, InnoDB, ROW binlog for PITR |
| [`env/`](env/) | `site.env.example`, `cloud.env.example` - every variable for API/admin/booking per deployment (placeholders) |
| [`network/`](network/) | Logical network segmentation (VLANs, allowed flows, Wi-Fi, DHCP) |
| [`runbooks/`](runbooks/) | Server installation, backup & restore, internet outage, device registration, incident response |
| [`scripts/`](scripts/) | Windows PowerShell scripts (API service install, MySQL backup) |

## Local development dependencies

```bash
cp compose/dev/.env.example compose/dev/.env      # edit placeholder passwords
docker compose -f compose/dev/docker-compose.yml --env-file compose/dev/.env up -d
docker compose -f compose/dev/docker-compose.yml --env-file compose/dev/.env --profile mail up -d  # + Mailpit
```

## Rules

- **No secrets committed** - ever. Passwords, keys, tokens, certificates and real `.env` files
  are git-ignored and scanned for by gitleaks in CI.
- Secrets are provided via the **environment / secret store** (Windows service environment with
  restricted ACLs on site; the cloud provider's secret manager in the cloud).
- Only the Otueke API owns and migrates the MySQL schema; PHP apps call the API.
- All timestamps are stored in **UTC**; money is stored/transported as exact decimals.

## CI

`.github/workflows/ci.yml`: docker compose validation, yamllint (relaxed) + actionlint,
PSScriptAnalyzer (severity Error) on `scripts/`, gitleaks secret scan.

## Related

- Architecture, ADRs and domain docs: [prinzderick/otueke-docs](https://github.com/prinzderick/otueke-docs)
- [prinzderick/otueke-api](https://github.com/prinzderick/otueke-api),
  [prinzderick/otueke-admin-web](https://github.com/prinzderick/otueke-admin-web),
  [prinzderick/otueke-booking-web](https://github.com/prinzderick/otueke-booking-web)
- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
