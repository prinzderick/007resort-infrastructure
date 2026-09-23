# Runbook: server installation (Local node and Cloud node)

> **DRAFT** - pending architecture approval. Specs: architecture/25 (007resort-docs)
> (Cloud VPS), architecture/26 (007resort-docs) (Windows Local node),
> ADR-0012/0013/0014. The scripts in this repo were written against the documented layout of `007resort-api`
> (standard Laravel app at the repo root, `APP_NODE=local|cloud`, Redis queue, Reverb, `/up`,
> `/api/v1/system/info`). Everything below has been dry-run and linted; it has **not** yet been run on real
> Windows Server / VPS hardware - do the first install on a spare machine and record deviations here.

Both nodes run the **same Laravel codebase and PHP 8.4**; only `APP_NODE` and the integrations differ.

| | Local node (property) | Cloud node (VPS) |
| --- | --- | --- |
| OS | Windows Server (LTSC) | Ubuntu 24.04 LTS |
| Web | IIS + PHP FastCGI (NTS) | nginx + PHP-FPM |
| DB / cache | MySQL 8.4 (ZIP, own service), Memurai (Redis-compatible) | MySQL 8.4 LTS (official apt repo), Redis |
| Processes | NSSM Windows services: `R007-Queue`, `R007-Sync`, `R007-Reverb`; Task Scheduler `R007 Scheduler` | Supervisor group `r007` (queue, sync, reverb); cron `schedule:run` |
| Exposure | property VLANs only; **no inbound from the internet**; outbound HTTPS only (sync, off-site backup) | 22 (key only), 80, 443; MySQL/Redis on localhost |
| Config | `C:\R007\shared\.env` from [`env/local.env.example`](../env/local.env.example) | `/var/www/r007/shared/.env` from [`env/cloud.env.example`](../env/cloud.env.example) |
| Scripts | [`scripts/windows/`](../scripts/windows/) | [`scripts/vps/`](../scripts/vps/) |

Every script supports a dry run (`-DryRun` for PowerShell, `--dry-run` for bash). **Always dry-run first.**

---

## A. Local node (Windows Server)

### Prerequisites

- Server hardware with mirrored storage and a UPS with graceful shutdown; Windows Server fully patched; BitLocker on;
  time sync (NTP) on; static IP on the SERVER VLAN (proposal `10.10.10.10`) and an internal DNS name
  (`r007-api.site.local`) pointing at it - see [device onboarding](device-registration.md).
- A data volume (`D:`) for MySQL data and local backups (falls back to `C:\R007\...` if there is no `D:`).
- [Chocolatey](https://chocolatey.org/install) installed once by an administrator (it supplies PHP, NSSM, the VC++
  runtime, IIS URL Rewrite and Memurai with vendor checksums).
- The release ZIP from CI (`r007-<sha>.zip`, built by `.github/workflow-templates/build-release-package.yml`) copied
  to the server by an administrator (USB / internal share). The server is never deployed to from the internet.
- The **node credential** issued by the Cloud node for this site ([rotation runbook](node-credential-rotation.md)).
- **Redis licensing:** `memurai-developer` is the free *developer* edition. For production either buy a Memurai
  licence (`-MemuraiPackage <your licensed package>`), or run another Redis-compatible server bound to `127.0.0.1`
  (Microsoft Garnet, or Redis in WSL2 - native Windows Redis builds are unmaintained upstream) and install with
  `-RedisProvider External`. Redis is never authoritative storage; losing it loses only queued jobs, and the outbox
  in MySQL re-drives sync.

### Install

From an elevated PowerShell on the server, in a checkout/copy of this repository:

```powershell
.\scripts\windows\install.ps1 -DryRun                      # read the plan
.\scripts\windows\install.ps1 `
    -NasPath '\\nas.site.local\r007-backups' `
    -AppUrl  'http://r007-api.site.local' `
    -NodeSiteId 'SITE-001' `
    -SyncPeerUrl 'https://api.example.com'                  # secure prompt asks for the node credential
```

What it does (idempotent - re-running converges; run a single part with `-Steps Firewall,Acl`):

1. Creates `C:\R007\{releases,shared,logs,secrets,tools,scripts}` and copies the scripts there (scheduled tasks and
   `update.ps1` never depend on the checkout).
