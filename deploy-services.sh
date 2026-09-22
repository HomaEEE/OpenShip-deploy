#!/usr/bin/env bash

# ==============================================================================
# OpenShip — Worker Services Deployer (MariaDB + Redis)
# ==============================================================================
#
# Helper script to launch the MariaDB and Redis deployment from the repository root.
#
# Usage:
#   sudo ./deploy-services.sh
#   sudo ./deploy-services.sh --status
#   sudo ./deploy-services.sh --logs
#   sudo ./deploy-services.sh --restart
#   sudo ./deploy-services.sh --stop
#
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_SCRIPT="${SCRIPT_DIR}/services/mariadb-redis/deploy.sh"

if [[ ! -f "$TARGET_SCRIPT" ]]; then
    echo "Error: Target deploy script not found at ${TARGET_SCRIPT}" >&2
    exit 1
fi

exec bash "$TARGET_SCRIPT" "$@"
