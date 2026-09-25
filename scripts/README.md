# Scripts

> **DRAFT.** Written against the documented `007resort-api` layout (standard Laravel app at the repo root, `artisan`,
> `APP_NODE=local|cloud`, Redis queue, `php artisan reverb:start`, `schedule:run`, health `/up`, `/api/v1/system/info`).
> Linted and dry-run tested; **not yet run on real Windows Server / VPS hardware** - rehearse on a spare machine first.

Every script supports a dry run: `-DryRun` (PowerShell) / `--dry-run` (bash). **Run it first.**

## Local node - Windows Server (`windows/`)

| Script | Purpose |
| --- | --- |
| [`install.ps1`](windows/install.ps1) | Idempotent full install: PHP (NTS) + IIS FastCGI, MySQL 8.4, Memurai, Composer, NSSM services (`R007-Queue`, `R007-Sync`, `R007-Reverb`), Task Scheduler (`R007 Scheduler`, backup, log cleanup), firewall limited to the property VLANs, ACLs. `-Steps` runs parts. |
| [`update.ps1`](windows/update.ps1) | Deploy a release ZIP: unpack, link shared `.env`/`storage`, migrate, cache, swap `current`, restart, health check, auto-rollback; `-Rollback`. |
| [`status.ps1`](windows/status.ps1) | Health of every service/task/port, `/up`, `/api/v1/system/info` + heartbeat, backup age, disk. Exit 0 = healthy; `-Json`. |
| [`backup-mysql.ps1`](windows/backup-mysql.ps1) | Nightly dump + binlogs, verify, NAS copy with checksum, optional rclone/age off-site, retention, event log. |
| [`restore-mysql.ps1`](windows/restore-mysql.ps1) | `-VerifyOnly` (quarterly test), `-TargetDatabase`, or `-Live` disaster restore with safety dump. |
| [`cleanup-logs.ps1`](windows/cleanup-logs.ps1) | Log retention for services/PHP/MySQL/IIS. |
| [`uninstall.ps1`](windows/uninstall.ps1) | Remove services/tasks/rules/site; data kept unless `-RemoveData -Force`. |
| `lib/R007.Common.ps1`, `templates/` | Shared helpers, `my.ini`, IIS `web.config` templates. |

The obsolete .NET `install-api-service.ps1` has been removed (ADR-0012).

## Dev / demo (`dev/`)

| Script | Purpose |
| --- | --- |
| [`local-node.sh`](dev/local-node.sh) | `up` / `stop` / `status` / `logs` / `url`: a whole Local node on a laptop for demos (0.0.0.0:8080 + queue + scheduler + Reverb 8081), prints LAN URL and QR. Never touches the API repo's `.env`. |

## Cloud node - Ubuntu VPS (`vps/`)

| Script | Purpose |
| --- | --- |
| [`bootstrap.sh`](vps/bootstrap.sh) | Deploy user, key-only SSH, ufw 22/80/443, fail2ban, unattended-upgrades, narrow sudoers. |
| [`provision-stack.sh`](vps/provision-stack.sh) | nginx, PHP 8.4-FPM (a pool + system user per app), MySQL 8.4 + Redis on localhost, api/site/admin release trees + `.env` files with generated secrets, Supervisor + cron (api), nginx server blocks (+ Reverb proxy), backup crons, the `r007-*` commands. Domains from `--*-domain` flags or `/etc/r007/stack.env`. |
| [`tls.sh`](vps/tls.sh) | `r007-tls`: certbot (HTTP-01) for all three names, re-runnable; `--test` = certbot `--dry-run` against staging, `--dry-run` = print the plan. |
| [`deploy.sh`](vps/deploy.sh) | `r007-deploy <api\|site\|admin\|all> <package>`: atomic release + symlink, `migrate --force` (api only), caches, storage link, reload, local smoke, **automatic rollback**; also `rollback`, `recache`, `list`, `status`. |
| [`smoke.sh`](vps/smoke.sh) | `r007-smoke`: health endpoints, `/api/v1/system/info`, site home + media, admin login, TLS expiry, redirects, HSTS; `--mode local` (deploy) / `public` (CI). |
| [`artisan.sh`](vps/artisan.sh) | `r007-artisan <app> ...`: artisan as the app's own user (e.g. `r007:cms-seed`). |
| [`backup.sh`](vps/backup.sh) | Nightly dump + binlogs + **media** + encrypted env files, age encryption, rclone off-server upload with verification, retention. |
| [`restore-test.sh`](vps/restore-test.sh) | Restore the newest backup into a scratch DB, prove the media/env archives, JSON evidence log. |
| [`check-nginx.sh`](vps/check-nginx.sh) | Dev/CI: render all nginx templates and `nginx -t`; `--routes` asserts routing, limits, headers, allow-list/basic auth against a running nginx. |
| `templates/` | nginx (common, per-app bodies, http/tls servers), PHP-FPM pool, supervisor, cron, logrotate templates. |

`lib/stack.sh` models the api/site/admin stack (domains, users, ports, nginx rendering); `lib/common.sh` holds the shared bash helpers (`run`, dry-run, `.env` editing, secret generation).

## Rules

- **No secrets in scripts or parameters.** Secrets are generated on the server or typed at a secure prompt and stored only in the
  protected `.env` / MySQL option files; passwords go to `mysql` over stdin or option files, never argv.
- Idempotent: re-running converges. State-changing steps are announced and skipped in dry-run mode.
- CI runs shellcheck, PSScriptAnalyzer (`PSScriptAnalyzerSettings.psd1`), actionlint, yamllint and gitleaks.

## Local checks

```bash
shellcheck -x scripts/lib/*.sh scripts/dev/*.sh scripts/vps/*.sh
docker compose -f compose/dev/docker-compose.yml --env-file compose/dev/.env.example --profile reverb config -q
```
```powershell
Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```
