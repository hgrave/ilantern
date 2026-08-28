#!/bin/sh
# Runs as www-data from the image entrypoint on every container start.
#
# The tuning file cannot be bind-mounted straight into /var/www/html/config:
# on a fresh volume Docker would create that directory as root, and the
# Nextcloud installer would then fail with "Cannot write into config directory".
# So it is mounted somewhere neutral and copied into place here instead.
set -eu

src=/usr/src/nextcloud-custom/zz-tuning.config.php
dst=/var/www/html/config/zz-tuning.config.php

[ -f "$src" ] || exit 0

if ! cmp -s "$src" "$dst" 2>/dev/null; then
    echo "==> Installing custom Nextcloud config: $(basename "$dst")"
    cp "$src" "$dst"
fi
