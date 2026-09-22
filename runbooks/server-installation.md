# Runbook: on-site server installation

> **DRAFT** - pending architecture approval.

## Scope

Install the Windows local application server that runs the Otueke API (Windows service),
MySQL 8.4, optional Redis and the local `otueke-admin-web`.

## Prerequisites

- Server hardware with RAID1/RAID10 (or mirrored) storage, UPS with graceful shutdown.
- Windows Server (current supported LTSC), fully patched, joined to no public network.
- Static IP on the SERVER VLAN (see [network segmentation](../network/logical-segmentation.md)).
- Separate data volume (e.g. `D:`) for MySQL data and local backups.
- Secrets prepared in the site secret store (DB passwords, token signing key, TLS PFX password,
  sync client secret). **Do not** put them in scripts, tickets or chat.

## Steps

1. **Base OS hardening**
   - Enable BitLocker on all volumes; store recovery keys in the approved vault.
   - Enable Windows Firewall; allow inbound only: API port (5443) from POS/OPS and STAFF
     VLANs, admin-web (443) from STAFF VLAN. Block everything else inbound.
   - Create a dedicated low-privilege service account for the API (e.g. `svc-otueke-api`).
   - Configure NTP time sync (UTC internally; Windows display time zone per site).
2. **MySQL 8.4**
   - Install MySQL 8.4 LTS as a Windows service, data directory on `D:\MySQL\data`.
   - Apply settings equivalent to [`mysql/conf.d/otueke.cnf`](../mysql/conf.d/otueke.cnf)
     in `my.ini` (utf8mb4, UTC, strict sql_mode, binlog ROW).
   - Bind to `127.0.0.1` (or the SERVER VLAN IP if other server-VLAN hosts need it).
   - Create users: `otueke_app` (DML on `otueke`), `otueke_migrator` (DDL, used only during
     deployment), `otueke_backup` (backup privileges). Strong unique passwords.
3. **Redis (optional)** - install and bind to localhost with a password, or skip.
4. **Otueke API**
   - Copy the published API build to `C:\Otueke\api\<version>\`.
   - Provide configuration via machine-level environment variables readable only by the
     service account (template: [`env/site.env.example`](../env/site.env.example)).
   - Run database migrations using the migrator credentials (per API release notes).
   - Install the service: [`scripts/windows/install-api-service.ps1`](../scripts/windows/install-api-service.ps1).
   - Verify `https://<server>:5443/health` from a POS/OPS device.
5. **otueke-admin-web** - install PHP 8.4 + web server (IIS with FastCGI or Caddy/nginx for
   Windows), deploy the release, create `.env` from the template with production values,
   `php artisan config:cache`. Verify `/health` from a STAFF workstation.
6. **Backups** - create the protected MySQL option file and schedule
   [`scripts/windows/backup-mysql.ps1`](../scripts/windows/backup-mysql.ps1); run once
   manually and verify output (see [backup and restore](backup-and-restore.md)).
7. **Monitoring** - enable service recovery (restart on failure), disk space alerts, and
   Windows event log forwarding if available.

## Acceptance

- [ ] API, MySQL (and Redis) start automatically after reboot.
- [ ] POS/OPS devices reach the API; nothing else on the server is reachable from them.
- [ ] First backup completed and copied to NAS.
- [ ] Outbound sync to cloud succeeds; no inbound internet exposure (external scan).
- [ ] Installation details recorded in the site record (versions, IPs, service accounts).
