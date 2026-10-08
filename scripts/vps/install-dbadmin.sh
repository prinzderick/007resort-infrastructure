#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE: Adminer (database web UI) reachable ONLY through an SSH tunnel.
#
#   sudo bash install-dbadmin.sh                 # install / upgrade, create the DB login on first run
#   sudo bash install-dbadmin.sh --read-only     # DB login can only read (SELECT, SHOW VIEW)
#   sudo bash install-dbadmin.sh --rotate        # issue a NEW DB password (printed once)
#   sudo bash install-dbadmin.sh --dry-run       # print the plan only
#   sudo bash install-dbadmin.sh --remove        # uninstall everything this script created
#   options: --db r007  --port 8099  --version 6.1.1
#
# Why Adminer and not phpMyAdmin: the latest phpMyAdmin (5.2.x) only supports PHP < 8.4 and this stack runs PHP 8.4.
# Adminer is one file, supports 8.4 and exposes far less code.
#
# Why a tunnel: nginx listens on 127.0.0.1 ONLY (the firewall never sees it), so there is no public login page to
# attack, no DNS name, no certificate, and it works from any network (house, office) with no IP allow-list:
#
#   ssh -N -L 8099:127.0.0.1:8099 deploy@<server>     then open  http://127.0.0.1:8099/
#
# What it sets up: its own PHP-FPM pool + system user (not the API's), open_basedir jail, no exec functions,
# a MySQL login `r007_dba` limited to ONE database and to localhost, with a random password printed once.
# Integrity: the Adminer file is fetched over HTTPS from the official GitHub release; upstream publishes no
# checksum, so its SHA-256 is printed for your records.
set -euo pipefail
SCRIPT_TAG="dbadmin"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if [[ -f "$SCRIPT_DIR/../lib/common.sh" ]]; then
  # shellcheck source=../lib/common.sh
  # shellcheck source-path=SCRIPTDIR
  source "$SCRIPT_DIR/../lib/common.sh"
else
  # Standalone mode (downloaded on its own into a root console): the few helpers this script needs.
  DRY_RUN=0; _c_dim=""; _c_off=""
  log()  { printf '[%s] %s\n' "$SCRIPT_TAG" "$*" >&2; }
  die()  { printf '[%s] ERROR: %s\n' "$SCRIPT_TAG" "$*" >&2; exit 1; }
  is_dry() { [[ "$DRY_RUN" == "1" ]]; }
  have() { command -v "$1" >/dev/null 2>&1; }
  run() { if is_dry; then echo "[dry-run] $*" >&2; else "$@"; fi; }
  need_root() { if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! is_dry; then die "run as root (sudo)"; fi; }
  random_secret() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; echo; }
  write_file() {
    local path="$1" mode="${2:-644}" tmp; tmp="$(mktemp)"; cat >"$tmp"
    if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then rm -f "$tmp"; return 0; fi
    if is_dry; then echo "[dry-run] write $path (mode $mode)" >&2; rm -f "$tmp"; return 0; fi
    install -m "$mode" "$tmp" "$path"; rm -f "$tmp"; log "wrote $path"
  }
  REST_ARGS=()
  parse_common_flags() { REST_ARGS=(); local a; for a in "$@"; do case "$a" in --dry-run|-n) DRY_RUN=1 ;; *) REST_ARGS+=("$a") ;; esac; done; }
fi

PHP_VER="${PHP_VER:-8.4}"
DB_NAME="r007"; PORT="8099"; VERSION=""; READ_ONLY=0; ROTATE=0; REMOVE=0
APP_USER="r007-dbadmin"; DB_USER="r007_dba"
WEB_DIR="/var/www/r007-dbadmin"; STATE_DIR="/var/lib/r007-dbadmin"
POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/r007-dbadmin.conf"; SOCK="/run/php/r007-dbadmin.sock"
NGINX_AVAIL="/etc/nginx/sites-available/r007-dbadmin.conf"; NGINX_ENABLED="/etc/nginx/sites-enabled/r007-dbadmin.conf"

parse_common_flags "$@"
set -- "${REST_ARGS[@]}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db) DB_NAME="${2:?--db needs a value}"; shift 2 ;;
    --port) PORT="${2:?--port needs a value}"; shift 2 ;;
    --version) VERSION="${2:?--version needs a value}"; shift 2 ;;
    --read-only) READ_ONLY=1; shift ;;
    --rotate) ROTATE=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "--db must be [A-Za-z0-9_]"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number"
