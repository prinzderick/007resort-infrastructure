#!/usr/bin/env bash
# Shared model of the multi-app VPS stack (api + site + admin) for the scripts in scripts/vps/.
# Source it after common.sh; do not execute it.
#
# Settings live in /etc/r007/stack.env (template: env/stack.env.example). NON-secret values only.
# An app is "enabled" when its *_DOMAIN is set; API_DOMAIN is always required (site + admin call it).
# shellcheck shell=bash

APPS_ALL=(api site admin)

# shellcheck disable=SC2034  # settings are consumed by the scripts that source this file
stack_defaults() {
  SITE_DOMAIN=""; API_DOMAIN=""; ADMIN_DOMAIN=""; SITE_WWW="on"
  CERT_EMAIL=""; DEPLOY_USER="deploy"; APP_ROOT_BASE="/var/www/r007"; PHP_VER="8.4"
  API_INTERNAL_URL=""
  ADMIN_ALLOW_IPS=""; ADMIN_BASIC_AUTH="off"; ADMIN_BASIC_AUTH_SECRET_FILE="/etc/r007/admin-basic-auth.secret"
  FPM_OPEN_BASEDIR="off"
  API_GIT_URL=""; SITE_GIT_URL=""; ADMIN_GIT_URL=""
  TLS_MIN_DAYS=14
}

# stack_load [FILE] : defaults, then FILE (default $R007_STACK_ENV or /etc/r007/stack.env) if present.
stack_load() {
  local f="${1:-${R007_STACK_ENV:-/etc/r007/stack.env}}"
  stack_defaults
  if [[ -f "$f" ]]; then
    # shellcheck disable=SC1090
    source "$f"
  fi
  [[ -z "${R007_APP_ROOT_BASE:-}" ]] || APP_ROOT_BASE="$R007_APP_ROOT_BASE"
  STACK_ENV_FILE="$f"
  return 0
}

app_valid() { [[ "$1" == "api" || "$1" == "site" || "$1" == "admin" ]]; }

app_domain() {
  case "$1" in
    api) printf '%s' "$API_DOMAIN" ;;
    site) printf '%s' "$SITE_DOMAIN" ;;
    admin) printf '%s' "$ADMIN_DOMAIN" ;;
    *) return 1 ;;
  esac
}
app_enabled() { [[ -n "$(app_domain "$1")" ]]; }
enabled_apps() { local a; for a in "${APPS_ALL[@]}"; do if app_enabled "$a"; then echo "$a"; fi; done; }

app_dir()  { printf '%s/%s' "$APP_ROOT_BASE" "$1"; }
app_user() { printf 'r007-%s' "$1"; }
app_sock() { printf '/run/php/r007-%s.sock' "$1"; }
app_git_url() {
  case "$1" in api) printf '%s' "$API_GIT_URL" ;; site) printf '%s' "$SITE_GIT_URL" ;; admin) printf '%s' "$ADMIN_GIT_URL" ;; *) return 1 ;; esac
}
# Loopback vhost (deploy/smoke health checks; never reachable from outside). R007_PORT_<APP> overrides (tests).
app_port() {
  local v="R007_PORT_${1^^}"
  if [[ -n "${!v:-}" ]]; then printf '%s' "${!v}"; return 0; fi
  case "$1" in api) echo 8088 ;; site) echo 8089 ;; admin) echo 8090 ;; *) return 1 ;; esac
}
# Names served by the app's server block (site also answers on www unless SITE_WWW=off).
app_server_names() {
  if [[ "$1" == "site" && "$SITE_WWW" == "on" ]]; then printf '%s www.%s' "$SITE_DOMAIN" "$SITE_DOMAIN"; else app_domain "$1"; fi
}
app_cert_exists() { [[ -f "${R007_LE_DIR:-/etc/letsencrypt}/live/$(app_domain "$1")/fullchain.pem" ]]; }
# Where site/admin reach the API (public HTTPS URL by default; loopback http://127.0.0.1:8088 is documented).
api_base_url() { if [[ -n "$API_INTERNAL_URL" ]]; then printf '%s' "$API_INTERNAL_URL"; else printf 'https://%s' "$API_DOMAIN"; fi; }

# ram_mb : total RAM in MB (8192 when unknown, e.g. in tests)
ram_mb() { awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 8192; }
# fpm_max_children APP : sized for a 4 vCPU / 8 GB box, scaled down (min 4) on smaller ones.
fpm_max_children() {
  local base ram n
  case "$1" in api) base=16 ;; site) base=10 ;; admin) base=6 ;; *) base=4 ;; esac
  ram="$(ram_mb)"; [[ "$ram" =~ ^[0-9]+$ && "$ram" -gt 0 ]] || ram=8192
  n=$(( base * ram / 8192 )); (( n < 4 )) && n=4
  printf '%s' "$n"
}

# fpm_max_spare APP : FPM insists start(3) >= min_spare(2) and max_spare <= max_children
fpm_max_spare() { local m; m="$(fpm_max_children "$1")"; if (( m - 1 < 6 )); then printf '%s' "$((m - 1))"; else printf '6'; fi; }

