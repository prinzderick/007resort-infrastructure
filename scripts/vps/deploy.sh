#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE: atomic release deploy per app (api | site | admin), smoke-gated, with rollback.
# Run as the DEPLOY user on the VPS (CI does this over SSH; see .github/workflow-templates/deploy-vps.yml).
# Installed as /usr/local/bin/r007-deploy.
#
#   deploy.sh <api|site|admin> <package.tar.gz | git-ref> [options]   deploy one app
#   deploy.sh all --api PKG --site PKG --admin PKG [options]           deploy several, in the order api -> site -> admin
#   deploy.sh rollback <app> [RELEASE_ID]                              default: the previous release
#   deploy.sh recache <app>                                            re-read the app's .env (config:cache etc.) for the
#                                                                      CURRENT release + reload; use after editing shared/.env
#   deploy.sh list [app] | status
#
# <package> is a tar.gz of the app root built in CI (vendor/ and public/build/ included - see the workflow template).
# Anything else is a git ref cloned from --git-url (or API_GIT_URL/SITE_GIT_URL/ADMIN_GIT_URL in stack.env); server-side
# builds are not supported: site/admin releases MUST already contain public/build/manifest.json.
#
# options:
#   --release-id ID       default: UTC timestamp (+ -<sha> when known)
#   --keep N              releases to keep per app (default 5)
#   --no-migrate          api only: skip `artisan migrate --force`
#   --no-smoke            only the loopback /up check after the switch, not the full local smoke (smoke.sh)
#   --allow-placeholders  do not refuse to deploy while .env still contains <secret>/<generate>
#   --allow-no-assets     site/admin: accept a release without public/build (NOT for production)
#   --git-url URL --ref REF | --package FILE    explicit forms of the positional argument
#   --dry-run             print the plan only
#
# Layout per app:  $APP_ROOT_BASE/<app>/releases/<id>/   <app>/current -> releases/<id>   <app>/shared/{.env,storage}
# Flow:    unpack -> link shared -> composer --no-dev (git mode) -> [api: migrate --force with the DDL account]
#          -> config/route/event/view cache + storage link -> atomic symlink swap -> reload php-fpm [api: restart
#          supervisor group r007] -> smoke (loopback) -> AUTOMATIC ROLLBACK of that app on failure -> prune old releases.
# The database is never reverted by a rollback: migrations must be backwards compatible with the previous release
# (expand/contract, see runbooks/server-installation.md). site/admin have no database and no queue workers.
#
# Env overrides (mainly for tests): R007_STACK_ENV, R007_APP_ROOT_BASE, R007_PHP, R007_SUDO ("" to disable),
# R007_SKIP_SERVICES=1, R007_SMOKE (path of smoke.sh), R007_ALLOW_DEBUG=1
set -euo pipefail
SCRIPT_TAG="deploy"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"

PHP="${R007_PHP:-php}"
SUDO="${R007_SUDO-sudo}"
SKIP_SERVICES="${R007_SKIP_SERVICES:-0}"
SMOKE="${R007_SMOKE:-$SCRIPT_DIR/smoke.sh}"
KEEP=5; PACKAGE=""; GIT_URL=""; GIT_REF=""; RELEASE_ID=""; MIGRATE=1; SMOKE_FULL=1
ALLOW_PLACEHOLDERS=0; ALLOW_NO_ASSETS=0
ALL_API=""; ALL_SITE=""; ALL_ADMIN=""

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

