#!/usr/bin/env bash
# One-shot installer: writes .env with generated secrets (if absent), starts the
# stack, waits for Nextcloud to finish installing, then applies post-install
# tuning. Safe to re-run — an existing .env and an installed instance are kept.
set -euo pipefail

cd "$(dirname "$0")/.."
COMPOSE=(docker compose)

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is not installed"
docker compose version >/dev/null 2>&1 || die "the docker compose plugin is required"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (is it running?)"

gen_secret() { openssl rand -base64 32 | tr -d '/+=\n' | cut -c1-32; }

if [[ -f .env ]]; then
  log ".env already exists — keeping it"
else
  log "Generating .env with fresh secrets"
  cp .env.example .env
  # Only fill the values left blank in the template.
  for var in NEXTCLOUD_ADMIN_PASSWORD POSTGRES_PASSWORD REDIS_PASSWORD; do
    secret="$(gen_secret)"
    sed -i.bak "s|^${var}=$|${var}=${secret}|" .env
  done
  rm -f .env.bak
  chmod 600 .env
fi

# The entrypoint only runs hooks that carry the executable flag, and a checkout
# can lose it (zip export, a mode-blind filesystem, an API-created commit).
chmod +x config/nextcloud/hooks/before-starting/*.sh

log "Pulling images"
# A registry hiccup or a Docker Hub rate limit should not abort a re-run when
# the images are already cached locally; `up` below fails loudly if they aren't.
if ! "${COMPOSE[@]}" pull --quiet; then
  log "Pull failed (registry unreachable or rate-limited) — continuing with locally cached images"
fi

log "Starting the stack"
"${COMPOSE[@]}" up -d

[[ -f .env ]] || { echo "Error: .env is missing — run ./scripts/bootstrap.sh first" >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source .env
set +a
port="${NEXTCLOUD_HTTP_PORT:-8080}"

log "Waiting for Nextcloud to finish installing (this takes a minute on first run)"
deadline=$(( SECONDS + 600 ))
until curl -fsS "http://localhost:${port}/status.php" 2>/dev/null | grep -q '"installed":true'; do
  (( SECONDS < deadline )) || {
    "${COMPOSE[@]}" logs --tail 50 app >&2
    die "Nextcloud did not come up within 10 minutes (logs above)"
  }
  sleep 5
done

log "Applying post-install tuning"
# Indices Nextcloud adds after the initial schema; without them large instances
# do full table scans on every file listing.
./scripts/occ db:add-missing-indices
./scripts/occ db:add-missing-columns
./scripts/occ db:add-missing-primary-keys
# New mimetypes ship with each release; applying them here keeps the admin
# overview clean and file icons correct.
./scripts/occ maintenance:mimetype:update-db
./scripts/occ maintenance:mimetype:update-js
# Applies the one-off repair steps a release ships with. Cheap on a fresh
# install; on a large existing instance it can take a while.
./scripts/occ maintenance:repair --include-expensive
# Run background jobs from the cron container rather than during page loads.
./scripts/occ background:cron

log "Instance status"
./scripts/occ status

cat <<EOF

Nextcloud is up:  http://localhost:${port}
  admin user:     ${NEXTCLOUD_ADMIN_USER}
  admin password: see NEXTCLOUD_ADMIN_PASSWORD in ./.env

Next steps:
  ./scripts/occ <command>     run any occ command
  docker compose logs -f app  follow the app log
  ./scripts/backup.sh         snapshot database + files
EOF
