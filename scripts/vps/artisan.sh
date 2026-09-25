#!/usr/bin/env bash
# Run an artisan command of a deployed app AS THAT APP'S OWN USER (correct file ownership, same rights as the web pool).
# Installed as /usr/local/bin/r007-artisan; run it as the deploy user.
#
#   r007-artisan api r007:cms-seed           # optional demo CMS content
#   r007-artisan api r007:service-token list
#   r007-artisan site route:list
#
# Not for migrations: deploy.sh runs those with the DDL account. Secrets are never echoed by this script.
set -euo pipefail
SCRIPT_TAG="artisan"; export SCRIPT_TAG
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/common.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/common.sh"
# shellcheck source=../lib/stack.sh
# shellcheck source-path=SCRIPTDIR
source "$SCRIPT_DIR/../lib/stack.sh"

case "${1:-}" in ""|-h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; *) : ;; esac
APP="$1"; shift
app_valid "$APP" || die "app must be api|site|admin"
[[ $# -gt 0 ]] || die "give an artisan command"
stack_load ""
app_enabled "$APP" || die "app $APP is not enabled on this server"
DIR="$(app_dir "$APP")/current"
[[ -f "$DIR/artisan" ]] || die "$APP is not deployed yet ($DIR/artisan missing)"
cd "$DIR"
if [[ "$(id -un)" == "$(app_user "$APP")" ]]; then exec /usr/bin/php artisan "$@"; fi
exec sudo -n -u "$(app_user "$APP")" -H /usr/bin/php artisan "$@"
