#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE: atomic release deploy, health-gated, with rollback.
# Run as the DEPLOY user on the VPS (CI does this over SSH; see .github/workflow-templates/).
#
#   deploy.sh deploy   --package /tmp/r007-<sha>.tar.gz [options]
#   deploy.sh deploy   --git-url URL --ref TAG_OR_BRANCH [options]
#   deploy.sh rollback [RELEASE_ID]          # default: the previous release
#   deploy.sh list | status
#
# deploy options:
#   --release-id ID       default: UTC timestamp (+ -<sha> when known)
#   --keep N              releases to keep (default 5)
#   --no-migrate          skip `artisan migrate --force`
#   --health-url URL      default http://127.0.0.1:8088/up (loopback vhost); failure => automatic rollback
#   --allow-placeholders  do not refuse to deploy while shared/.env still contains <secret>/<generate>
#   --dry-run             print the plan only
#
# Layout:  $APP_ROOT/releases/<id>/   $APP_ROOT/current -> releases/<id>   $APP_ROOT/shared/{.env,storage}
# Flow:    unpack -> link shared -> composer --no-dev (git mode / no vendor) -> migrate --force (DDL account)
#          -> cache config/routes/events/views -> atomic symlink swap -> reload php-fpm -> restart
#          supervisor group r007 -> health check (auto-rollback on failure) -> prune old releases.
# Migrations must be backwards compatible with the previous release (expand/contract), because a
# rollback swaps code but never reverses the database (see runbooks/server-installation.md).
#
# Env overrides (mainly for tests): R007_APP_ROOT, R007_PHP, R007_SUDO ("" to disable), R007_SKIP_SERVICES=1
set -euo pipefail
SCRIPT_TAG="deploy"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"

APP_ROOT="${R007_APP_ROOT:-/var/www/r007}"
PHP="${R007_PHP:-php}"
SUDO="${R007_SUDO-sudo}"
SKIP_SERVICES="${R007_SKIP_SERVICES:-0}"
PHP_FPM_UNIT="${R007_PHP_FPM_UNIT:-php8.4-fpm}"
KEEP=5; PACKAGE=""; GIT_URL=""; GIT_REF=""; RELEASE_ID=""; MIGRATE=1
HEALTH_URL="http://127.0.0.1:8088/up"; ALLOW_PLACEHOLDERS=0

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-}"; [[ $# -gt 0 ]] && shift
ROLLBACK_TARGET=""
if [[ "$CMD" == "rollback" && $# -gt 0 && "$1" != -* ]]; then ROLLBACK_TARGET="$1"; shift; fi
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) PACKAGE="${2:?}"; shift 2 ;;
    --git-url) GIT_URL="${2:?}"; shift 2 ;;
    --ref) GIT_REF="${2:?}"; shift 2 ;;
    --release-id) RELEASE_ID="${2:?}"; shift 2 ;;
    --keep) KEEP="${2:?}"; shift 2 ;;
    --no-migrate) MIGRATE=0; shift ;;
    --health-url) HEALTH_URL="${2:?}"; shift 2 ;;
    --allow-placeholders) ALLOW_PLACEHOLDERS=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

RELEASES="$APP_ROOT/releases"; SHARED="$APP_ROOT/shared"; CURRENT="$APP_ROOT/current"
ENV_FILE="$SHARED/.env"

svc() { # svc COMMAND... : run a privileged service command unless services are skipped
  if [[ "$SKIP_SERVICES" == "1" ]]; then log "skip (R007_SKIP_SERVICES): $*"; return 0; fi
  # shellcheck disable=SC2086
  run $SUDO "$@"
}

current_release() {
  if [[ -L "$CURRENT" ]]; then basename "$(readlink -f "$CURRENT")"; fi
}

swap_current() { # swap_current RELEASE_ID : atomic symlink replacement
  local id="$1"
  run ln -sfn "$RELEASES/$id" "$APP_ROOT/.current.tmp"
  run mv -Tf "$APP_ROOT/.current.tmp" "$CURRENT"
}

restart_services() {
  svc systemctl reload "$PHP_FPM_UNIT"
  svc supervisorctl restart 'r007:*'
}

