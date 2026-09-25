#!/usr/bin/env bash
# 007 Resort & Spa - CLOUD NODE restore test: prove the latest backup actually restores.
# Installed as /usr/local/sbin/r007-restore-test (monthly cron). The quarterly human checklist is in
# runbooks/backup-and-restore.md; this script is the mechanical part of it.
#
#   sudo scripts/vps/restore-test.sh [--dry-run] [--file DUMP.sql.gz[.age]] [--from-remote]
#                                     [--age-identity FILE] [--min-tables N] [--max-age-hours H] [--skip-media]
#
# Restores into a THROWAWAY database (r007_restore_test_<pid>) on the local MySQL - never into the live one -
# checks table count and the Laravel `migrations` table, records duration (RTO evidence) and the age of the
# backup (RPO evidence) as one JSON line in /var/log/r007/restore-test.log, then drops the scratch database.
# It also proves the MEDIA archive (r007-media-*.tar.gz[.age]: decrypts, lists and extracts into a scratch dir) and,
# when --age-identity is given, that the env archive contains the API .env. --skip-media only for a media-less install.
# Exit 0 = pass. Non-zero = the backup chain is broken: treat as an incident.
set -euo pipefail
SCRIPT_TAG="restore-test"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"

CONFIG="/etc/r007/backup.env"; BACKUP_DIR="/var/backups/r007"; FILE=""; FROM_REMOTE=0; IDENTITY=""
MIN_TABLES=10; MAX_AGE_H=26; SKIP_MEDIA=0; LOGFILE="/var/log/r007/restore-test.log"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --file) FILE="${2:?}"; shift 2 ;;
    --from-remote) FROM_REMOTE=1; shift ;;
    --age-identity) IDENTITY="${2:?}"; shift 2 ;;
    --skip-media) SKIP_MEDIA=1; shift ;;
    --min-tables) MIN_TABLES="${2:?}"; shift 2 ;;
    --max-age-hours) MAX_AGE_H="${2:?}"; shift 2 ;;
    --config) CONFIG="${2:?}"; shift 2 ;;
    --backup-dir) BACKUP_DIR="${2:?}"; shift 2 ;;
    --log) LOGFILE="${2:?}"; shift 2 ;;
    --dry-run|-n) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done
RCLONE_REMOTE=""
# shellcheck disable=SC1090
[[ -f "$CONFIG" ]] && source "$CONFIG"

WORK="$(mktemp -d)"; SCRATCH_DB="r007_restore_test_$$"; STARTED="$(date +%s)"; RESULT="fail"; DETAIL=""
cleanup() {
  local rc=$?
  is_dry || mysql -e "DROP DATABASE IF EXISTS \`$SCRATCH_DB\`" 2>/dev/null || true
  rm -rf "$WORK"
  if ! is_dry; then
    mkdir -p "$(dirname "$LOGFILE")"
    printf '{"ts":"%s","result":"%s","seconds":%s,"file":"%s","detail":"%s"}\n' \
      "$(date -u +%FT%TZ)" "$RESULT" "$(( $(date +%s) - STARTED ))" "$(basename "${FILE:-none}")" "$DETAIL" >>"$LOGFILE"
  fi
  [[ $rc -eq 0 ]] || err "RESTORE TEST FAILED: $DETAIL"
}
trap cleanup EXIT
fail() { DETAIL="$*"; die "$*"; }

if [[ -z "$FILE" ]]; then
  if [[ "$FROM_REMOTE" == "1" ]]; then
    [[ -n "$RCLONE_REMOTE" ]] || fail "--from-remote needs RCLONE_REMOTE in $CONFIG"
    if is_dry; then echo "[dry-run] rclone lsf newest r007-*.sql.gz* from $RCLONE_REMOTE/daily and copy" >&2; FILE="$WORK/remote-latest.sql.gz.age"; else
      newest="$(rclone lsf "$RCLONE_REMOTE/daily" --include 'r007-2*.sql.gz*' | sort | tail -n1)"
      [[ -n "$newest" ]] || fail "no dump found on remote"
      rclone copy "$RCLONE_REMOTE/daily/$newest" "$WORK/"
      FILE="$WORK/$newest"
    fi
  else
    if is_dry; then FILE="$BACKUP_DIR/r007-<latest>.sql.gz"; else
      FILE="$(find "$BACKUP_DIR" -maxdepth 1 -name 'r007-2*.sql.gz' | sort | tail -n1)"
      [[ -n "$FILE" ]] || fail "no local dump in $BACKUP_DIR"
    fi
  fi
fi
log "testing $FILE"

if is_dry; then
  echo "[dry-run] decrypt (if .age) -> gzip -t -> create $SCRATCH_DB -> load -> count tables (>= $MIN_TABLES) -> check migrations -> drop" >&2
  echo "[dry-run] newest r007-media-*.tar.gz[.age]: decrypt -> tar -tzf -> extract to scratch dir -> count files; env archive listing (with --age-identity)" >&2
  RESULT="dry-run"; exit 0
