#!/usr/bin/env bash
# ==============================================================================
# Automated MariaDB Backup Script for OpenShip
# ==============================================================================
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-/var/backups/mariadb}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CONTAINER="${MARIADB_CONTAINER:-}"
ROOT_PASSWORD="${MARIADB_ROOT_PASSWORD:-openship_root_secret}"

# Auto-detect running MariaDB container if not specified
if [ -z "$CONTAINER" ]; then
    for candidate in openship-openship-deploy-mariadb mariadb openship-deploy-mariadb; do
        if docker ps --format '{{.Names}}' | grep -qx "$candidate"; then
            CONTAINER="$candidate"
            break
        fi
    done
fi

if [ -z "$CONTAINER" ]; then
    echo "ERROR: MariaDB container not found or not running." >&2
    exit 1
fi

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/mariadb_all_${TIMESTAMP}.sql.gz"

echo "==> [$(date)] Backing up MariaDB container [${CONTAINER}] to ${BACKUP_FILE}..."

docker exec "$CONTAINER" mariadb-dump \
    -u root \
    -p"${ROOT_PASSWORD}" \
    --all-databases \
    --single-transaction \
    --quick \
    --routines \
    --triggers 2>/dev/null | gzip -9 > "$BACKUP_FILE"

# Verify backup size
BACKUP_SIZE=$(stat -c%s "$BACKUP_FILE" 2>/dev/null || stat -f%z "$BACKUP_FILE" 2>/dev/null || echo 0)
if [ "$BACKUP_SIZE" -lt 500 ]; then
    echo "ERROR: Backup file is suspiciously small (${BACKUP_SIZE} bytes). Please verify credentials!" >&2
    exit 1
fi

echo "==> Backup completed successfully: ${BACKUP_FILE} (${BACKUP_SIZE} bytes)"

# Retention cleanup
echo "==> Cleaning up backups older than ${RETENTION_DAYS} days..."
find "$BACKUP_DIR" -name "mariadb_all_*.sql.gz" -mtime +"${RETENTION_DAYS}" -delete

echo "==> Done."
