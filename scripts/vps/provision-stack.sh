#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE step 2: install the application stack on Ubuntu 24.04 (api + site + admin).
#
#   sudo scripts/vps/provision-stack.sh --api-domain api.example.com [--site-domain example.com]
#        [--admin-domain admin.example.com] [--email ops@example.com] [options] [--dry-run]
#
# Domains and options can also come from /etc/r007/stack.env (template: env/stack.env.example); flags override the
# file and are saved back to it. An app is hosted when its domain is set (API_DOMAIN is always required).
#
# Options:
#   --site-domain NAME | --api-domain NAME | --admin-domain NAME   public hostnames (DNS must point here before TLS)
#   --domain NAME          legacy alias of --api-domain
#   --email ADDR           Let's Encrypt contact (CERT_EMAIL); only needed for TLS
#   --config FILE          stack settings file (default /etc/r007/stack.env)
#   --tls                  also run certbot now (default: NOT now - deploy first, then `sudo r007-tls`)
#   --deploy-user NAME     default: deploy (must exist - run bootstrap.sh first)
#   --app-root DIR         default: /var/www/r007 (api/ site/ admin/ below it)
#   --skip-mysql-repo      use MySQL from the distro repo instead of the official 8.4 LTS repo (NOT recommended)
#   --dry-run              print actions, change nothing
#
# Installs/configures (idempotent): nginx, PHP 8.4-FPM (one pool + one system user per app), Composer, MySQL 8.4
# (127.0.0.1), Redis (127.0.0.1, password), Supervisor programs + cron scheduler (API only), per-app release trees
# and .env files with generated secrets (mode 640, group = app group), nginx server blocks (+ Reverb proxy on the
# API domain), logrotate, backup crons and the r007-* commands (deploy, smoke, tls, artisan, backup).
# Node.js is NOT installed: front-end assets are built in CI and shipped inside the release package.
# Secrets are written only to mode-640/600 files and never printed.
set -euo pipefail
SCRIPT_TAG="provision"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

CONFIG=""; RUN_TLS=0; SKIP_MYSQL_REPO=0
F_SITE=""; F_API=""; F_ADMIN=""; F_EMAIL=""; F_USER=""; F_ROOT=""
# MySQL release-signing key. Verified by fingerprint before it is trusted. The fingerprint is unchanged since 2023 but the
# 2023 file EXPIRED (Oct 2025: apt reports EXPKEYSIG); the "-2025" file is the same key with a later expiry (Oct 2027).
# When apt starts reporting EXPKEYSIG again, look for a newer RPM-GPG-KEY-mysql-<year> file on repo.mysql.com.
MYSQL_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2025"
MYSQL_KEY_FPR="BCA4 3417 C3B4 85DD 128E  C6D4 B7B3 B788 A8D3 785C"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --site-domain) F_SITE="${2:?}"; shift 2 ;;
    --api-domain|--domain) F_API="${2:?}"; shift 2 ;;
    --admin-domain) F_ADMIN="${2:?}"; shift 2 ;;
    --email) F_EMAIL="${2:?}"; shift 2 ;;
    --config) CONFIG="${2:?}"; shift 2 ;;
    --tls) RUN_TLS=1; shift ;;
    --skip-tls) RUN_TLS=0; shift ;;
    --deploy-user) F_USER="${2:?}"; shift 2 ;;
    --app-root) F_ROOT="${2:?}"; shift 2 ;;
    --skip-mysql-repo) SKIP_MYSQL_REPO=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

stack_load "$CONFIG"
[[ -z "$F_SITE" ]] || SITE_DOMAIN="$F_SITE"
[[ -z "$F_API" ]] || API_DOMAIN="$F_API"
[[ -z "$F_ADMIN" ]] || ADMIN_DOMAIN="$F_ADMIN"
[[ -z "$F_EMAIL" ]] || CERT_EMAIL="$F_EMAIL"
[[ -z "$F_USER" ]] || DEPLOY_USER="$F_USER"
[[ -z "$F_ROOT" ]] || APP_ROOT_BASE="$F_ROOT"
stack_validate
need_root
is_dry || id "$DEPLOY_USER" >/dev/null 2>&1 || die "user $DEPLOY_USER not found - run bootstrap.sh first"
export DEBIAN_FRONTEND=noninteractive
mapfile -t APPS < <(enabled_apps)
log "hosting: ${APPS[*]}  (api=$API_DOMAIN site=${SITE_DOMAIN:-none} admin=${ADMIN_DOMAIN:-none})"

