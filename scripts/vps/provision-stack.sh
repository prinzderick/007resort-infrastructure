#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE step 2: install the application stack on Ubuntu 24.04.
#
#   sudo scripts/vps/provision-stack.sh --domain api.example.com --email ops@example.com [options] [--dry-run]
#
# Options:
#   --domain NAME          public hostname of this node (REQUIRED; DNS A/AAAA must already point here)
#   --email ADDR           Let's Encrypt registration/renewal contact (REQUIRED unless --skip-tls)
#   --deploy-user NAME     default: deploy (must exist - run bootstrap.sh first)
#   --app-root DIR         default: /var/www/r007   (releases/, shared/, current -> releases/<id>)
#   --skip-tls             do not run certbot (HTTP only; use for staging behind another TLS terminator)
#   --skip-mysql-repo      use MySQL from the distro repo instead of the official 8.4 LTS repo (NOT recommended: Ubuntu 24.04 ships 8.0)
#   --dry-run              print actions, change nothing
#
# Installs/configures (all idempotent): nginx, PHP 8.4-FPM + extensions (ppa:ondrej/php),
# Composer, MySQL 8.4 LTS bound to 127.0.0.1, Redis bound to 127.0.0.1 with a password,
# Supervisor programs (queue, sync worker, Reverb) in group `r007`, cron for schedule:run,
# nginx vhost with a WebSocket proxy for Reverb, certbot TLS, logrotate, and creates
# shared/.env from env/cloud.env.example with generated secrets. Secrets are written only
# to root/deploy-owned mode-600 files and never printed.
set -euo pipefail
SCRIPT_TAG="provision"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"

DOMAIN=""; EMAIL=""; DEPLOY_USER="deploy"; APP_ROOT="/var/www/r007"; SKIP_TLS=0; SKIP_MYSQL_REPO=0
PHP_VER="8.4"
# MySQL release-signing key (2023). Verified by fingerprint before it is trusted.
MYSQL_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2023"
MYSQL_KEY_FPR="BCA4 3417 C3B4 85DD 128E  C6D4 B7B3 B788 A8D3 785C"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:?}"; shift 2 ;;
    --email) EMAIL="${2:?}"; shift 2 ;;
    --deploy-user) DEPLOY_USER="${2:?}"; shift 2 ;;
    --app-root) APP_ROOT="${2:?}"; shift 2 ;;
    --skip-tls) SKIP_TLS=1; shift ;;
    --skip-mysql-repo) SKIP_MYSQL_REPO=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -n "$DOMAIN" ]] || die "--domain is required"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain"
if [[ "$SKIP_TLS" == "0" && -z "$EMAIL" ]]; then die "--email is required for certbot (or pass --skip-tls)"; fi
need_root
is_dry || id "$DEPLOY_USER" >/dev/null 2>&1 || die "user $DEPLOY_USER not found - run bootstrap.sh first"
export DEBIAN_FRONTEND=noninteractive

TEMPLATES="$SCRIPT_DIR/templates"
render() { # render TEMPLATE : substitute @@VARS@@ and print
  sed -e "s|@@DOMAIN@@|$DOMAIN|g" -e "s|@@APP_ROOT@@|$APP_ROOT|g" -e "s|@@DEPLOY_USER@@|$DEPLOY_USER|g" \
      -e "s|@@PHP_VER@@|$PHP_VER|g" "$1"
}

log "1/10 base packages"
run apt-get update -y
run apt-get install -y software-properties-common curl gnupg ca-certificates lsb-release unzip git jq rclone age logrotate cron

log "2/10 PHP $PHP_VER (ppa:ondrej/php), nginx, Redis, Supervisor, certbot"
if ! grep -rqs "ondrej/php" /etc/apt/sources.list.d/ 2>/dev/null; then run add-apt-repository -y ppa:ondrej/php; fi
run apt-get update -y
run apt-get install -y nginx redis-server supervisor certbot \
  "php$PHP_VER-fpm" "php$PHP_VER-cli" "php$PHP_VER-mysql" "php$PHP_VER-redis" "php$PHP_VER-mbstring" "php$PHP_VER-xml" \
  "php$PHP_VER-curl" "php$PHP_VER-zip" "php$PHP_VER-bcmath" "php$PHP_VER-intl" "php$PHP_VER-gd" "php$PHP_VER-opcache" \
  "php$PHP_VER-pcntl" "php$PHP_VER-sqlite3"

