#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE nightly backup with OFF-SERVER upload (provider-agnostic, via rclone).
# Installed by provision-stack.sh as /usr/local/sbin/r007-backup and run by /etc/cron.d/r007-backup.
#
#   sudo scripts/vps/backup.sh [--dry-run] [--config /etc/r007/backup.env] [--app-root /var/www/r007]
#   (--app-root = APP_ROOT_BASE: the API lives in <root>/api, site/admin next to it)
#
# Config (/etc/r007/backup.env - paths/remote NAMES only, no secrets):
#   RCLONE_REMOTE=remote:bucket/path   any rclone remote (S3, B2, GCS, SFTP, ...). Credentials live in root's rclone.conf.
#   AGE_RECIPIENT=age1...              age PUBLIC key; dumps + .env are encrypted before upload. The private key is kept
#                                      OFF this server (password manager / safe). Empty => uploaded unencrypted (a crypt remote is then required).
#   LOCAL_RETENTION_DAYS=7  REMOTE_RETENTION_DAYS=35  HEALTHCHECK_URL=https://... (optional dead-man's-switch ping)
#   MEDIA_BACKUP=archive|off           nightly tar of the uploaded media (default archive)
#
# Produces in /var/backups/r007: r007-<UTC>.sql.gz (mysqldump --single-transaction, routines/triggers/events,
# binlog position for PITR), a .sha256, r007-media-<UTC>.tar.gz (the API's shared/storage/app/public: CMS uploads),
# an ENCRYPTED-ONLY r007-env-<UTC>.tar.gz (the .env of every app + /etc/r007/stack.env + the admin basic-auth secret),
# and closed binlogs. A dump is only accepted after gzip -t and the "Dump completed" trailer check.
# A failed run exits non-zero (cron mails root / healthcheck pings /fail).
set -euo pipefail
SCRIPT_TAG="backup"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"
stack_load

CONFIG="/etc/r007/backup.env"; APP_ROOT="$APP_ROOT_BASE"; BACKUP_DIR="/var/backups/r007"; STATE_DIR="/var/lib/r007-backup"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG="${2:?}"; shift 2 ;;
    --app-root) APP_ROOT="${2:?}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:?}"; shift 2 ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

RCLONE_REMOTE=""; AGE_RECIPIENT=""; LOCAL_RETENTION_DAYS=7; REMOTE_RETENTION_DAYS=35; HEALTHCHECK_URL=""; MEDIA_BACKUP="archive"
if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
elif ! is_dry; then
  die "config $CONFIG not found (copy /etc/r007/backup.env.example)"
