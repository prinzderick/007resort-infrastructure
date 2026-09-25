#!/usr/bin/env bash
# Dev/CI helper: render every nginx template with sample values into a sandbox and run `nginx -t` on the result,
# in HTTP-only mode (no certificates yet) and in HTTPS mode (self-signed test certificates), with the admin
# allow-list + basic auth on and off. Needs nginx and openssl; touches nothing outside a temp directory.
#
#   scripts/vps/check-nginx.sh [--nginx /path/to/nginx] [--routes]
#
# --routes additionally starts nginx unprivileged on high ports (public 127.0.0.1:18080/18443, loopback 18088-18090) with
# PHP replaced by a marker, and asserts the behaviour: routing (robots/sitemap reach Laravel, /build and /storage/cms cache
# headers, dotfiles/.php denied), body-size limits (api/admin 12M, site 4M), HTTP->HTTPS + www redirects, HSTS and security
# headers on every response type, unknown-host rejection, ACME path, admin allow-list (403), basic auth (401), noindex,
# robots.txt, and the POST-only login rate limit (429). Needs curl and python3-free coreutils only.
# shellcheck disable=SC2016,SC2018,SC2019  # printf formats contain literal nginx variables; tr on ASCII headers
set -euo pipefail
SCRIPT_TAG="check-nginx"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

NGINX_BIN="$(command -v nginx || true)"; ROUTES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nginx) NGINX_BIN="${2:?}"; shift 2 ;;
    --routes) ROUTES=1; shift ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ -x "$NGINX_BIN" ]] || die "nginx not found (apt install nginx / brew install nginx)"
need_cmd openssl
[[ "$ROUTES" == "0" ]] || need_cmd curl

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export R007_NGINX_ETC="$T/etc/nginx" R007_LE_DIR="$T/le" R007_ACME_ROOT="$T/acme"
NGINX_ETC="$R007_NGINX_ETC"; LE_DIR="$R007_LE_DIR"; ACME_ROOT="$R007_ACME_ROOT"
mkdir -p "$NGINX_ETC"/{snippets,sites-available,sites-enabled,conf.d} "$ACME_ROOT" "$T/logs"

