#!/bin/sh
# Bootstraps a TYPO3 composer-mode project in /var/www/html on first start, then hands over to php-fpm.
set -eu

APP=/var/www/html
as_www() { runuser -u www-data -- "$@"; }
log() { echo "[typo3-entrypoint] $*"; }

# Docker creates a missing bind-mount source as root
chown www-data:www-data "$APP"

if [ ! -f "$APP/composer.json" ]; then
    log "No composer.json found - creating typo3/cms-base-distribution ${TYPO3_VERSION}"
    rm -rf /tmp/typo3-install
    as_www composer create-project --no-interaction --no-progress \
        typo3/cms-base-distribution /tmp/typo3-install "${TYPO3_VERSION}"
    as_www cp -a /tmp/typo3-install/. "$APP/"
    rm -rf /tmp/typo3-install
elif [ ! -f "$APP/vendor/autoload.php" ]; then
    log "vendor/ missing - running composer install"
    (cd "$APP" && as_www composer install --no-interaction --no-progress)
fi

if [ ! -f "$APP/config/system/settings.php" ] && [ "${TYPO3_AUTO_SETUP:-1}" = "1" ]; then
    log "Running 'typo3 setup' (database ${TYPO3_DB_DBNAME} on ${TYPO3_DB_HOST})"
    (cd "$APP" && as_www vendor/bin/typo3 setup --no-interaction --force) \
        || log "WARNING: automatic setup failed - finish the installation via /typo3/install.php"
fi

if [ -f "$APP/config/system/settings.php" ] && [ ! -f "$APP/config/system/additional.php" ]; then
    log "Installing config/system/additional.php (DB credentials from environment)"
    as_www cp /usr/local/share/typo3-docker/additional.php "$APP/config/system/additional.php"
fi

exec docker-php-entrypoint "$@"
