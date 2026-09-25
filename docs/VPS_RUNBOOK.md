# VPS runbook: API + public website + admin portal on one Ubuntu server

> Status: scripts are linted, dry-run in CI, and were exercised end to end in an Ubuntu 24.04 container against a stock
> Laravel app (see "What was verified"). They have **not** yet run on the real VPS: do the first install with the
> checklist below and note any deviation here.

One Ubuntu 24.04 LTS VPS hosts the whole online side of 007 Resort & Spa:

| App | Repo | Public name | What it is |
| --- | --- | --- | --- |
| **api** | `007resort-api` | `API_DOMAIN` (`api.<domain>`) | Laravel, `APP_NODE=cloud`, MySQL 8.4, Redis, queue + sync workers, Reverb websockets (`wss://api.<domain>/app`), uploaded media (`/storage/cms/*`) |
| **site** | `007resort-booking-web` | `SITE_DOMAIN` (`<domain>`, `www.` redirects) | Public website (Laravel/Blade). No database; talks to the API over HTTP with a service token |
| **admin** | `007resort-admin-web` | `ADMIN_DOMAIN` (`admin.<domain>`) | Staff portal (Laravel). No database; staff sign in with their API credentials |

```
 internet ── 80/443 ──> nginx ──┬─ site.example.com   -> PHP-FPM pool r007-site  (user r007-site)   /var/www/r007/site
   (ufw: 22/80/443)             ├─ api.example.com    -> PHP-FPM pool r007-api   (user r007-api)    /var/www/r007/api
                                │                        └─ /app, /apps -> Reverb 127.0.0.1:8080 ; /storage -> shared media
                                └─ admin.example.com  -> PHP-FPM pool r007-admin (user r007-admin)  /var/www/r007/admin
 site + admin ──HTTPS (or loopback)──> api        MySQL 8.4 + Redis on 127.0.0.1 only
 Supervisor (api only): queue x2, sync, reverb     cron: schedule:run (api only)     certbot: 3 certificates
```

## 1. What the owner must supply

| Item | Used for |
| --- | --- |
| **Domain** you control (e.g. `007resort.com`) and access to its DNS | three names (site, api, admin) + email records |
| The **VPS** (Ubuntu 24.04 LTS, root access) and its public IPv4 | hosting |
| An **SSH public key** for the deploy user (and a second one for CI, see 6) | key-only access; root login is switched off |
| **SMTP relay credentials** (host, port 587, user, password, sender address on your domain) | booking confirmations, newsletter double opt-in, password resets |
| **Paystack** public key, secret key, webhook secret | card payments (`PAYSTACK_*` in the API `.env`) |
| An email for **Let's Encrypt** notices (`CERT_EMAIL`) | certificate expiry warnings |
| An **age public key** and an **rclone remote** (S3/B2/SFTP...) | encrypted off-server backups |
| GitHub repo secrets (section 6) | CI deployments |

Nothing secret ever goes into git. The generated ones (database, Redis, Reverb) are created on the server and never printed.

## 2. Sizing (and resizing)

| | vCPU | RAM | Disk | Note |
| --- | --- | --- | --- | --- |
| Minimum | 2 | 4 GB | 60 GB SSD | works for the pilot; add 2 GB swap (`fallocate -l 2G /swapfile`...) |
| **Recommended** | **4** | **8 GB** | 100-160 GB SSD | headroom for MySQL, 3 FPM pools, queue + Reverb |

MySQL's buffer pool (40 % of RAM) and each pool's `pm.max_children` (api 16 / site 10 / admin 6 at 8 GB, scaled down
proportionally, minimum 4) are computed at provision time. **After resizing the VPS re-run the provisioner** (`sudo r007-provision`): it is idempotent, re-scales those numbers and briefly restarts MySQL and PHP-FPM.

## 3. Namecheap notes (unmanaged VPS)

- Order **Ubuntu 24.04 LTS**, "unmanaged" (you get root and an IP; Namecheap does not administer the box). Pick a plan at or above the
  sizing table (plan names change: match on vCPU/RAM). Note the IPv4 (and IPv6 if it is assigned and actually routed).
- **SSH key**: add your public key in the VPS panel at order time if offered, or from your laptop `ssh-copy-id root@<ip>` /
  paste the first login. `bootstrap.sh` then turns **password login and root login off**: never run it without a key that works for the new `deploy` user.
