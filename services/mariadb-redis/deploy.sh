#!/usr/bin/env bash

# ==============================================================================
# OpenShip Shared Infrastructure Deployment Script (MariaDB + Redis + phpMyAdmin)
# ==============================================================================
#
# Idempotent deployer for production MariaDB 11.4 LTS, Redis 7.4, and phpMyAdmin
# configured with low memory footprint on 2GB VPS nodes and connected via
# the shared 'openship' Docker network with internal DNS resolution.
#
# ==============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
ENV_FILE="${SCRIPT_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"

# ANSI Colors
RED='[0;31m'
GREEN='[0;32m'
YELLOW='[1;33m'
BLUE='[0;34m'
BOLD='[1m'
NC='[0m' # No Color

log()     { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "
${BOLD}=== $* ===${NC}"; }

require_root_or_docker() {
    if ! command -v docker &>/dev/null; then
        error "Docker is required but not installed. Please install Docker first."
        exit 1
    fi

    if [[ $EUID -ne 0 ]] && ! groups | grep -q 'docker'; then
        error "Permission denied. Run with sudo or add your user to the 'docker' group."
        exit 1
    fi
}

ensure_docker_and_compose() {
    if ! docker compose version &>/dev/null; then
        error "Docker Compose v2 plugin is required ('docker compose')."
        exit 1
    fi
}

generate_random_password() {
    local length="${1:-24}"
    if command -v openssl &>/dev/null; then
        openssl rand -hex "$(( (length + 1) / 2 ))" 2>/dev/null | cut -c1-"$length"
    else
        tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$length" || true
    fi
}

ensure_docker_network() {
    local net_name="${OPENSHIP_NETWORK:-openship}"
    if ! docker network inspect "$net_name" &>/dev/null; then
        log "Creating shared user-defined Docker network '${net_name}'..."
        docker network create             --driver bridge             --opt "com.docker.network.bridge.enable_icc=true"             "$net_name"
        success "Network '${net_name}' created (internal Docker DNS active)."
    else
        log "Using existing Docker network '${net_name}'."
    fi
}

tune_mariadb_buffer_pool() {
    local mem_total_mb=2048
    if [[ -f /proc/meminfo ]]; then
        mem_total_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 2048)"
    fi

    local pool_mb=256
    if (( mem_total_mb <= 2048 )); then
        pool_mb=128
    elif (( mem_total_mb <= 4096 )); then
        pool_mb=256
    elif (( mem_total_mb <= 8192 )); then
        pool_mb=512
    else
        pool_mb=1024
    fi
    MARIADB_BUFFER_POOL_SIZE="${pool_mb}M"
    log "Optimized MariaDB innodb_buffer_pool_size = ${MARIADB_BUFFER_POOL_SIZE} for ${mem_total_mb}MB host RAM."
}

configure_environment() {
    section "Configuring Environment (.env)"

    tune_mariadb_buffer_pool

    if [[ ! -f "$ENV_FILE" ]]; then
        if [[ -f "$ENV_EXAMPLE" ]]; then
            cp "$ENV_EXAMPLE" "$ENV_FILE"
        fi
    fi

    # Read current values if present
    local maria_pass redis_pass maria_ver redis_ver maria_pool pma_ver pma_port pma_limit redis_policy net_name
    maria_ver="$(grep -E '^MARIADB_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo '11.4')"
    redis_ver="$(grep -E '^REDIS_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo '7.4-alpine')"
    maria_pass="$(grep -E '^MARIADB_ROOT_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || true)"
    redis_pass="$(grep -E '^REDIS_PASSWORD=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || true)"
    maria_pool="$(grep -E '^MARIADB_BUFFER_POOL_SIZE=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo "${MARIADB_BUFFER_POOL_SIZE}")"
    pma_ver="$(grep -E '^PHPMYADMIN_VERSION=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo 'latest')"
    pma_port="$(grep -E '^PHPMYADMIN_PORT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo '20003')"
    pma_limit="$(grep -E '^PHPMYADMIN_MEMORY_LIMIT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo '256M')"
    redis_policy="$(grep -E '^REDIS_MAXMEMORY_POLICY=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo 'noeviction')"
    net_name="$(grep -E '^OPENSHIP_NETWORK=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo 'openship')"

    [[ -z "$maria_ver" ]] && maria_ver="11.4"
    [[ -z "$redis_ver" ]] && redis_ver="7.4-alpine"
    [[ -z "$maria_pool" ]] && maria_pool="${MARIADB_BUFFER_POOL_SIZE}"
    [[ -z "$pma_ver" ]] && pma_ver="latest"
    [[ -z "$pma_port" ]] && pma_port="20003"
    [[ -z "$pma_limit" ]] && pma_limit="256M"
    [[ -z "$redis_policy" ]] && redis_policy="noeviction"
    [[ -z "$net_name" ]] && net_name="openship"

    local is_new=false
    if [[ -z "$maria_pass" ]]; then
        maria_pass="$(generate_random_password 24)"
        is_new=true
        log "Generated strong MariaDB root password."
    fi

    if [[ -z "$redis_pass" ]]; then
        redis_pass="$(generate_random_password 24)"
        is_new=true
        log "Generated strong Redis password."
    fi

    cat > "$ENV_FILE" <<EOF
# OpenShip Shared Services — MariaDB + Redis + phpMyAdmin
# Generated on: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

MARIADB_VERSION=${maria_ver}
MARIADB_ROOT_PASSWORD=${maria_pass}
MARIADB_BUFFER_POOL_SIZE=${maria_pool}
MARIADB_MEMORY_LIMIT=1024M

REDIS_VERSION=${redis_ver}
REDIS_PASSWORD=${redis_pass}
REDIS_MAXMEMORY=256mb
REDIS_MAXMEMORY_POLICY=${redis_policy}
REDIS_MEMORY_LIMIT=512M

PHPMYADMIN_VERSION=${pma_ver}
PHPMYADMIN_HOST=mariadb
PHPMYADMIN_PORT=${pma_port}
PHPMYADMIN_BIND_IP=127.0.0.1
PHPMYADMIN_UPLOAD_LIMIT=512M
PHPMYADMIN_MEMORY_LIMIT=${pma_limit}

OPENSHIP_NETWORK=${net_name}
EOF

    chmod 600 "$ENV_FILE"
    success "Configuration secured in ${ENV_FILE}"
}

