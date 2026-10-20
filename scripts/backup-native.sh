#!/usr/bin/env bash
# Backs up an existing NON-Docker, composer-based TYPO3 installation into the same archive format as
# backup.sh, so the result can be restored into this Docker stack with restore.sh.
#
# Self-contained: copy this single file to the server running TYPO3. Needs bash, php (CLI), tar, zip,
# sha256sum, realpath and mariadb-dump/mysqldump + mariadb/mysql client. Run it as a user that can read
# the whole TYPO3 project (typically the web server user or root).
#
# Archive layout (must match restore.sh / lib.sh BACKUP_FORMAT):
#   database.sql      dump of the TYPO3 database (data of cache_* tables skipped), no CREATE DATABASE/USE
#   files/            composer.json/.lock, config/, packages/, vendor/, <web-dir>/fileadmin, legacy
#                     <web-dir>/uploads + typo3conf, and every other local FAL storage inside the project
#   backup-paths.txt  the project paths contained in files/
#   MANIFEST          metadata;  SHA256SUMS  checksums of everything above
set -Eeuo pipefail

BACKUP_FORMAT=1   # keep in sync with scripts/lib.sh

log()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
warn() { log "WARNING: $*"; }
die()  { log "ERROR: $*"; exit 1; }
require() {
    local cmd
    for cmd; do command -v "$cmd" >/dev/null 2>&1 || die "required command not found: $cmd"; done
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [TYPO3_PROJECT_DIR]

TYPO3_PROJECT_DIR is the composer project root (contains composer.json); default: current directory.
Database credentials are read from config/system/settings.php + additional.php (TYPO3 >= 12) or
<web-dir>/typo3conf/LocalConfiguration.php + AdditionalConfiguration.php (TYPO3 9-11).

  -o, --output DIR             where to write the archive (default: \$BACKUP_DIR or ./backups)
      --no-vendor              leave out vendor/ (restore then needs network access for 'composer install')
      --routines               also dump stored routines and events (needs extra DB privileges)
      --fix-mysql8-collations  rewrite MySQL 8 utf8mb4_0900_* collations to utf8mb4_unicode_ci in the
                               dump's DDL, for import into MariaDB
      --no-additional-config   don't evaluate additional.php / AdditionalConfiguration.php
      --php BIN                PHP CLI binary (default: \$PHP or php)

  Database overrides (take precedence over the TYPO3 configuration):
      --db-host HOST   --db-port PORT   --db-socket PATH   --db-name NAME   --db-user USER
      --db-password-file FILE  read the password from FILE (or set env TYPO3_DB_PASSWORD);
                               passwords are never accepted on the command line

  -h, --help                   show this help

Environment: BACKUP_DIR, BACKUP_TMPDIR (staging dir, needs space for a full copy), PHP, TYPO3_DB_PASSWORD
EOF
}

output_dir=${BACKUP_DIR:-$PWD/backups}
include_vendor=1 dump_routines=0 fix_collations=0 eval_additional=1
php_bin=${PHP:-php}
root=
declare -A ovr=()
while (($#)); do
    case $1 in
        -o|--output)             output_dir=${2:?missing value for $1}; shift 2 ;;
        --no-vendor)             include_vendor=0; shift ;;
        --routines)              dump_routines=1; shift ;;
        --fix-mysql8-collations) fix_collations=1; shift ;;
        --no-additional-config)  eval_additional=0; shift ;;
        --php)                   php_bin=${2:?missing value for $1}; shift 2 ;;
        --db-host)               ovr[host]=${2:?missing value for $1}; shift 2 ;;
        --db-port)               ovr[port]=${2:?missing value for $1}; shift 2 ;;
        --db-socket)             ovr[unix_socket]=${2:?missing value for $1}; shift 2 ;;
        --db-name)               ovr[dbname]=${2:?missing value for $1}; shift 2 ;;
        --db-user)               ovr[user]=${2:?missing value for $1}; shift 2 ;;
        --db-password-file)      f=${2:?missing value for $1}; [[ -r $f ]] || die "cannot read $f"
                                 ovr[password]=$(<"$f"); shift 2 ;;
        -h|--help)               usage; exit 0 ;;
        -*)                      usage >&2; die "unknown option: $1" ;;
        *)                       [[ -z $root ]] || die "only one project directory allowed"; root=$1; shift ;;
    esac
done
[[ -n ${TYPO3_DB_PASSWORD+x} && -z ${ovr[password]+x} ]] && ovr[password]=$TYPO3_DB_PASSWORD

require "$php_bin" tar zip sha256sum realpath find
if command -v mariadb-dump >/dev/null 2>&1 && command -v mariadb >/dev/null 2>&1; then
    dump_bin=mariadb-dump client_bin=mariadb