CMD="${1:-}"; [[ $# -gt 0 ]] && shift
TARGET=""; ROLLBACK_TARGET=""; REF=""
case "$CMD" in
  api|site|admin|all)
    TARGET="$CMD"; CMD="deploy"
    if [[ $# -gt 0 && "$1" != -* ]]; then REF="$1"; shift; fi ;;
  deploy)
    [[ $# -gt 0 ]] || { usage; exit 2; }
    TARGET="$1"; shift
    if [[ $# -gt 0 && "$1" != -* ]]; then REF="$1"; shift; fi ;;
  rollback)
    TARGET="${1:-}"; [[ $# -gt 0 ]] && shift
    if [[ $# -gt 0 && "$1" != -* ]]; then ROLLBACK_TARGET="$1"; shift; fi ;;
  list)
    if [[ $# -gt 0 && "$1" != -* ]]; then TARGET="$1"; shift; fi ;;
  recache)
    TARGET="${1:-}"; [[ $# -gt 0 ]] && shift ;;
  status|""|-h|--help|help) : ;;
  *) usage; exit 2 ;;
esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    --package) PACKAGE="${2:?}"; shift 2 ;;
    --git-url) GIT_URL="${2:?}"; shift 2 ;;
    --ref) GIT_REF="${2:?}"; shift 2 ;;
    --api) ALL_API="${2:?}"; shift 2 ;;
    --site) ALL_SITE="${2:?}"; shift 2 ;;
    --admin) ALL_ADMIN="${2:?}"; shift 2 ;;
    --release-id) RELEASE_ID="${2:?}"; shift 2 ;;
    --keep) KEEP="${2:?}"; shift 2 ;;
    --no-migrate) MIGRATE=0; shift ;;
    --no-smoke) SMOKE_FULL=0; shift ;;
    --allow-placeholders) ALLOW_PLACEHOLDERS=1; shift ;;
    --allow-no-assets) ALLOW_NO_ASSETS=1; shift ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$CMD" in ""|-h|--help|help) usage; exit 0 ;; *) : ;; esac
stack_load ""
[[ "$KEEP" =~ ^[0-9]+$ && "$KEEP" -ge 2 ]] || die "--keep must be an integer >= 2"

# select_app APP : point the per-app globals at APP
select_app() {
  APP="$1"
  app_valid "$APP" || die "app must be api|site|admin (got: ${APP:-empty})"
  app_enabled "$APP" || die "app $APP is not enabled in $STACK_ENV_FILE (no ${APP^^}_DOMAIN)"
  APP_DIR="$(app_dir "$APP")"; APP_GROUP="$(app_user "$APP")"
  RELEASES="$APP_DIR/releases"; SHARED="$APP_DIR/shared"; CURRENT="$APP_DIR/current"; ENV_FILE="$SHARED/.env"
  REL_DIR=""; SWITCHED=0
}

svc() { # svc COMMAND... : run a privileged service command unless services are skipped
  if [[ "$SKIP_SERVICES" == "1" ]]; then log "skip (R007_SKIP_SERVICES): $*"; return 0; fi
  # shellcheck disable=SC2086
  run $SUDO "$@"
}

current_release() { if [[ -L "$CURRENT" ]]; then basename "$(readlink -f "$CURRENT")"; fi; }

swap_current() { # swap_current RELEASE_ID : atomic symlink replacement
  local id="$1"
  run ln -sfn "$RELEASES/$id" "$APP_DIR/.current.tmp"
  run mv -Tf "$APP_DIR/.current.tmp" "$CURRENT"
}

restart_services() {
  svc systemctl reload "php${PHP_VER}-fpm"
  if [[ "$APP" == "api" ]]; then svc supervisorctl restart 'r007:*'; fi   # queue/sync/Reverb run from current/
}

# loopback /up only (used after a rollback and with --no-smoke)
health_check() {
  if is_dry; then echo "[dry-run] health check http://127.0.0.1:$(app_port "$APP")/up" >&2; return 0; fi
  local i url
  url="http://127.0.0.1:$(app_port "$APP")/up"
  for i in $(seq 1 30); do
    if curl -fsS --max-time 5 -o /dev/null "$url" 2>/dev/null; then log "$APP health OK ($url)"; return 0; fi
    sleep 1
  done
  return 1
}

# post_switch_checks : full local smoke (default) or just /up; non-zero = the release is bad
post_switch_checks() {
  if is_dry; then echo "[dry-run] smoke.sh --app $APP --mode local" >&2; return 0; fi
  if [[ "$SMOKE_FULL" == "1" ]]; then "$SMOKE" --app "$APP" --mode local; else health_check; fi
}

do_rollback() { # do_rollback TARGET_ID
  local target="$1" cur
  [[ -d "$RELEASES/$target" ]] || die "release not found: $APP/$target"
  cur="$(current_release)"
  log "$APP: rolling back ${cur:-none} -> $target (database is NOT reverted)"
  swap_current "$target"
  restart_services
  if health_check; then log "$APP: rollback complete"; else err "$APP: health check still failing after rollback - investigate immediately (runbooks/incident-response.md)"; return 1; fi
}