# mysql_key_refresh : (re)install the MySQL repo signing key after verifying its fingerprint. Re-runs refresh it too, so an
# expired key (EXPKEYSIG) from an earlier run is repaired instead of breaking every later `apt-get update`.
mysql_key_refresh() {
  if is_dry; then echo "[dry-run] fetch $MYSQL_KEY_URL, verify fingerprint $MYSQL_KEY_FPR, install /etc/apt/keyrings/mysql.gpg" >&2; return 0; fi
  local tmpkey got want
  tmpkey="$(mktemp)"
  curl -fsSL "$MYSQL_KEY_URL" -o "$tmpkey"
  got="$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '$1=="fpr"{print $10; exit}')"
  want="${MYSQL_KEY_FPR// /}"
  [[ "$got" == "$want" ]] || { rm -f "$tmpkey"; die "MySQL repo key fingerprint mismatch (got $got). Aborting - verify the current fingerprint on dev.mysql.com and edit MYSQL_KEY_FPR."; }
  install -d -m 755 /etc/apt/keyrings
  gpg --dearmor <"$tmpkey" >/etc/apt/keyrings/mysql.gpg.new
  mv -f /etc/apt/keyrings/mysql.gpg.new /etc/apt/keyrings/mysql.gpg
  rm -f "$tmpkey"
}

log "1/11 base packages"
if [[ "$SKIP_MYSQL_REPO" == "0" && -f /etc/apt/sources.list.d/mysql-8.4-lts.list ]] && have gpg; then mysql_key_refresh; fi
run apt-get update -y
run apt-get install -y software-properties-common curl gnupg ca-certificates lsb-release unzip git jq rclone age logrotate cron openssl

log "2/11 PHP $PHP_VER (ppa:ondrej/php), nginx, Redis, Supervisor, certbot"
if ! grep -rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then run add-apt-repository -y ppa:ondrej/php; fi
run apt-get update -y
run apt-get install -y nginx redis-server supervisor certbot \
  "php${PHP_VER}-fpm" "php${PHP_VER}-cli" "php${PHP_VER}-mysql" "php${PHP_VER}-redis" "php${PHP_VER}-mbstring" "php${PHP_VER}-xml" \
  "php${PHP_VER}-curl" "php${PHP_VER}-zip" "php${PHP_VER}-bcmath" "php${PHP_VER}-intl" "php${PHP_VER}-gd" "php${PHP_VER}-opcache" \
  "php${PHP_VER}-sqlite3"   # (pcntl ships inside php-cli; there is no separate package)

log "3/11 MySQL 8.4 LTS"
if [[ "$SKIP_MYSQL_REPO" == "0" ]] && ! [[ -f /etc/apt/sources.list.d/mysql-8.4-lts.list ]]; then
  mysql_key_refresh
  if ! is_dry; then
    echo "deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/ubuntu $(lsb_release -sc) mysql-8.4-lts mysql-tools" \
      >/etc/apt/sources.list.d/mysql-8.4-lts.list
  fi
  run apt-get update -y
fi
run apt-get install -y mysql-server
if ! is_dry; then
  ver="$(mysqld --version 2>/dev/null || true)"
  [[ "$ver" == *"Ver 8.4."* ]] || warn "expected MySQL 8.4.x, found: ${ver:-unknown}"
fi
MYCNF_SRC="$INFRA_ROOT/mysql/conf.d/r007.cnf"
RAM_MB="$(ram_mb)"
BP_MB=$(( RAM_MB * 40 / 100 )); (( BP_MB < 512 )) && BP_MB=512
if [[ -f "$MYCNF_SRC" ]]; then
  {
    sed -e "s|^innodb_buffer_pool_size .*|innodb_buffer_pool_size         = ${BP_MB}M|" "$MYCNF_SRC"
    printf '\n[mysqld]\nbind-address = 127.0.0.1\nmysqlx = OFF\n'
  } | write_file /etc/mysql/conf.d/r007.cnf 644
fi
run systemctl enable --now mysql
run systemctl restart mysql