start_services() {
    section "Deploying MariaDB, Redis and phpMyAdmin containers"

    ensure_docker_network

    log "Starting stack..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

    log "Waiting for containers to become healthy..."
    local max_wait=50
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local maria_status redis_status pma_status
        maria_status="$(docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo '"starting"')"
        redis_status="$(docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo '"starting"')"
        pma_status="$(docker inspect --format='{{json .State.Health.Status}}' phpmyadmin 2>/dev/null || echo '"starting"')"

        if [[ "$maria_status" == '"healthy"' && "$redis_status" == '"healthy"' && "$pma_status" == '"healthy"' ]]; then
            healthy=true
            break
        fi

        sleep 2
        elapsed=$(( elapsed + 2 ))
        echo -n "."
    done
    echo

    local net="${OPENSHIP_NETWORK:-openship}"
    if [[ "$healthy" == "true" ]]; then
        success "MariaDB, Redis and phpMyAdmin are healthy and running on '${net}'!"
    else
        warn "Containers started. Checking final statuses:"
        warn "MariaDB:    $(docker inspect --format='{{json .State.Health.Status}}' mariadb 2>/dev/null || echo 'not found')"
        warn "Redis:      $(docker inspect --format='{{json .State.Health.Status}}' redis 2>/dev/null || echo 'not found')"
        warn "phpMyAdmin: $(docker inspect --format='{{json .State.Health.Status}}' phpmyadmin 2>/dev/null || echo 'not found')"
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
    docker ps -a --filter "name=mariadb" --filter "name=redis" --filter "name=phpmyadmin" --format "table {{.Names}}	{{.Status}}	{{.Ports}}	{{.Networks}}"

    local net="${OPENSHIP_NETWORK:-openship}"
    echo
    echo -e "${BOLD}Network (${net}):${NC}"
    docker network inspect "$net" --format '{{range .Containers}}{{.Name}} ({{.IPv4Address}}){{"
"}}{{end}}' 2>/dev/null || echo "Network not found."

    echo
    echo -e "${BOLD}Volumes:${NC}"
    docker volume ls --filter "name=mariadb_data" --filter "name=redis_data"
}

follow_logs() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f
}

print_summary() {
    local pma_port net_name
    pma_port="$(grep -E '^PHPMYADMIN_PORT=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo '20003')"
    net_name="$(grep -E '^OPENSHIP_NETWORK=' "$ENV_FILE" 2>/dev/null | cut -d '=' -f2- | tr -d '"'' ' || echo 'openship')"

    section "Ready! Connection Details"

    echo -e "${BOLD}1. Services Access (Internal Network '${net_name}'):${NC}"
    echo "------------------------------------------------------------"
    echo "MariaDB Host:          mariadb:3306"
    echo "Redis Host:            redis:6379"
    echo "phpMyAdmin Local Port: 127.0.0.1:${pma_port} (proxied to pma.blackcore.dev)"
    echo "Credentials saved in:  ${ENV_FILE}"
    echo "------------------------------------------------------------"
    echo
    echo -e "${BOLD}2. Project Database Provisioning:${NC}"
    echo "------------------------------------------------------------"
    echo "Projects auto-provision their DB & user during deployment"
    echo "using DB_ROOT_PASSWORD or manage tables via phpMyAdmin:"
    echo "https://pma.blackcore.dev"
    echo "------------------------------------------------------------"
}

show_help() {
    cat <<EOF
OpenShip Shared Services Deployer (MariaDB + Redis + phpMyAdmin)

Usage:
  sudo ./deploy.sh [OPTIONS]

Options:
  --status        Display current status and health of containers
  --restart       Restart MariaDB, Redis, and phpMyAdmin containers
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
