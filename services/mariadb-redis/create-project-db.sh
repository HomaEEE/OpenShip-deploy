#!/usr/bin/env bash

# ==============================================================================
# OpenShip — Provision Database & User for Project
# ==============================================================================
#
# Creates an isolated MariaDB database and user with privileges for a project.
#
# Usage:
#   sudo ./create-project-db.sh --database=my_app --user=my_user --password=secret
#   sudo ./create-project-db.sh --env-file=/var/www/my-app/.env
#   sudo ./create-project-db.sh   (interactive mode)
#
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICES_ENV="${SCRIPT_DIR}/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()  { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { err "$*"; exit 1; }

DB_NAME=""
DB_USER=""
DB_PASS=""
ENV_FILE=""

# Parse flags
while [[ $# -gt 0 ]]; do
    case "$1" in
        -d=*|--database=*)
            DB_NAME="${1#*=}"
            shift
            ;;
        -d|--database)
            DB_NAME="$2"
            shift 2
            ;;
        -u=*|--user=*)
            DB_USER="${1#*=}"
            shift
            ;;
        -u|--user)
            DB_USER="$2"
            shift 2
            ;;
        -p=*|--password=*)
            DB_PASS="${1#*=}"
            shift
            ;;
        -p|--password)
            DB_PASS="$2"
            shift 2
            ;;
        -e=*|--env-file=*)
            ENV_FILE="${1#*=}"
            shift
            ;;
        -e|--env-file)
            ENV_FILE="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo
            echo "Options:"
            echo "  -d, --database NAME   Database name"
            echo "  -u, --user USERNAME   Database username (defaults to database name if omitted)"
            echo "  -p, --password PASS   Database password (generated automatically if omitted)"
            echo "  -e, --env-file PATH   Read DB_DATABASE, DB_USERNAME, DB_PASSWORD from .env file"
            echo "  -h, --help            Show this help"
            exit 0
            ;;
        *)
            die "Unknown option: $1. Run with --help for usage."
            ;;
    esac
done

# Check root / docker privileges
if [[ "$EUID" -ne 0 ]] && ! groups | grep -q '\bdocker\b'; then
    die "Run with sudo or as a user in the docker group."
fi

# Load services .env to obtain root credentials
if [[ ! -f "$SERVICES_ENV" ]]; then
    die "Services environment file not found at ${SERVICES_ENV}. Run deploy.sh first."
fi

MARIADB_ROOT_PASSWORD="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$SERVICES_ENV" | cut -d '=' -f2- | tr -d '"'"'" || true)"
REDIS_PASSWORD="$(grep -E '^REDIS_PASSWORD=' "$SERVICES_ENV" | cut -d '=' -f2- | tr -d '"'"'" || true)"

if [[ -z "$MARIADB_ROOT_PASSWORD" ]]; then
    die "MARIADB_ROOT_PASSWORD is empty in ${SERVICES_ENV}."
fi

# Check mariadb container status
if ! docker ps --filter "name=mariadb" --filter "status=running" --format '{{.Names}}' | grep -q "^mariadb$"; then
    die "MariaDB container is not running. Start services first: ./deploy-services.sh"
fi



# If env file is provided, read credentials
if [[ -n "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
        die "Specified env file does not exist: $ENV_FILE"
    fi
    log "Reading database config from ${ENV_FILE}..."
    [[ -z "$DB_NAME" ]] && DB_NAME="$(grep -E '^(DB_DATABASE|MARIADB_DATABASE)=' "$ENV_FILE" | head -n1 | cut -d '=' -f2- | tr -d '"'"'" || true)"
    [[ -z "$DB_USER" ]] && DB_USER="$(grep -E '^(DB_USERNAME|MARIADB_USER)=' "$ENV_FILE" | head -n1 | cut -d '=' -f2- | tr -d '"'"'" || true)"
    [[ -z "$DB_PASS" ]] && DB_PASS="$(grep -E '^(DB_PASSWORD|MARIADB_PASSWORD)=' "$ENV_FILE" | head -n1 | cut -d '=' -f2- | tr -d '"'"'" || true)"
fi

# Interactive fallback if values missing
if [[ -z "$DB_NAME" ]]; then
    read -rp "Enter Database Name: " DB_NAME
fi

if [[ -z "$DB_USER" ]]; then
    read -rp "Enter Database User [default: ${DB_NAME}]: " input_user
    DB_USER="${input_user:-$DB_NAME}"
fi

if [[ -z "$DB_PASS" ]]; then
    # Generate secure random password
    DB_PASS="$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 20)"
    log "Generated random database password."
fi

# Sanitize names (alphanumeric and underscores only)
if [[ ! "$DB_NAME" =~ ^[a-zA-Z0-9_]+$ ]]; then
    die "Invalid database name '${DB_NAME}'. Allowed: letters, numbers, underscores."
fi

if [[ ! "$DB_USER" =~ ^[a-zA-Z0-9_]+$ ]]; then
    die "Invalid username '${DB_USER}'. Allowed: letters, numbers, underscores."
fi

log "Provisioning database '${DB_NAME}' and user '${DB_USER}'..."

# Run SQL statements in MariaDB container
SQL="
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
"

docker exec -i mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" <<< "$SQL"

ok "Database and user provisioned successfully!"
echo
echo -e "${BOLD}Project .env snippet:${NC}"
echo "--------------------------------------------------"
echo "DB_CONNECTION=mysql"
echo "DB_HOST=mariadb"
echo "DB_PORT=3306"
echo "DB_DATABASE=${DB_NAME}"
echo "DB_USERNAME=${DB_USER}"
echo "DB_PASSWORD=${DB_PASS}"
echo
echo "REDIS_HOST=redis"
echo "REDIS_PORT=6379"
echo "REDIS_PASSWORD=${REDIS_PASSWORD}"
echo "--------------------------------------------------"
echo -e "Ensure your project's docker-compose attaches to network: ${CYAN}openship-network${NC}"
