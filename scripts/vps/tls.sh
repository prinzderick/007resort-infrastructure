#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE: Let's Encrypt certificates for the site, API and admin names (HTTP-01, webroot).
# One command, safe to re-run at any time (already valid certificates are kept; new/changed names are added).
# Installed as /usr/local/sbin/r007-tls.
#
#   sudo r007-tls                      # issue/renew all three certificates, switch nginx to HTTPS
#   sudo r007-tls --test               # certbot --dry-run: full ACME validation against the LE STAGING server,
#                                      # changes nothing on disk (use it to check DNS + port 80 before the real run)
#   sudo r007-tls --dry-run            # print the plan only (no certbot, no nginx changes)
#   sudo r007-tls --apps api,site      # only some apps
#   sudo r007-tls --email ops@example.com --config /etc/r007/stack.env --force-renewal
#
# Needs: DNS A/AAAA of every name pointing at this server, ports 80/443 open (bootstrap.sh does ufw), nginx running
# with the r007 server blocks (provision-stack.sh). Certificates: /etc/letsencrypt/live/<domain>/ ; the site
# certificate also covers www.<SITE_DOMAIN>. Renewal is automatic (certbot.timer) and reloads nginx via a deploy hook.
set -euo pipefail
SCRIPT_TAG="tls"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"
TEMPLATES_DIR="$SCRIPT_DIR/templates"

CONFIG=""; ONLY=""; F_EMAIL=""; ACME_TEST=0; FORCE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:?}"; shift 2 ;;
    --apps) ONLY="${2:?}"; shift 2 ;;
    --email) F_EMAIL="${2:?}"; shift 2 ;;
    --test) ACME_TEST=1; shift ;;
    --force-renewal) FORCE=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

stack_load "$CONFIG"
[[ -z "$F_EMAIL" ]] || CERT_EMAIL="$F_EMAIL"
stack_validate
[[ -n "$CERT_EMAIL" ]] || die "CERT_EMAIL is not set (stack.env) - pass --email"
need_root
mapfile -t APPS < <(enabled_apps)
if [[ -n "$ONLY" ]]; then
  APPS=()
  for a in ${ONLY//,/ }; do
    app_valid "$a" || die "unknown app: $a"
    app_enabled "$a" || die "app $a is not enabled (no domain set)"
    APPS+=("$a")
  done
fi
[[ ${#APPS[@]} -gt 0 ]] || die "nothing to do"

# 1. Make sure the HTTP server blocks (ACME webroot) are live and current.
run install -d -m 755 /var/www/letsencrypt
if [[ "$ACME_TEST" == "0" ]]; then
  nginx_render_common
  for a in "${APPS[@]}"; do nginx_render_app "$a"; done
  if ! is_dry; then nginx -t; fi
  run systemctl reload nginx
fi

# 2. Pre-flight: names must resolve (certbot would fail with a less helpful message).
for a in "${APPS[@]}"; do
  for n in $(app_server_names "$a"); do
    if have getent && ! getent hosts "$n" >/dev/null 2>&1; then
      warn "DNS: $n does not resolve from this server yet - HTTP-01 will fail until the A/AAAA record exists"
    fi
  done
done

# 3. Certificates: one per app (--cert-name = primary domain), all names of the app on it.
for a in "${APPS[@]}"; do
  d="$(app_domain "$a")"; args=(certonly --webroot -w /var/www/letsencrypt --cert-name "$d" -m "$CERT_EMAIL" --agree-tos --no-eff-email --non-interactive --keep-until-expiring --expand)
  for n in $(app_server_names "$a"); do args+=(-d "$n"); done
  [[ "$FORCE" == "0" ]] || args+=(--force-renewal)
  [[ "$ACME_TEST" == "0" ]] || args+=(--dry-run)
  note=""; if [[ "$ACME_TEST" == "1" ]]; then note=" [staging test, nothing is saved]"; fi
  log "certbot: $a ($(app_server_names "$a"))$note"
  run certbot "${args[@]}"
done

if [[ "$ACME_TEST" == "1" ]]; then
  log "staging test finished (no certificates were changed). If it passed, run 'sudo r007-tls' for the real thing."
  exit 0
fi

# 4. Renewal hook + switch nginx to the HTTPS server blocks.
write_file /etc/letsencrypt/renewal-hooks/deploy/r007-nginx-reload.sh 755 <<'HOOK'
#!/bin/sh
systemctl reload nginx
HOOK
for a in "${APPS[@]}"; do nginx_render_app "$a"; done
if ! is_dry; then nginx -t; fi
run systemctl reload nginx
run systemctl enable --now certbot.timer
log "done. Verify: r007-smoke --mode public   (and 'certbot renew --dry-run' for the renewal path)"
