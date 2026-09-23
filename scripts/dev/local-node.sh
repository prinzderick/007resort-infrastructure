#!/usr/bin/env bash
# 007 Resort & Spa - bring up a complete LOCAL NODE for demos on macOS/Linux.
#
#   scripts/dev/local-node.sh up      [--dry-run] [--fresh] [--skip-seed] [--api-dir DIR]
#   scripts/dev/local-node.sh stop    [--dry-run]
#   scripts/dev/local-node.sh status
#   scripts/dev/local-node.sh logs [serve|queue|scheduler|reverb]
#   scripts/dev/local-node.sh url
#
# What `up` does (APP_NODE=local):
#   1. checks MySQL 8.4 + Redis are reachable (Homebrew: `brew services start mysql@8.4 redis`)
#   2. creates the database, `composer install` when vendor/ is missing
#   3. php artisan migrate --force, then the demo seeder
#   4. starts, in the background: HTTP server (0.0.0.0:8080), queue worker, scheduler
#      (schedule:work) and Reverb (0.0.0.0:8081)
#   5. prints the LAN URL (and a QR code when `qrencode` is installed) for tablets
#
# It never touches the API repo's own .env: configuration is exported into the child
# processes (real environment variables win over .env in Laravel). The generated APP_KEY
# is kept in the state directory. Dev credentials only - never use this on a real property.
#
# Environment overrides (all optional):
#   R007_API_DIR (path to 007resort-api)   R007_HTTP_PORT (8080)   R007_REVERB_PORT (8081)
#   R007_DB_NAME (r007_local)  R007_DB_USER (root)  R007_DB_PASSWORD ()  R007_DB_HOST (127.0.0.1)
#   R007_REDIS_HOST (127.0.0.1) R007_REDIS_PORT (6379) R007_REDIS_DB (5)
#   R007_DEMO_SEEDER (DemoSeeder)  R007_STATE_DIR (<infra>/.run/local-node)  R007_LAN_IP
set -euo pipefail

SCRIPT_TAG="local-node" # used by lib/common.sh log helpers
export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"

HTTP_PORT="${R007_HTTP_PORT:-8080}"
REVERB_PORT="${R007_REVERB_PORT:-8081}"
DB_NAME="${R007_DB_NAME:-r007_local}"
DB_USER="${R007_DB_USER:-root}"
DB_PASSWORD="${R007_DB_PASSWORD:-}"
DB_HOST="${R007_DB_HOST:-127.0.0.1}"
DB_PORT="${R007_DB_PORT:-3306}"
REDIS_HOST="${R007_REDIS_HOST:-127.0.0.1}"
REDIS_PORT="${R007_REDIS_PORT:-6379}"
REDIS_DB="${R007_REDIS_DB:-5}"
DEMO_SEEDER="${R007_DEMO_SEEDER:-DemoSeeder}"
STATE_DIR="${R007_STATE_DIR:-$INFRA_ROOT/.run/local-node}"
PID_DIR="$STATE_DIR/pids"
LOG_DIR="$STATE_DIR/logs"
API_DIR="${R007_API_DIR:-}"
FRESH=0
SKIP_SEED=0
PROCS=(serve queue scheduler reverb)

usage() { sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

find_api_dir() {
  local c
  if [[ -n "$API_DIR" ]]; then return 0; fi
  for c in "$INFRA_ROOT/../007resort-api" "$INFRA_ROOT/../../007resort-api" "$INFRA_ROOT/../api"; do
    if [[ -f "$c/artisan" ]]; then API_DIR="$(cd "$c" && pwd)"; return 0; fi
  done
  API_DIR="$(cd "$INFRA_ROOT/.." && pwd)/007resort-api"
}

lan_ip() {
  if [[ -n "${R007_LAN_IP:-}" ]]; then echo "$R007_LAN_IP"; return; fi
  local ip=""
  if have ipconfig; then
    ip="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]] && have hostname; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  fi
  echo "${ip:-127.0.0.1}"
}

mysql_cli() {
  local args=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")
  if [[ -n "$DB_PASSWORD" ]]; then MYSQL_PWD="$DB_PASSWORD" mysql "${args[@]}" "$@"; else mysql "${args[@]}" "$@"; fi
}

# db_exec SQL : run one statement (or print it in dry-run mode).
db_exec() {
  if is_dry; then printf '[dry-run] mysql -e "%s"\n' "$1" >&2; else mysql_cli -e "$1"; fi
}

pid_file() { echo "$PID_DIR/$1.pid"; }
is_running() {
  local f pid; f="$(pid_file "$1")"
  [[ -f "$f" ]] || return 1
  pid="$(cat "$f")"
  kill -0 "$pid" 2>/dev/null
}

kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do kill_tree "$child"; done
  kill "$pid" 2>/dev/null || true
}