log "3/10 MySQL 8.4 LTS"
if [[ "$SKIP_MYSQL_REPO" == "0" ]] && ! [[ -f /etc/apt/sources.list.d/mysql-8.4-lts.list ]]; then
  if is_dry; then
    echo "[dry-run] fetch $MYSQL_KEY_URL, verify fingerprint $MYSQL_KEY_FPR, add repo mysql-8.4-lts" >&2
  else
    tmpkey="$(mktemp)"
    curl -fsSL "$MYSQL_KEY_URL" -o "$tmpkey"
    got="$(gpg --show-keys --with-colons "$tmpkey" | awk -F: '$1=="fpr"{print $10; exit}')"
    want="${MYSQL_KEY_FPR// /}"
    [[ "$got" == "$want" ]] || { rm -f "$tmpkey"; die "MySQL repo key fingerprint mismatch (got $got). Aborting - verify the current fingerprint on dev.mysql.com and edit MYSQL_KEY_FPR."; }
    install -d -m 755 /etc/apt/keyrings
    gpg --dearmor <"$tmpkey" >/etc/apt/keyrings/mysql.gpg
    rm -f "$tmpkey"
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
RAM_MB="$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 8192)"
BP_MB=$(( RAM_MB * 40 / 100 )); (( BP_MB < 512 )) && BP_MB=512
if [[ -f "$MYCNF_SRC" ]]; then
  {
    sed -e "s|^innodb_buffer_pool_size .*|innodb_buffer_pool_size         = ${BP_MB}M|" "$MYCNF_SRC"
    printf '\n[mysqld]\nbind-address = 127.0.0.1\nmysqlx = OFF\n'
  } | write_file /etc/mysql/conf.d/r007.cnf 644
fi
run systemctl enable --now mysql
run systemctl restart mysql

log "4/10 Redis (localhost only, password)"
SECRETS_DIR=/etc/r007
run install -d -m 750 "$SECRETS_DIR"

log "5/10 PHP + Composer"
write_file "/etc/php/$PHP_VER/fpm/conf.d/99-r007.ini" 644 <<'INI'
expose_php = Off
memory_limit = 512M
upload_max_filesize = 20M
post_max_size = 25M
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
# Dedicated FPM pool running as the deploy user, so web + workers + deploy share file ownership
# of storage/ (no group-permission juggling). The socket stays reachable only by nginx (www-data).
write_file "/etc/php/$PHP_VER/fpm/pool.d/r007.conf" 644 <<POOL
[r007]
user = $DEPLOY_USER
group = $DEPLOY_USER
listen = /run/php/php$PHP_VER-fpm.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 24
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 500
catch_workers_output = yes
POOL
if [[ -f "/etc/php/$PHP_VER/fpm/pool.d/www.conf" ]]; then run mv "/etc/php/$PHP_VER/fpm/pool.d/www.conf" "/etc/php/$PHP_VER/fpm/pool.d/www.conf.disabled"; fi
run systemctl enable --now "php$PHP_VER-fpm"
run systemctl reload "php$PHP_VER-fpm"

log "6/10 app directories + database + shared/.env"
run install -d -m 755 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_ROOT" "$APP_ROOT/releases" "$APP_ROOT/shared"
run install -d -m 750 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_ROOT/shared/storage"
run install -d -m 755 /var/log/r007 /var/backups/r007

ENV_FILE="$APP_ROOT/shared/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  if is_dry; then echo "[dry-run] create $ENV_FILE from env/cloud.env.example with generated secrets (mode 600)" >&2; else
    install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$INFRA_ROOT/env/cloud.env.example" "$ENV_FILE"
    for k in DB_PASSWORD DB_MIGRATOR_PASSWORD REDIS_PASSWORD REVERB_APP_SECRET; do env_fill_generated "$ENV_FILE" "$k" 32; done
    env_set "$ENV_FILE" REVERB_APP_ID "$(random_secret 8)"
    env_set "$ENV_FILE" REVERB_APP_KEY "$(random_secret 20)"
    env_set "$ENV_FILE" APP_URL "https://$DOMAIN"
    env_set "$ENV_FILE" REVERB_HOST "$DOMAIN"
    env_set "$ENV_FILE" APP_KEY ""
    log "created $ENV_FILE (generated DB/Redis/Reverb secrets). Fill the <secret> values (Paystack, mail, sync) before the first deploy."
  fi
fi

if [[ -f "$ENV_FILE" ]]; then
  DB_NAME="$(env_get "$ENV_FILE" DB_DATABASE)"; DB_USER="$(env_get "$ENV_FILE" DB_USERNAME)"
  MIG_USER="$(env_get "$ENV_FILE" DB_MIGRATOR_USERNAME)"
  # Passwords are read into variables only; they are passed to mysql on stdin, not argv.
  DB_PASS="$(env_get "$ENV_FILE" DB_PASSWORD)"; MIG_PASS="$(env_get "$ENV_FILE" DB_MIGRATOR_PASSWORD)"
  REDIS_PASS="$(env_get "$ENV_FILE" REDIS_PASSWORD)"
  [[ "$DB_NAME$DB_USER$MIG_USER" =~ ^[A-Za-z0-9_]+$ ]] || die "DB names in $ENV_FILE must be [A-Za-z0-9_]"
  log "creating database + users (idempotent)"
  if is_dry; then echo "[dry-run] mysql: CREATE DATABASE/USER $DB_NAME $DB_USER $MIG_USER (grants: app=DML, migrator=DDL)" >&2; else
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
  fi
  if [[ -n "$REDIS_PASS" && "$REDIS_PASS" != "<generate>" ]]; then
    if is_dry; then echo "[dry-run] redis.conf: bind 127.0.0.1 ::1, requirepass <hidden>" >&2; else
      RC=/etc/redis/redis.conf
      sed -i -E 's/^#?\s*bind .*/bind 127.0.0.1 -::1/; s/^protected-mode .*/protected-mode yes/; s/^#?\s*supervised .*/supervised systemd/' "$RC"
      sed -i -E '/^requirepass /d' "$RC"
      printf 'requirepass %s\n' "$REDIS_PASS" >>"$RC"
      chown redis:redis "$RC"; chmod 640 "$RC"
      systemctl enable --now redis-server; systemctl restart redis-server
    fi
  fi
