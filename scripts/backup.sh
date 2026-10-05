#!/usr/bin/env bash
# Creates ONE zip archive of the running TYPO3 stack:
#   database.sql      full dump of the TYPO3 database (data of cache_* tables skipped)
#   files/            composer.json/.lock, config/, packages/ (site packages, themes, local extensions),
#                     vendor/ (all installed extensions), public/fileadmin and every other local
#                     FAL storage configured in TYPO3 (processed/temp files are skipped)
#   backup-paths.txt  the project paths contained in files/ (used by restore.sh)
#   MANIFEST          metadata;  SHA256SUMS  checksums of everything above
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

  -o, --output DIR        where to write the archive (default: \$BACKUP_DIR or ./backups)
      --no-vendor         leave out vendor/ (restore then needs network access for 'composer install')
      --encrypt-to KEY    encrypt the archive with GnuPG for this recipient (writes .zip.gpg)
  -h, --help              show this help
EOF
}

output_dir=${BACKUP_DIR:-$PROJECT_DIR/backups}
include_vendor=1
gpg_recipient=
while (($#)); do
    case $1 in
        -o|--output)  output_dir=${2:?missing value for $1}; shift 2 ;;
        --no-vendor)  include_vendor=0; shift ;;
        --encrypt-to) gpg_recipient=${2:?missing value for $1}; shift 2 ;;
        -h|--help)    usage; exit 0 ;;
        *)            usage >&2; die "unknown option: $1" ;;
    esac
done

require docker zip sha256sum realpath
[[ -z $gpg_recipient ]] || require gpg
ensure_running db typo3

output_dir=$(realpath -m -- "$output_dir")
mkdir -p "$output_dir"
stage=$(make_stage backup)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/files"

# Local FAL storages from sys_file_storage, as paths relative to the project root
fal_storage_paths() {
    local rows row base type
    rows=$(db_sh 'mariadb -uroot -N -B "$MARIADB_DATABASE"' \
        <<<"SELECT configuration FROM sys_file_storage WHERE driver = 'Local' AND deleted = 0" 2>/dev/null) || return 0
    while IFS= read -r row; do
        base=$(sed -n 's/.*index="basePath">[^<]*<value index="vDEF">\([^<]*\)<.*/\1/p' <<<"$row")
        type=$(sed -n 's/.*index="pathType">[^<]*<value index="vDEF">\([^<]*\)<.*/\1/p' <<<"$row")
        [[ -n $base ]] || continue
        if [[ $type == absolute ]]; then
            if [[ $base != "$APP_ROOT"/* ]]; then
                warn "FAL storage '$base' is outside $APP_ROOT - NOT included, back it up separately"
                continue
            fi
            base=${base#"$APP_ROOT"/}
        else
            base=public/${base#/}   # relative storages are relative to the public/ directory
        fi
        base=${base%/}
        if [[ /$base/ == */../* ]]; then
            warn "skipping suspicious FAL storage path: $base"
            continue
        fi
        printf '%s\n' "$base"
    done <<<"$rows"
}

candidates=(composer.json composer.lock config packages public/fileadmin public/uploads public/typo3conf)
((include_vendor)) && candidates+=(vendor)
mapfile -t storages < <(fal_storage_paths)
candidates+=("${storages[@]}")

# De-duplicate, drop paths nested inside another candidate, keep only what exists in the container
mapfile -t paths < <(printf '%s\n' "${candidates[@]}" | LC_ALL=C sort -u |
    awk '{ for (p in seen) if (index($0, p "/") == 1) next; seen[$0]; print }')
mapfile -t paths < <(app_root sh -c 'for p; do [ -e "$p" ] && printf "%s\n" "$p"; done; true' sh "${paths[@]}")
((${#paths[@]})) || die "nothing to back up - is TYPO3 installed in ./app?"

db=$(db_name)
log "Dumping database '$db' …"
dump_opts=(--single-transaction --quick --routines --triggers --events --hex-blob
           --default-character-set=utf8mb4 --add-drop-table)
dump_help=$(compose exec -T db mariadb-dump --help)
if [[ $dump_help == *--ignore-table-data* ]]; then
    mapfile -t cache_tables < <(db_sh 'mariadb -uroot -N -B "$MARIADB_DATABASE"' <<<"SHOW TABLES LIKE 'cache\\_%'")
    for t in "${cache_tables[@]}"; do dump_opts+=("--ignore-table-data=$db.$t"); done
fi
db_sh 'exec mariadb-dump -uroot "$@" "$MARIADB_DATABASE"' "${dump_opts[@]}" >"$stage/database.sql"
[[ -s $stage/database.sql ]] || die "database dump is empty"

log "Copying files: ${paths[*]}"
app_root tar --exclude='_processed_' --exclude='_temp_' -cf - -- "${paths[@]}" |
    tar -C "$stage/files" --no-same-owner --same-permissions -xf -   # keep modes; $stage itself is 0700

typo3_version=$(app_www vendor/bin/typo3 --version 2>/dev/null | head -n 1) || typo3_version=unknown
printf '%s\n' "${paths[@]}" >"$stage/backup-paths.txt"
cat >"$stage/MANIFEST" <<EOF
format=$BACKUP_FORMAT
created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host=$(uname -n)
project=$PROJECT_DIR
typo3=$typo3_version
database=$db
vendor_included=$include_vendor
EOF
(cd "$stage" && find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum >SHA256SUMS)

archive="$output_dir/typo3-backup-$(date +%Y%m%d-%H%M%S).zip"
log "Writing archive …"
# -y stores symlinks as symlinks (composer path repositories link vendor/ -> packages/)
(umask 077 && cd "$stage" && zip -q -r -y "$archive.part" .)

if [[ -n $gpg_recipient ]]; then
    (umask 077 && gpg --batch --yes --encrypt --recipient "$gpg_recipient" --output "$archive.gpg" "$archive.part")
    rm -f "$archive.part"
    archive=$archive.gpg
else
    mv "$archive.part" "$archive"
fi
chmod 600 "$archive"
(cd "$output_dir" && sha256sum "$(basename "$archive")" >"$(basename "$archive").sha256")

log "Backup complete: $archive ($(du -h "$archive" | cut -f1))"