- **Firewall**: the box firewalls itself (`ufw`: 22, 80, 443). If the Namecheap panel offers a network firewall, allow the same three ports, and
  keep the console/VNC access from the panel as your way back in if you lock yourself out.
- **DNS**: use Namecheap's Advanced DNS (or any DNS host). Keep the TTL low (300 s) until everything works.
- **Reverse DNS (PTR)**: only matters if this server sends email itself. We do **not** (use an SMTP relay): outbound port 25 is commonly blocked on VPS providers.
  If you ever do send directly, set the PTR of the IP to the mail hostname in the panel.
- **Snapshots/backups** in the panel are welcome in addition to (never instead of) the application backups of section 8.

## 4. DNS records to create (before the TLS step)

| Type | Host | Value | Note |
| --- | --- | --- | --- |
| A | `@` (`007resort.com`) | VPS IPv4 | site |
| A | `www` | VPS IPv4 | redirects to the apex (needs its own record; `SITE_WWW=off` to skip) |
| A | `api` | VPS IPv4 | API + websockets + media |
| A | `admin` | VPS IPv4 | admin portal (skip if you do not host it, see 7) |
| AAAA | same four | VPS IPv6 | **only** if IPv6 works on the VPS; otherwise leave AAAA out (a broken AAAA breaks Let's Encrypt) |
| CAA | `@` | `0 issue "letsencrypt.org"` | optional hardening |

**Transactional email** (newsletter confirmation, booking mail) is sent by the API through your SMTP relay. On the sender domain add exactly what the provider tells you:
- **SPF** `TXT @  "v=spf1 include:<provider-spf-host> ~all"` (one SPF record only; merge if you already have one)
- **DKIM** the `TXT`/`CNAME` records the provider gives you (usually `selector._domainkey`)
- **DMARC** `TXT _dmarc  "v=DMARC1; p=none; rua=mailto:postmaster@007resort.com"`; move to `p=quarantine` once reports look clean
- `MAIL_FROM_ADDRESS` must be an address on that domain (e.g. `no-reply@007resort.com`) or DMARC alignment fails.

## 5. First-time order of operations

Everything is driven by [`env/stack.env.example`](../env/stack.env.example) (installed as `/etc/r007/stack.env`, non-secret) and the per-app
`.env` files (`env/cloud.env.example`, `site.env.example`, `admin.env.example`).

```bash
# 0. laptop: a deploy key pair (and later a separate CI key), DNS A records created, VPS ordered.
ssh-keygen -t ed25519 -f ~/.ssh/007resort-deploy -C "007 deploy"
rsync -a --exclude .git ./007resort-infrastructure/ root@<ip>:/root/007resort-infrastructure/

# 1. ON THE SERVER, as root. Harden. Keep this root session open; test `ssh -i ~/.ssh/007resort-deploy deploy@<ip>` in ANOTHER terminal.
cd /root/007resort-infrastructure
scripts/vps/bootstrap.sh --ssh-pubkey-file /root/deploy.pub --dry-run     # (copy the .pub there first)
scripts/vps/bootstrap.sh --ssh-pubkey-file /root/deploy.pub

# 2. Same root session: install the stack (nginx, PHP 8.4, MySQL 8.4, Redis, Supervisor, certbot, 3 users/pools, 3 .env files)
scripts/vps/provision-stack.sh --api-domain api.007resort.com --site-domain 007resort.com \
    --admin-domain admin.007resort.com --email ops@007resort.com --dry-run
scripts/vps/provision-stack.sh --api-domain api.007resort.com --site-domain 007resort.com \
    --admin-domain admin.007resort.com --email ops@007resort.com
#    -> saves the names to /etc/r007/stack.env; serves plain HTTP until step 8. From now on you work as `deploy`.

# 3. As deploy: fill the <secret> values (Paystack, SMTP, sync credential; the site's service token comes in step 5)
nano /var/www/r007/api/shared/.env       # PAYSTACK_*, MAIL_*, SYNC_NODE_CREDENTIAL, NODE_SITE_ID ...
nano /var/www/r007/site/shared/.env      # R007_API_SERVICE_TOKEN (step 5), SITE_PHONE/EMAIL/ADDRESS
nano /var/www/r007/admin/shared/.env     # usually nothing more
#    Files are deploy:r007-<app>, mode 640. deploy.sh refuses to deploy while a <secret> placeholder is left.

# 4. Deploy the API first (CI does this in normal life, section 6; manual equivalent with a package you built):
r007-deploy api /tmp/r007-api-<sha>.tar.gz         # migrate --force, caches, switch, local smoke, auto-rollback

# 5. Optional demo CMS content, and the website's service token
r007-artisan api r007:cms-seed                     # idempotent demo content (pages, gallery, ...)
r007-artisan api r007:service-token create ...     # see 007resort-api docs/CUSTOMER_PUBLIC_API.md; the token is shown once
nano /var/www/r007/site/shared/.env                # R007_API_SERVICE_TOKEN=r7s_...

# 6. Deploy site and admin (after the API): assets are prebuilt by CI
r007-deploy site  /tmp/r007-site-<sha>.tar.gz
r007-deploy admin /tmp/r007-admin-<sha>.tar.gz
#    (all in one: r007-deploy all --api <pkg> --site <pkg> --admin <pkg>   order: api -> site -> admin)

# 7. TLS for all three names (DNS must resolve to this server; port 80 open)
sudo r007-tls --test          # certbot --dry-run against the Let's Encrypt staging server: nothing is saved
sudo r007-tls                 # real certificates, nginx switches to HTTPS, HSTS on, renewal timer enabled (re-runnable any time)

# 8. Smoke the real thing, then set up backups (section 8)
r007-smoke --mode public
```

Day-2 without root SSH: `sudoedit /etc/r007/stack.env` then `sudo r007-provision`,
`sudo r007-tls`, `sudo r007-backup`, `sudo r007-restore-test` are whitelisted for the deploy user (exact commands only).
Updating the scripts themselves needs a new checkout of this repo and a root run of `provision-stack.sh` (or the provider console).

## 6. Deployments and CI

**Build in CI, ship the result.** The server has no Node: `npm ci && npm run build` runs in GitHub Actions and `public/build`
travels inside the release package (`deploy.sh` refuses a site/admin release without `public/build/manifest.json`).

`r007-deploy <app> <package|git-ref> [options]` (also `all`, `rollback <app> [id]`, `recache <app>`, `list [app]`, `status`):

1. unpack into `<app>/releases/<id>` and link `shared/.env` + `shared/storage`
2. api only: `php artisan migrate --force` with the DDL account (`DB_MIGRATOR_*`); site/admin have no database
3. `config:cache`, `route:cache` (skipped with a warning if a closure route cannot be cached), `event:cache`, `view:cache`, media link (`public/storage`)
4. atomic symlink swap of `current`, reload PHP-FPM (api: also restart the Supervisor group `r007`)
5. **local smoke** (`smoke.sh --mode local`): a failure **rolls that app back automatically**; the database is never reverted, so migrations must stay backwards compatible (expand/contract)
6. keep the last 5 releases

Refuses to deploy while: placeholders remain in the `.env`, `APP_DEBUG=true`, API `APP_NODE` is not `cloud`, site `CMS_FIXTURES`/`R007_MOCK` or admin `R007_MOCK` are on.
After editing an `.env`: `r007-deploy recache <app>`.

**Workflow**: copy [`.github/workflow-templates/deploy-vps.yml`](../.github/workflow-templates/deploy-vps.yml) into each app repo and set `APP: api|site|admin`
(one line). Jobs: build (composer `--no-dev`, `npm ci && npm run build`, tarball) -> deploy over SSH (`r007-deploy`) -> **public smoke** (`r007-smoke --mode public`) -> **rollback** if it fails.

GitHub Environment `vps-production` (add required reviewers) in each repo:

| Kind | Name | Value |
| --- | --- | --- |
| secret | `VPS_HOST` | server hostname or IP |
| secret | `VPS_USER` | `deploy` |
| secret | `VPS_SSH_KEY` | private half of a **dedicated CI key** (append its public half to `/home/deploy/.ssh/authorized_keys`) |
| secret | `VPS_KNOWN_HOSTS` | `ssh-keyscan -t ed25519 <host>` output, verified out of band |
| secret (optional) | `SMOKE_ADMIN_BASIC_AUTH` | `user:password` of the admin basic-auth layer, if enabled (admin repo only) |
| variable (optional) | `VPS_PORT` | SSH port if not 22 |

Deploy order for a coordinated release: api, then site and admin.

## 7. Configuration recipes

**Pointing the website at the API.** The site's `.env` has `R007_API_BASE_URL` (default `https://<API_DOMAIN>`, set at provisioning),
`R007_API_SERVICE_TOKEN` (`r7s_...`, issued on the API) and `CMS_FIXTURES=false`. Loopback alternative (same box, skips DNS/TLS/nginx rate limits):
set `API_INTERNAL_URL=http://127.0.0.1:8088` in `stack.env` **before** the first provisioning, or edit `R007_API_BASE_URL` in both `.env` files and `r007-deploy recache <app>`.
Media lives on the API domain (`/storage/cms/*`, cached 1 year); the site's `CMS_MEDIA_HOSTS` lists that origin for its CSP.

**Newsletter links** land on the site because the API's `CMS_WEB_URL` is `https://<SITE_DOMAIN>` (set at provisioning; emails link to
`<CMS_WEB_URL>/newsletter/confirm?token=...`). Check: `grep CMS_WEB_URL /var/www/r007/api/shared/.env`, change it there and `r007-deploy recache api`.