2. Creates `shared\.env` from the template and **generates** DB, Redis and Reverb secrets. Only the node credential
   (secure prompt) and mail/Paystack values are typed by a human. Nothing secret is in the scripts or the repo.
3. Installs PHP 8.4 (NTS), phpredis, Composer (signature-checked), MySQL 8.4 (from the official ZIP, or `-MySqlZip`
   for an offline install - verify the checksum; pass `-MySqlZipSha256`), Memurai.
4. MySQL: own `my.ini` (utf8mb4, UTC, strict mode, ROW binlog for PITR, **bound to 127.0.0.1**), service `R007MySQL`
   running as a virtual service account, users `r007_app` (DML), `r007_migrator` (DDL, used only by `update.ps1`),
   `r007_backup`. Admin and backup credentials are written to `C:\R007\secrets\*.cnf` (Administrators/SYSTEM only).
5. IIS site `R007` -> `C:\R007\current\public` with the FastCGI handler, URL-rewrite front controller, hidden `.env`,
   no `X-Powered-By`. Optional HTTPS with `-CertThumbprint` (internal CA certificate).
6. NSSM services (auto-start, restart on failure with 5 s delay, stdout/stderr rotation, depend on MySQL/Redis),
   Task Scheduler `R007 Scheduler` every minute, `R007 Nightly Backup` 02:30, `R007 Log Cleanup` 03:30.
7. Firewall: inbound TCP 80 (443) and the Reverb port 8085 **only from the property subnets**
   (default `10.10.10.0/24, 10.10.20.0/24, 10.10.40.0/24`; override with `-AllowedSubnets`). Public/non-RFC1918
   ranges are refused unless `-AllowPublicSubnets`. Default inbound policy is Block; no rule for 3306/6379 exists.

### First deploy and later updates

```powershell
C:\R007\scripts\update.ps1 -Package D:\incoming\r007-3f9c1a2b7d10.zip -DryRun
C:\R007\scripts\update.ps1 -Package D:\incoming\r007-3f9c1a2b7d10.zip
C:\R007\scripts\update.ps1 -Rollback                         # swap back to the previous release
```

`update.ps1` unpacks to `releases\<id>`, links the shared `.env`/`storage`, migrates with the DDL account
(`--force`), caches config/routes/events/views, stops only the workers, swaps the `current` junction, restarts them,
recycles the IIS pool and health-checks `/up` - **automatic rollback** if the check fails. The property keeps
serving from the old release until the swap. Migrations must be backward compatible with the previous release
(expand/contract) because rollback never reverses the database. Take `backup-mysql.ps1` before risky releases.
It refuses to deploy while `.env` still contains `<secret>` placeholders (`-AllowPlaceholders` for demos only).

### Verify (acceptance)

```powershell
C:\R007\scripts\status.ps1          # exit 0 = healthy; shows services, tasks, ports, /up, system/info + heartbeat, backups, disk
```

- [ ] `status.ps1` all OK after a **reboot** (services, IIS and MySQL start by themselves; nobody runs `queue:work`).
- [ ] From a POS/tablet on the OPS VLAN: `http://r007-api.site.local/up` works; ports 3306/6379 are unreachable.
- [ ] From GUEST Wi-Fi and from the internet (external scan): nothing reachable.
- [ ] `/api/v1/system/info` reports `local`; the heartbeat reaches Cloud (Cloud shows the site ONLINE).
- [ ] First backup completed and copied to the NAS; `restore-mysql.ps1 -VerifyOnly` passes.
- [ ] Unplug the WAN: a POS order -> payment (cash) -> KDS still works; plug back: outbox drains ([internet outage](internet-outage.md)).
- [ ] Installation recorded in the site record (versions, IPs, dates, who).

### Uninstall

`scripts\windows\uninstall.ps1 -DryRun` removes services, tasks, firewall rules and the IIS site. Data, backups and
MySQL are kept unless `-RemoveMySql` / `-RemoveData -Force` are given (typed confirmation).

---

## B. Cloud node (Ubuntu VPS)