cat >"$NGINX_ETC/fastcgi_params" <<'FCGI'
fastcgi_param  QUERY_STRING       $query_string;
fastcgi_param  REQUEST_METHOD     $request_method;
fastcgi_param  CONTENT_TYPE       $content_type;
fastcgi_param  CONTENT_LENGTH     $content_length;
fastcgi_param  SCRIPT_NAME        $fastcgi_script_name;
fastcgi_param  REQUEST_URI        $request_uri;
fastcgi_param  DOCUMENT_URI       $document_uri;
fastcgi_param  DOCUMENT_ROOT      $document_root;
fastcgi_param  SERVER_PROTOCOL    $server_protocol;
fastcgi_param  REQUEST_SCHEME     $scheme;
fastcgi_param  HTTPS              $https if_not_empty;
fastcgi_param  GATEWAY_INTERFACE  CGI/1.1;
fastcgi_param  SERVER_SOFTWARE    nginx/$nginx_version;
fastcgi_param  REMOTE_ADDR        $remote_addr;
fastcgi_param  REMOTE_PORT        $remote_port;
fastcgi_param  SERVER_ADDR        $server_addr;
fastcgi_param  SERVER_PORT        $server_port;
fastcgi_param  SERVER_NAME        $server_name;
fastcgi_param  REDIRECT_STATUS    200;
FCGI
# Same shape as Ubuntu's stock nginx.conf (gzip already on at http level: our snippets must not clash with it).
cat >"$NGINX_ETC/nginx.conf" <<CONF
pid $T/nginx.pid;
error_log $T/logs/error.log;
events { worker_connections 64; }
http {
    default_type application/octet-stream;
    types { text/plain txt; text/html html; text/css css; application/javascript js; image/jpeg jpg; }
    access_log $T/logs/access.log;
    client_body_temp_path $T/tmp/body; proxy_temp_path $T/tmp/proxy; fastcgi_temp_path $T/tmp/fcgi;
    uwsgi_temp_path $T/tmp/uwsgi; scgi_temp_path $T/tmp/scgi;
    sendfile on;
    ssl_prefer_server_ciphers on;
    gzip on;
    include $NGINX_ETC/conf.d/*.conf;
    include $NGINX_ETC/sites-enabled/*;
}
CONF

mk_cert() { # mk_cert DOMAIN
  mkdir -p "$LE_DIR/live/$1"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$1" \
    -keyout "$LE_DIR/live/$1/privkey.pem" -out "$LE_DIR/live/$1/fullchain.pem" >/dev/null 2>&1
}

n_ok=0
render_and_test() { # render_and_test LABEL
  local label="$1" a
  rm -f "$NGINX_ETC"/sites-available/* "$NGINX_ETC"/sites-enabled/*
  nginx_render_common
  for a in $(enabled_apps); do nginx_render_app "$a" 2>/dev/null; done
  if "$NGINX_BIN" -t -c "$NGINX_ETC/nginx.conf" -p "$T" >"$T/nginx-t.log" 2>&1; then
    log "OK   nginx -t: $label"; n_ok=$((n_ok+1))
  else
    err "FAIL nginx -t: $label"; sed 's/^/    /' "$T/nginx-t.log" >&2; exit 1
  fi
}

stack_defaults
SITE_DOMAIN=example.com; API_DOMAIN=api.example.com; ADMIN_DOMAIN=admin.example.com
stack_validate
# shellcheck disable=SC2016  # literal htpasswd hash
printf 'admin:$apr1$test$abcdefghijklmnopqrstuv\n' >"$NGINX_ETC/r007-admin.htpasswd"
mkdir -p "$T/tmp"

ADMIN_ALLOW_IPS="203.0.113.7 198.51.100.0/24 2001:db8::/32"; ADMIN_BASIC_AUTH=on
render_and_test "http-only, admin allow-list + basic auth"
ADMIN_ALLOW_IPS=""; ADMIN_BASIC_AUTH=off
render_and_test "http-only, admin open"
for d in "$SITE_DOMAIN" "$API_DOMAIN" "$ADMIN_DOMAIN"; do mk_cert "$d"; done
ADMIN_ALLOW_IPS="203.0.113.7"; ADMIN_BASIC_AUTH=on
render_and_test "https, admin allow-list + basic auth"
grep -q 'allow 203.0.113.7;' "$NGINX_ETC/snippets/r007-admin-access.conf" || die "allow-list missing from the admin access snippet"
grep -q 'auth_basic_user_file' "$NGINX_ETC/snippets/r007-admin-access.conf" || die "basic auth missing from the admin access snippet"
ADMIN_ALLOW_IPS=""; ADMIN_BASIC_AUTH=off; SITE_WWW=off
render_and_test "https, admin open, no www"
SITE_WWW=on
render_and_test "https, defaults"
SITE_DOMAIN=""; ADMIN_DOMAIN=""
render_and_test "https, API only"
log "all $n_ok nginx configurations validated"

# ---------------------------------------------------------------------------------------------------------------
# --routes : behavioural test against a running nginx
# ---------------------------------------------------------------------------------------------------------------
[[ "$ROUTES" == "1" ]] || exit 0
export R007_PORT_API=18088 R007_PORT_SITE=18089 R007_PORT_ADMIN=18090
APP_ROOT_BASE="$T/www"
ADMIN_ALLOW_IPS="203.0.113.7"; ADMIN_BASIC_AUTH=on; SITE_WWW=on
SITE_DOMAIN=example.com; API_DOMAIN=api.example.com; ADMIN_DOMAIN=admin.example.com
printf 'u:%s\n' "$(printf 'pw' | openssl passwd -apr1 -stdin)" >"$NGINX_ETC/r007-admin.htpasswd"
nginx_render_common >/dev/null 2>&1
for a in api site admin; do nginx_render_app "$a" >/dev/null 2>&1; done

# fake application trees (nginx serves static files from public/, PHP is replaced by a marker)
for a in api site admin; do
  mkdir -p "$T/www/$a/current/public/build"
  echo "static robots" >"$T/www/$a/current/public/robots.txt"; echo '<?php' >"$T/www/$a/current/public/index.php"
  echo "js" >"$T/www/$a/current/public/build/app.js"
  printf 'location ~ ^/index\\.php(/|$) { default_type text/plain; include %s/snippets/r007-%s-headers.conf; return 200 "PHP:$uri?$args https=$https\\n"; }\nlocation ~ \\.php$ { return 404; }\n' \
    "$NGINX_ETC" "$a" >"$NGINX_ETC/snippets/r007-$a-php.conf"
done
mkdir -p "$T/www/api/current/public/storage/cms/2026"
echo jpgdata >"$T/www/api/current/public/storage/cms/2026/a.jpg"; echo x >"$T/www/api/current/public/storage/other.txt"
echo SECRET >"$T/www/api/current/public/.env"
head -c 6000 /dev/zero | tr '\0' 'a' >"$T/www/api/current/public/big.txt"
head -c 11000000 /dev/zero >"$T/11m"; head -c 13000000 /dev/zero >"$T/13m"; head -c 5000000 /dev/zero >"$T/5m"

# move the public listeners to unprivileged ports
for f in "$NGINX_ETC"/sites-available/*.conf "$NGINX_ETC/conf.d/r007-common.conf"; do
  sed -i.bak -E '/listen \[::\]/d; s/listen 80( default_server)?;/listen 127.0.0.1:18080\1;/; s/listen 443 ssl( http2| default_server)?;/listen 127.0.0.1:18443 ssl\1;/' "$f"
  rm -f "$f.bak"
done
"$NGINX_BIN" -t -c "$NGINX_ETC/nginx.conf" -p "$T" >"$T/nginx-t.log" 2>&1 || { sed 's/^/    /' "$T/nginx-t.log" >&2; die "routes: nginx -t failed"; }
stop_nginx() { if [[ -f "$T/nginx.pid" ]]; then kill "$(cat "$T/nginx.pid")" 2>/dev/null || true; fi; }
trap 'stop_nginx; rm -rf "$T"' EXIT
"$NGINX_BIN" -c "$NGINX_ETC/nginx.conf" -p "$T"; sleep 1

RES=(--resolve example.com:18443:127.0.0.1 --resolve www.example.com:18443:127.0.0.1 --resolve api.example.com:18443:127.0.0.1 --resolve admin.example.com:18443:127.0.0.1)
hdrs() { curl -sk "${RES[@]}" -o /dev/null -D - "$@" | tr -d '\r' | tr 'A-Z' 'a-z'; }
body() { curl -sk "${RES[@]}" "$@"; }
code() { curl -sk "${RES[@]}" -o /dev/null -w '%{http_code}' "$@" || true; }
R_PASS=0; R_FAIL=0
expect() { # expect NAME WANT_SUBSTRING GOT
  if [[ "$3" == *"$2"* ]]; then R_PASS=$((R_PASS+1)); log "PASS $1"; else R_FAIL=$((R_FAIL+1)); err "FAIL $1: wanted [$2], got [$(printf '%s' "$3" | head -c 300)]"; fi
}
L_API=http://127.0.0.1:18088; L_SITE=http://127.0.0.1:18089; L_ADMIN=http://127.0.0.1:18090

expect "api /up reaches PHP" "PHP:/index.php" "$(body $L_API/up)"
expect "site robots.txt goes to Laravel, not the static file" "PHP:/index.php" "$(body $L_SITE/robots.txt)"
expect "site sitemap.xml goes to Laravel" "PHP:/index.php" "$(body $L_SITE/sitemap.xml)"
expect "site /build immutable cache" "immutable" "$(hdrs $L_SITE/build/app.js)"
expect "site /build keeps security headers" "x-content-type-options: nosniff" "$(hdrs $L_SITE/build/app.js)"
expect "site /build keeps HSTS" "strict-transport-security: max-age=31536000" "$(hdrs $L_SITE/build/app.js)"
expect "api /storage/cms one-year immutable" "max-age=31536000, immutable" "$(hdrs $L_API/storage/cms/2026/a.jpg)"
expect "api /storage/cms serves the file" "200" "$(code $L_API/storage/cms/2026/a.jpg)"
expect "api other /storage 1h" "max-age=3600" "$(hdrs $L_API/storage/other.txt)"
expect "api missing media 404 (not PHP)" "404" "$(code $L_API/storage/cms/none.jpg)"
expect "dotfiles denied" "403" "$(code $L_API/.env)"
expect "stray .php denied" "404" "$(code $L_API/foo.php)"
expect "gzip on text" "content-encoding: gzip" "$(curl -s -o /dev/null -D - -H 'Accept-Encoding: gzip' $L_API/big.txt | tr -d '\r' | tr 'A-Z' 'a-z')"
expect "api accepts an 11 MB body" "PHP:" "$(body -X POST --data-binary @"$T/11m" $L_API/api/v1/x)"
expect "api rejects a 13 MB body" "413" "$(code -X POST --data-binary @"$T/13m" $L_API/api/v1/x)"
expect "admin accepts an 11 MB body (forwards CMS uploads)" "PHP:" "$(body -X POST --data-binary @"$T/11m" $L_ADMIN/x)"
expect "site rejects a 5 MB body" "413" "$(code -X POST --data-binary @"$T/5m" $L_SITE/x)"
expect "loopback admin bypasses allow-list/basic auth" "PHP:" "$(body $L_ADMIN/login)"
expect "site over TLS: PHP sees HTTPS=on" "https=on" "$(body https://example.com:18443/)"
expect "site HSTS" "strict-transport-security: max-age=31536000" "$(hdrs https://example.com:18443/)"
expect "site X-Frame-Options" "x-frame-options: sameorigin" "$(hdrs https://example.com:18443/)"
expect "www -> apex" "location: https://example.com/x" "$(hdrs https://www.example.com:18443/x)"
expect "http -> https keeps path+query" "location: https://example.com/p?q=1" "$(hdrs -H 'Host: example.com' 'http://127.0.0.1:18080/p?q=1')"
expect "http www -> https apex" "location: https://example.com/" "$(hdrs -H 'Host: www.example.com' http://127.0.0.1:18080/)"
expect "unknown Host gets nothing" "000" "$(code -H 'Host: evil.test' http://127.0.0.1:18080/)"
expect "ACME path answered by nginx (404 when no token)" "404" "$(code -H 'Host: example.com' http://127.0.0.1:18080/.well-known/acme-challenge/x)"
expect "api media over TLS" "200" "$(code https://api.example.com:18443/storage/cms/2026/a.jpg)"
expect "admin allow-list blocks other sources" "403" "$(code https://admin.example.com:18443/login)"

# second phase: allow-list off, basic auth on
ADMIN_ALLOW_IPS=""
nginx_render_app admin >/dev/null 2>&1
printf 'location ~ ^/index\\.php(/|$) { default_type text/plain; include %s/snippets/r007-admin-headers.conf; return 200 "PHP:$uri\\n"; }\nlocation ~ \\.php$ { return 404; }\n' "$NGINX_ETC" >"$NGINX_ETC/snippets/r007-admin-php.conf"
sed -i.bak -E '/listen \[::\]/d; s/listen 80( default_server)?;/listen 127.0.0.1:18080\1;/; s/listen 443 ssl( http2| default_server)?;/listen 127.0.0.1:18443 ssl\1;/' "$NGINX_ETC/sites-available/r007-admin.conf"
rm -f "$NGINX_ETC/sites-available/r007-admin.conf.bak"
"$NGINX_BIN" -s reload -c "$NGINX_ETC/nginx.conf" -p "$T"; sleep 1
expect "admin without credentials -> 401" "401" "$(code https://admin.example.com:18443/login)"
expect "admin wrong credentials -> 401" "401" "$(code -u u:bad https://admin.example.com:18443/login)"
expect "admin good credentials reach the app" "PHP:/index.php" "$(body -u u:pw https://admin.example.com:18443/login)"
expect "admin X-Robots-Tag noindex" "x-robots-tag: noindex" "$(hdrs -u u:pw https://admin.example.com:18443/login)"
expect "admin robots.txt disallows all" "Disallow: /" "$(body -u u:pw https://admin.example.com:18443/robots.txt)"
expect "admin ACME path needs no auth" "404" "$(code -H 'Host: admin.example.com' http://127.0.0.1:18080/.well-known/acme-challenge/x)"
codes=""; for _ in $(seq 1 20); do codes+="$(code -u u:pw -X POST -d a=b https://admin.example.com:18443/login) "; done
expect "admin login POST is rate limited (429)" "429" "$codes"
codes=""; for _ in $(seq 1 20); do codes+="$(code -u u:pw https://admin.example.com:18443/login) "; done
if [[ "$codes" == *429* ]]; then expect "admin login GET is not rate limited" "no 429" "$codes"; else expect "admin login GET is not rate limited" "200" "$codes"; fi

log "routes: $R_PASS passed, $R_FAIL failed"
[[ "$R_FAIL" -eq 0 ]]