need_root

# shellcheck disable=SC2154  # _c_dim/_c_off come from common.sh
mysql_exec() { # stdin -> mysql as root over the unix socket (no password on argv)
  if is_dry; then printf '%s[dry-run]%s mysql: %s\n' "$_c_dim" "$_c_off" "$1" >&2; cat >/dev/null; return 0; fi
  mysql --batch
}

if [[ "$REMOVE" == "1" ]]; then
  log "removing Adminer (nginx site, FPM pool, files, system user, MySQL login)"
  run rm -f "$NGINX_ENABLED" "$NGINX_AVAIL" "$POOL_FILE"
  run rm -rf "$WEB_DIR" "$STATE_DIR"
  if id "$APP_USER" >/dev/null 2>&1; then run userdel "$APP_USER" || true; fi
  mysql_exec "drop login" <<SQL
DROP USER IF EXISTS '${DB_USER}'@'localhost';
DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';
SQL
  if ! is_dry; then nginx -t && systemctl reload nginx; systemctl reload "php${PHP_VER}-fpm"; fi
  log "done"
  exit 0
fi

if ! is_dry; then
  have nginx || die "nginx is not installed - run provision-stack.sh first"
  [[ -d "/etc/php/${PHP_VER}/fpm/pool.d" ]] || die "php${PHP_VER}-fpm is not installed (set PHP_VER=...)"
  have mysql || die "mysql client not found"
  have curl || die "curl not found"
  have jq || die "jq not found"
fi
if ! is_dry && [[ ! -d /etc/nginx/sites-enabled ]]; then die "expected Debian/Ubuntu nginx layout (sites-enabled)"; fi

if ! is_dry && ss -ltnH "sport = :${PORT}" 2>/dev/null | grep -q . && [[ ! -L "$NGINX_ENABLED" ]]; then
  die "port ${PORT} is already used by something else - pick another with --port"
fi

# ---- 1. system user + directories
log "1/6 system user and directories"
if ! id "$APP_USER" >/dev/null 2>&1; then
  run useradd --system --no-create-home --shell /usr/sbin/nologin "$APP_USER"
fi
run install -d -m 755 -o root -g root "$WEB_DIR"
run install -d -m 700 -o "$APP_USER" -g "$APP_USER" "$STATE_DIR"

# ---- 2. Adminer (MySQL-only, English-only build = smallest surface)
log "2/6 Adminer"
if [[ -z "$VERSION" ]]; then
  if is_dry; then VERSION="<latest>"; else
    VERSION="$(curl -fsSL --max-time 20 https://api.github.com/repos/vrana/adminer/releases/latest | jq -r '.tag_name' | sed 's/^v//')"
  fi
fi
[[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+|<latest>)$ ]] || die "unexpected Adminer version '$VERSION'"
URL="https://github.com/vrana/adminer/releases/download/v${VERSION}/adminer-${VERSION}-mysql-en.php"
if is_dry; then
  echo "[dry-run] download $URL -> $WEB_DIR/index.php (mode 644, root-owned)" >&2
else
  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  curl -fsSL --max-time 120 -o "$tmp" "$URL" || die "download failed: $URL"
  head -c 5 "$tmp" | grep -q '^<?php' || die "downloaded file does not look like PHP - aborting"
  php"${PHP_VER}" -l "$tmp" >/dev/null || die "downloaded file failed a PHP syntax check"
  install -m 644 -o root -g root "$tmp" "$WEB_DIR/index.php"
  log "Adminer ${VERSION} installed, sha256=$(sha256sum "$WEB_DIR/index.php" | cut -d' ' -f1)"
fi

# ---- 3. PHP-FPM pool (own user, jailed, no shell-exec functions)
log "3/6 PHP-FPM pool"
write_file "$POOL_FILE" 644 <<POOL
; Managed by 007resort-infrastructure (scripts/vps/install-dbadmin.sh). Adminer only.
[r007-dbadmin]
user = ${APP_USER}
group = ${APP_USER}
listen = ${SOCK}
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = ondemand
pm.max_children = 3
pm.process_idle_timeout = 30s
pm.max_requests = 200
request_terminate_timeout = 120s
security.limit_extensions = .php
php_admin_value[upload_max_filesize] = 64M
php_admin_value[post_max_size] = 64M
php_admin_value[session.save_path] = ${STATE_DIR}
php_admin_value[open_basedir] = ${WEB_DIR}:${STATE_DIR}:/tmp:/usr/share/php:/dev/urandom
php_admin_value[disable_functions] = exec,passthru,shell_exec,system,proc_open,popen,pcntl_exec
php_admin_flag[expose_php] = off
POOL

