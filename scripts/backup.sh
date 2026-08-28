#!/usr/bin/env bash
# Consistent snapshot of the database and the Nextcloud files volume.
# Writes backups/<timestamp>/ and puts the instance in maintenance mode for the
# duration so the two halves agree.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -f .env ]] || { echo "Error: .env is missing — run ./scripts/bootstrap.sh first" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source .env
set +a

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
dest="backups/${stamp}"
mkdir -p "$dest"

# Maintenance mode keeps the SQL dump and the file archive consistent with each
# other. The trap is armed first so a failure mid-backup cannot leave the
# instance stuck in maintenance mode.
finish() { ./scripts/occ maintenance:mode --off >/dev/null; }
trap finish EXIT
./scripts/occ maintenance:mode --on

echo "==> Dumping database to ${dest}/database.sql.gz"
docker compose exec -T db pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
  | gzip > "${dest}/database.sql.gz"

echo "==> Archiving the nextcloud volume to ${dest}/nextcloud.tar.gz"
docker compose run --rm --no-deps --user root --entrypoint sh \
  -v "$PWD/${dest}:/backup" app \
  -c 'tar czf /backup/nextcloud.tar.gz -C /var/www/html .'

cp .env "${dest}/env.snapshot"
chmod 600 "${dest}/env.snapshot"
echo "==> Backup complete: ${dest}"
du -sh "${dest}"
