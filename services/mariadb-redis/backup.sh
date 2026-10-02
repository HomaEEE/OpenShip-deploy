#!/usr/bin/env bash
# ==============================================================================
# Automated MariaDB + Redis Backup Script for OpenShip
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"

if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a
fi

BACKUP_DIR="${BACKUP_DIR:-/var/backups/openship-services}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
MARIA_CONTAINER="${MARIADB_CONTAINER:-}"
REDIS_CONTAINER="${REDIS_CONTAINER:-}"
ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}"
REDIS_AUTH="${REDIS_PASSWORD:-}"

mkdir -p "$BACKUP_DIR"

# Auto-detect running MariaDB container if not specified
if [ -z "$MARIA_CONTAINER" ]; then
    for candidate in shared-mariadb mariadb openship-openship-deploy-mariadb openship-deploy-mariadb; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            MARIA_CONTAINER="$candidate"
            break
        fi
    done
fi

# Auto-detect running Redis container if not specified
if [ -z "$REDIS_CONTAINER" ]; then
    for candidate in shared-redis redis openship-openship-deploy-redis openship-deploy-redis; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            REDIS_CONTAINER="$candidate"
            break
        fi
    done
fi

BACKUP_SUCCESS=true

# 1. MariaDB Backup
if [ -n "$MARIA_CONTAINER" ]; then
    MARIA_FILE="${BACKUP_DIR}/mariadb_all_${TIMESTAMP}.sql.gz"
    echo "==> [$(date)] Backing up MariaDB container [${MARIA_CONTAINER}] to ${MARIA_FILE}..."

    if [ -n "$ROOT_PASSWORD" ]; then
        docker exec "$MARIA_CONTAINER" mariadb-dump             -u root             -p"${ROOT_PASSWORD}"             --all-databases             --single-transaction             --quick             --routines             --triggers 2>/dev/null | gzip -9 > "$MARIA_FILE"
    else
        echo "ERROR: MARIADB_ROOT_PASSWORD is not set." >&2
        BACKUP_SUCCESS=false
    fi

    if [ "$BACKUP_SUCCESS" = true ]; then
        if ! gzip -t "$MARIA_FILE" 2>/dev/null; then
            echo "ERROR: MariaDB backup archive is corrupted or invalid!" >&2
            rm -f "$MARIA_FILE"
            BACKUP_SUCCESS=false
        else
            BACKUP_SIZE=$(stat -c%s "$MARIA_FILE" 2>/dev/null || stat -f%z "$MARIA_FILE" 2>/dev/null || echo 0)
            if [ "$BACKUP_SIZE" -lt 500 ]; then
                echo "ERROR: MariaDB backup file is suspiciously small (${BACKUP_SIZE} bytes). Check credentials!" >&2
                BACKUP_SUCCESS=false
            else
                echo "==> MariaDB backup completed and verified: ${MARIA_FILE} (${BACKUP_SIZE} bytes)"
            fi
        fi
    fi
else
    echo "WARN: MariaDB container not found or not running. Skipping MariaDB backup." >&2
fi

# 2. Redis Snapshot Backup
if [ -n "$REDIS_CONTAINER" ]; then
    REDIS_FILE="${BACKUP_DIR}/redis_${TIMESTAMP}.rdb"
    echo "==> [$(date)] Triggering Redis BGSAVE on container [${REDIS_CONTAINER}]..."
    
    REDIS_CLI_CMD=(docker exec "$REDIS_CONTAINER" redis-cli)
    if [ -n "$REDIS_AUTH" ]; then
        REDIS_CLI_CMD+=(-a "$REDIS_AUTH")
    fi

    # Record initial lastsave timestamp
    INITIAL_LASTSAVE=$("${REDIS_CLI_CMD[@]}" lastsave 2>/dev/null | tr -d '"
' || echo 0)
    "${REDIS_CLI_CMD[@]}" bgsave 2>/dev/null || true

    # Poll until lastsave timestamp advances and bgsave finishes (max 30s)
    WAIT_SEC=0
    SAVED=false
    while [ "$WAIT_SEC" -lt 30 ]; do
        sleep 1
        WAIT_SEC=$((WAIT_SEC + 1))
        CURRENT_LASTSAVE=$("${REDIS_CLI_CMD[@]}" lastsave 2>/dev/null | tr -d '"
' || echo 0)
        IN_PROGRESS=$("${REDIS_CLI_CMD[@]}" info persistence 2>/dev/null | grep -E '^rdb_bgsave_in_progress:' | cut -d: -f2 | tr -d '"
' || echo 0)

        if [ "$CURRENT_LASTSAVE" -gt "$INITIAL_LASTSAVE" ] && [ "$IN_PROGRESS" = "0" ]; then
            SAVED=true
            break
        fi
    done

    if [ "$SAVED" = true ] && docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "$REDIS_FILE" 2>/dev/null; then
        REDIS_SIZE=$(stat -c%s "$REDIS_FILE" 2>/dev/null || stat -f%z "$REDIS_FILE" 2>/dev/null || echo 0)
        echo "==> Redis snapshot backup completed: ${REDIS_FILE} (${REDIS_SIZE} bytes)"
    else
        echo "WARN: Redis BGSAVE timed out or failed to export snapshot." >&2
    fi
fi

# 3. Retention Cleanup (only if backup completed successfully)
if [ "$BACKUP_SUCCESS" = true ]; then
    echo "==> Cleaning up backups older than ${RETENTION_DAYS} days..."
    find "$BACKUP_DIR" -name "mariadb_all_*.sql.gz" -mtime +"${RETENTION_DAYS}" -delete 2>/dev/null || true
    find "$BACKUP_DIR" -name "redis_*.rdb" -mtime +"${RETENTION_DAYS}" -delete 2>/dev/null || true
    echo "==> Backup routine completed successfully."
else
    echo "WARN: Retention cleanup skipped due to backup warnings." >&2
fi