# Environment exported to every artisan process. Secrets are dev-only and local.
export_node_env() {
  local key_file="$STATE_DIR/app.key" lan
  lan="$(lan_ip)"
  if [[ ! -f "$key_file" ]]; then
    if ! is_dry; then
      mkdir -p "$STATE_DIR"; umask 077
      printf 'base64:%s\n' "$(head -c 32 /dev/urandom | base64)" >"$key_file"
    fi
  fi
  APP_KEY="$(cat "$key_file" 2>/dev/null || echo base64:dryrun)"
  export APP_KEY
  export APP_NODE=local APP_ENV=local APP_DEBUG=true
  export APP_URL="http://$lan:$HTTP_PORT"
  export APP_TIMEZONE=UTC APP_DISPLAY_TIMEZONE=Africa/Lagos
  export LOG_CHANNEL=stack LOG_LEVEL=debug
  export DB_CONNECTION=mysql DB_HOST="$DB_HOST" DB_PORT="$DB_PORT" DB_DATABASE="$DB_NAME"
  export DB_USERNAME="$DB_USER" DB_PASSWORD="$DB_PASSWORD"
  export REDIS_CLIENT="${R007_REDIS_CLIENT:-phpredis}" REDIS_HOST="$REDIS_HOST" REDIS_PORT="$REDIS_PORT"
  export REDIS_DB REDIS_CACHE_DB="$REDIS_DB" REDIS_PREFIX=r007_dev_
  export CACHE_STORE=redis SESSION_DRIVER=redis QUEUE_CONNECTION=redis
  export BROADCAST_CONNECTION=reverb
  export REVERB_APP_ID=r007-dev REVERB_APP_KEY=r007-dev-key REVERB_APP_SECRET=r007-dev-secret
  export REVERB_SERVER_HOST=0.0.0.0 REVERB_SERVER_PORT="$REVERB_PORT"
  export REVERB_HOST="$lan" REVERB_PORT="$REVERB_PORT" REVERB_SCHEME=http
  export NODE_SITE_ID=SITE-DEV-001 NODE_NAME=dev-local
  export SYNC_ENABLED="${R007_SYNC_ENABLED:-false}"
  export PHP_CLI_SERVER_WORKERS="${PHP_CLI_SERVER_WORKERS:-4}"
}

start_proc() {
  local name="$1"; shift
  if is_running "$name"; then log "$name already running (pid $(cat "$(pid_file "$name")"))"; return 0; fi
  if is_dry; then printf '[dry-run] start %s: (cd %s && php artisan %s)\n' "$name" "$API_DIR" "$*" >&2; return 0; fi
  mkdir -p "$PID_DIR" "$LOG_DIR"
  (cd "$API_DIR" && exec nohup php artisan "$@" >>"$LOG_DIR/$name.log" 2>&1 </dev/null) &
  echo $! >"$(pid_file "$name")"
  disown 2>/dev/null || true
  log "started $name (pid $(cat "$(pid_file "$name")")), log: $LOG_DIR/$name.log"
}

preflight() {
  local ok=1
  [[ -f "$API_DIR/artisan" ]] || { err "no Laravel app at $API_DIR (missing artisan). Set R007_API_DIR or --api-dir."; ok=0; }
  have php || { err "php not found on PATH"; ok=0; }
  have mysql || { err "mysql client not found (brew install mysql-client / export PATH=/opt/homebrew/opt/mysql@8.4/bin:\$PATH)"; ok=0; }
  if have mysqladmin; then
    local a=(-h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER")
    if ! { if [[ -n "$DB_PASSWORD" ]]; then MYSQL_PWD="$DB_PASSWORD" mysqladmin "${a[@]}" ping; else mysqladmin "${a[@]}" ping; fi; } >/dev/null 2>&1; then
      err "MySQL not reachable at $DB_HOST:$DB_PORT as $DB_USER (brew services start mysql@8.4)"; ok=0
    fi
  fi
  if have redis-cli; then
    redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1 || { err "Redis not reachable at $REDIS_HOST:$REDIS_PORT (brew services start redis)"; ok=0; }
  else
    warn "redis-cli not found; skipping Redis check"
  fi
  if [[ "$ok" == "0" ]]; then
    if is_dry; then warn "preflight problems above would abort a real run"; else exit 1; fi
  fi
}

cmd_up() {
  find_api_dir
  log "API dir: $API_DIR   state: $STATE_DIR"
  preflight
  export_node_env

  if [[ ! -d "$API_DIR/vendor" ]]; then
    have composer || { is_dry || die "composer not found"; }
    run bash -c "cd '$API_DIR' && composer install --no-interaction --prefer-dist"
  fi

  if [[ "$FRESH" == "1" ]]; then
    warn "--fresh: dropping and recreating database $DB_NAME"
    case "$DB_NAME" in r007_*) ;; *) die "refusing --fresh on database '$DB_NAME' (name must start with r007_)";; esac
    db_exec "DROP DATABASE IF EXISTS \`$DB_NAME\`"
  fi
  log "ensuring database $DB_NAME"
  db_exec "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"

  log "migrating"
  if is_dry; then echo "[dry-run] (cd $API_DIR && php artisan migrate --force)" >&2; else (cd "$API_DIR" && php artisan migrate --force); fi
  if [[ "$SKIP_SEED" == "1" ]]; then
    log "seeding skipped"
  else
    log "seeding demo data ($DEMO_SEEDER)"
    if is_dry; then echo "[dry-run] (cd $API_DIR && php artisan db:seed --class=$DEMO_SEEDER --force)" >&2
    else (cd "$API_DIR" && php artisan db:seed --class="$DEMO_SEEDER" --force) \
      || die "demo seeder '$DEMO_SEEDER' failed (set R007_DEMO_SEEDER or use --skip-seed)"; fi
  fi

  start_proc serve serve --host=0.0.0.0 --port="$HTTP_PORT"
  start_proc queue queue:work redis --queue=default,sync --tries=3 --sleep=1 --max-time=3600
  start_proc scheduler schedule:work
  start_proc reverb reverb:start --host=0.0.0.0 --port="$REVERB_PORT"

  if ! is_dry; then
    local i
    for i in $(seq 1 20); do
      if curl -fsS -o /dev/null "http://127.0.0.1:$HTTP_PORT/up" 2>/dev/null; then break; fi
      sleep 0.5
    done
  fi
  print_url
}

