#!/usr/bin/env bash
# Creates .env from .env.example with random secrets and the current user's UID/GID.
# Never overwrites an existing .env.
set -eu
umask 077
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [[ -e .env ]]; then
    echo ".env already exists - not touching it." >&2
    exit 1
fi

rand() { head -c 64 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-32}"; }

admin_password="$(rand 20)-Aa1"
sed -e "s/^HOST_UID=.*/HOST_UID=$(id -u)/" \
    -e "s/^HOST_GID=.*/HOST_GID=$(id -g)/" \
    -e "s/^DB_PASSWORD=.*/DB_PASSWORD=$(rand 32)/" \
    -e "s/^DB_ROOT_PASSWORD=.*/DB_ROOT_PASSWORD=$(rand 32)/" \
    -e "s/^TYPO3_ADMIN_PASSWORD=.*/TYPO3_ADMIN_PASSWORD=${admin_password}/" \
    .env.example >.env

echo "Created .env (mode 600). TYPO3 backend login: user 'admin', password in TYPO3_ADMIN_PASSWORD."
