#!/usr/bin/env bash
# Runs the plugin's checks. Uses omarchy-plugin-validate when available.
set -euo pipefail
cd "$(dirname "$0")/.."
bash -n bin/zalo-notify-watch bin/zalo-launch
node tests/model.test.js
if command -v omarchy-plugin-validate >/dev/null 2>&1; then
  omarchy-plugin-validate . && echo "ok - omarchy-plugin-validate"
fi