cmd_stop() {
  local n pid
  for n in "${PROCS[@]}"; do
    if is_running "$n"; then
      pid="$(cat "$(pid_file "$n")")"
      if is_dry; then echo "[dry-run] kill process tree $n ($pid)" >&2; else
        kill_tree "$pid"; rm -f "$(pid_file "$n")"; log "stopped $n"
      fi
    else
      rm -f "$(pid_file "$n")" 2>/dev/null || true
    fi
  done
}

print_url() {
  local lan url; lan="$(lan_ip)"; url="http://$lan:$HTTP_PORT"
  echo
  echo "  API / admin base URL for tablets : $url"
  echo "  Health                           : $url/up"
  echo "  System info                      : $url/api/v1/system/info"
  echo "  Reverb (WebSocket)               : ws://$lan:$REVERB_PORT  (key: r007-dev-key)"
  echo "  Logs                             : $LOG_DIR"
  echo
  if have qrencode; then
    qrencode -t ANSIUTF8 "$url"
  else
    echo "  (install 'qrencode' - brew install qrencode - to print a QR code for the tablets)"
  fi
}

cmd_status() {
  find_api_dir
  local n rc=0 lan; lan="$(lan_ip)"
  for n in "${PROCS[@]}"; do
    if is_running "$n"; then printf '  %-10s running (pid %s)\n' "$n" "$(cat "$(pid_file "$n")")"
    else printf '  %-10s STOPPED\n' "$n"; rc=1; fi
  done
  if curl -fsS --max-time 3 "http://127.0.0.1:$HTTP_PORT/up" >/dev/null 2>&1; then echo "  /up        OK"; else echo "  /up        FAILED"; rc=1; fi
  if have redis-cli && redis-cli -h "$REDIS_HOST" -p "$REDIS_PORT" ping >/dev/null 2>&1; then echo "  redis      OK"; else echo "  redis      unreachable"; rc=1; fi
  echo "  LAN URL    http://$lan:$HTTP_PORT"
  return "$rc"
}

cmd_logs() {
  local n="${1:-serve}"
  [[ -f "$LOG_DIR/$n.log" ]] || die "no log for $n"
  tail -n 100 -f "$LOG_DIR/$n.log"
}

main() {
  local cmd="${1:-help}"; shift || true
  local a args=("$@")
  set -- ; local i=0
  while [[ $i -lt ${#args[@]} ]]; do
    a="${args[$i]}"
    case "$a" in
      --dry-run|-n) DRY_RUN=1 ;;
      --fresh) FRESH=1 ;;
      --skip-seed) SKIP_SEED=1 ;;
      --api-dir) i=$((i+1)); API_DIR="${args[$i]:?--api-dir needs a path}" ;;
      -h|--help) usage; exit 0 ;;
      *) set -- "$@" "$a" ;;
    esac
    i=$((i+1))
  done
  case "$cmd" in
    up|start) cmd_up ;;
    stop|down) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs "$@" ;;
    url) find_api_dir; print_url ;;
    help|-h|--help) usage ;;
    *) usage; exit 2 ;;
  esac
}
main "$@"