health_check() {
  if is_dry; then echo "[dry-run] health check $HEALTH_URL" >&2; return 0; fi
  local i
  for i in $(seq 1 30); do
    if curl -fsS --max-time 5 -o /dev/null "$HEALTH_URL" 2>/dev/null; then log "health OK ($HEALTH_URL)"; return 0; fi
    sleep 1
  done
  return 1
}

do_rollback() { # do_rollback TARGET_ID
  local target="$1" cur
  [[ -d "$RELEASES/$target" ]] || die "release not found: $target"
  cur="$(current_release)"
  log "rolling back: ${cur:-none} -> $target (database is NOT reverted)"
  swap_current "$target"
  restart_services
  if health_check; then log "rollback complete"; else err "health check still failing after rollback - investigate immediately (runbooks/incident-response.md)"; return 1; fi
}

SWITCHED=0
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$SWITCHED" == "0" && -n "${REL_DIR:-}" && -d "${REL_DIR:-}" ]] && ! is_dry; then
    warn "deploy failed before the switch; removing $REL_DIR (running release untouched)"
    rm -rf "$REL_DIR"
  fi
}

artisan() { (cd "$REL_DIR" && "$PHP" artisan "$@"); }

cmd_deploy() {
  [[ -n "$PACKAGE" || -n "$GIT_URL" ]] || die "give --package or --git-url/--ref"
  if [[ -n "$PACKAGE" ]] && ! is_dry; then [[ -f "$PACKAGE" ]] || die "package not found: $PACKAGE"; fi
  if ! is_dry; then
    [[ -f "$ENV_FILE" ]] || die "$ENV_FILE missing - run provision-stack.sh first"
    if [[ "$ALLOW_PLACEHOLDERS" == "0" ]] && grep -Eq '^[A-Z_]+=(<secret>|<generate>)' "$ENV_FILE"; then
      grep -E '^[A-Z_]+=(<secret>|<generate>)' "$ENV_FILE" | cut -d= -f1 | sed 's/^/  unset: /' >&2
      die "shared/.env still has <secret>/<generate> placeholders (except APP_KEY handled below); fill them or use --allow-placeholders"
    fi
    [[ "$(env_get "$ENV_FILE" APP_NODE)" == "cloud" ]] || die "APP_NODE in $ENV_FILE is not 'cloud'"
  fi

  local sha=""
  [[ -n "$PACKAGE" ]] && sha="$(basename "$PACKAGE" | sed -E 's/^r007-//; s/\.(tar\.gz|tgz)$//' | cut -c1-12)"
  [[ -n "$GIT_REF" ]] && sha="$(echo "$GIT_REF" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-24)"
  [[ -n "$RELEASE_ID" ]] || RELEASE_ID="$(date -u +%Y%m%d%H%M%S)${sha:+-$sha}"
  REL_DIR="$RELEASES/$RELEASE_ID"
  [[ ! -e "$REL_DIR" ]] || die "release $RELEASE_ID already exists"

  local lockfile="$APP_ROOT/.deploy.lock"
  if ! is_dry; then exec 9>"$lockfile"; flock -n 9 || die "another deploy is running"; fi

  local prev; prev="$(current_release)"
  log "deploying $RELEASE_ID (previous: ${prev:-none})"
  run mkdir -p "$REL_DIR"
  # Any failure before the swap leaves the running release untouched: clean up the half-built dir.
  trap on_exit EXIT

  if [[ -n "$PACKAGE" ]]; then
    run tar -xzf "$PACKAGE" -C "$REL_DIR"
  else
    run git clone --quiet --depth 1 ${GIT_REF:+--branch "$GIT_REF"} "$GIT_URL" "$REL_DIR"
    run rm -rf "$REL_DIR/.git"
  fi
  if ! is_dry; then [[ -f "$REL_DIR/artisan" ]] || die "no artisan in release - is the package the Laravel app root?"; fi

  log "linking shared state"
  run install -d -m 750 "$SHARED/storage/app/public" "$SHARED/storage/framework/cache/data" \
    "$SHARED/storage/framework/sessions" "$SHARED/storage/framework/views" "$SHARED/storage/logs"
  if [[ -d "$REL_DIR/storage" ]]; then
    run cp -an "$REL_DIR/storage/." "$SHARED/storage/"
    run rm -rf "$REL_DIR/storage"
  fi
  run ln -sfn "$SHARED/storage" "$REL_DIR/storage"
  run ln -sfn "$ENV_FILE" "$REL_DIR/.env"

  if [[ -n "$GIT_URL" || ! -f "$REL_DIR/vendor/autoload.php" ]]; then
    log "composer install --no-dev"
    run bash -c "cd '$REL_DIR' && composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist"
  fi

  if ! is_dry && [[ -z "$(env_get "$ENV_FILE" APP_KEY)" || "$(env_get "$ENV_FILE" APP_KEY)" == "<generate>" ]]; then
    log "APP_KEY empty: generating (first deploy). Back up shared/.env - losing APP_KEY loses encrypted data."
    artisan key:generate --force
  fi

  if [[ "$MIGRATE" == "1" ]]; then
    log "migrating (DDL account, --force)"
    if is_dry; then echo "[dry-run] (cd $REL_DIR && DB_USERNAME=<migrator> php artisan migrate --force)" >&2; else
      mu="$(env_get "$ENV_FILE" DB_MIGRATOR_USERNAME)"; mp="$(env_get "$ENV_FILE" DB_MIGRATOR_PASSWORD)"
      if [[ -n "$mu" && -n "$mp" ]]; then
        (cd "$REL_DIR" && DB_USERNAME="$mu" DB_PASSWORD="$mp" "$PHP" artisan migrate --force)
      else
        warn "no DB_MIGRATOR_* in .env; migrating with the app account"
        artisan migrate --force
      fi
    fi
  fi

  log "caching config/routes/events/views"
  if is_dry; then echo "[dry-run] php artisan config:cache route:cache event:cache view:cache" >&2; else
    artisan config:cache; artisan route:cache; artisan event:cache; artisan view:cache
  fi

  log "switching current -> $RELEASE_ID"
  swap_current "$RELEASE_ID"
  SWITCHED=1
  is_dry || echo "${prev:-}" >"$SHARED/.previous_release"
  restart_services

  if ! health_check; then
    err "health check FAILED after deploy of $RELEASE_ID"
    if [[ -n "$prev" ]]; then do_rollback "$prev" || true; fi
    exit 1
  fi

  log "pruning old releases (keep $KEEP)"
  if ! is_dry; then
    local keep_ids i=0 d id
    keep_ids="$RELEASE_ID $prev"
    # newest first; keep the newest $KEEP plus current/previous
    # shellcheck disable=SC2012
    while IFS= read -r d; do
      id="$(basename "$d")"; i=$((i+1))
      if (( i > KEEP )) && [[ " $keep_ids " != *" $id "* ]]; then rm -rf "$d"; log "removed $id"; fi
    done < <(ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's|/$||')
  fi
  log "deploy complete: $RELEASE_ID"
}

cmd_rollback() {
  local target="$ROLLBACK_TARGET"
  if [[ -z "$target" ]]; then
    [[ -f "$SHARED/.previous_release" ]] && target="$(cat "$SHARED/.previous_release")"
    [[ -n "$target" ]] || die "no previous release recorded; pass a release id (deploy.sh list)"
  fi
  do_rollback "$target"
}

cmd_list() {
  local cur; cur="$(current_release)"
  # shellcheck disable=SC2012
  ls -1t "$RELEASES" 2>/dev/null | while read -r r; do printf '%s %s\n' "$([[ "$r" == "$cur" ]] && echo '*' || echo ' ')" "$r"; done
}

case "$CMD" in
  deploy) cmd_deploy ;;
  rollback) cmd_rollback ;;
  list) cmd_list ;;
  status) log "current: $(current_release)"; cmd_list; "$SUDO" supervisorctl status 'r007:*' 2>/dev/null || true ;;
  ""|-h|--help|help) usage ;;
  *) usage; exit 2 ;;
esac
