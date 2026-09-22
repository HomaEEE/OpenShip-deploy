#!/usr/bin/env bash

# ==============================================================================
# OpenShip Worker Services — MariaDB + Redis Backup Utility
# ==============================================================================
#
# Creates automated, compressed dumps of MariaDB databases and Redis snapshots.
#
# Usage:
#   sudo ./backup.sh              # Run backup now
#   sudo ./backup.sh --db <name>  # Backup specific database only
#   sudo ./backup.sh --list       # List existing backups
#   sudo ./backup.sh --cron       # Install daily cron job (03:00 AM)
#   sudo ./backup.sh --help       # Show help message
#
# Environment variables:
#   BACKUP_DIR      - Target backup directory (default: /var/backups/openship-services)
#   RETENTION_DAYS  - Number of days to keep backups (default: 7)
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly LOG_FILE="/var/log/openship-services-backup.log"
readonly BACKUP_DIR="${BACKUP_DIR:-/var/backups/openship-services}"
readonly RETENTION_DAYS="${RETENTION_DAYS:-7}"

# ------------------------------------------------------------------------------
# Colors & Output
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    NC=''
fi

log() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

success() {
    echo -e "${GREEN}[ OK ]${NC} $*"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

die() {
    error "$*"
    exit 1
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "This script must be run as root or with sudo."
    fi
}

# ------------------------------------------------------------------------------
# Load Configuration
# ------------------------------------------------------------------------------

load_env() {
    if [[ -f "$ENV_FILE" ]]; then
        # shellcheck disable=SC1090
        set -a
        source "$ENV_FILE"
        set +a
    fi

    if [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]]; then
        die "MARIADB_ROOT_PASSWORD is not set in environment or ${ENV_FILE}"
    fi
}

# ------------------------------------------------------------------------------
# Backup Functions
# ------------------------------------------------------------------------------

backup_mariadb() {
    local target_db="${1:-all}"
    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    local output_file

    if ! docker ps --filter "name=openship-mariadb" --filter "status=running" | grep -q openship-mariadb; then
        error "MariaDB container (openship-mariadb) is not running!"
        return 1
    fi

    if [[ "$target_db" == "all" ]]; then
        output_file="${BACKUP_DIR}/mariadb_all_databases_${timestamp}.sql.gz"
        log "Dumping all MariaDB databases to ${output_file}..."
        docker exec openship-mariadb mariadb-dump \
            -u root \
            -p"${MARIADB_ROOT_PASSWORD}" \
            --all-databases \
            --single-transaction \
            --quick \
            2>/dev/null | gzip -9 > "$output_file"
    else
        output_file="${BACKUP_DIR}/mariadb_${target_db}_${timestamp}.sql.gz"
        log "Dumping database '${target_db}' to ${output_file}..."
        docker exec openship-mariadb mariadb-dump \
            -u root \
            -p"${MARIADB_ROOT_PASSWORD}" \
            --single-transaction \
            --quick \
            "${target_db}" \
            2>/dev/null | gzip -9 > "$output_file"
    fi

    chmod 600 "$output_file"
    local size
    size="$(du -h "$output_file" | awk '{print $1}')"
    success "MariaDB backup completed: ${output_file} (${size})"
}

backup_redis() {
    local timestamp
    timestamp="$(date +"%Y%m%d_%H%M%S")"
    local output_file="${BACKUP_DIR}/redis_dump_${timestamp}.rdb"

    if ! docker ps --filter "name=openship-redis" --filter "status=running" | grep -q openship-redis; then
        warn "Redis container (openship-redis) is not running. Skipping Redis backup."
        return 0
    fi

    log "Triggering Redis BGSAVE snapshot..."
    if [[ -n "${REDIS_PASSWORD:-}" ]]; then
        docker exec openship-redis redis-cli -a "${REDIS_PASSWORD}" BGSAVE 2>/dev/null || true
    else
        docker exec openship-redis redis-cli BGSAVE 2>/dev/null || true
    fi

    # Wait 2 seconds for BGSAVE to write to disk
    sleep 2

    # Copy dump.rdb from container
    if docker cp openship-redis:/data/dump.rdb "$output_file" 2>/dev/null; then
        chmod 600 "$output_file"
        local size
        size="$(du -h "$output_file" | awk '{print $1}')"
        success "Redis backup completed: ${output_file} (${size})"
    else
        warn "Could not copy dump.rdb from Redis container (no persistent dump created yet)."
    fi
}