on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && "$SWITCHED" == "0" && -n "${REL_DIR:-}" && -d "${REL_DIR:-}" ]] && ! is_dry; then
    warn "$APP: deploy failed before the switch; removing $REL_DIR (running release untouched)"
    rm -rf "$REL_DIR"
  fi
}

artisan() { (umask 007; cd "$REL_DIR" && "$PHP" artisan "$@"); }   # umask 007: group-writable for the app's pool user

# guard_env : refuse obviously unsafe production settings
guard_env() {
  local f="$ENV_FILE" p
  [[ -f "$f" ]] || die "$f missing - run provision-stack.sh first"
  if [[ "$ALLOW_PLACEHOLDERS" == "0" ]]; then
    p="$(grep -E '^[A-Z_0-9]+=(<secret>|<generate>)' "$f" | grep -v '^APP_KEY=' | cut -d= -f1 || true)"
    if [[ -n "$p" ]]; then
      printf '%s\n' "$p" | sed 's/^/  unset: /' >&2
      die "$APP: $f still has <secret>/<generate> placeholders; fill them or use --allow-placeholders"
    fi
  fi
  if [[ "$(env_val "$f" APP_DEBUG)" == "true" && "${R007_ALLOW_DEBUG:-0}" != "1" ]]; then die "$APP: APP_DEBUG=true in $f (production must be false)"; fi
  case "$APP" in
    api)  [[ "$(env_val "$f" APP_NODE)" == "cloud" ]] || die "APP_NODE in $f is not 'cloud'" ;;
    site) [[ "$(env_val "$f" CMS_FIXTURES)" == "false" ]] || die "site: CMS_FIXTURES must be false in $f (true serves demo content)"
          [[ "$(env_val "$f" R007_MOCK)" != "true" ]] || die "site: R007_MOCK=true in $f" ;;
    admin) [[ "$(env_val "$f" R007_MOCK)" != "true" ]] || die "admin: R007_MOCK=true in $f (fixture data, known password)" ;;
    *) : ;;
  esac
}