log "4/11 stack settings (/etc/r007/stack.env)"
SECRETS_DIR=/etc/r007
run install -d -m 751 "$SECRETS_DIR"
STACK_FILE="${CONFIG:-/etc/r007/stack.env}"
if is_dry; then echo "[dry-run] create/update $STACK_FILE (non-secret, mode 644)" >&2; else
  [[ -f "$STACK_FILE" ]] || install -m 644 "$INFRA_ROOT/env/stack.env.example" "$STACK_FILE"
  for k in SITE_DOMAIN API_DOMAIN ADMIN_DOMAIN CERT_EMAIL DEPLOY_USER APP_ROOT_BASE; do env_set "$STACK_FILE" "$k" "${!k}"; done
  chmod 644 "$STACK_FILE"   # /etc/r007 is 751 so the deploy user can read stack.env; secrets inside are root-only 600 files
fi

log "5/11 PHP + Composer"
# Upload limits are NOT global: they are set per pool (api/admin 9M/10M, site 2M/4M).
write_file "/etc/php/$PHP_VER/fpm/conf.d/99-r007.ini" 644 <<'INI'
expose_php = Off
memory_limit = 512M
max_execution_time = 60
opcache.enable = 1
opcache.validate_timestamps = 0
opcache.memory_consumption = 192
opcache.max_accelerated_files = 20000
date.timezone = UTC
INI
write_file "/etc/php/$PHP_VER/cli/conf.d/99-r007.ini" 644 <<'INI'
memory_limit = 1G
date.timezone = UTC
INI
if ! have composer; then
  if is_dry; then echo "[dry-run] install composer with signature check" >&2; else
    sig="$(curl -fsSL https://composer.github.io/installer.sig)"
    tmp="$(mktemp -d)"
    curl -fsSL https://getcomposer.org/installer -o "$tmp/installer.php"
    [[ "$(php -r "echo hash_file('sha384','$tmp/installer.php');")" == "$sig" ]] || { rm -rf "$tmp"; die "composer installer signature mismatch"; }
    php "$tmp/installer.php" --quiet --install-dir=/usr/local/bin --filename=composer
    rm -rf "$tmp"
  fi
fi

log "6/11 system users, app directories, PHP-FPM pools (one pool + one user per app)"
run install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_ROOT_BASE"
run install -d -m 755 /var/log/r007 /var/backups/r007 /var/www/letsencrypt
if [[ -e "$APP_ROOT_BASE/current" && ! -e "$APP_ROOT_BASE/api" ]]; then
  warn "legacy single-app layout found in $APP_ROOT_BASE (current/, shared/). The API now lives in $APP_ROOT_BASE/api: move releases/ shared/ current there"
fi
for app in "${APPS[@]}"; do
  u="$(app_user "$app")"; d="$(app_dir "$app")"
  if ! getent group "$u" >/dev/null 2>&1; then run groupadd --system "$u"; fi
  if ! id "$u" >/dev/null 2>&1; then
    run useradd --system --gid "$u" --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$u"
  fi
  run usermod -aG "$u" "$DEPLOY_USER"     # deploy reads .env / writes storage through the group
  run install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$d" "$d/releases"
  run install -d -m 755 -o "$DEPLOY_USER" -g "$u" "$d/shared" "$d/shared/storage"
  ensure_storage_tree "$app"
  render_tpl "$TEMPLATES_DIR/fpm-pool.conf" "$app" | write_file "/etc/php/$PHP_VER/fpm/pool.d/r007-$app.conf" 644
done
# Pool files umask 0007 (files created by PHP are group-writable for the deploy user, invisible to everyone else).
run install -d "/etc/systemd/system/php$PHP_VER-fpm.service.d"
write_file "/etc/systemd/system/php$PHP_VER-fpm.service.d/r007-umask.conf" 644 <<'UM'
[Service]
UMask=0007
UM
for legacy in "/etc/php/$PHP_VER/fpm/pool.d/www.conf" "/etc/php/$PHP_VER/fpm/pool.d/r007.conf"; do
  if [[ -f "$legacy" ]]; then run mv "$legacy" "$legacy.disabled"; fi
done
run systemctl daemon-reload
run systemctl enable --now "php$PHP_VER-fpm"
if ! is_dry; then "php-fpm$PHP_VER" -t >/dev/null 2>&1 || { "php-fpm$PHP_VER" -t >&2 || true; die "php-fpm config test failed"; }; fi
run systemctl restart "php$PHP_VER-fpm"