**Mail driver.** The API sends mail. Default is an SMTP relay (any provider: Brevo, Mailgun, SES SMTP, Postmark, your host's relay):
`MAIL_MAILER=smtp`, `MAIL_HOST`, `MAIL_PORT=587`, `MAIL_ENCRYPTION=tls`, `MAIL_USERNAME`, `MAIL_PASSWORD`, `MAIL_FROM_ADDRESS`. Provider API mailers (`ses`, `postmark`, `mailgun`) work too if the API has that package.
Do not send from the VPS directly (port 25, reputation). Test: `r007-artisan api tinker` and send yourself a message. `MAIL_MAILER=log` writes to the log instead: fine for a dry run, never for go-live.

**Paystack.** `PAYSTACK_PUBLIC_KEY`, `PAYSTACK_SECRET_KEY`, `PAYSTACK_WEBHOOK_SECRET` in the API `.env`; register `https://<API_DOMAIN>/api/v1/payments/webhooks/paystack` as the webhook URL in the Paystack dashboard.

**Admin hardening** (all optional, in `stack.env`; then re-provision as described above):
- `ADMIN_ALLOW_IPS="203.0.113.7 198.51.100.0/24"`: nginx answers 403 to everybody else before the app is reached (empty = reachable from the internet, protected by the portal login).
  Mind dynamic IPs: keep the provider console as your way back in.
- `ADMIN_BASIC_AUTH=on`: an extra HTTP basic-auth layer. Credentials come from `/etc/r007/admin-basic-auth.secret` (`user:password`, root-only, generated if missing;
  read it with `sudo cat`). Anything that calls the admin over HTTP (smoke test in CI: `SMOKE_ADMIN_BASIC_AUTH`) needs them. Allow-list and basic auth combine (both required).
- Always on: `X-Robots-Tag: noindex, nofollow`, `robots.txt` = disallow all, host-only cookies (`SESSION_DOMAIN=null`) with a distinct cookie name per app
  (`r007_admin_session`, `r007_site_session`), so no cookie is shared between the apps or with the API.
- **Login rate limiting**: nginx allows 10 sign-in POSTs/min per IP (burst 5, then 429); the portal adds its own `throttle` and the API has the authoritative lockout. The limit is per source IP: many staff behind one office NAT share it (raise `rate=` in `nginx-common.conf` if needed).
- **Keep the admin private instead**: (a) do not host it (`ADMIN_DOMAIN` empty) and run the admin portal at the property against the Cloud or Local API; (b) host it but allow only the property's static IP; (c) allow only a VPN address range
  (WireGuard on the VPS, `ADMIN_ALLOW_IPS=10.8.0.0/24`; setting up the VPN itself is outside these scripts). MFA (`R007_MFA_ENFORCE`) is the next layer once the API supports it.

**Trusted proxies / forwarded headers.** nginx terminates TLS and tells PHP `HTTPS=on` (+ `X-Forwarded-Proto`), so URLs, redirects and secure cookies are right in every app,
including the admin which does not configure trusted proxies itself. The site also reads `TRUSTED_PROXIES` (default `127.0.0.1`): only change it if a CDN sits in front, and then also configure nginx `real_ip` so client IPs stay right.

**Health routes.** `/up` (Laravel) on all three apps is what deploys and smoke tests use; the loopback ports (127.0.0.1:8088 api, 8089 site, 8090 admin) are never public.

## 8. Backups, media, restore

`r007-backup` (nightly cron) produces: MySQL dump + binlogs, **`r007-media-<UTC>.tar.gz`** (the API's `shared/storage/app/public`, i.e. all CMS uploads), and an
**encrypted-only** archive of every app's `.env` + `stack.env` + the admin basic-auth secret. Everything is age-encrypted and pushed off-server via rclone.
`/etc/r007/backup.env` (template `backup.env.example`): `RCLONE_REMOTE`, `AGE_RECIPIENT`, `MEDIA_BACKUP=archive|off`, retention. Configure rclone as root (`rclone config`); keep the age **private** key off the server.
Media grows over time: the archive is a full copy each night (35 days remote retention by default); switch `MEDIA_BACKUP=off` and use `rclone sync` of the media dir yourself if it gets large.
`r007-restore-test [--from-remote] --age-identity <key>` (monthly cron) restores the dump into a scratch database, and proves the media archive extracts and the env archive holds `api/shared/.env`. Full procedure: [backup-and-restore runbook](../runbooks/backup-and-restore.md).

## 9. Layout and isolation

```
/var/www/r007/{api,site,admin}/  releases/<id>/  current -> releases/<id>  shared/{.env,storage}   (deploy:deploy, shared is deploy:r007-<app>)
/etc/r007/stack.env (644, no secrets)   /etc/r007/backup.env (600)   /etc/r007/admin-basic-auth.secret (600)
/opt/r007/infra  installed copy of this repo's scripts  ->  r007-deploy r007-smoke r007-artisan  (/usr/local/bin)   r007-tls r007-backup r007-restore-test (/usr/local/sbin)
/etc/nginx/{conf.d/r007-common.conf, sites-available/r007-<app>.conf, snippets/r007-<app>-*.conf}   /etc/php/8.4/fpm/pool.d/r007-<app>.conf
```
- Each app has its own **system user/group** (`r007-api|site|admin`), **PHP-FPM pool + socket**, `.env` (640, group = the app), storage tree and (for site/admin) file-based sessions/cache. One compromised app cannot read another's `.env`, sessions or cached config (verified, section 10).
- `deploy` is a member of the three groups; nginx (`www-data`) can only read `public/` and the media directory.
- PHP upload limits are per pool: **api and admin 9M upload / 10M post** (the admin forwards CMS uploads to the API), site 2M/4M; nginx `client_max_body_size` 12m (api, admin) and 4m (site). Set `FPM_OPEN_BASEDIR=on` for a per-pool filesystem jail once tested on your build.
- Supervisor and cron exist **only for the API** (queue x2, sync, Reverb, `schedule:run`): site and admin use `QUEUE_CONNECTION=sync` and define no scheduled commands (checked in both repos).
- `r007-artisan <app> <command>` runs artisan as the app's own user (e.g. `r007-artisan api r007:cms-seed`).

## 10. What was verified, and what was not

Executed: shellcheck + `bash -n` on every script; dry-runs of every script; `scripts/vps/check-nginx.sh --routes` (all templates rendered in http and https mode and `nginx -t`, then **36 behavioural assertions against a running nginx**: routing, cache headers, limits, redirects, HSTS, allow-list, basic auth, noindex, rate limit); in an **Ubuntu 24.04 container** (arm64, nginx 1.24, PHP 8.4-FPM from ondrej, Redis, Supervisor, MySQL 8.0 because the MySQL 8.4 apt repo has no arm64 packages): the real `provision-stack.sh` (twice: idempotent), pools/users/permissions, three real Laravel apps deployed with the real `deploy.sh` (migrate, caches, switch, smoke, automatic rollback of a bad release, `all`, `recache`), public smoke over TLS (self-signed), admin allow-list and basic auth, isolation checks between the three users, `r007-backup` + `r007-restore-test` (media + env archives, local and via an rclone remote); the MySQL 8.4 apt repository and its signing key on amd64.

Not executed: bootstrap.sh on a real host (SSH/ufw/fail2ban; dry-run only), certbot against the real Let's Encrypt (`r007-tls --test` is the check to run first), systemd itself (the container used a service shim), the real API/site/admin code (a stock Laravel app stood in for all three), the CI workflow on GitHub, Reverb (a stand-in command), real email, Paystack.