fi
[[ -f "$FILE" ]] || fail "file not found: $FILE"

age_h=$(( ( $(date +%s) - $(stat -c %Y "$FILE" 2>/dev/null || stat -f %m "$FILE") ) / 3600 ))
if [[ "$FROM_REMOTE" == "0" && "$age_h" -gt "$MAX_AGE_H" ]]; then fail "newest backup is ${age_h}h old (> ${MAX_AGE_H}h): the nightly backup is not running"; fi

DUMP="$FILE"
if [[ "$FILE" == *.age ]]; then
  [[ -n "$IDENTITY" && -f "$IDENTITY" ]] || fail "encrypted backup: pass --age-identity FILE (private key is kept off the server; copy it here temporarily and shred afterwards)"
  DUMP="$WORK/dump.sql.gz"; age -d -i "$IDENTITY" -o "$DUMP" "$FILE" || fail "decryption failed"
fi
gzip -t "$DUMP" || fail "gzip integrity check failed"

mysql -e "CREATE DATABASE \`$SCRATCH_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci"
# The dump was made with --databases (contains CREATE DATABASE/USE for the live name): rewrite to the scratch DB.
gzip -dc "$DUMP" | grep -q '^USE ' || fail "no USE statement in dump (not a --databases dump?)"
gzip -dc "$DUMP" | sed -E "/^(CREATE DATABASE|USE) /d" | mysql "$SCRATCH_DB" || fail "load failed"

tables="$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$SCRATCH_DB' AND table_type='BASE TABLE'")"
[[ "$tables" -ge "$MIN_TABLES" ]] || fail "only $tables tables restored (expected >= $MIN_TABLES)"
migs="$(mysql -N -e "SELECT COUNT(*) FROM \`$SCRATCH_DB\`.migrations" 2>/dev/null || echo 0)"
[[ "$migs" -ge 1 ]] || fail "migrations table empty/missing"
DETAIL="tables=$tables migrations=$migs backup_age_h=$age_h"

# ---- media archive ----------------------------------------------------------------------------
# newest_of PATTERN : newest matching artifact, local (BACKUP_DIR) or remote (copied into $WORK); empty when none
newest_of() {
  local pat="$1" n
  if [[ "$FROM_REMOTE" == "1" ]]; then
    n="$(rclone lsf "$RCLONE_REMOTE/daily" --include "$pat" | sort | tail -n1)"
    [[ -n "$n" ]] || return 0
    rclone copy "$RCLONE_REMOTE/daily/$n" "$WORK/" && printf '%s' "$WORK/$n"
  else
    find "$BACKUP_DIR" -maxdepth 1 -name "$pat" | sort | tail -n1
  fi
}
# plain_of FILE OUT : the file itself, or its decrypted copy (needs the identity)
plain_of() {
  if [[ "$1" == *.age ]]; then
    [[ -n "$IDENTITY" && -f "$IDENTITY" ]] || return 1
    age -d -i "$IDENTITY" -o "$2" "$1" || return 1
    printf '%s' "$2"
  else printf '%s' "$1"; fi
}
if [[ "$SKIP_MEDIA" == "0" ]]; then
  media="$(newest_of 'r007-media-2*.tar.gz*')"
  [[ -n "$media" ]] || fail "no media backup found (r007-media-*.tar.gz[.age]); MEDIA_BACKUP=off? use --skip-media only if there are no uploads"
  m_age_h=$(( ( $(date +%s) - $(stat -c %Y "$media" 2>/dev/null || stat -f %m "$media") ) / 3600 ))
  if [[ "$FROM_REMOTE" == "0" && "$m_age_h" -gt "$MAX_AGE_H" ]]; then fail "newest media backup is ${m_age_h}h old (> ${MAX_AGE_H}h)"; fi
  mplain="$(plain_of "$media" "$WORK/media.tar.gz")" || fail "media backup is encrypted: pass --age-identity FILE"
  tar -tzf "$mplain" >/dev/null || fail "media archive is corrupt"
  mkdir -p "$WORK/media"
  tar -xzf "$mplain" -C "$WORK/media" || fail "media archive does not extract"
  m_files="$(find "$WORK/media" -type f | wc -l | tr -d ' ')"
  DETAIL="$DETAIL media_files=$m_files media_age_h=$m_age_h"
  log "media archive OK: $m_files files"
fi
# env archive (only checkable with the private key): must contain the API .env
envb="$(newest_of 'r007-env-2*.tar.gz*')"
if [[ -n "$envb" ]]; then
  if eplain="$(plain_of "$envb" "$WORK/env.tar.gz")"; then
    tar -tzf "$eplain" | grep -q '^api/shared/\.env$' || fail "env archive does not contain api/shared/.env"
    DETAIL="$DETAIL env_archive=ok"
  else
    DETAIL="$DETAIL env_archive=skipped(no identity)"
  fi
else
  warn "no env archive found (AGE_RECIPIENT not set? secrets are never uploaded unencrypted)"
fi
RESULT="pass"
log "PASS: $DETAIL in $(( $(date +%s) - STARTED ))s"
