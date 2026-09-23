#!/usr/bin/env bash
# Shared helpers for the 007 Resort & Spa bash scripts (dev + vps).
# Source it; do not execute it. Every script using it supports --dry-run:
# state-changing commands go through `run`, which only prints them in dry-run mode.
# shellcheck shell=bash

: "${DRY_RUN:=0}"

if [[ -t 2 ]]; then
  _c_red=$'\033[31m'; _c_yel=$'\033[33m'; _c_grn=$'\033[32m'; _c_dim=$'\033[2m'; _c_off=$'\033[0m'
else
  _c_red=""; _c_yel=""; _c_grn=""; _c_dim=""; _c_off=""
fi

log()  { printf '%s[%s]%s %s\n' "$_c_grn" "${SCRIPT_TAG:-r007}" "$_c_off" "$*" >&2; }
warn() { printf '%s[%s] WARN:%s %s\n' "$_c_yel" "${SCRIPT_TAG:-r007}" "$_c_off" "$*" >&2; }
err()  { printf '%s[%s] ERROR:%s %s\n' "$_c_red" "${SCRIPT_TAG:-r007}" "$_c_off" "$*" >&2; }
die()  { err "$*"; exit 1; }

is_dry() { [[ "$DRY_RUN" == "1" ]]; }

# run CMD ARGS... : execute, or print in dry-run mode.
run() {
  if is_dry; then
    printf '%s[dry-run]%s %s\n' "$_c_dim" "$_c_off" "$*" >&2
    return 0
  fi
  "$@"
}

# run_sh 'shell string' : same for commands that need pipes/redirection.
run_sh() {
  if is_dry; then
    printf '%s[dry-run]%s %s\n' "$_c_dim" "$_c_off" "$1" >&2
    return 0
  fi
  bash -c "$1"
}

# write_file PATH MODE < content : create/overwrite only when content changed (idempotent).
write_file() {
  local path="$1" mode="${2:-644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [[ -f "$path" ]] && cmp -s "$tmp" "$path"; then
    rm -f "$tmp"
    return 0
  fi
  if is_dry; then
    printf '%s[dry-run]%s write %s (mode %s)\n' "$_c_dim" "$_c_off" "$path" "$mode" >&2
    rm -f "$tmp"
    return 0
  fi
  install -m "$mode" "$tmp" "$path"
  rm -f "$tmp"
  log "wrote $path"
}

have() { command -v "$1" >/dev/null 2>&1; }

need_cmd() { have "$1" || die "required command not found: $1"; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]] && ! is_dry; then
    die "run as root (sudo)"
  fi
}

# random_secret [BYTES] : URL-safe random string, never echoed to logs by callers.
random_secret() {
  local n="${1:-32}"
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$n"
  echo
}

# env_get FILE KEY : print value (no quotes stripping beyond outer double quotes).
env_get() {
  local file="$1" key="$2" line
  line="$(grep -E "^${key}=" "$file" 2>/dev/null | tail -n1 || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  printf '%s' "$line"
}

# env_set FILE KEY VALUE : replace the KEY= line or append it. Value written verbatim.
env_set() {
  local file="$1" key="$2" value="$3" tmp
  if is_dry; then
    printf '%s[dry-run]%s env_set %s %s=<hidden>\n' "$_c_dim" "$_c_off" "$file" "$key" >&2
    return 0
  fi
  tmp="$(mktemp)"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    KEY="$key" VAL="$value" awk 'BEGIN{FS=OFS="="} $1==ENVIRON["KEY"] && !d {print ENVIRON["KEY"] "=" ENVIRON["VAL"]; d=1; next} {print}' "$file" >"$tmp"
  else
    cat "$file" >"$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$value" >>"$tmp"
  fi
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# env_fill_generated FILE KEY [BYTES] : if KEY's value is empty or "<generate>", set a random secret.
env_fill_generated() {
  local file="$1" key="$2" bytes="${3:-32}" cur
  cur="$(env_get "$file" "$key")"
  cur="${cur%%[[:space:]]#*}"
  cur="${cur%"${cur##*[![:space:]]}"}"
  if [[ -z "$cur" || "$cur" == "<generate>" ]]; then
    env_set "$file" "$key" "$(random_secret "$bytes")"
  fi
}

# parse the common flags; leaves the rest in REST_ARGS.
REST_ARGS=()
parse_common_flags() {
  REST_ARGS=()
  local a
  for a in "$@"; do
    case "$a" in
      --dry-run|-n) DRY_RUN=1 ;;
      *) REST_ARGS+=("$a") ;;
    esac
  done
}