else
    require mysqldump mysql
    dump_bin=mysqldump client_bin=mysql
fi

root=$(realpath -e -- "${root:-.}") || die "project directory not found"
[[ -f $root/composer.json ]] || die "$root/composer.json not found - restore.sh only supports composer-based TYPO3 (migrate classic installs to composer first)"

output_dir=$(realpath -m -- "$output_dir")
[[ $output_dir/ != "$root"/* ]] || die "output directory must not be inside the TYPO3 project"
mkdir -p "$output_dir"
umask 077
stage=$(mktemp -d "${BACKUP_TMPDIR:-${TMPDIR:-/tmp}}/typo3-backup.XXXXXX")
trap 'rm -rf "$stage"' EXIT
stage=$(realpath "$stage")
mkdir "$stage/files"
sfiles=$stage/files

# --- Read project and DB settings from the TYPO3 configuration ---------------------------------
# Output: NUL-separated key=value pairs. Executes the site's own config files (as TYPO3 itself does).
cat >"$stage/read-config.php" <<'PHP'
<?php
error_reporting(E_ALL & ~E_DEPRECATED & ~E_NOTICE & ~E_WARNING);
ini_set('display_errors', 'stderr');
[, $root, $evalAdditional] = $argv;
$out = [];
$composer = json_decode((string)@file_get_contents("$root/composer.json"), true) ?: [];
$web = trim($composer['extra']['typo3/cms']['web-dir'] ?? 'public', '/');
$vendor = trim($composer['config']['vendor-dir'] ?? 'vendor', '/');
$out['web_dir'] = $web;
$out['vendor_dir'] = $vendor;
$out['typo3_version'] = '';
$lock = json_decode((string)@file_get_contents("$root/composer.lock"), true) ?: [];
foreach ($lock['packages'] ?? [] as $p) {
    if (($p['name'] ?? '') === 'typo3/cms-core') { $out['typo3_version'] = ltrim($p['version'], 'v'); break; }
}

$pairs = [
    ["$root/config/system/settings.php", "$root/config/system/additional.php"],
    ["$root/$web/typo3conf/LocalConfiguration.php", "$root/$web/typo3conf/AdditionalConfiguration.php"],
];
$GLOBALS['TYPO3_CONF_VARS'] = [];
$out['settings_file'] = '';
foreach ($pairs as [$settings, $additional]) {
    if (!is_file($settings)) continue;
    $out['settings_file'] = substr($settings, strlen($root) + 1);
    ob_start();
    $conf = require $settings;
    ob_end_clean();
    if (is_array($conf)) $GLOBALS['TYPO3_CONF_VARS'] = $conf;
    if ($evalAdditional === '1' && is_file($additional)) {
        defined('TYPO3') || define('TYPO3', true);
        defined('TYPO3_MODE') || define('TYPO3_MODE', 'BE');
        if (is_file("$root/$vendor/autoload.php")) require_once "$root/$vendor/autoload.php";
        ob_start();
        try {
            (static function () use ($additional) { require $additional; })();
        } catch (\Throwable $e) {
            fwrite(STDERR, "WARNING: could not evaluate " . basename($additional) . " (" . $e->getMessage()
                . ") - using values from " . basename($settings) . "; override with --db-* if needed\n");
        }
        ob_end_clean();
    }
    break;
}
$db = $GLOBALS['TYPO3_CONF_VARS']['DB']['Connections']['Default'] ?? [];
foreach (['driver', 'host', 'port', 'unix_socket', 'dbname', 'user', 'password'] as $k) {
    $out["db_$k"] = (string)($db[$k] ?? '');
}
foreach ($out as $k => $v) {
    if (strpbrk($v, "\0\n") !== false) { fwrite(STDERR, "ERROR: unsupported character in $k\n"); exit(1); }
    echo "$k=$v\0";
}
PHP

log "Reading TYPO3 configuration from $root …"
"$php_bin" "$stage/read-config.php" "$root" "$eval_additional" >"$stage/config.out" ||
    die "could not read the TYPO3 configuration (use --db-* options or --no-additional-config)"
declare -A cfg=()
while IFS= read -r -d '' kv; do cfg[${kv%%=*}]=${kv#*=}; done <"$stage/config.out"
rm -f "$stage/config.out"

web_dir=${cfg[web_dir]} vendor_dir=${cfg[vendor_dir]} typo3_version=${cfg[typo3_version]}
[[ -n $typo3_version ]] || die "typo3/cms-core not found in composer.lock - is this a composer-based TYPO3 project?"
[[ $web_dir == public ]] || warn "web-dir is '$web_dir' - the Docker stack serves 'public/'; adjust composer.json after restore"
[[ $vendor_dir == vendor ]] || warn "vendor-dir is '$vendor_dir' - restore.sh expects 'vendor/'"
if [[ ${typo3_version%%.*} =~ ^[0-9]+$ ]] && ((${typo3_version%%.*} < 12)); then
    warn "TYPO3 $typo3_version: restore.sh injects DB credentials via config/system/additional.php (TYPO3 >= 12);"
    warn "for this version adjust the DB settings in ${cfg[settings_file]:-LocalConfiguration.php} after restore"
fi

declare -A db=()
for k in driver host port unix_socket dbname user password; do db[$k]=${cfg[db_$k]-}; done
for k in "${!ovr[@]}"; do db[$k]=${ovr[$k]}; done
unset cfg ovr
case ${db[driver]:-mysqli} in
    mysqli|pdo_mysql) ;;
    *) die "database driver '${db[driver]}' is not supported - the Docker stack uses MariaDB" ;;
esac
[[ -n ${db[dbname]} ]] || die "no database name found - use --db-name"

# Credentials go into a 0600 option file in the 0700 stage dir - never onto a command line
optval() { local v=${1//\\/\\\\}; printf '"%s"' "${v//\"/\\\"}"; }
{
    echo '[client]'
    [[ -n ${db[host]} ]]        && echo "host=$(optval "${db[host]}")"
    [[ -n ${db[port]} ]]        && echo "port=$(optval "${db[port]}")"
    [[ -n ${db[unix_socket]} ]] && echo "socket=$(optval "${db[unix_socket]}")"
    [[ -n ${db[user]} ]]        && echo "user=$(optval "${db[user]}")"
    [[ -n ${db[password]} ]]    && echo "password=$(optval "${db[password]}")"
    echo 'default-character-set=utf8mb4'
} >"$stage/my.cnf"
dbname=${db[dbname]}
unset db

dbq() { "$client_bin" --defaults-extra-file="$stage/my.cnf" -N -B "$dbname"; }
dbq <<<"SELECT 1" >/dev/null || die "cannot connect to database '$dbname'"

# --- Paths to back up ---------------------------------------------------------------------------
# Local FAL storages from sys_file_storage, as paths relative to the project root
fal_storage_paths() {
    local rows row base type
    rows=$(dbq <<<"SELECT configuration FROM sys_file_storage WHERE driver = 'Local' AND deleted = 0" 2>/dev/null) || return 0
    while IFS= read -r row; do
        base=$(sed -n 's/.*index="basePath">[^<]*<value index="vDEF">\([^<]*\)<.*/\1/p' <<<"$row")
        type=$(sed -n 's/.*index="pathType">[^<]*<value index="vDEF">\([^<]*\)<.*/\1/p' <<<"$row")
        [[ -n $base ]] || continue
        if [[ $type == absolute ]]; then
            base=$(realpath -m -- "$base")
            if [[ $base != "$root"/* ]]; then
                warn "FAL storage '$base' is outside $root - NOT included, back it up separately"
                continue
            fi
            warn "FAL storage '$base' uses an absolute path - update it in the backend after restore"
            base=${base#"$root"/}
        else
            base=$web_dir/${base#/}   # relative storages are relative to the web directory
        fi
        base=${base%/}
        if [[ /$base/ == */../* ]]; then
            warn "skipping suspicious FAL storage path: $base"
            continue
        fi
        printf '%s\n' "$base"
    done <<<"$rows"
}

candidates=(composer.json composer.lock config packages local_packages "$web_dir/fileadmin" "$web_dir/uploads" "$web_dir/typo3conf")
((include_vendor)) && candidates+=("$vendor_dir")
mapfile -t storages < <(fal_storage_paths)
candidates+=("${storages[@]}")

# De-duplicate, drop paths nested inside another candidate, keep what exists and restore.sh accepts
mapfile -t sorted < <(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort -u |
    awk '{ for (p in seen) if (index($0, p "/") == 1) next; seen[$0]; print }')
paths=()
for p in "${sorted[@]}"; do
    [[ -e $root/$p || -L $root/$p ]] || continue
    if [[ ! $p =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ || /$p/ == */./* ]]; then
        warn "path '$p' contains characters restore.sh rejects - NOT included, back it up separately"
        continue
    fi
    paths+=("$p")
done
((${#paths[@]})) || die "nothing to back up in $root"

# --- Database -----------------------------------------------------------------------------------
log "Dumping database '$dbname' with $dump_bin …"
dump_help=$("$dump_bin" --help 2>/dev/null || true)
dump_opts=(--single-transaction --quick --hex-blob --triggers --add-drop-table --default-character-set=utf8mb4)
((dump_routines)) && dump_opts+=(--routines --events)
[[ $dump_help == *--no-tablespaces* ]]    && dump_opts+=(--no-tablespaces)       # avoids PROCESS privilege
[[ $dump_help == *--set-gtid-purged* ]]   && dump_opts+=(--set-gtid-purged=OFF)  # MySQL: GTID lines break MariaDB import
[[ $dump_help == *--column-statistics* ]] && dump_opts+=(--column-statistics=0)  # MySQL 8 client vs. MariaDB server

mapfile -t cache_tables < <(dbq <<<"SHOW TABLES LIKE 'cache\\_%'")
nodata_tables=()
for t in "${cache_tables[@]}"; do
    if [[ $dump_help == *--ignore-table-data* ]]; then
        dump_opts+=("--ignore-table-data=$dbname.$t")
    else
        dump_opts+=("--ignore-table=$dbname.$t"); nodata_tables+=("$t")
    fi
done
"$dump_bin" --defaults-extra-file="$stage/my.cnf" "${dump_opts[@]}" "$dbname" >"$stage/database.sql"
if ((${#nodata_tables[@]})); then   # client without --ignore-table-data: add structure-only cache tables
    "$dump_bin" --defaults-extra-file="$stage/my.cnf" --no-data --add-drop-table --skip-triggers \
        --default-character-set=utf8mb4 "$dbname" "${nodata_tables[@]}" >>"$stage/database.sql"
fi
rm -f "$stage/my.cnf"
[[ -s $stage/database.sql ]] || die "database dump is empty"

if grep -q 'utf8mb4_0900_' "$stage/database.sql"; then
    if ((fix_collations)); then
        log "Rewriting MySQL 8 collations to utf8mb4_unicode_ci …"
        sed -i '/^INSERT /!s/utf8mb4_0900_[a-z_]*/utf8mb4_unicode_ci/g' "$stage/database.sql"
    else
        warn "dump uses MySQL 8 utf8mb4_0900_* collations that MariaDB may reject - consider --fix-mysql8-collations"
    fi
fi

# --- Files --------------------------------------------------------------------------------------
log "Copying files: ${paths[*]}"
tar -C "$root" --exclude='_processed_' --exclude='_temp_' -cf - -- "${paths[@]}" |
    tar -C "$sfiles" --no-same-owner --same-permissions -xf -

# restore.sh rejects symlinks that leave files/. Typical on deployment setups (fileadmin -> shared/,
# absolute links into vendor/): rewrite links into the project as relative links, copy everything else.
for pass in 1 2 3 4 5; do
    changed=0
    while IFS= read -r -d '' link; do
        [[ $(realpath -m -- "$link") == "$sfiles/"* ]] && continue
        rel=${link#"$sfiles/"}
        target=$(realpath -m -- "$root/$rel")   # resolved on the source host, same relative layout
        changed=1
        rm -f -- "$link"
        if [[ $target == "$root/"* && -e $sfiles/${target#"$root/"} ]]; then
            ln -s -- "$(realpath -m --relative-to="$(dirname -- "$link")" -- "$sfiles/${target#"$root/"}")" "$link"
        elif [[ -d $target ]]; then
            log "Copying symlinked directory $rel -> $target"
            mkdir -- "$link"
            tar -C "$target" --exclude='_processed_' --exclude='_temp_' -cf - . |
                tar -C "$link" --no-same-owner --same-permissions -xf -
        elif [[ -f $target ]]; then
            cp -p -- "$target" "$link"
        else
            warn "dropping dangling symlink $rel"
        fi
    done < <(find "$sfiles" -type l -print0)
    ((changed)) || break
done
while IFS= read -r -d '' link; do
    [[ $(realpath -m -- "$link") == "$sfiles/"* ]] || die "could not resolve symlink ${link#"$sfiles/"} (loop?)"
done < <(find "$sfiles" -type l -print0)

# --- Metadata and archive -----------------------------------------------------------------------
rm -f "$stage/read-config.php"
printf '%s\n' "${paths[@]}" >"$stage/backup-paths.txt"
cat >"$stage/MANIFEST" <<EOF
format=$BACKUP_FORMAT
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host=$(uname -n)
project=$root
typo3=TYPO3 CMS $typo3_version
database=$dbname
vendor_included=$include_vendor
source=native
EOF
(cd "$stage" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS)

archive="$output_dir/typo3-backup-$(date +%Y%m%d-%H%M%S).zip"
log "Writing archive …"
# -y stores symlinks as symlinks (composer path repositories link vendor/ -> packages/)
(cd "$stage" && zip -q -r -y "$archive.part" .)
mv "$archive.part" "$archive"
chmod 600 "$archive"
(cd "$output_dir" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")

log "Backup complete: $archive ($(du -h "$archive" | cut -f1))"
log "Restore on the Docker host with: ./scripts/restore.sh $(basename "$archive")"