fi
# Layout: $APP_ROOT/{api,site,admin}/shared/.env ; media = the API's public disk (served by nginx as /storage).
ENV_FILE="$APP_ROOT/api/shared/.env"
MEDIA_DIR="$APP_ROOT/api/shared/storage/app/public"
DB_NAME="r007"; [[ -f "$ENV_FILE" ]] && DB_NAME="$(env_get "$ENV_FILE" DB_DATABASE)"
[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "bad DB name"

ping_hc() {
  if [[ -n "$HEALTHCHECK_URL" ]] && ! is_dry; then
    curl -fsS -m 10 --retry 3 "$HEALTHCHECK_URL$1" >/dev/null 2>&1 || true
  fi
}
on_fail() { local rc=$?; if [[ $rc -ne 0 ]]; then err "backup FAILED (exit $rc)"; ping_hc /fail; fi; }
trap on_fail EXIT
ping_hc /start

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="$BACKUP_DIR/r007-$STAMP.sql.gz"
run install -d -m 700 "$BACKUP_DIR" "$STATE_DIR"

log "dumping $DB_NAME -> $DUMP"
if is_dry; then echo "[dry-run] mysqldump --single-transaction ... $DB_NAME | gzip > $DUMP (+ verify)" >&2; else
  tmp="$DUMP.partial"
  mysqldump --single-transaction --quick --routines --triggers --events --source-data=2 \
    --set-gtid-purged=OFF --default-character-set=utf8mb4 --hex-blob --databases "$DB_NAME" | gzip -9 >"$tmp"
  gzip -t "$tmp"
  gzip -dc "$tmp" | tail -n 3 | grep -q "Dump completed" || die "dump trailer missing - dump incomplete"
  chmod 600 "$tmp"; mv "$tmp" "$DUMP"
  (cd "$BACKUP_DIR" && sha256sum "$(basename "$DUMP")" >"$(basename "$DUMP").sha256")
  log "dump ok: $(du -h "$DUMP" | cut -f1)"
fi

UPLOADS=()
prepare_upload() { # prepare_upload FILE : print the file to upload (encrypted copy when AGE_RECIPIENT set)
  local f="$1"
  if [[ -n "$AGE_RECIPIENT" ]]; then
    is_dry || age -r "$AGE_RECIPIENT" -o "$f.age" "$f"
    echo "$f.age"
  else
    echo "$f"
  fi
}
[[ -n "$AGE_RECIPIENT" ]] || warn "AGE_RECIPIENT empty: artifacts are uploaded UNENCRYPTED - only acceptable with an rclone crypt remote"
UPLOADS+=("$(prepare_upload "$DUMP")")

# Uploaded media (CMS images etc.). Small archive of public content; encrypted too when a key is configured.
if [[ "$MEDIA_BACKUP" == "archive" ]]; then
  MEDIABAK="$BACKUP_DIR/r007-media-$STAMP.tar.gz"
  log "media: $MEDIA_DIR -> $MEDIABAK"
  if is_dry; then echo "[dry-run] tar -czf $MEDIABAK -C $MEDIA_DIR . (encrypted when AGE_RECIPIENT is set)" >&2; else
    if [[ -d "$MEDIA_DIR" ]]; then
      rc=0; tar -czf "$MEDIABAK.partial" -C "$MEDIA_DIR" . || rc=$?
      # tar exits 1 when a file changed while being read (an upload during the run): the archive is still usable
      [[ "$rc" -le 1 ]] || die "media archive failed (tar exit $rc)"
      tar -tzf "$MEDIABAK.partial" >/dev/null || die "media archive is corrupt"
      chmod 600 "$MEDIABAK.partial"; mv "$MEDIABAK.partial" "$MEDIABAK"
      log "media ok: $(du -h "$MEDIABAK" | cut -f1)"
    else
      warn "media dir $MEDIA_DIR missing (API not deployed yet?) - skipped"; MEDIABAK=""
    fi
  fi
  if [[ -n "$MEDIABAK" ]]; then UPLOADS+=("$(prepare_upload "$MEDIABAK")"); fi
else
  warn "MEDIA_BACKUP=off: uploaded media is NOT backed up"
fi

# Every app's .env (+ stack.env, admin basic-auth secret) holds secrets: only ever uploaded encrypted.
if [[ -f "$ENV_FILE" || -n "${DRY_RUN:-}" ]]; then
  if [[ -n "$AGE_RECIPIENT" ]]; then
    ENVBAK="$BACKUP_DIR/r007-env-$STAMP.tar.gz"
    if ! is_dry; then
      envfiles=(); for a in api site admin; do [[ -f "$APP_ROOT/$a/shared/.env" ]] && envfiles+=("$a/shared/.env"); done
      etcfiles=(); for f in r007/stack.env r007/admin-basic-auth.secret; do [[ -f "/etc/$f" ]] && etcfiles+=("$f"); done
      targs=(-C "$APP_ROOT" "${envfiles[@]}")
      if [[ ${#etcfiles[@]} -gt 0 ]]; then targs+=(-C /etc "${etcfiles[@]}"); fi
      tar -czf "$ENVBAK" "${targs[@]}"
      chmod 600 "$ENVBAK"
    fi
    UPLOADS+=("$(prepare_upload "$ENVBAK")")
    is_dry || rm -f "$ENVBAK"   # secrets: keep only the encrypted copy on disk
  else
    warn "not backing up .env files: refusing to upload secrets without encryption"
  fi
fi

# Closed binary logs since the last run (point-in-time recovery). The active log is left alone.
log "binary logs"
if is_dry; then echo "[dry-run] FLUSH BINARY LOGS; archive closed binlogs" >&2; else
  mysql -e 'FLUSH BINARY LOGS' 2>/dev/null || warn "FLUSH BINARY LOGS failed"
  datadir="$(mysql -N -e 'SELECT @@datadir' 2>/dev/null || echo /var/lib/mysql)"
  last_done="$(cat "$STATE_DIR/last-binlog" 2>/dev/null || true)"
  mapfile -t logs < <(find "$datadir" -maxdepth 1 -name 'r007-binlog.[0-9]*' -printf '%f\n' | sort)
  if (( ${#logs[@]} > 1 )); then
    unset 'logs[${#logs[@]}-1]'   # active one
    todo=(); for l in "${logs[@]}"; do [[ -z "$last_done" || "$l" > "$last_done" ]] && todo+=("$l"); done
    if (( ${#todo[@]} > 0 )); then
      BL="$BACKUP_DIR/r007-binlogs-$STAMP.tar.gz"
      tar -czf "$BL" -C "$datadir" "${todo[@]}"; chmod 600 "$BL"
      UPLOADS+=("$(prepare_upload "$BL")")
      printf '%s' "${todo[${#todo[@]}-1]}" >"$STATE_DIR/last-binlog"
    fi
  fi
fi

if [[ -n "$RCLONE_REMOTE" ]]; then
  for f in "${UPLOADS[@]}"; do
    log "upload $(basename "$f") -> $RCLONE_REMOTE/daily/"
    run rclone copy --checksum --immutable "$f" "$RCLONE_REMOTE/daily/"
    is_dry || rclone check --one-way --include "$(basename "$f")" "$BACKUP_DIR" "$RCLONE_REMOTE/daily" >/dev/null \
      || die "remote verification failed for $(basename "$f")"
  done
  log "remote retention: $REMOTE_RETENTION_DAYS days"
  run rclone delete --min-age "${REMOTE_RETENTION_DAYS}d" "$RCLONE_REMOTE/daily/"
else
  warn "RCLONE_REMOTE not set - NO off-server copy was made. A VPS-local-only backup does not survive losing the VPS."
fi

log "local retention: $LOCAL_RETENTION_DAYS days"
run find "$BACKUP_DIR" -maxdepth 1 -type f \( -name 'r007-*.gz' -o -name 'r007-*.age' -o -name 'r007-*.sha256' \) -mtime "+$LOCAL_RETENTION_DAYS" -delete
# The encrypted staging copies are redundant locally once uploaded.
[[ -z "$AGE_RECIPIENT" ]] || run find "$BACKUP_DIR" -maxdepth 1 -type f -name '*.age' -delete

if ! is_dry; then date +%s >"$STATE_DIR/last-success"; fi
ping_hc ""
log "backup complete: $STAMP"
