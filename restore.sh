#!/usr/bin/env bash
# ==============================================================================
# OpenShip — Worker Services Restore Forwarder
# ==============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/services/mariadb-redis/restore.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "Error: Target restore script not found at ${TARGET_SCRIPT}" >&2
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