log "7/11 per-app .env files (mode 640, never in git) + database + Redis"
create_env() { # create_env APP TEMPLATE
  local app="$1" tpl="$2" f; f="$(app_dir "$app")/shared/.env"
  [[ ! -f "$f" ]] || { log "$app: $f exists (left untouched)"; return 0; }
  if is_dry; then echo "[dry-run] create $f from env/$tpl (mode 640, group $(app_user "$app"))" >&2; return 0; fi
  install -m 640 -o "$DEPLOY_USER" -g "$(app_user "$app")" "$INFRA_ROOT/env/$tpl" "$f"
  env_set "$f" APP_KEY ""
  case "$app" in
    api)
      for k in DB_PASSWORD DB_MIGRATOR_PASSWORD REDIS_PASSWORD REVERB_APP_SECRET; do env_fill_generated "$f" "$k" 32; done
      env_set "$f" REVERB_APP_ID "$(random_secret 8)"
      env_set "$f" REVERB_APP_KEY "$(random_secret 20)"
      env_set "$f" APP_URL "https://$API_DOMAIN"
      env_set "$f" REVERB_HOST "$API_DOMAIN"
      env_set "$f" PAYSTACK_CALLBACK_URL "https://$API_DOMAIN/api/v1/payments/webhooks/paystack"
      if app_enabled site; then env_set "$f" CMS_WEB_URL "https://$SITE_DOMAIN"; fi ;;
    site)
      env_set "$f" APP_URL "https://$SITE_DOMAIN"
      env_set "$f" R007_API_BASE_URL "$(api_base_url)"
      env_set "$f" CMS_MEDIA_HOSTS "https://$API_DOMAIN" ;;
    admin)
      env_set "$f" APP_URL "https://$ADMIN_DOMAIN"
      env_set "$f" R007_API_BASE_URL "$(api_base_url)"
      if app_enabled site; then env_set "$f" R007_SITE_URL "https://$SITE_DOMAIN"; fi ;;
    *) die "unknown app $app" ;;
  esac
  log "created $f - fill the remaining <secret> values before the first deploy of $app"
}
for app in "${APPS[@]}"; do
  case "$app" in api) create_env api cloud.env.example ;; site) create_env site site.env.example ;; admin) create_env admin admin.env.example ;; *) : ;; esac
done

ENV_FILE="$(app_dir api)/shared/.env"
if is_dry; then
  echo "[dry-run] mysql: CREATE DATABASE/USER from $ENV_FILE (app=DML, migrator=DDL); redis.conf: bind 127.0.0.1, requirepass <hidden>" >&2
