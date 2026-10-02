#!/usr/bin/env bash
# ==============================================================================
# Automated MariaDB + Redis Restore Script for OpenShip
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/openship-services}"
MARIA_CONTAINER="${MARIADB_CONTAINER:-}"
REDIS_CONTAINER="${REDIS_CONTAINER:-}"
ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"
FORCE=false

MARIA_FILE=""
REDIS_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mariadb|-m)
            MARIA_FILE="$2"
            shift 2
            ;;
        --redis|-r)
            REDIS_FILE="$2"
            shift 2
            ;;
        --yes|-y|--force)
            FORCE=true
            shift
            ;;
        --help|-h)
            echo "Usage: sudo ./restore.sh [--mariadb <dump.sql.gz>] [--redis <dump.rdb>] [--yes]"
            exit 0
            ;;
        *)
            if [[ -z "$MARIA_FILE" && "$1" == *.sql.gz ]]; then
                MARIA_FILE="$1"
            elif [[ -z "$REDIS_FILE" && "$1" == *.rdb ]]; then
                REDIS_FILE="$1"
            fi
            shift
            ;;
    esac
done

# If no files specified, find latest in BACKUP_DIR
if [[ -z "$MARIA_FILE" && -z "$REDIS_FILE" ]]; then
    LATEST_MARIA=$(ls -t "${BACKUP_DIR}"/mariadb_all_*.sql.gz 2>/dev/null | head -n 1 || true)
    LATEST_REDIS=$(ls -t "${BACKUP_DIR}"/redis_*.rdb 2>/dev/null | head -n 1 || true)
    MARIA_FILE="$LATEST_MARIA"
    REDIS_FILE="$LATEST_REDIS"
fi

if [[ -z "$MARIA_FILE" && -z "$REDIS_FILE" ]]; then
    echo "Error: No backup files found to restore in ${BACKUP_DIR}" >&2
    exit 1
fi

echo "=== OpenShip Service Restore ==="
[[ -n "$MARIA_FILE" ]] && echo "MariaDB Backup: $MARIA_FILE"
[[ -n "$REDIS_FILE" ]] && echo "Redis Backup:   $REDIS_FILE"

if [[ "$FORCE" != true ]]; then
    read -r -p "WARNING: This will overwrite current database and cache data. Type 'yes' to proceed: " CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        echo "Aborted by user."
        exit 0
    fi
fi

# Find containers
if [ -z "$MARIA_CONTAINER" ]; then
    for candidate in shared-mariadb mariadb openship-openship-deploy-mariadb openship-deploy-mariadb; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            MARIA_CONTAINER="$candidate"
            break
        fi
    done
fi

if [ -z "$REDIS_CONTAINER" ]; then
    for candidate in shared-redis redis openship-openship-deploy-redis openship-deploy-redis; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            REDIS_CONTAINER="$candidate"
            break
        fi
    done
fi

# 1. Restore MariaDB
if [[ -n "$MARIA_FILE" ]]; then
    if [[ ! -f "$MARIA_FILE" ]]; then
        echo "Error: MariaDB file '$MARIA_FILE' does not exist!" >&2
        exit 1
    fi

    echo "==> Verifying gzip archive integrity..."
    if ! gzip -t "$MARIA_FILE"; then
        echo "Error: Corrupted MariaDB archive. Aborting!" >&2
        exit 1
    fi

    if [[ -z "$MARIA_CONTAINER" ]]; then
        echo "Error: Running MariaDB container not found!" >&2
        exit 1
    fi

    echo "==> Restoring MariaDB from '$MARIA_FILE' to container [${MARIA_CONTAINER}]..."
    gzip -dc "$MARIA_FILE" | docker exec -i "$MARIA_CONTAINER" mariadb -u root -p"${ROOT_PASSWORD}"
    echo "==> MariaDB restored successfully."
fi

# 2. Restore Redis
if [[ -n "$REDIS_FILE" ]]; then
    if [[ ! -f "$REDIS_FILE" ]]; then
        echo "Error: Redis file '$REDIS_FILE' does not exist!" >&2
        exit 1
    fi

    if [[ -z "$REDIS_CONTAINER" ]]; then
        echo "Error: Running Redis container not found!" >&2
        exit 1
    fi

    echo "==> Restoring Redis snapshot from '$REDIS_FILE' to container [${REDIS_CONTAINER}]..."
    docker cp "$REDIS_FILE" "${REDIS_CONTAINER}:/data/dump.rdb"
    docker restart "$REDIS_CONTAINER"
    echo "==> Redis restarted with restored snapshot."
fi

echo "==> Restore completed successfully."
