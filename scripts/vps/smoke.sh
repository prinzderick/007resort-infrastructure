#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE smoke tests for the api, site and admin apps. Installed as /usr/local/bin/r007-smoke.
# Used by deploy.sh (mode local, after every deploy; a failure rolls that app back) and by the CI workflow
# (mode public, after the deploy; a failure triggers `r007-deploy rollback <app>`).
#
#   r007-smoke [--app api|site|admin|all] [--mode local|public] [options]
#
#   --mode local     talk to the loopback servers (127.0.0.1:8088 api / 8089 site / 8090 admin): app health only,
#                    independent of DNS, TLS, the IP allow-list and basic auth. Default for deploy.sh.
#   --mode public    talk to https://<domain>: also checks TLS validity + expiry (>= TLS_MIN_DAYS, default 14),
#                    HTTP->HTTPS redirect, HSTS, www redirect, admin noindex. Default.
#   --retries N      attempts (2 s apart) for each app's /up before giving up (default: 1 public, 20 local)
#   --strict         a missing CMS media URL on the home page is a failure (default: warning; a fresh site has none)
#   --insecure       do not verify the TLS chain (staging with a self-signed certificate only; expiry is still checked)
#   --admin-auth-stdin   read "user:password" for the admin basic-auth layer from stdin (or SMOKE_ADMIN_BASIC_AUTH)
#   --config FILE    stack settings (default /etc/r007/stack.env)      --dry-run   print the checks only
#
# Checks: API /up + /api/v1/system/info; site /up, home page (200 + real HTML), robots.txt, sitemap.xml, one CMS media
# URL from the home page (200 + image/*; or SMOKE_MEDIA_URL); admin /up + /login (200 + password field).
# Public mode with an admin allow-list/basic auth in front: 403/401 is reported as "protected" (loopback covers the app).
# Exit 0 = all passed. Never prints secrets.
set -euo pipefail
SCRIPT_TAG="smoke"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"

APP="all"; MODE="public"; CONFIG=""; RETRIES=""; STRICT=0; AUTH_STDIN=0; INSECURE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="${2:?}"; shift 2 ;;
    --mode) MODE="${2:?}"; shift 2 ;;
    --config) CONFIG="${2:?}"; shift 2 ;;
    --retries) RETRIES="${2:?}"; shift 2 ;;
    --strict) STRICT=1; shift ;;
    --insecure) INSECURE=1; shift ;;
    --admin-auth-stdin) AUTH_STDIN=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
[[ "$MODE" == "local" || "$MODE" == "public" ]] || die "--mode must be local|public"
[[ "$APP" == "all" ]] || app_valid "$APP" || die "--app must be api|site|admin|all"
need_cmd curl
stack_load "$CONFIG"
stack_validate
[[ -n "$RETRIES" ]] || { if [[ "$MODE" == "local" ]]; then RETRIES=20; else RETRIES=1; fi; }
[[ "$RETRIES" =~ ^[0-9]+$ && "$RETRIES" -ge 1 ]] || die "--retries must be a positive integer"
ADMIN_AUTH="${SMOKE_ADMIN_BASIC_AUTH:-}"
if [[ "$AUTH_STDIN" == "1" ]]; then IFS= read -r ADMIN_AUTH || true; fi
SMOKE_TLS_DAYS="${TLS_MIN_DAYS:-14}"

if [[ "$APP" == "all" ]]; then mapfile -t APPS < <(enabled_apps); else
  app_enabled "$APP" || die "app $APP is not enabled in $STACK_ENV_FILE"
  APPS=("$APP")
fi
if is_dry; then
  for a in "${APPS[@]}"; do
    if [[ "$MODE" == "local" ]]; then u="http://127.0.0.1:$(app_port "$a")"; else u="https://$(app_domain "$a")"; fi
    log "[dry-run] would check $a ($MODE): $u"
  done
  exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
FAILS=0; PASSES=0; WARNS=0
# ok_if LABEL_OK LABEL_FAIL CMD... : pass/fail by the command's status
ok_if() { local a="$1" b="$2"; shift 2; if "$@"; then pass "$a"; else fail "$b"; fi; }
pass() { PASSES=$((PASSES+1)); printf '  PASS  %s\n' "$*" >&2; }
fail() { FAILS=$((FAILS+1)); printf '  FAIL  %s\n' "$*" >&2; }
note() { WARNS=$((WARNS+1)); printf '  WARN  %s\n' "$*" >&2; }

