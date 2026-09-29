#!/usr/bin/env bash

# ==============================================================================
# OpenShip Shared Services — MariaDB + Redis Deployer
# ==============================================================================
#
# Deploys and manages isolated MariaDB and Redis containers connected to the
# shared Docker network (openship-network).
#
# Usage:
#   sudo ./deploy.sh              # Deploy / update stack
#   sudo ./deploy.sh --status     # Show service status and health
#   sudo ./deploy.sh --restart    # Restart services
#   sudo ./deploy.sh --stop       # Stop services
#   sudo ./deploy.sh --logs       # Follow container logs
#   sudo ./deploy.sh --pull       # Pull latest images and update
#   sudo ./deploy.sh --help       # Show help message
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# Colors
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''
fi

log() { echo -e "${CYAN}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die() { error "$*"; exit 1; }

section() {
    echo
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN} $*${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo
}

require_root_or_docker() {
    if [[ "$EUID" -ne 0 ]] && ! groups | grep -q '\bdocker\b'; then
        die "This script must be run as root or with sudo / docker group privileges."
    fi
}

generate_random_password() {
    local length="${1:-32}"
    if command -v openssl >/dev/null 2>&1; then
        openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
    fi
}

ensure_docker_and_compose() {
    if ! command -v docker >/dev/null 2>&1; then
        die "Docker is not installed. Please install Docker first."
    fi

    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose plugin is not installed."
    fi

    docker info >/dev/null 2>&1 || die "Docker daemon is not running."
}

ensure_docker_network() {
    if ! docker network inspect openship-network >/dev/null 2>&1; then
        log "Creating shared Docker network: openship-network..."
        docker network create openship-network
        success "Network openship-network created."
    else
        log "Network openship-network already exists."
    fi
}

tune_mariadb_buffer_pool() {
    # Check total memory in MB
    local mem_total_mb=2048
    if [[ -f /proc/meminfo ]]; then
        mem_total_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
    fi

    # Buffer pool is roughly 40% of host RAM
    local pool_mb=$(( (mem_total_mb * 40) / 100 ))
    if (( pool_mb < 256 )); then
        pool_mb=256
    elif (( pool_mb > 4096 )); then
        pool_mb=4096
    fi
    MARIADB_BUFFER_POOL_SIZE="${pool_mb}M"
    log "Detected MariaDB innodb_buffer_pool_size = ${MARIADB_BUFFER_POOL_SIZE} (~40% of RAM)."
}

configure_environment() {
    section "Configuring Environment (.env)"

    tune_mariadb_buffer_pool

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "$ENV_EXAMPLE" ]]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
        else
            cat > "$ENV_FILE" <<'EOF'
MARIADB_VERSION=11.4
MARIADB_ROOT_PASSWORD=
MARIADB_BUFFER_POOL_SIZE=512M
REDIS_VERSION=7.4-alpine
REDIS_PASSWORD=
EOF
        fi
        chmod 600 "$ENV_FILE"
    fi

    # Read current values
    local maria_pass redis_pass maria_ver redis_ver maria_pool
    maria_ver="$(grep -E '^MARIADB_VERSION=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || echo "11.4")"
    redis_ver="$(grep -E '^REDIS_VERSION=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || echo "7.4-alpine")"
    maria_pass="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || true)"
    redis_pass="$(grep -E '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || true)"
    maria_pool="$(grep -E '^MARIADB_BUFFER_POOL_SIZE=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || echo "${MARIADB_BUFFER_POOL_SIZE}")"

    [[ -z "$maria_ver" ]] && maria_ver="11.4"
    [[ -z "$redis_ver" ]] && redis_ver="7.4-alpine"
    [[ -z "$maria_pool" ]] && maria_pool="${MARIADB_BUFFER_POOL_SIZE}"

    if [[ -z "$maria_pass" ]]; then
        maria_pass="$(generate_random_password 24)"
        log "Generated strong MariaDB root password."
    fi

    if [[ -z "$redis_pass" ]]; then
        redis_pass="$(generate_random_password 24)"
        log "Generated strong Redis password."
    fi

    cat > "$ENV_FILE" <<EOF
# OpenShip Shared Services
# Generated on: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

MARIADB_VERSION=${maria_ver}
MARIADB_ROOT_PASSWORD=${maria_pass}
MARIADB_BUFFER_POOL_SIZE=${maria_pool}