else
  warn "$ENV_FILE missing (dry-run?) - skipping DB/Redis credential setup"
fi

log "7/10 Supervisor programs (group r007)"
render "$TEMPLATES/supervisor-r007.conf" | write_file /etc/supervisor/conf.d/r007.conf 644
run systemctl enable --now supervisor
run supervisorctl reread
run supervisorctl update

log "8/10 cron (scheduler) + logrotate"
render "$TEMPLATES/cron-r007" | write_file /etc/cron.d/r007 644
render "$TEMPLATES/logrotate-r007" | write_file /etc/logrotate.d/r007 644

log "9/10 nginx vhost (+ Reverb WebSocket proxy)"
render "$TEMPLATES/nginx-r007-app.inc" | write_file /etc/nginx/snippets/r007-app.conf 644
run install -d -m 755 /var/www/letsencrypt
write_file /etc/nginx/conf.d/r007-ratelimit.conf 644 <<'NGX'
# Bound the damage of a misbehaving peer/client (per source IP). Sync also has per-credential limits in the API.
limit_req_zone $binary_remote_addr zone=r007_sync:10m rate=20r/s;
limit_req_zone $binary_remote_addr zone=r007_api:10m rate=30r/s;
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
NGX
run rm -f /etc/nginx/sites-enabled/default
run ln -sfn /etc/nginx/sites-available/r007.conf /etc/nginx/sites-enabled/r007.conf
render_vhost() {
  if [[ "$SKIP_TLS" == "0" && -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    render "$TEMPLATES/nginx-r007-tls.conf"
  else
    render "$TEMPLATES/nginx-r007-http.conf"
  fi
}
render_vhost | write_file /etc/nginx/sites-available/r007.conf 644
if ! is_dry; then nginx -t; fi
run systemctl enable --now nginx
run systemctl reload nginx

log "10/10 TLS (certbot, webroot mode; nginx config stays under our control)"
if [[ "$SKIP_TLS" == "1" ]]; then
  warn "TLS skipped (--skip-tls). The API MUST be served over HTTPS in production."
else
  if [[ ! -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    run certbot certonly --webroot -w /var/www/letsencrypt -d "$DOMAIN" -m "$EMAIL" --agree-tos --no-eff-email --non-interactive
  else
    log "certificate for $DOMAIN already present"
  fi
  write_file /etc/letsencrypt/renewal-hooks/deploy/r007-nginx-reload.sh 755 <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
  if is_dry || [[ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]]; then
    render "$TEMPLATES/nginx-r007-tls.conf" | write_file /etc/nginx/sites-available/r007.conf 644
    if ! is_dry; then nginx -t; fi
    run systemctl reload nginx
  fi
  run systemctl enable --now certbot.timer
fi

# Nightly backup + monthly restore test. Installed here so a fresh node is never without them.
install_backup_cron() {
  render "$TEMPLATES/cron-r007-backup" | write_file /etc/cron.d/r007-backup 644
  write_file /etc/r007/backup.env.example 644 <<'BK'
# Copy to /etc/r007/backup.env (chmod 600) and edit. NO secrets here except paths/remote names;
# rclone credentials live in root's rclone.conf (rclone config), age private key stays OFF this server.
RCLONE_REMOTE=r007-offsite:007resort-cloud-backups   # any rclone remote (S3/B2/GCS/SFTP/...); use a crypt remote for encryption
AGE_RECIPIENT=                                        # age public key (age1...). Encrypts dumps + .env before upload
LOCAL_RETENTION_DAYS=7
REMOTE_RETENTION_DAYS=35
BK
}
install_backup_cron
if ! is_dry; then
  install -m 755 "$SCRIPT_DIR/backup.sh" /usr/local/sbin/r007-backup
  install -m 755 "$SCRIPT_DIR/restore-test.sh" /usr/local/sbin/r007-restore-test
  install -m 755 "$SCRIPT_DIR/deploy.sh" /usr/local/bin/r007-deploy
  install -m 755 "$SCRIPT_DIR/../lib/common.sh" /usr/local/lib/r007-common.sh
  sed -i 's|^source .*common.sh"$|source /usr/local/lib/r007-common.sh|' /usr/local/sbin/r007-backup /usr/local/sbin/r007-restore-test /usr/local/bin/r007-deploy
fi
log "done. Next: create /etc/r007/backup.env, fill secrets in $ENV_FILE, then deploy as $DEPLOY_USER: r007-deploy deploy --package <file> (installed from scripts/vps/deploy.sh)."
