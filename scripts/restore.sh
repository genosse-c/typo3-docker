#!/usr/bin/env bash
# Restores an archive created by backup.sh into this stack: replaces the TYPO3 database and the
# project paths contained in the backup, then runs composer install, extension:setup and cache:flush.
set -Eeuo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] BACKUP_FILE(.zip|.zip.gpg)

  -y, --yes          don't ask for confirmation
      --db-only      restore only the database
      --files-only   restore only the files
  -h, --help         show this help
EOF
}

assume_yes=0 do_db=1 do_files=1 archive=
while (($#)); do
    case $1 in
        -y|--yes)     assume_yes=1; shift ;;
        --db-only)    do_files=0; shift ;;
        --files-only) do_db=0; shift ;;
        -h|--help)    usage; exit 0 ;;
        -*)           usage >&2; die "unknown option: $1" ;;
        *)            [[ -z $archive ]] || die "only one backup file allowed"; archive=$1; shift ;;
    esac
done
[[ -n $archive ]] || { usage >&2; exit 1; }
[[ -f $archive ]] || die "backup file not found: $archive"
((do_db || do_files)) || die "--db-only and --files-only are mutually exclusive"

require docker unzip sha256sum realpath
archive=$(realpath -- "$archive")
stage=$(make_stage restore)
web_stopped=0
cleanup() {
    rm -rf "$stage"
    if ((web_stopped)); then
        warn "restore did not finish - web server left stopped; run 'docker compose up -d' once fixed"
    fi
}
trap cleanup EXIT

# --- Verify the archive before touching anything ------------------------------------------------
if [[ -f $archive.sha256 ]]; then
    log "Verifying $(basename "$archive").sha256 …"
    (cd "$(dirname "$archive")" && sha256sum -c --quiet "$(basename "$archive").sha256") || die "archive checksum mismatch"
fi

zipfile=$archive
if [[ $archive == *.gpg ]]; then
    require gpg
    log "Decrypting …"
    gpg --batch --quiet --decrypt --output "$stage/backup.zip" "$archive"
    zipfile=$stage/backup.zip
fi

unzip -tqq "$zipfile" >/dev/null || die "archive is corrupt"
listing=$(unzip -Z1 "$zipfile")
if grep -Eq '(^/|(^|/)\.\.(/|$))' <<<"$listing"; then
    die "archive contains absolute or '..' paths - refusing to extract"
fi

mkdir "$stage/x"
unzip -qq "$zipfile" -d "$stage/x"
x=$(realpath "$stage/x")
[[ -f $x/MANIFEST ]] && grep -qx "format=$BACKUP_FORMAT" "$x/MANIFEST" || die "not a backup created by backup.sh (format $BACKUP_FORMAT)"
(cd "$x" && sha256sum -c --quiet SHA256SUMS) || die "content checksums do not match - archive damaged or tampered with"

# Symlinks must stay inside the restored tree
while IFS= read -r -d '' link; do
    [[ $(realpath -m -- "$link") == "$x/files/"* ]] || die "symlink points outside the backup: ${link#"$x/"}"
done < <(find "$x" -type l -print0)

mapfile -t paths <"$x/backup-paths.txt"
for p in "${paths[@]}"; do
    # These paths are deleted in the container before restoring - be strict
    [[ $p =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ && /$p/ != */../* && /$p/ != */./* ]] || die "invalid path in backup-paths.txt: '$p'"
done

log "Backup details:"
sed 's/^/    /' "$x/MANIFEST" >&2
((do_db)) && log "Will replace the database"
((do_files)) && log "Will replace: ${paths[*]}"
if ((!assume_yes)); then
    read -r -p "This OVERWRITES the current site in '$PROJECT_DIR'. Type 'yes' to continue: " answer
    [[ $answer == yes ]] || die "aborted"
fi

# --- Restore ------------------------------------------------------------------------------------
log "Starting database and TYPO3 containers …"
compose up -d --wait db typo3
compose stop web >/dev/null 2>&1 && web_stopped=1   # no visitors / editors during the restore

if ((do_db)); then
    [[ -f $x/database.sql ]] || die "backup contains no database.sql"
    db=$(db_name)
    log "Restoring database '$db' …"
    db_sh 'mariadb -uroot' <<<"DROP DATABASE IF EXISTS \`$db\`; CREATE DATABASE \`$db\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
    db_sh 'mariadb -uroot "$MARIADB_DATABASE"' <"$x/database.sql"
fi

if ((do_files)); then
    log "Replacing files: ${paths[*]}"
    app_root rm -rf -- "${paths[@]}"
    # Explicit paths (not "."), so the project root's own permissions are left untouched
    tar -C "$x/files" -cf - -- "${paths[@]}" | app_root tar --no-same-owner -xf -
    app_root chown -R www-data:www-data -- "${paths[@]}"

    if app_root test ! -f config/system/additional.php; then
        app_www cp /usr/local/share/typo3-docker/additional.php config/system/additional.php
    elif ! app_root grep -q 'typo3-docker: managed file' config/system/additional.php; then
        warn "config/system/additional.php comes from the backup and does not read DB credentials from the"
        warn "environment - check the DB connection settings if the site cannot connect to the database"
    fi

    log "composer install …"
    app_www composer install --no-interaction --no-progress
    log "typo3 extension:setup …"
    app_www vendor/bin/typo3 extension:setup
fi

log "typo3 cache:flush …"
app_www vendor/bin/typo3 cache:flush

compose up -d
web_stopped=0
log "Restore complete."
