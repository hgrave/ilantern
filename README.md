# Nextcloud

A self-hosted [Nextcloud](https://nextcloud.com) instance, defined as a Docker
Compose stack: the Apache-based Nextcloud image, PostgreSQL for the database,
Redis for caching and file locking, a dedicated background-jobs container, and
an optional Caddy reverse proxy that handles TLS.

## Requirements

- Docker Engine 24+ with the Compose v2 plugin
- ~2 GB RAM and enough disk for your files
- Ports 8080 (or `NEXTCLOUD_HTTP_PORT`) — plus 80/443 if you enable the TLS profile

## Install

```bash
git clone <this repo> && cd ilantern
./scripts/bootstrap.sh
```

`bootstrap.sh` writes a `.env` with generated passwords, pulls the images,
starts the stack, waits for the installer to finish, and applies the database
index migrations Nextcloud otherwise nags about. It is idempotent — re-running
it against a live instance keeps the existing `.env` and data.

When it finishes, open <http://localhost:8080> and log in as `admin` with the
`NEXTCLOUD_ADMIN_PASSWORD` value from `.env`.

To configure things by hand instead, `cp .env.example .env`, fill in the three
blank secrets, make sure `config/nextcloud/hooks/before-starting/*.sh` is
executable (the entrypoint skips hooks that are not), and run
`docker compose up -d`.

## Day-to-day

```bash
./scripts/occ user:add alice     # any occ command
docker compose logs -f app       # application log
docker compose ps                # health of each container
make help                        # the same things, as make targets
```

## Serving it on a real domain

1. Point a DNS A/AAAA record at the host.
2. In `.env` set:

   ```ini
   NEXTCLOUD_DOMAIN=cloud.example.com
   NEXTCLOUD_TRUSTED_DOMAINS=cloud.example.com
   ACME_EMAIL=you@example.com
   OVERWRITEPROTOCOL=https
   OVERWRITECLIURL=https://cloud.example.com
   TRUSTED_PROXIES=172.16.0.0/12
   APACHE_DISABLE_REWRITE_IP=1
   ```

3. Start the stack with the proxy: `docker compose --profile tls up -d`.

Caddy obtains and renews a Let's Encrypt certificate on its own and adds the
`/.well-known/{card,cal}dav` redirects Nextcloud's mobile and desktop clients
expect. Once the proxy fronts the instance, either drop the `app` port mapping
from `compose.yaml` or bind it to loopback (`127.0.0.1:8080:80`) so the plain
HTTP port is not reachable from outside the host.

## Backup and restore

```bash
./scripts/backup.sh                    # -> backups/<timestamp>/
./scripts/restore.sh backups/<stamp>   # overwrites the running instance
```

The backup puts the instance into maintenance mode so the SQL dump and the file
archive describe the same moment, then dumps the database, tars the
`/var/www/html` volume (config, apps, and user data), and copies `.env`
alongside them. Snapshots are written to `backups/`, which is git-ignored —
copy them off the host to somewhere durable.

## Upgrades

Nextcloud supports only one major version step per upgrade, so bump
`NEXTCLOUD_IMAGE_TAG` in `.env` one major at a time and run:

```bash
make upgrade      # pull, recreate, occ upgrade, re-add indices, status
```

Take a backup first. The image runs the upgrade automatically on start; `occ
upgrade` is a no-op when there is nothing to do.

## Layout

| Path | What it is |
| --- | --- |
| `compose.yaml` | The stack: `app`, `db`, `redis`, `cron`, and the `tls`-profile `proxy` |
| `.env.example` | Every knob, with comments; copied to `.env` on install |
| `config/nextcloud/zz-tuning.config.php` | Extra config merged after `config.php`, so it survives upgrades |
| `config/nextcloud/hooks/` | Entrypoint hooks; installs the tuning config on every start |
| `config/caddy/Caddyfile` | Reverse-proxy and TLS configuration |
| `scripts/` | `bootstrap.sh`, `occ`, `backup.sh`, `restore.sh` |

## Notes on the configuration

- **Redis is mandatory here, not optional.** It backs `memcache.locking`, which
  is what keeps two concurrent clients from corrupting a file during sync.
- **The `cron` container matters.** Without it Nextcloud falls back to running
  background jobs during page loads, which is slow and skips jobs on idle
  instances. `bootstrap.sh` sets the instance to `cron` mode to match.
- **PostgreSQL is initialised with `--locale=C`** so index ordering does not
  shift under a glibc upgrade.
- **Secrets live only in `.env`** (mode 600, git-ignored). The compose file
  fails fast with a named error if one is missing.
- **Logs go to the container's stderr** (`log_type => errorlog`), so
  `docker compose logs app` shows the Nextcloud log alongside Apache's.
- **The tuning config is installed by an entrypoint hook**, not bind-mounted
  into `config/`. Bind-mounting a file there makes Docker create the directory
  as root on a fresh volume, and the installer then fails with "Cannot write
  into config directory".

Two warnings under *Administration → Overview* are expected on a plain-HTTP
setup and clear themselves once the instance is reachable from the internet
behind the TLS profile: the missing `Strict-Transport-Security` header, which
Caddy sets, and the internet-connectivity check.