_valid_domain() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]]; }

# stack_validate : dies with a clear message on bad settings.
stack_validate() {
  local a d ip seen=" "
  [[ -n "$API_DOMAIN" ]] || die "API_DOMAIN is required (site and admin call the API); set it in $STACK_ENV_FILE or pass --api-domain"
  for a in "${APPS_ALL[@]}"; do
    d="$(app_domain "$a")"
    [[ -z "$d" ]] && continue
    _valid_domain "$d" || die "invalid ${a^^}_DOMAIN: $d"
    [[ "$seen" != *" $d "* ]] || die "the three domains must be different (duplicate: $d)"
    seen+="$d "
  done
  [[ "$SITE_WWW" == "on" || "$SITE_WWW" == "off" ]] || die "SITE_WWW must be on|off"
  [[ "$ADMIN_BASIC_AUTH" == "on" || "$ADMIN_BASIC_AUTH" == "off" ]] || die "ADMIN_BASIC_AUTH must be on|off"
  [[ "$FPM_OPEN_BASEDIR" == "on" || "$FPM_OPEN_BASEDIR" == "off" ]] || die "FPM_OPEN_BASEDIR must be on|off"
  [[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || die "invalid DEPLOY_USER"
  [[ "$APP_ROOT_BASE" =~ ^/[A-Za-z0-9._/-]+$ ]] || die "invalid APP_ROOT_BASE"
  [[ "$PHP_VER" =~ ^[0-9]+\.[0-9]+$ ]] || die "invalid PHP_VER"
  [[ "$API_INTERNAL_URL" =~ ^(https?://[A-Za-z0-9.:-]+)?$ ]] || die "API_INTERNAL_URL must look like https://host[:port] (no path)"
  for ip in ${ADMIN_ALLOW_IPS//,/ }; do
    [[ "$ip" =~ ^[0-9A-Fa-f:.]+(/[0-9]{1,3})?$ ]] || die "ADMIN_ALLOW_IPS: not an IP/CIDR: $ip"
  done
  return 0
}

# ---------------------------------------------------------------------------------------------
# nginx rendering. Templates use @@NAME@@ placeholders; values are validated above (no '|' or '&').
# ---------------------------------------------------------------------------------------------
TEMPLATES_DIR="${TEMPLATES_DIR:-}"
NGINX_ETC="${R007_NGINX_ETC:-/etc/nginx}"
LE_DIR="${R007_LE_DIR:-/etc/letsencrypt}"
ACME_ROOT="${R007_ACME_ROOT:-/var/www/letsencrypt}"

# render_tpl TEMPLATE APP : substitute and print
render_tpl() {
  local t="$1" app="$2" dom names ob upload post
  dom="$(app_domain "$app")"; names="$(app_server_names "$app")"
  ob=";"; [[ "$FPM_OPEN_BASEDIR" == "on" ]] && ob=""
  case "$app" in api|admin) upload="9M"; post="10M" ;; *) upload="2M"; post="4M" ;; esac
  sed -e "s|@@APP@@|$app|g" \
      -e "s|@@APP_DIR@@|$(app_dir "$app")|g" \
      -e "s|@@APP_USER@@|$(app_user "$app")|g" \
      -e "s|@@DOMAIN@@|$dom|g" \
      -e "s|@@SERVER_NAMES@@|$names|g" \
      -e "s|@@FPM_SOCK@@|$(app_sock "$app")|g" \
      -e "s|@@LOOPBACK_PORT@@|$(app_port "$app")|g" \
      -e "s|@@PHP_VER@@|$PHP_VER|g" \
      -e "s|@@DEPLOY_USER@@|$DEPLOY_USER|g" \
      -e "s|@@APP_ROOT_BASE@@|$APP_ROOT_BASE|g" \
      -e "s|@@PM_MAX_CHILDREN@@|$(fpm_max_children "$app")|g" \
      -e "s|@@PM_MAX_SPARE@@|$(fpm_max_spare "$app")|g" \
      -e "s|@@UPLOAD_MAX@@|$upload|g" -e "s|@@POST_MAX@@|$post|g" \
      -e "s|@@OB_PREFIX@@|$ob|g" \
      -e "s|@@NGINX_ETC@@|$NGINX_ETC|g" -e "s|@@LE_DIR@@|$LE_DIR|g" -e "s|@@ACME_ROOT@@|$ACME_ROOT|g" \
      "$t"
}

# nginx_admin_access : the allow/deny + basic-auth snippet body for the admin server block.
nginx_admin_access() {
  local ip
  echo "# Managed by 007resort-infrastructure (scripts/lib/stack.sh). Admin access controls, included by the admin HTTPS server."
  if [[ -n "${ADMIN_ALLOW_IPS//[ ,]/}" ]]; then
    echo "# ADMIN_ALLOW_IPS is set: only these sources may reach the admin portal."
    for ip in ${ADMIN_ALLOW_IPS//,/ }; do echo "allow $ip;"; done
    echo "deny all;"
  else
    echo "# ADMIN_ALLOW_IPS is empty: open to the internet, protected by the portal login (and basic auth when enabled)."
  fi
  if [[ "$ADMIN_BASIC_AUTH" == "on" ]]; then
    echo 'auth_basic "007 Resort admin";'
    echo "auth_basic_user_file $NGINX_ETC/r007-admin.htpasswd;"
    echo "# satisfy all (default): allow-list AND basic auth AND portal login."
  fi
}

# nginx_render_common : http-level settings + default (reject-unknown-host) server
nginx_render_common() {
  render_tpl "$TEMPLATES_DIR/nginx-common.conf" api | write_file "$NGINX_ETC/conf.d/r007-common.conf" 644
  render_tpl "$TEMPLATES_DIR/nginx-common-server.inc" api | write_file "$NGINX_ETC/snippets/r007-common.conf" 644
}

# nginx_render_app APP : snippets + server file for one app. Uses the TLS server once its certificate exists.
nginx_render_app() {
  local app="$1" mode="http" robots=""
  app_cert_exists "$app" && mode="tls"
  [[ "$app" == "admin" ]] && robots='add_header X-Robots-Tag "noindex, nofollow, noarchive" always;'
  render_tpl "$TEMPLATES_DIR/nginx-headers.inc" "$app" | sed "s|@@ROBOTS_HEADER@@|$robots|" | write_file "$NGINX_ETC/snippets/r007-$app-headers.conf" 644
  render_tpl "$TEMPLATES_DIR/nginx-php.inc" "$app" | write_file "$NGINX_ETC/snippets/r007-$app-php.conf" 644
  render_tpl "$TEMPLATES_DIR/nginx-body-$app.inc" "$app" | write_file "$NGINX_ETC/snippets/r007-$app-body.conf" 644
  if [[ "$app" == "admin" ]]; then
    nginx_admin_access | write_file "$NGINX_ETC/snippets/r007-admin-access.conf" 644
  else
    printf '# Managed by 007resort-infrastructure. No extra access controls for %s.\n' "$app" | write_file "$NGINX_ETC/snippets/r007-$app-access.conf" 644
  fi
  {
    render_tpl "$TEMPLATES_DIR/nginx-server-$mode.conf" "$app"
    if [[ "$app" == "site" && "$SITE_WWW" == "on" && "$mode" == "tls" ]]; then
      render_tpl "$TEMPLATES_DIR/nginx-site-www-redirect.conf" "$app"
    fi
    render_tpl "$TEMPLATES_DIR/nginx-server-loopback.conf" "$app"
  } | write_file "$NGINX_ETC/sites-available/r007-$app.conf" 644
  run ln -sfn "$NGINX_ETC/sites-available/r007-$app.conf" "$NGINX_ETC/sites-enabled/r007-$app.conf"
  log "nginx: $app -> $(app_domain "$app") ($mode)"
}

# ---------------------------------------------------------------------------------------------
# .env helpers and per-app filesystem layout
# ---------------------------------------------------------------------------------------------

# env_val FILE KEY : value with a trailing "  # comment" and outer double quotes removed.
env_val() {
  local v; v="$(env_get "$1" "$2")"
  v="${v%%[[:space:]]#*}"
  v="${v%"${v##*[![:space:]]}"}"
  v="${v%\"}"; v="${v#\"}"
  printf '%s' "$v"
}

# ensure_storage_tree APP : the per-app shared/storage tree with isolation-friendly permissions.
#   * group = the app's own group (r007-<app>); pool user + workers write via that group, deploy is a member;
#   * storage/ and storage/app/ are traversable (x only) by others so nginx can reach app/public;
#   * app/public is world-readable (uploaded media, served by nginx), everything else is group-only.
# Runs as root (provision) or as the deploy user (deploy.sh): as non-root it only touches what it owns.
ensure_storage_tree() {
  local app="$1" s u d
  s="$(app_dir "$app")/shared/storage"; u="$(app_user "$app")"
  for d in app/public framework/cache/data framework/sessions framework/views logs; do run mkdir -p "$s/$d"; done
  if is_dry; then return 0; fi
  local own=()
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    own=(-user "$(id -u)")
  elif id "$DEPLOY_USER" >/dev/null 2>&1; then
    find "$s" -path "$s/app/public" -prune -o -user root -exec chown "$DEPLOY_USER" {} + 2>/dev/null || true
  fi
  find "$s" -path "$s/app/public" -prune -o "${own[@]}" -exec chgrp "$u" {} + 2>/dev/null || true
  find "$s" -path "$s/app/public" -prune -o -type d "${own[@]}" -exec chmod 2770 {} + 2>/dev/null || true
  find "$s/framework" "$s/logs" -type f "${own[@]}" -exec chmod 0660 {} + 2>/dev/null || true
  chmod 2771 "$s" "$s/app" 2>/dev/null || true
  if [[ "${EUID:-$(id -u)}" -eq 0 ]] && id "$DEPLOY_USER" >/dev/null 2>&1; then chown "$DEPLOY_USER" "$s/app/public" 2>/dev/null || true; fi
  chgrp "$u" "$s/app/public" 2>/dev/null || true
  chmod 2775 "$s/app/public" 2>/dev/null || true
  return 0
}
