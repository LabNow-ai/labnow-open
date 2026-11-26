#!/usr/bin/env bash
set -eu

if ! mountpoint -q /srv/ignis; then
    echo "Ignis requires the Lab's persistent volume at /srv/ignis." >&2
    exit 1
fi

export VAULT_ROOT=/srv/ignis/vaults
export DATA_ROOT=/srv/ignis/data
export OBSIDIAN_ASSETS_PATH=/srv/ignis/obsidian-app
mkdir -p "$VAULT_ROOT" "$DATA_ROOT" "$OBSIDIAN_ASSETS_PATH"

cd /app
exec /app/apps/ignis-server/scripts/entrypoint.sh