cleanup_old_backups() {
    log "Cleaning up backups older than ${RETENTION_DAYS} days in ${BACKUP_DIR}..."
    local count=0
    while IFS= read -r file; do
        [[ -n "$file" ]] || continue
        rm -f "$file"
        count=$(( count + 1 ))
    done < <(find "$BACKUP_DIR" -type f \( -name "*.sql.gz" -o -name "*.rdb" \) -mtime +"${RETENTION_DAYS}" 2>/dev/null || true)

    if (( count > 0 )); then
        success "Removed ${count} outdated backup file(s)."
    else
        log "No expired backups found to delete."
    fi
}

list_backups() {
    echo -e "${BOLD}${CYAN}Existing Backups in ${BACKUP_DIR}:${NC}"
    if [[ ! -d "$BACKUP_DIR" ]]; then
        log "Directory ${BACKUP_DIR} does not exist yet."
        return
    fi

    local files
    files="$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "*.sql.gz" -o -name "*.rdb" \) 2>/dev/null | sort -r || true)"
    if [[ -z "$files" ]]; then
        log "No backup files found."
        return
    fi

    echo
    printf "%-10s %-30s %s\n" "SIZE" "DATE" "FILE"
    echo "----------------------------------------------------------------------"
    for f in $files; do
        local sz dt nm
        sz="$(du -h "$f" | awk '{print $1}')"
        dt="$(date -r "$f" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d'.' -f1)"
        nm="$(basename "$f")"
        printf "%-10s %-30s %s\n" "$sz" "$dt" "$nm"
    done
    echo
}

install_cron() {
    local cron_file="/etc/cron.d/openship-services-backup"
    log "Installing daily backup cron job at 03:00 AM..."

    cat > "$cron_file" <<EOF
# OpenShip Services Backup Job
# Runs daily at 03:00 AM
0 3 * * * root /bin/bash ${SCRIPT_DIR}/backup.sh >> /var/log/openship-services-backup.log 2>&1
EOF

    chmod 644 "$cron_file"
    success "Cron job installed at ${cron_file}."
    log "Runs every day at 03:00 UTC."
}

show_help() {
    cat <<EOF
OpenShip Worker Services Backup Utility

Usage:
  sudo ./backup.sh [OPTIONS]

Options:
  --db <database>   Backup a single database instead of all databases
  --list            Show list of existing backups
  --cron            Install daily cron task (runs at 03:00 AM)
  --help, -h        Show this help message

Environment variables:
  BACKUP_DIR        Directory for backups (default: /var/backups/openship-services)
  RETENTION_DAYS    Days to keep old backups (default: 7)
EOF
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    # Allow help without root
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        show_help
        exit 0
    fi

    require_root

    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    touch "$LOG_FILE" 2>/dev/null || true

    local target_db="all"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)
                list_backups
                exit 0
                ;;
            --cron)
                install_cron
                exit 0
                ;;
            --db)
                shift
                target_db="${1:-}"
                [[ -z "$target_db" ]] && die "Missing database name for --db"
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
        shift || true
    done

    load_env

    echo
    log "Starting OpenShip services backup: $(date -u +"%Y-%m-%d %H:%M:%S UTC")"
    backup_mariadb "$target_db"
    backup_redis
    cleanup_old_backups
    echo
    success "Backup workflow finished successfully."
}

main "$@"