CURL_TLS=(); [[ "$INSECURE" == "0" ]] || CURL_TLS=(-k)
base_url() { if [[ "$MODE" == "local" ]]; then printf 'http://127.0.0.1:%s' "$(app_port "$1")"; else printf 'https://%s' "$(app_domain "$1")"; fi; }

# get APP PATH [extra curl args...] : body in $WORK/body, headers in $WORK/head, prints the HTTP status (000 = no answer)
get() {
  local app="$1" path="$2"; shift 2
  local url cfg=()
  url="$(base_url "$app")$path"
  if [[ "$app" == "admin" && -n "$ADMIN_AUTH" && "$MODE" == "public" ]]; then
    local q="${ADMIN_AUTH//\\/\\\\}"; q="${q//\"/\\\"}"
    printf 'user = "%s"\n' "$q" >"$WORK/curlcfg"; cfg=(-K "$WORK/curlcfg")
  fi
  curl -sS -o "$WORK/body" -D "$WORK/head" -w '%{http_code}' --max-time 20 -H 'Accept: text/html,application/json' \
    "${cfg[@]}" "${CURL_TLS[@]}" "$@" "$url" 2>/dev/null || true
}
header() { grep -i "^$1:" "$WORK/head" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//' || true; }

# expect_200 APP PATH LABEL : returns 0 and leaves the body in $WORK/body when 200
expect_200() {
  local code; code="$(get "$1" "$2")"
  if [[ "$code" == "200" ]]; then pass "$3 -> 200"; return 0; fi
  if [[ "$MODE" == "public" && "$1" == "admin" && ( "$code" == "401" || "$code" == "403" ) ]]; then
    note "$3 -> $code: admin is protected by the allow-list/basic auth (verified by the loopback smoke instead)"; return 1
  fi
  fail "$3 -> HTTP $code (expected 200)"; return 1
}

wait_up() { # wait_up APP : /up with retries
  local i code
  for (( i=1; i<=RETRIES; i++ )); do
    code="$(get "$1" /up)"
    if [[ "$code" == "200" ]]; then pass "$1 /up -> 200"; return 0; fi
    if [[ "$MODE" == "public" && "$1" == "admin" && ( "$code" == "401" || "$code" == "403" ) ]]; then
      note "admin /up -> $code: protected by the allow-list/basic auth (verified by the loopback smoke instead)"; return 1
    fi
    (( i < RETRIES )) && sleep 2
  done
  fail "$1 /up -> HTTP $code after $RETRIES attempt(s)"; return 1
}

check_tls() { # check_tls DOMAIN
  local d="$1" pem to=()
  have timeout && to=(timeout 15)
  pem="$("${to[@]}" openssl s_client -servername "$d" -connect "$d:443" </dev/null 2>/dev/null | openssl x509 2>/dev/null || true)"
  if [[ -z "$pem" ]]; then fail "TLS $d: no certificate presented on :443"; return; fi
  if printf '%s' "$pem" | openssl x509 -noout -checkend $(( SMOKE_TLS_DAYS * 86400 )) >/dev/null; then
    pass "TLS $d valid, $(printf '%s' "$pem" | openssl x509 -noout -enddate | sed 's/notAfter=/expires /') (>= ${SMOKE_TLS_DAYS} days left)"
  else
    fail "TLS $d certificate expires within ${SMOKE_TLS_DAYS} days (or already expired): run 'sudo r007-tls' / check certbot.timer"
  fi
}

check_redirect() { # check_redirect HOST TARGET_PREFIX
  local code loc
  code="$(curl -sS -o /dev/null -D "$WORK/rh" -w '%{http_code}' --max-time 15 "http://$1/" 2>/dev/null || true)"
  loc="$(grep -i '^location:' "$WORK/rh" 2>/dev/null | head -n1 | cut -d: -f2- | tr -d '\r ' || true)"
  if [[ ( "$code" == "301" || "$code" == "308" ) && "$loc" == "$2"* ]]; then pass "http://$1/ -> $code $2"; else fail "http://$1/ -> $code ${loc:+($loc)} (expected redirect to $2)"; fi
}

check_api() {
  log "api ($(base_url api))"
  wait_up api || return 0
  if expect_200 api /api/v1/system/info "api /api/v1/system/info"; then
    ok_if "system/info is JSON" "system/info is not JSON" grep -q '^ *{' "$WORK/body"
  fi
  if [[ "$MODE" == "public" ]]; then
    check_tls "$API_DOMAIN"; check_redirect "$API_DOMAIN" "https://$API_DOMAIN"
    get api /up >/dev/null; ok_if "api HSTS header present" "api HSTS header missing" test -n "$(header strict-transport-security)"
  fi
}

check_media() {
  local home="$1" url="${SMOKE_MEDIA_URL:-}" code ctype
  if [[ -z "$url" ]]; then
    url="$(grep -oE "(https?://[^\"' )]+)?/storage/cms/[^\"' )]+" "$home" 2>/dev/null | head -n1 || true)"
  fi
  if [[ -z "$url" ]]; then
    if [[ "$STRICT" == "1" ]]; then fail "no CMS media URL found on the home page (--strict)"; else note "no /storage/cms/ media URL on the home page yet (seed or upload content, or set SMOKE_MEDIA_URL)"; fi
    return
  fi
  if [[ "$url" == /* ]]; then url="$(base_url api)$url"; fi
  if [[ "$MODE" == "local" ]]; then url="$(printf '%s' "$url" | sed -E "s#^https?://$API_DOMAIN#$(base_url api)#")"; fi
  code="$(curl -sS "${CURL_TLS[@]}" -o /dev/null -w '%{http_code} %{content_type}' --max-time 20 "$url" 2>/dev/null || true)"
  ctype="${code#* }"; code="${code%% *}"
  if [[ "$code" == "200" && "$ctype" == image/* ]]; then pass "media $(printf '%s' "$url" | sed -E 's#^https?://[^/]+##') -> 200 $ctype"; else fail "media URL -> HTTP $code ($ctype)"; fi
}

check_site() {
  log "site ($(base_url site))"
  wait_up site || return 0
  if expect_200 site / "site home"; then
    local size; size="$(wc -c <"$WORK/body" | tr -d ' ')"
    if grep -qi '<html' "$WORK/body" && (( size > 500 )); then pass "site home has content (${size} bytes of HTML)"; else fail "site home is not a real HTML page (${size} bytes)"; fi
    cp "$WORK/body" "$WORK/home.html"; check_media "$WORK/home.html"
  fi
  expect_200 site /robots.txt "site robots.txt" || true
  expect_200 site /sitemap.xml "site sitemap.xml" || true
  if [[ "$MODE" == "public" ]]; then
    check_tls "$SITE_DOMAIN"; check_redirect "$SITE_DOMAIN" "https://$SITE_DOMAIN"
    if [[ "$SITE_WWW" == "on" ]]; then check_redirect "www.$SITE_DOMAIN" "https://$SITE_DOMAIN"; fi
    get site /up >/dev/null; ok_if "site HSTS header present" "site HSTS header missing" test -n "$(header strict-transport-security)"
  fi
}

check_admin() {
  log "admin ($(base_url admin))"
  if [[ "$MODE" == "public" ]]; then   # independent of the app (and of any allow-list/basic auth in front of it)
    check_tls "$ADMIN_DOMAIN"; check_redirect "$ADMIN_DOMAIN" "https://$ADMIN_DOMAIN"
  fi
  wait_up admin || return 0
  if expect_200 admin /login "admin login page"; then
    ok_if "admin login page has a password field" "admin login page has no password field" grep -qi password "$WORK/body"
    if [[ "$MODE" == "public" ]]; then
      ok_if "admin X-Robots-Tag noindex" "admin X-Robots-Tag noindex missing" grep -qi noindex <<<"$(header x-robots-tag)"
    fi
  fi
}

log "smoke ($MODE) for: ${APPS[*]}"
for a in "${APPS[@]}"; do
  case "$a" in api) check_api ;; site) check_site ;; admin) check_admin ;; *) : ;; esac
done
log "result: $PASSES passed, $FAILS failed, $WARNS warnings"
[[ "$FAILS" -eq 0 ]]
