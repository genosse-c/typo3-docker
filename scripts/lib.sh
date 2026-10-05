# shellcheck shell=bash
# Shared helpers for backup.sh and restore.sh - sourced, not executed.

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
APP_ROOT=/var/www/html   # TYPO3 project root inside the typo3 container
BACKUP_FORMAT=1          # bump when the archive layout changes

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }

require() {
    local cmd
    for cmd; do command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"; done
}

compose() { docker compose -f "$PROJECT_DIR/compose.yaml" "$@"; }

# db_sh SCRIPT [ARGS...] - run a shell snippet in the db container, authenticated as root via the
# container's own MARIADB_ROOT_PASSWORD (never passed on a command line). ARGS become $1.. in SCRIPT.
db_sh() {
    local script=$1; shift
    compose exec -T db sh -c "export MYSQL_PWD=\"\$MARIADB_ROOT_PASSWORD\"; $script" sh "$@"
}

# app_www CMD... - run a command as www-data in the TYPO3 project root
app_www() { compose exec -T -u www-data -w "$APP_ROOT" typo3 "$@"; }

# app_root CMD... - run a command as root in the TYPO3 project root
app_root() { compose exec -T -w "$APP_ROOT" typo3 "$@"; }

db_name() { compose exec -T db printenv MARIADB_DATABASE; }

ensure_running() {
    local svc running
    running=$(compose ps --status running --services)
    for svc; do
        grep -qx "$svc" <<<"$running" || die "service '$svc' is not running - start the stack with: docker compose up -d"
    done
}

make_stage() {
    mktemp -d "${BACKUP_TMPDIR:-${TMPDIR:-/tmp}}/typo3-$1.XXXXXX"
}
