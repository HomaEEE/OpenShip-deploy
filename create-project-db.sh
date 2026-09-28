#!/usr/bin/env bash

# ==============================================================================
# OpenShip — Provision Database & User for Project
# ==============================================================================
#
# Helper script to provision a MariaDB database and user from repository root.
#
# Usage:
#   sudo ./create-project-db.sh --database=my_app --user=my_user --password=secret
#   sudo ./create-project-db.sh --env-file=/var/www/my-app/.env
#   sudo ./create-project-db.sh
#
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/services/mariadb-redis/create-project-db.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "Error: Target script not found at ${TARGET_SCRIPT}" >&2
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