# ---- 4. nginx: loopback only
log "4/6 nginx (127.0.0.1:${PORT} only)"
write_file "$NGINX_AVAIL" 644 <<NGINX
# Managed by 007resort-infrastructure (scripts/vps/install-dbadmin.sh). Loopback only: reach it via an SSH tunnel.
server {
    listen 127.0.0.1:${PORT};
    server_name _;
    server_tokens off;
    root ${WEB_DIR};
    client_max_body_size 64m;

    location = / { try_files /index.php =404; }
    location = /index.php {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME ${WEB_DIR}/index.php;
        fastcgi_pass unix:${SOCK};
        fastcgi_read_timeout 120s;
    }
    location / { return 404; }
}
NGINX
run ln -sfn "$NGINX_AVAIL" "$NGINX_ENABLED"
if ! is_dry; then
  "php-fpm${PHP_VER}" -t >/dev/null 2>&1 || { "php-fpm${PHP_VER}" -t >&2 || true; die "php-fpm config test failed"; }
  nginx -t >/dev/null 2>&1 || { nginx -t >&2 || true; die "nginx config test failed"; }
  systemctl reload "php${PHP_VER}-fpm"
  systemctl reload nginx
fi

# ---- 5. MySQL login limited to one database, localhost only
log "5/6 MySQL login ${DB_USER} (${DB_NAME} only$([[ "$READ_ONLY" == "1" ]] && echo ', read-only'))"
if [[ "$READ_ONLY" == "1" ]]; then PRIV="SELECT, SHOW VIEW"; else PRIV="ALL PRIVILEGES"; fi
NEW_PASS=""
exists=0
if ! is_dry; then
  [[ "$(mysql --batch --skip-column-names -e "SELECT COUNT(*) FROM mysql.user WHERE User='${DB_USER}'")" -gt 0 ]] && exists=1
fi
if [[ "$exists" == "0" || "$ROTATE" == "1" ]]; then
  if is_dry; then NEW_PASS="<generated-on-real-run>"; else NEW_PASS="$(random_secret 28)"; fi
fi
{
    if [[ -n "$NEW_PASS" ]]; then
      for h in localhost 127.0.0.1; do
        echo "CREATE USER IF NOT EXISTS '${DB_USER}'@'${h}' IDENTIFIED BY '${NEW_PASS}' WITH MAX_USER_CONNECTIONS 5;"
        echo "ALTER USER '${DB_USER}'@'${h}' IDENTIFIED BY '${NEW_PASS}';"
      done
    fi
    for h in localhost 127.0.0.1; do
      echo "REVOKE ALL PRIVILEGES, GRANT OPTION FROM '${DB_USER}'@'${h}';"
      echo "GRANT ${PRIV} ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${h}';"
    done
} | mysql_exec "create/alter ${DB_USER} (password hidden)"

# ---- 6. self-check
log "6/6 checks"
if ! is_dry; then
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:${PORT}/" || true)"
  [[ "$code" == "200" ]] || die "Adminer answered HTTP ${code:-none} on 127.0.0.1:${PORT} (see: journalctl -u nginx, /var/log/php${PHP_VER}-fpm.log)"
  if ss -ltnH "sport = :${PORT}" | grep -vq "127.0.0.1:${PORT}"; then die "port ${PORT} is listening on a non-loopback address - refusing to leave it like this"; fi
  log "OK: answers on 127.0.0.1:${PORT} and nowhere else"
fi

cat >&2 <<DONE

  Adminer is ready (tunnel only). From YOUR computer:

      ssh -N -L ${PORT}:127.0.0.1:${PORT} deploy@<this-server>
      then open  http://127.0.0.1:${PORT}/

  Login:  System = MySQL   Server = localhost   Database = ${DB_NAME}
          Username = ${DB_USER}
DONE
if [[ -n "$NEW_PASS" ]]; then
  printf '          Password = %s\n\n  Copy the password NOW - it is not stored anywhere. Lost it? Re-run with --rotate.\n\n' "$NEW_PASS" >&2
else
  printf '          Password = (unchanged - re-run with --rotate for a new one)\n\n' >&2
fi