Provisioning the VPS itself (provider account, billing, DNS A/AAAA record, provider snapshots on) is an owner action
- see architecture/25 section 0 (007resort-docs). Sizing target: ~4 vCPU / 8 GB / 100-160 GB SSD.

```bash
# 1. as root on the fresh server (copy the repo or just scripts/ + env/ + mysql/)
sudo scripts/vps/bootstrap.sh --ssh-pubkey-file deploy.pub --dry-run
sudo scripts/vps/bootstrap.sh --ssh-pubkey-file deploy.pub
#    -> deploy user, key-only SSH (root login off), ufw 22/80/443, fail2ban, unattended-upgrades (reboot 02:30 UTC window)
#    !! keep the current session open and test a NEW login as `deploy` before closing it.

# 2. the stack
sudo scripts/vps/provision-stack.sh --domain api.example.com --email ops@example.com --dry-run
sudo scripts/vps/provision-stack.sh --domain api.example.com --email ops@example.com
#    -> nginx, PHP 8.4-FPM (+ext), Composer, MySQL 8.4 LTS (localhost), Redis (localhost + password), Supervisor
#       group r007, cron scheduler, logrotate, certbot TLS (webroot mode, auto-renew), nginx WebSocket proxy for Reverb,
#       /var/www/r007/shared/.env with generated secrets, nightly backup + monthly restore test crons.

# 3. fill the remaining <secret> values (Paystack, mail, sync) as the deploy user
sudoedit /var/www/r007/shared/.env      # or paste over SSH; never commit, never chat

# 4. off-server backups (see backup-and-restore.md): configure rclone as root, then
sudo cp /etc/r007/backup.env.example /etc/r007/backup.env && sudoedit /etc/r007/backup.env

# 5. deploy (CI does this; manual equivalent as the deploy user)
r007-deploy deploy --package /tmp/r007-3f9c1a2b7d10.tar.gz
r007-deploy rollback                                  # previous release
r007-deploy list | status
```

Deploy = atomic release directory + symlink swap: unpack -> link shared `.env`/`storage` -> `composer install
--no-dev` (git mode) -> `migrate --force` (DDL account) -> `config/route/event/view:cache` -> swap -> reload
PHP-FPM -> `supervisorctl restart r007:*` -> health check on the loopback vhost (`127.0.0.1:8088/up`) ->
**automatic rollback** on failure -> keep 5 releases. Same expand/contract rule for migrations as on Local.

### CI/CD

Copy `.github/workflow-templates/deploy-cloud-vps.yml` (and `build-release-package.yml`) into `007resort-api`.
Create a GitHub *Environment* `cloud-production` with required reviewers and these **secrets** (values are never in
git): `VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY` (dedicated deploy key), `VPS_KNOWN_HOSTS` (verified `ssh-keyscan` output).

### Verify (acceptance)

- [ ] `curl -I https://api.example.com/up` = 200 with a valid certificate; HTTP redirects to HTTPS.
- [ ] External scan shows only 22, 80, 443. MySQL 3306 and Redis 6379 closed; `ss -ltn` shows them on 127.0.0.1.
- [ ] `sudo supervisorctl status` shows `r007:*` RUNNING; `crontab`/`/etc/cron.d/r007` scheduler entry present; after a reboot everything returns.
- [ ] `wss://api.example.com/app/<REVERB_APP_KEY>` upgrades (browser devtools or `websocat`).
- [ ] Sync/heartbeat handshake with a test Local node succeeds; the site shows ONLINE, and OFFLINE ~90 s after unplugging Local.
- [ ] `r007-backup` run once, object visible off-server; `r007-restore-test --from-remote` passes.
- [ ] Provider snapshot schedule enabled (in addition to, not instead of, application backups).

## Hardening notes

- Secrets: `.env` files are mode 600 (Windows: ACL Administrators/SYSTEM + service accounts). Consider a secret
  manager as a follow-up (architecture 25 section 2). Never paste secrets into tickets/chat/CI logs.
- Windows services run as `NT AUTHORITY\LOCAL SERVICE` (no stored passwords); any process running as that account on
  the server can read `.env`, so keep the server dedicated and minimal.
- Reverb on Windows uses `stream_select` (no `pcntl`): fine for the property's 30-40 concurrent clients; revisit above ~1000.