REDIS_VERSION=${redis_ver}
REDIS_PASSWORD=${redis_pass}
EOF

    chmod 600 "$ENV_FILE"
    success "Configuration secured in ${ENV_FILE}"
}

start_services() {
    section "Deploying MariaDB and Redis containers"

    ensure_docker_network

    log "Starting stack..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

    log "Waiting for containers to become healthy..."
    local max_wait=50
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local maria_status redis_status
        maria_status="$(docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo "\"starting\"")"
        redis_status="$(docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo "\"starting\"")"

        if [[ "$maria_status" == "\"healthy\"" && "$redis_status" == "\"healthy\"" ]]; then
            healthy=true
            break
        fi

        sleep 2
        elapsed=$(( elapsed + 2 ))
        echo -n "."
    done
    echo

    if [[ "$healthy" == "true" ]]; then
        success "MariaDB and Redis are healthy and running on openship-network!"
    else
        warn "Containers started, but health checks are taking longer than usual."
        warn "MariaDB status: $(docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo 'not found')"
        warn "Redis status: $(docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo 'not found')"
    fi
}

stop_services() {
    section "Stopping services"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    success "Services stopped. (Data volumes preserved)"
}

restart_services() {
    section "Restarting services"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart
    success "Services restarted."
}

pull_images() {
    section "Pulling updated images"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d
    success "Services updated."
}

show_status() {
    section "Shared Services Status"

    echo -e "${BOLD}Containers:${NC}"
    docker ps -a --filter "name=mariadb" --filter "name=redis" --format "table {{.Names}}\t{{.Status}}\t{{.Networks}}"

    echo
    echo -e "${BOLD}Network (openship-network):${NC}"
    docker network inspect openship-network --format '{{range .Containers}}{{.Name}} ({{.IPv4Address}}){{"\n"}}{{end}}' 2>/dev/null || echo "Network not found."

    echo
    echo -e "${BOLD}Volumes:${NC}"
    docker volume ls --filter "name=mariadb_data" --filter "name=redis_data"
}

follow_logs() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f
}

print_summary() {
    local maria_pass redis_pass
    maria_pass="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || true)"
    redis_pass="$(grep -E '^REDIS_PASSWORD=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"'"'" || true)"

    section "Ready! How to connect projects"

    echo -e "${BOLD}1. Attach project container to the Docker network:${NC}"
    echo "------------------------------------------------------------"
    cat <<'EOF'
# In project docker-compose.yml:
services:
  app:
    # ...
    networks:
      - default

networks:
  default:
    name: openship-network
    external: true
EOF
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}2. Project Environment Variables (e.g. OpenShip UI / .env):${NC}"
    echo "------------------------------------------------------------"
    cat <<EOF
DB_CONNECTION=mysql
DB_HOST=mariadb
DB_PORT=3306
DB_DATABASE=your_project_db
DB_USERNAME=root
DB_PASSWORD=${maria_pass}
DB_ROOT_PASSWORD=${maria_pass}

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_PASSWORD=${redis_pass}
CACHE_PREFIX=your_project_
EOF
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}Services credentials saved in:${NC} ${YELLOW}${ENV_FILE}${NC}"
    echo "MariaDB Host:          mariadb:3306"
    echo "MariaDB Root Password: ${maria_pass}"
    echo "Redis Host:            redis:6379"
    echo "Redis Password:        ${redis_pass}"
}

show_help() {
    cat <<EOF
OpenShip Shared Services Deployer (MariaDB + Redis)

Usage:
  sudo ./deploy.sh [OPTIONS]

Options:
  --status        Display current status and health of containers
  --restart       Restart MariaDB and Redis containers
  --stop          Stop containers (volumes preserved)
  --logs          Follow container logs in real time
  --pull          Pull updated Docker images and recreate containers
  --help, -h      Display this help message
EOF
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        show_help
        exit 0
    fi

    require_root_or_docker
    ensure_docker_and_compose

    case "${1:-}" in
        --status)
            show_status
            ;;
        --restart)
            restart_services
            ;;
        --stop)
            stop_services
            ;;
        --logs)
            follow_logs
            ;;
        --pull)
            pull_images
            ;;
        --help|-h)
            show_help
            ;;
        "")
            configure_environment
            start_services
            print_summary
            ;;
        *)
            error "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