deploy_one() { # deploy_one APP REF
  select_app "$1"
  local ref="$2" package="$PACKAGE" git_url="$GIT_URL" git_ref="$GIT_REF" sha="" prev
  if [[ -n "$ref" && -z "$package" && -z "$git_ref" ]]; then
    if [[ -f "$ref" ]]; then package="$ref"
    elif [[ "$ref" == */* || "$ref" == *.tar.gz || "$ref" == *.tgz ]] && ! is_dry; then die "package not found: $ref"
    elif [[ "$ref" == */* || "$ref" == *.tar.gz || "$ref" == *.tgz ]]; then package="$ref"
    else git_ref="$ref"; fi
  fi
  [[ -n "$package" || -n "$git_ref" || -n "$git_url" ]] || die "$APP: give a package file or a git ref"
  if [[ -z "$package" && -z "$git_url" ]]; then git_url="$(app_git_url "$APP")"; fi
  if [[ -z "$package" ]]; then [[ -n "$git_url" ]] || die "$APP: git mode needs --git-url or ${APP^^}_GIT_URL in stack.env"; fi
  if [[ -n "$package" ]] && ! is_dry; then [[ -f "$package" ]] || die "package not found: $package"; fi
  is_dry || guard_env

  [[ -n "$package" ]] && sha="$(basename "$package" | sed -E 's/^r007-(api|site|admin)-//; s/^r007-//; s/\.(tar\.gz|tgz)$//' | cut -c1-12)"
  [[ -n "$git_ref" ]] && sha="$(echo "$git_ref" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-24)"
  local rid="$RELEASE_ID"
  [[ -n "$rid" ]] || rid="$(date -u +%Y%m%d%H%M%S)${sha:+-$sha}"
  REL_DIR="$RELEASES/$rid"
  [[ ! -e "$REL_DIR" ]] || die "release $rid already exists"

  if ! is_dry; then exec 9>"$APP_DIR/.deploy.lock"; flock -n 9 || die "$APP: another deploy is running"; fi

  prev="$(current_release)"
  log "$APP: deploying $rid (previous: ${prev:-none})"
  run mkdir -p "$REL_DIR"
  trap on_exit EXIT   # any failure before the swap leaves the running release untouched

  if [[ -n "$package" ]]; then
    run tar -xzf "$package" -C "$REL_DIR"
  else
    run git clone --quiet --depth 1 ${git_ref:+--branch "$git_ref"} "$git_url" "$REL_DIR"
    run rm -rf "$REL_DIR/.git"
  fi
  if ! is_dry; then
    [[ -f "$REL_DIR/artisan" ]] || die "no artisan in release - is the package the Laravel app root?"
    if [[ "$APP" != "api" && "$ALLOW_NO_ASSETS" == "0" && ! -f "$REL_DIR/public/build/manifest.json" ]]; then
      die "$APP: release has no public/build/manifest.json. Front-end assets are built in CI (npm ci && npm run build) and shipped in the package; the server has no Node."
    fi
  fi

  log "$APP: linking shared state (.env, storage)"
  ensure_storage_tree "$APP"
  if [[ -d "$REL_DIR/storage" && ! -L "$REL_DIR/storage" ]]; then
    # skeleton files only (never overwrite). NOT `cp -a`: it would stamp the skeleton's owner/mode onto the shared dirs.
    run cp -rn "$REL_DIR/storage/." "$SHARED/storage/"
    run rm -rf "$REL_DIR/storage"
    ensure_storage_tree "$APP"   # the copied skeleton is owned by deploy with default modes: fix group/setgid again
  fi
  run ln -sfn "$SHARED/storage" "$REL_DIR/storage"
  run ln -sfn "$ENV_FILE" "$REL_DIR/.env"
  # bootstrap/cache holds the compiled config (contains secrets): app group only, never world-readable.
  run mkdir -p "$REL_DIR/bootstrap/cache"
  if ! is_dry; then
    chgrp "$APP_GROUP" "$REL_DIR/bootstrap/cache" 2>/dev/null || die "cannot chgrp to $APP_GROUP: is '$(id -un)' in that group? (log out and back in after provisioning)"
    chmod 2750 "$REL_DIR/bootstrap/cache"
  fi

  if [[ -n "$git_url" && -z "$package" ]] || { ! is_dry && [[ ! -f "$REL_DIR/vendor/autoload.php" ]]; }; then
    log "$APP: composer install --no-dev"
    run bash -c "cd '$REL_DIR' && composer install --no-dev --optimize-autoloader --no-interaction --prefer-dist"
  fi

  if ! is_dry && [[ -z "$(env_val "$ENV_FILE" APP_KEY)" || "$(env_val "$ENV_FILE" APP_KEY)" == "<generate>" ]]; then
    log "$APP: APP_KEY empty: generating (first deploy). Back up the .env - losing APP_KEY loses encrypted data/sessions."
    artisan key:generate --force
  fi

  if [[ "$APP" == "api" && "$MIGRATE" == "1" ]]; then
    log "api: migrating (DDL account, --force)"
    if is_dry; then echo "[dry-run] (cd $REL_DIR && DB_USERNAME=<migrator> php artisan migrate --force)" >&2; else
      local mu mp
      mu="$(env_val "$ENV_FILE" DB_MIGRATOR_USERNAME)"; mp="$(env_val "$ENV_FILE" DB_MIGRATOR_PASSWORD)"
      if [[ -n "$mu" && -n "$mp" ]]; then
        (umask 007; cd "$REL_DIR" && DB_USERNAME="$mu" DB_PASSWORD="$mp" "$PHP" artisan migrate --force)
      else
        warn "no DB_MIGRATOR_* in .env; migrating with the app account"
        artisan migrate --force
      fi
    fi
  fi

  log "$APP: storage link + caching config/routes/events/views"
  if [[ -e "$REL_DIR/public/storage" && ! -L "$REL_DIR/public/storage" ]]; then run rm -rf "$REL_DIR/public/storage"; fi
  run ln -sfn "$SHARED/storage/app/public" "$REL_DIR/public/storage"   # == artisan storage:link, with a target that survives releases
  if is_dry; then echo "[dry-run] php artisan config:cache route:cache event:cache view:cache" >&2; else
    artisan config:cache
    if ! artisan route:cache; then
      warn "$APP: route:cache failed (closure routes cannot be cached) - continuing without the route cache"
      artisan route:clear || true
    fi
    artisan event:cache || warn "$APP: event:cache failed - continuing"
    artisan view:cache
  fi

  log "$APP: switching current -> $rid"
  swap_current "$rid"
  SWITCHED=1
  is_dry || echo "${prev:-}" >"$SHARED/.previous_release"
  restart_services

  if ! post_switch_checks; then
    err "$APP: smoke/health check FAILED after deploy of $rid"
    if [[ -n "$prev" ]]; then do_rollback "$prev" || true; else err "$APP: no previous release to roll back to"; fi
    exit 1
  fi

  log "$APP: pruning old releases (keep $KEEP)"
  if ! is_dry; then
    local keep_ids i=0 d id
    keep_ids="$rid $prev"
    # newest first; keep the newest $KEEP plus current/previous
    # shellcheck disable=SC2012
    while IFS= read -r d; do
      id="$(basename "$d")"; i=$((i+1))
      if (( i > KEEP )) && [[ " $keep_ids " != *" $id "* ]]; then rm -rf "$d"; log "removed $APP/$id"; fi
    done < <(ls -1dt "$RELEASES"/*/ 2>/dev/null | sed 's|/$||')
  fi
  log "$APP: deploy complete: $rid"
}

cmd_deploy() {
  [[ -n "$TARGET" ]] || die "give an app: api|site|admin|all"
  if [[ "$TARGET" == "all" ]]; then
    [[ -z "$REF" && -z "$PACKAGE" && -z "$GIT_REF" ]] || die "'all' takes --api/--site/--admin per app, not a single package/ref"
    [[ -z "$RELEASE_ID" ]] || die "--release-id cannot be combined with 'all'"
    local a ref n=0
    for a in "${APPS_ALL[@]}"; do
      case "$a" in api) ref="$ALL_API" ;; site) ref="$ALL_SITE" ;; admin) ref="$ALL_ADMIN" ;; *) ref="" ;; esac
      [[ -n "$ref" ]] || continue
      n=$((n+1))
      # a fresh shell state per app: only per-app options are shared
      deploy_one "$a" "$ref"
    done
    [[ "$n" -gt 0 ]] || die "'all' needs at least one of --api/--site/--admin"
  else
    app_valid "$TARGET" || die "unknown app: $TARGET"
    deploy_one "$TARGET" "$REF"
  fi
}

cmd_recache() {
  select_app "$TARGET"
  REL_DIR="$(readlink -f "$CURRENT" 2>/dev/null || true)"
  [[ -n "$REL_DIR" && -d "$REL_DIR" ]] || die "$APP is not deployed yet"
  is_dry || guard_env
  log "$APP: rebuilding caches for $(basename "$REL_DIR") from $ENV_FILE"
  if is_dry; then echo "[dry-run] php artisan config:cache route:cache event:cache view:cache; reload" >&2; else
    artisan config:cache
    artisan route:cache || { warn "$APP: route:cache failed - continuing without the route cache"; artisan route:clear || true; }
    artisan event:cache || warn "$APP: event:cache failed - continuing"
    artisan view:cache
  fi
  restart_services
  post_switch_checks || die "$APP: smoke failed after recache - check the .env change (a previous .env is not kept: restore it from backup)"
  log "$APP: recache complete"
}

cmd_rollback() {
  select_app "$TARGET"
  local target="$ROLLBACK_TARGET"
  if [[ -z "$target" ]]; then
    [[ -f "$SHARED/.previous_release" ]] && target="$(cat "$SHARED/.previous_release")"
    [[ -n "$target" ]] || die "$APP: no previous release recorded; pass a release id (deploy.sh list $APP)"
  fi
  do_rollback "$target"
}

list_app() {
  select_app "$1"
  local cur; cur="$(current_release)"
  echo "== $APP ($APP_DIR)"
  # shellcheck disable=SC2012
  ls -1t "$RELEASES" 2>/dev/null | while read -r r; do printf '%s %s\n' "$([[ "$r" == "$cur" ]] && echo '*' || echo ' ')" "$r"; done
}
cmd_list() {
  if [[ -n "$TARGET" ]]; then list_app "$TARGET"; else local a; for a in $(enabled_apps); do list_app "$a"; done; fi
}

case "$CMD" in
  deploy) cmd_deploy ;;
  rollback) cmd_rollback ;;
  recache) cmd_recache ;;
  list) cmd_list ;;
  status) cmd_list; if [[ "$SKIP_SERVICES" != "1" ]]; then ${SUDO:+"$SUDO"} supervisorctl status 'r007:*' 2>/dev/null || true; fi ;;
  *) usage; exit 2 ;;
esac