elif [[ -f "$ENV_FILE" ]]; then
  DB_NAME="$(env_get "$ENV_FILE" DB_DATABASE)"; DB_USER="$(env_get "$ENV_FILE" DB_USERNAME)"
  MIG_USER="$(env_get "$ENV_FILE" DB_MIGRATOR_USERNAME)"
  # Passwords are read into variables only; they are passed to mysql on stdin, not argv.
  DB_PASS="$(env_get "$ENV_FILE" DB_PASSWORD)"; MIG_PASS="$(env_get "$ENV_FILE" DB_MIGRATOR_PASSWORD)"
  REDIS_PASS="$(env_get "$ENV_FILE" REDIS_PASSWORD)"
  [[ "$DB_NAME$DB_USER$MIG_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "DB names in $ENV_FILE must be [A-Za-z0-9_]"
  log "creating database + users (idempotent)"
  mysql --batch <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER IF NOT EXISTS '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'127.0.0.1' IDENTIFIED BY '$DB_PASS';
ALTER USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';
GRANT SELECT, INSERT, UPDATE, DELETE ON \`$DB_NAME\`.* TO '$DB_USER'@'127.0.0.1', '$DB_USER'@'localhost';
CREATE USER IF NOT EXISTS '$MIG_USER'@'127.0.0.1' IDENTIFIED BY '$MIG_PASS';
CREATE USER IF NOT EXISTS '$MIG_USER'@'localhost' IDENTIFIED BY '$MIG_PASS';
ALTER USER '$MIG_USER'@'127.0.0.1' IDENTIFIED BY '$MIG_PASS';
ALTER USER '$MIG_USER'@'localhost' IDENTIFIED BY '$MIG_PASS';
GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$MIG_USER'@'127.0.0.1', '$MIG_USER'@'localhost';
FLUSH PRIVILEGES;
SQL
  if [[ -n "$REDIS_PASS" && "$REDIS_PASS" != "<generate>" ]]; then
    RC=/etc/redis/redis.conf
    # One managed block at the end of redis.conf (re-runnable): drop active bind/requirepass/... lines, append ours.
    sed -i -E '/^(bind|requirepass|protected-mode|supervised) /d; /^# BEGIN r007/,/^# END r007/d' "$RC"
    {
      printf '# BEGIN r007 (managed by provision-stack.sh)\nbind 127.0.0.1 -::1\nprotected-mode yes\nsupervised systemd\n'
      printf 'requirepass %s\n# END r007\n' "$REDIS_PASS"
    } >>"$RC"
    chown redis:redis "$RC"; chmod 640 "$RC"
    systemctl enable --now redis-server; systemctl restart redis-server
  fi
else
  warn "$ENV_FILE missing (dry-run?) - skipping DB/Redis credential setup"
fi

log "8/11 Supervisor (API queue/sync/Reverb), cron (API scheduler), logrotate"
# site + admin: QUEUE_CONNECTION=sync and no scheduled commands -> nothing to supervise or schedule.
render_tpl "$TEMPLATES_DIR/supervisor-r007.conf" api | write_file /etc/supervisor/conf.d/r007.conf 644
run systemctl enable --now supervisor
run supervisorctl reread
run supervisorctl update
render_tpl "$TEMPLATES_DIR/cron-r007" api | write_file /etc/cron.d/r007 644
render_tpl "$TEMPLATES_DIR/logrotate-r007" api | write_file /etc/logrotate.d/r007 644
for app in "${APPS[@]}"; do
  render_tpl "$TEMPLATES_DIR/logrotate-r007-app" "$app" | write_file "/etc/logrotate.d/r007-$app" 644
done

log "9/11 nginx server blocks (+ Reverb WebSocket proxy on the API domain)"
run rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-enabled/r007.conf /etc/nginx/sites-available/r007.conf /etc/nginx/snippets/r007-app.conf
nginx_render_common
if [[ "$ADMIN_BASIC_AUTH" == "on" ]] && app_enabled admin; then
  # user:password in a root-only secret file -> nginx htpasswd (apr1 hash; the password never appears in argv or logs)
  if [[ ! -f "$ADMIN_BASIC_AUTH_SECRET_FILE" ]]; then
    if is_dry; then echo "[dry-run] generate $ADMIN_BASIC_AUTH_SECRET_FILE (admin:<random>, mode 600)" >&2; else
      ( umask 077; printf 'admin:%s\n' "$(random_secret 24)" >"$ADMIN_BASIC_AUTH_SECRET_FILE" )
      log "generated $ADMIN_BASIC_AUTH_SECRET_FILE (read it with: sudo cat; hand it to the admins over a secure channel)"
    fi
  fi
  if ! is_dry; then
    chmod 600 "$ADMIN_BASIC_AUTH_SECRET_FILE"
    ba_user="$(cut -d: -f1 <"$ADMIN_BASIC_AUTH_SECRET_FILE" | head -n1)"
    [[ "$ba_user" =~ ^[A-Za-z0-9_.-]+$ ]] || die "basic-auth user in $ADMIN_BASIC_AUTH_SECRET_FILE must match [A-Za-z0-9_.-]+"
    ba_hash="$(cut -d: -f2- <"$ADMIN_BASIC_AUTH_SECRET_FILE" | head -n1 | tr -d '\n' | openssl passwd -apr1 -stdin)"
    ( umask 037; printf '%s:%s\n' "$ba_user" "$ba_hash" >/etc/nginx/r007-admin.htpasswd )
    chown root:www-data /etc/nginx/r007-admin.htpasswd; chmod 640 /etc/nginx/r007-admin.htpasswd
    unset ba_hash
  fi
elif [[ "$ADMIN_BASIC_AUTH" == "off" ]]; then
  run rm -f "$NGINX_ETC/r007-admin.htpasswd"
fi
for app in "${APPS[@]}"; do nginx_render_app "$app"; done
if ! is_dry; then nginx -t; fi
run systemctl enable --now nginx
run systemctl reload nginx

log "10/11 commands (r007-deploy, r007-smoke, r007-tls, r007-provision, r007-artisan, r007-backup, r007-restore-test)"
# The whole scripts tree is copied so the installed commands keep their relative layout; symlinks point into it.
INSTALL_DIR=/opt/r007/infra
if is_dry; then echo "[dry-run] copy scripts/ + env/ + mysql/ to $INSTALL_DIR, symlink r007-* into /usr/local/{bin,sbin}" >&2; else
  install -d -m 755 "$INSTALL_DIR"
  if [[ "$INFRA_ROOT" != "$INSTALL_DIR" ]]; then   # (re-running the installed copy: nothing to copy)
    rm -rf "$INSTALL_DIR/scripts" "$INSTALL_DIR/env" "$INSTALL_DIR/mysql"
    cp -a "$INFRA_ROOT/scripts" "$INFRA_ROOT/env" "$INFRA_ROOT/mysql" "$INSTALL_DIR/"
    rm -rf "$INSTALL_DIR/scripts/windows" "$INSTALL_DIR/scripts/dev"
    chmod -R go-w,a+rX "$INSTALL_DIR"; chown -R root:root "$INSTALL_DIR"
  fi
  ln -sfn "$INSTALL_DIR/scripts/vps/deploy.sh" /usr/local/bin/r007-deploy
  ln -sfn "$INSTALL_DIR/scripts/vps/smoke.sh" /usr/local/bin/r007-smoke
  ln -sfn "$INSTALL_DIR/scripts/vps/artisan.sh" /usr/local/bin/r007-artisan
  ln -sfn "$INSTALL_DIR/scripts/vps/tls.sh" /usr/local/sbin/r007-tls
  ln -sfn "$INSTALL_DIR/scripts/vps/provision-stack.sh" /usr/local/sbin/r007-provision
  ln -sfn "$INSTALL_DIR/scripts/vps/backup.sh" /usr/local/sbin/r007-backup
  ln -sfn "$INSTALL_DIR/scripts/vps/restore-test.sh" /usr/local/sbin/r007-restore-test
fi
# r007-artisan lets the deploy user run artisan AS an app's own user (right file ownership for seeders, cache clears...).
ART_SUDOERS="$(mktemp)"
{
  echo "# Managed by 007resort-infrastructure (provision-stack.sh)"
  for app in "${APPS[@]}"; do
    echo "$DEPLOY_USER ALL=($(app_user "$app")) NOPASSWD: /usr/bin/php artisan *"
  done
} >"$ART_SUDOERS"
if is_dry; then echo "[dry-run] install /etc/sudoers.d/r007-artisan" >&2; else
  visudo -cf "$ART_SUDOERS" >/dev/null || die "generated sudoers file is invalid"
  install -m 440 "$ART_SUDOERS" /etc/sudoers.d/r007-artisan
fi
rm -f "$ART_SUDOERS"
render_tpl "$TEMPLATES_DIR/cron-r007-backup" api | write_file /etc/cron.d/r007-backup 644
write_file /etc/r007/backup.env.example 644 <<'BK'
# Copy to /etc/r007/backup.env (chmod 600) and edit. NO secrets here except paths/remote names;
# rclone credentials live in root's rclone.conf (rclone config), age private key stays OFF this server.
RCLONE_REMOTE=r007-offsite:007resort-cloud-backups   # any rclone remote (S3/B2/GCS/SFTP/...); use a crypt remote for encryption
AGE_RECIPIENT=                                        # age public key (age1...). Encrypts dumps + media + .env files before upload
LOCAL_RETENTION_DAYS=7
REMOTE_RETENTION_DAYS=35
MEDIA_BACKUP=archive                                  # archive = nightly tar of uploaded media | off
# HEALTHCHECK_URL=https://hc-ping.com/<uuid>          # optional dead-man's-switch
BK

log "11/11 TLS"
if [[ "$RUN_TLS" == "1" ]]; then
  [[ -n "$CERT_EMAIL" ]] || die "--email (CERT_EMAIL) is required for --tls"
  if is_dry; then "$SCRIPT_DIR/tls.sh" --dry-run --config "${CONFIG:-/etc/r007/stack.env}"; else "$SCRIPT_DIR/tls.sh"; fi
else
  warn "TLS not requested. Serving plain HTTP until you run 'sudo r007-tls' (after DNS points here and the apps are deployed)."
fi
log "done. Next: fill <secret> values in each shared/.env, then deploy (api first): r007-deploy api <package>. See docs/VPS_RUNBOOK.md"
