#!/usr/bin/env bash
# ==============================================================================
# Automated MariaDB + Redis Backup Script for OpenShip
# ==============================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/openship}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
MARIA_CONTAINER="${MARIADB_CONTAINER:-}"
REDIS_CONTAINER="${REDIS_CONTAINER:-}"
ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-openship_root_secret}"
REDIS_AUTH="${REDIS_PASSWORD:-}"

mkdir -p "$BACKUP_DIR"

# Auto-detect running MariaDB container if not specified
if [ -z "$MARIA_CONTAINER" ]; then
    for candidate in openship-openship-deploy-mariadb mariadb openship-deploy-mariadb; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            MARIA_CONTAINER="$candidate"
            break
        fi
    done
fi

# Auto-detect running Redis container if not specified
if [ -z "$REDIS_CONTAINER" ]; then
    for candidate in openship-openship-deploy-redis redis openship-deploy-redis; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            REDIS_CONTAINER="$candidate"
            break
        fi
    done
fi

# 1. MariaDB Backup
if [ -n "$MARIA_CONTAINER" ]; then
    MARIA_FILE="${BACKUP_DIR}/mariadb_all_${TIMESTAMP}.sql.gz"
    echo "==> [$(date)] Backing up MariaDB container [${MARIA_CONTAINER}] to ${MARIA_FILE}..."

    docker exec "$MARIA_CONTAINER" mariadb-dump         -u root         -p"${ROOT_PASSWORD}"         --all-databases         --single-transaction         --quick         --routines         --triggers 2>/dev/null | gzip -9 > "$MARIA_FILE"

    BACKUP_SIZE=$(stat -c%s "$MARIA_FILE" 2>/dev/null || stat -f%z "$MARIA_FILE" 2>/dev/null || echo 0)
    if [ "$BACKUP_SIZE" -lt 500 ]; then
        echo "ERROR: MariaDB backup file is suspiciously small (${BACKUP_SIZE} bytes). Check credentials!" >&2
    else
        echo "==> MariaDB backup completed: ${MARIA_FILE} (${BACKUP_SIZE} bytes)"
    fi
else
    echo "WARN: MariaDB container not found or not running. Skipping MariaDB backup." >&2
fi

# 2. Redis Snapshot Backup
if [ -n "$REDIS_CONTAINER" ]; then
    REDIS_FILE="${BACKUP_DIR}/redis_${TIMESTAMP}.rdb"
    echo "==> [$(date)] Triggering Redis BGSAVE on container [${REDIS_CONTAINER}]..."
    
    if [ -n "$REDIS_AUTH" ]; then
        docker exec "$REDIS_CONTAINER" redis-cli -a "$REDIS_AUTH" bgsave 2>/dev/null || true
    else
        docker exec "$REDIS_CONTAINER" redis-cli bgsave 2>/dev/null || true
    fi
    sleep 2

    if docker cp "${REDIS_CONTAINER}:/data/dump.rdb" "$REDIS_FILE" 2>/dev/null; then
        echo "==> Redis snapshot backup completed: ${REDIS_FILE}"
    fi
fi

# 3. Retention Cleanup
echo "==> Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "mariadb_all_*.sql.gz" -mtime +"${RETENTION_DAYS}" -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "redis_*.rdb" -mtime +"${RETENTION_DAYS}" -delete 2>/dev/null || true

echo "==> Backup routine completed successfully."
