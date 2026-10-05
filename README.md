# TYPO3 (composer mode) on Docker

| Service      | Image                       | Purpose                                            | Reachable at            |
|--------------|-----------------------------|----------------------------------------------------|-------------------------|
| `web`        | `nginx:1.28-alpine`         | Web server, static files, forwards PHP to FPM      | http://localhost:8080   |
| `typo3`      | built from `docker/typo3`   | PHP-FPM 8.3 + Composer, TYPO3 in composer mode     | internal only (:9000)   |
| `db`         | `mariadb:11.4`              | Database                                           | internal network only   |
| `phpmyadmin` | `phpmyadmin:5.2`            | DB administration                                  | http://127.0.0.1:8081   |

nginx is used instead of Apache: with PHP-FPM in its own container it's the leaner, more common setup, and
it keeps the web server and PHP runtime in separate containers.

## Quick start

```bash
./scripts/init-env.sh          # creates .env with random passwords and your UID/GID
docker compose up -d --build   # first start runs composer create-project + typo3 setup (takes a few minutes)
docker compose logs -f typo3   # watch progress
```

Backend: http://localhost:8080/typo3. User `admin`, password = `TYPO3_ADMIN_PASSWORD` in `.env`.
After the first install, remove `TYPO3_ADMIN_PASSWORD` from `.env` and run `docker compose up -d`.

The TYPO3 project lives in `./app` on the host (composer.json, `config/`, `packages/`, `public/`, `vendor/`):

```bash
docker compose exec -u www-data typo3 composer require georgringer/news
docker compose exec -u www-data typo3 vendor/bin/typo3 cache:flush
```

If `./app` already contains a composer-based TYPO3 project, it's used as-is. Otherwise a fresh
`typo3/cms-base-distribution` (`TYPO3_VERSION`) is installed there.

Database credentials are injected from the environment through `config/system/additional.php`
(installed automatically), so a site restored from another instance of this stack works without editing
`settings.php`.

## Backup

```bash
./scripts/backup.sh                         # -> backups/typo3-backup-YYYYmmdd-HHMMSS.zip (+ .sha256)
./scripts/backup.sh --encrypt-to ops@example.com   # GnuPG-encrypted .zip.gpg
./scripts/backup.sh --no-vendor -o /mnt/backup     # smaller; restore then runs composer online
```

The archive contains:

| Entry              | Content                                                                                   |
|--------------------|-------------------------------------------------------------------------------------------|
| `database.sql`     | Full dump (routines, triggers, events). Data of `cache_*` tables is skipped (structure kept) |
| `files/`           | `composer.json`, `composer.lock`, `config/`, `packages/` (site packages / themes / local extensions), `vendor/` (installed extensions), `public/fileadmin`, legacy `public/uploads` / `public/typo3conf`, **and every other Local FAL storage configured in `sys_file_storage`** |
| `backup-paths.txt` | The project paths in `files/`                                                            |
| `MANIFEST`         | Date, host, TYPO3 version, DB name                                                        |
| `SHA256SUMS`       | Checksums of all entries                                                                  |

Regenerable data (`_processed_`, `_temp_`, `var/cache`) is excluded. FAL storages with an absolute path
outside the project are reported with a warning and must be backed up separately.

## Restore

```bash
./scripts/restore.sh backups/typo3-backup-20260929-120000.zip
./scripts/restore.sh -y --db-only backup.zip.gpg
```

Before anything is changed, the restore:

1. verifies the `.sha256` file (if present), the zip itself and `SHA256SUMS`,
2. rejects archives with absolute or `..` paths, symlinks pointing outside the backup, or invalid entries in `backup-paths.txt`,
3. shows the manifest and asks for confirmation.

It then stops `web`, recreates the database and imports the dump, replaces the backed-up paths,
and runs `composer install`, `typo3 extension:setup` and `typo3 cache:flush`. Finally it starts the stack again.
It works on an empty checkout too: `./scripts/init-env.sh && ./scripts/restore.sh <file>`.

## Security notes (ISO 27001 / SOC 2)

- **Secrets**: only in `.env` (mode 600, git-ignored). DB passwords are never passed on command lines,
  because the scripts use `MYSQL_PWD` inside the container. The TYPO3 setup password is not forwarded to PHP-FPM.
- **Network exposure**: HTTP binds to `127.0.0.1` by default (`BIND_ADDRESS`). phpMyAdmin is *always*
  localhost-only; reach it via SSH tunnel. MariaDB is on an `internal` network with no published port.
  Put a TLS-terminating reverse proxy in front for anything beyond local use.
- **Hardening**: `no-new-privileges` on all containers, PHP runs as an unprivileged user, `expose_php`/`server_tokens` off,
  nginx blocks TYPO3's protected files.
- **Backups contain secrets**: `config/system/settings.php` holds the TYPO3 `encryptionKey` and the install-time
  DB password, and the dump contains personal data. Archives are created with mode 600. Use `--encrypt-to`
  for anything that leaves the host, and define retention/rotation and **regular restore tests** for your
  backup policy (A.8.13 / CC-A1.2).
- **Updates**: images are pinned to major/minor versions. Rebuild regularly with
  `docker compose build --pull && docker compose up -d` and run `composer audit` inside the `typo3` container.
