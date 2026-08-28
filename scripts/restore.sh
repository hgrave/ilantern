#!/usr/bin/env bash
# Restore a snapshot produced by backup.sh:  ./scripts/restore.sh backups/<stamp>
# This overwrites the current database and files volume.
set -euo pipefail

cd "$(dirname "$0")/.."
src="${1:?usage: restore.sh backups/<timestamp>}"
[[ -f "${src}/database.sql.gz" && -f "${src}/nextcloud.tar.gz" ]] \
  || { echo "Error: ${src} does not look like a backup directory" >&2; exit 1; }

read -r -p "This overwrites the running instance from ${src}. Continue? [y/N] " ans
[[ "$ans" == [yY] ]] || exit 1

[[ -f .env ]] || { echo "Error: .env is missing — run ./scripts/bootstrap.sh first" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source .env
set +a

echo "==> Stopping application containers"
docker compose stop app cron

echo "==> Restoring the nextcloud volume"
docker compose run --rm --no-deps --user root --entrypoint sh \
  -v "$PWD/${src}:/backup:ro" app \
  -c 'rm -rf /var/www/html/* /var/www/html/.[!.]* 2>/dev/null; tar xzf /backup/nextcloud.tar.gz -C /var/www/html'

echo "==> Restoring the database"
gzip -dc "${src}/database.sql.gz" \
  | docker compose exec -T db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

echo "==> Starting application containers"
docker compose up -d app cron
./scripts/occ maintenance:mode --off || true
./scripts/occ status
