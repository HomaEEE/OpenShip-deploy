#!/usr/bin/env bash

# ==============================================================================
# OpenShip Worker Services — MariaDB + Redis Deployer
# ==============================================================================
#
# This script deploys and manages isolated MariaDB and Redis containers
# on OpenShip worker/child nodes.
#
# Usage:
#   sudo ./deploy.sh              # Interactive / standard deploy
#   sudo ./deploy.sh --status     # Show service status and health
#   sudo ./deploy.sh --restart    # Restart services
#   sudo ./deploy.sh --stop       # Stop services
#   sudo ./deploy.sh --logs       # Follow container logs
#   sudo ./deploy.sh --pull       # Pull latest images and update
#   sudo ./deploy.sh --help       # Show help message
#
# Environment variables (or defined in .env):
#   MARIADB_ROOT_PASSWORD   - Root password for MariaDB (generated if empty)
#   MARIADB_DATABASE        - Default database name (optional)
#   MARIADB_USER            - Default user name (optional)
#   MARIADB_PASSWORD        - Default user password (optional)
#   MARIADB_PORT            - Host port (default: 3306)
#   REDIS_PASSWORD          - Redis auth password (generated if empty)
#   REDIS_PORT              - Host port (default: 6379)
#   UFW_ALLOW_IPS           - Allowed IP list or "any" for firewall
#   NON_INTERACTIVE         - Set to "1" or "true" for automated run
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly COMPOSE_FILE="${SCRIPT_DIR}/docker-compose.yml"
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly ENV_EXAMPLE="${SCRIPT_DIR}/.env.example"
readonly LOG_FILE="/var/log/openship-services-deploy.log"

# ------------------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    BOLD=''
    NC=''
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
touch "$LOG_FILE" 2>/dev/null || true

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
    echo
    error "See log: ${LOG_FILE}"
    exit 1
}

section() {
    echo
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo -e "${BOLD}${CYAN} $*${NC}"
    echo -e "${BOLD}${CYAN}============================================================${NC}"
    echo
}

# ------------------------------------------------------------------------------
# Error handling
# ------------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_no=$1
    echo
    error "Deployment script failed at line ${line_no} with exit code ${exit_code}."
    error "Check log file: ${LOG_FILE}"
    echo
    exit "$exit_code"
}

trap 'on_error ${LINENO}' ERR

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "This script must be run as root or with sudo."
    fi
}

generate_random_password() {
    local length="${1:-32}"
    if command_exists openssl; then
        openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$length"
    else
        LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c "$length"
    fi
}

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer

    if [[ "${NON_INTERACTIVE:-false}" == "true" || "${NON_INTERACTIVE:-0}" == "1" ]]; then
        [[ "$default" == "Y" ]] && return 0 || return 1
    fi

    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n]: " answer
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N]: " answer
        answer="${answer:-N}"
    fi

    case "${answer,,}" in
        y|yes) return 0 ;;
        *) return 1 ;;
    esac
}

ask_input() {
    local prompt="$1"
    local default="$2"
    local value

    if [[ "${NON_INTERACTIVE:-false}" == "true" || "${NON_INTERACTIVE:-0}" == "1" ]]; then
        echo "$default"
        return
    fi

    read -r -p "$prompt [$default]: " value
    echo "${value:-$default}"
}

get_server_ip() {
    local ip
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    if [[ -z "$ip" ]]; then
        ip="$(curl -fsSL -m 3 https://api.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")"
    fi
    echo "$ip"
}

# ------------------------------------------------------------------------------
# Docker verification and installation
# ------------------------------------------------------------------------------

check_and_install_docker() {
    section "Docker environment check"

    if command_exists docker && docker compose version >/dev/null 2>&1; then
        success "Docker and Docker Compose plugin are installed."
        docker --version
        docker compose version
        return
    fi

    warn "Docker or Docker Compose plugin not found."

    if ! ask_yes_no "Install official Docker Engine now?" "Y"; then
        die "Docker is required to run OpenShip worker database services."
    fi

    log "Installing Docker prerequisites..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
    fi

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-${VERSION_CODENAME:-noble}} stable
EOF

    apt-get update
    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker
    success "Docker successfully installed."
}

ensure_docker_running() {
    docker info >/dev/null 2>&1 || die "Docker daemon is not running. Check: systemctl status docker"
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

# ------------------------------------------------------------------------------
# Environment configuration
# ------------------------------------------------------------------------------

configure_environment() {
    section "Services Configuration (.env)"

    # Load existing .env if present
    if [[ -f "$ENV_FILE" ]]; then
        log "Loading existing configuration from ${ENV_FILE}..."
        # shellcheck disable=SC1090
        set -a
        source "$ENV_FILE"
        set +a
    elif [[ -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    else
        touch "$ENV_FILE"
        chmod 600 "$ENV_FILE"
    fi

    # Detect or configure server characteristics
    if [[ -z "${SERVER_RAM_GB:-}" ]]; then
        if command_exists free; then
            local ram_mb
            ram_mb="$(free -m | awk '/^Mem:/ {print $2}')"
            SERVER_RAM_GB=$(( (ram_mb + 512) / 1024 ))
            (( SERVER_RAM_GB < 1 )) && SERVER_RAM_GB=1
        elif [[ -f /proc/meminfo ]]; then
            local ram_mb
            ram_mb="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
            SERVER_RAM_GB=$(( (ram_mb + 512) / 1024 ))
            (( SERVER_RAM_GB < 1 )) && SERVER_RAM_GB=1
        else
            SERVER_RAM_GB="2"
        fi
    fi

    if [[ -z "${SERVER_CPU_CORES:-}" ]]; then
        if command_exists nproc; then
            SERVER_CPU_CORES="$(nproc)"
        else
            SERVER_CPU_CORES="1"
        fi
    fi

    # Set default ports & versions
    MARIADB_VERSION="${MARIADB_VERSION:-11.4}"
    MARIADB_PORT="${MARIADB_PORT:-3306}"
    MARIADB_BUFFER_POOL_SIZE="${MARIADB_BUFFER_POOL_SIZE:-}"
    MARIADB_MAX_CONNECTIONS="${MARIADB_MAX_CONNECTIONS:-}"

    REDIS_VERSION="${REDIS_VERSION:-7.4-alpine}"
    REDIS_PORT="${REDIS_PORT:-6379}"
    REDIS_MAXMEMORY="${REDIS_MAXMEMORY:-}"
    REDIS_MAXMEMORY_POLICY="${REDIS_MAXMEMORY_POLICY:-allkeys-lru}"

    # MariaDB Root Password
    if [[ -z "${MARIADB_ROOT_PASSWORD:-}" ]]; then
        local gen_pwd
        gen_pwd="$(generate_random_password 32)"
        if [[ "${NON_INTERACTIVE:-false}" == "true" || "${NON_INTERACTIVE:-0}" == "1" ]]; then
            MARIADB_ROOT_PASSWORD="$gen_pwd"
            log "Generated secure random MariaDB root password."
        else
            echo
            echo "No MARIADB_ROOT_PASSWORD configured."
            MARIADB_ROOT_PASSWORD="$(ask_input "Enter MariaDB root password (leave empty to generate)" "$gen_pwd")"
        fi
    fi

    # Redis Password
    if [[ -z "${REDIS_PASSWORD:-}" ]]; then
        local gen_redis_pwd
        gen_redis_pwd="$(generate_random_password 32)"
        if [[ "${NON_INTERACTIVE:-false}" == "true" || "${NON_INTERACTIVE:-0}" == "1" ]]; then
            REDIS_PASSWORD="$gen_redis_pwd"
            log "Generated secure random Redis password."
        else
            echo
            echo "No REDIS_PASSWORD configured."
            REDIS_PASSWORD="$(ask_input "Enter Redis password (leave empty to generate)" "$gen_redis_pwd")"
        fi
    fi

    # Save to .env
    cat > "$ENV_FILE" <<EOF
# OpenShip Worker Services Configuration
# Generated on: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

# Server Characteristics
SERVER_RAM_GB=${SERVER_RAM_GB:-}
SERVER_CPU_CORES=${SERVER_CPU_CORES:-}

# MariaDB
MARIADB_VERSION=${MARIADB_VERSION}
MARIADB_ROOT_PASSWORD=${MARIADB_ROOT_PASSWORD}
MARIADB_PORT=${MARIADB_PORT}
MARIADB_BUFFER_POOL_SIZE=${MARIADB_BUFFER_POOL_SIZE}
MARIADB_MAX_CONNECTIONS=${MARIADB_MAX_CONNECTIONS}

# Redis
REDIS_VERSION=${REDIS_VERSION}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_PORT=${REDIS_PORT}
REDIS_MAXMEMORY=${REDIS_MAXMEMORY}
REDIS_MAXMEMORY_POLICY=${REDIS_MAXMEMORY_POLICY}

# Firewall
UFW_ALLOW_IPS=${UFW_ALLOW_IPS:-}
EOF

    chmod 600 "$ENV_FILE"
    success "Configuration saved to ${ENV_FILE} (permissions 600)."
}

# ------------------------------------------------------------------------------
# Firewall / UFW
# ------------------------------------------------------------------------------

configure_firewall() {
    section "Firewall (UFW) Configuration"

    if ! command_exists ufw; then
        log "UFW is not installed. Skipping firewall rules."
        return
    fi

    local ufw_status
    ufw_status="$(ufw status | head -n 1 || true)"
    if [[ "$ufw_status" != *"active"* ]]; then
        log "UFW is not active. Skipping firewall rules."
        return
    fi

    local ips="${UFW_ALLOW_IPS:-}"

    if [[ -z "$ips" ]]; then
        if [[ "${NON_INTERACTIVE:-false}" == "true" || "${NON_INTERACTIVE:-0}" == "1" ]]; then
            log "Non-interactive mode without UFW_ALLOW_IPS: leaving UFW as is."
            return
        fi

        echo "MariaDB (${MARIADB_PORT}) and Redis (${REDIS_PORT}) can be exposed via UFW."
        echo "Options:"
        echo "  1) Restrict access to trusted IP addresses (recommended for multi-server clusters)"
        echo "  2) Open access to all IP addresses (password protected)"
        echo "  3) Do not change UFW rules"
        echo
        local choice
        read -r -p "Select firewall policy [1/2/3, default 1]: " choice
        choice="${choice:-1}"

        case "$choice" in
            1)
                read -r -p "Enter client IPs or subnets (e.g. 10.0.0.5, 192.168.1.0/24): " ips
                ;;
            2)
                ips="any"
                ;;
            *)
                log "Skipping UFW modification."
                return
                ;;
        esac
    fi

    if [[ "$ips" == "any" || "$ips" == "all" ]]; then
        log "Opening ports ${MARIADB_PORT} and ${REDIS_PORT} for all IP addresses in UFW..."
        ufw allow "${MARIADB_PORT}/tcp" comment 'OpenShip MariaDB' || true
        ufw allow "${REDIS_PORT}/tcp" comment 'OpenShip Redis' || true
        success "Ports ${MARIADB_PORT} and ${REDIS_PORT} opened for all IPs."
    elif [[ -n "$ips" ]]; then
        # Replace commas with spaces and iterate
        local clean_ips="${ips//,/ }"
        for ip in $clean_ips; do
            ip="$(echo "$ip" | tr -d ' ')"
            [[ -z "$ip" ]] && continue
            log "Allowing ${ip} access to ports ${MARIADB_PORT} and ${REDIS_PORT}..."
            ufw allow from "$ip" to any port "${MARIADB_PORT}" proto tcp comment "OpenShip MariaDB from ${ip}" || true
            ufw allow from "$ip" to any port "${REDIS_PORT}" proto tcp comment "OpenShip Redis from ${ip}" || true
        done
        success "UFW rules applied for specified IPs: ${ips}"
    fi
}

# ------------------------------------------------------------------------------
# System and Kernel Tuning (MariaDB + Redis)
# ------------------------------------------------------------------------------

configure_swap() {
    section "Swap configuration"

    if [[ "${SKIP_TUNING:-false}" == "true" || "${SKIP_TUNING:-0}" == "1" ]]; then
        log "Skipping swap configuration (SKIP_TUNING is active)."
        return
    fi

    if swapon --show 2>/dev/null | grep -q .; then
        success "Swap is already active:"
        swapon --show
        return
    fi

    local mem_total_kb
    mem_total_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 2097152)"
    local mem_total_gb=$(( mem_total_kb / 1048576 ))

    local swap_gb=2
    if (( mem_total_gb > 4 )); then
        swap_gb=4
    fi

    log "Host RAM: ~${mem_total_gb} GB. Creating ${swap_gb} GB swapfile..."

    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${swap_gb}G" /swapfile 2>/dev/null; then
            warn "fallocate failed, creating swapfile with dd..."
            dd if=/dev/zero of=/swapfile bs=1M count="$(( swap_gb * 1024 ))" status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile
    fi

    if ! swapon /swapfile 2>/dev/null; then
        warn "swapon failed (possibly running inside unprivileged container or unsupported filesystem)."
        warn "Continuing without swap."
        return
    fi

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    success "${swap_gb} GB swap configured and active."
}

optimize_system() {
    section "Kernel & System Limits Tuning (MariaDB + Redis)"

    if [[ "${SKIP_TUNING:-false}" == "true" || "${SKIP_TUNING:-0}" == "1" ]]; then
        log "Skipping system tuning (SKIP_TUNING is active)."
        return
    fi

    log "Applying sysctl optimizations for MariaDB and Redis..."
    mkdir -p /etc/sysctl.d 2>/dev/null || true
    cat > /etc/sysctl.d/99-openship-mariadb-redis.conf <<'EOF'
# Redis requirements
vm.overcommit_memory = 1
net.core.somaxconn = 4096

# MariaDB & Redis memory & swap tuning
vm.swappiness = 1
vm.vfs_cache_pressure = 50

# MariaDB InnoDB AIO and file limits
fs.aio-max-nr = 1048576
fs.file-max = 2097152

# TCP connection tuning
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
EOF

    # Apply sysctl, safe fallback if inside container or virtualized
    sysctl -p /etc/sysctl.d/99-openship-mariadb-redis.conf >> "$LOG_FILE" 2>&1 || {
        warn "sysctl command failed (possibly restricted permissions in container). Continuing."
    }

    log "Configuring file descriptor limits (nofile 65535)..."
    mkdir -p /etc/security/limits.d 2>/dev/null || true
    cat > /etc/security/limits.d/99-openship-services.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

    success "Kernel parameters and ulimits configured."
}

configure_thp() {
    section "Transparent Huge Pages (THP) Tuning"

    if [[ "${SKIP_TUNING:-false}" == "true" || "${SKIP_TUNING:-0}" == "1" ]]; then
        log "Skipping THP tuning (SKIP_TUNING is active)."
        return
    fi

    log "Configuring Transparent Huge Pages for Redis latency prevention..."

    # Apply immediately at runtime if sysfs node is available
    if [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
        echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || \
        echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    fi

    if [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]]; then
        echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || \
        echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true
    fi

    # Create systemd service for persistence across reboots
    if command_exists systemctl && [[ -d /etc/systemd/system ]]; then
        cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent Huge Pages for Redis/Databases
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if test -w /sys/kernel/mm/transparent_hugepage/enabled; then echo madvise > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo never > /sys/kernel/mm/transparent_hugepage/enabled; fi; if test -w /sys/kernel/mm/transparent_hugepage/defrag; then echo madvise > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || echo never > /sys/kernel/mm/transparent_hugepage/defrag; fi'

[Install]
WantedBy=basic.target
EOF
        systemctl daemon-reload >> "$LOG_FILE" 2>&1 || true
        systemctl enable disable-thp.service >> "$LOG_FILE" 2>&1 || true
        success "THP tuning applied and persisted via disable-thp.service."
    else
        success "THP runtime tuning applied."
    fi
}

# ------------------------------------------------------------------------------
# Compose Operations
# ------------------------------------------------------------------------------

start_services() {
    section "Starting MariaDB + Redis containers"

    log "Deploying stack using Docker Compose..."
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d

    log "Waiting for containers to become healthy..."
    local max_wait=45
    local elapsed=0
    local healthy=false

    while (( elapsed < max_wait )); do
        local maria_status redis_status
        maria_status="$(docker inspect --format='{{json .State.Health.Status}}' openship-mariadb 2>/dev/null || echo "\"unknown\"")"
        redis_status="$(docker inspect --format='{{json .State.Health.Status}}' openship-redis 2>/dev/null || echo "\"unknown\"")"

        if [[ "$maria_status" == "\"healthy\"" && "$redis_status" == "\"healthy\"" ]]; then
            healthy=true
            break
        fi

        sleep 3
        elapsed=$(( elapsed + 3 ))
        echo -n "."
    done
    echo

    if [[ "$healthy" == "true" ]]; then
        success "Both MariaDB and Redis containers are healthy and running!"
    else
        warn "Containers started, but healthcheck is still in progress or unconfirmed."
        warn "MariaDB status: $(docker inspect --format='{{json .State.Health.Status}}' openship-mariadb 2>/dev/null || echo 'not found')"
        warn "Redis status: $(docker inspect --format='{{json .State.Health.Status}}' openship-redis 2>/dev/null || echo 'not found')"
    fi
}

stop_services() {
    section "Stopping services"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down
    success "Services stopped."
}

restart_services() {
    section "Restarting services"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" restart
    success "Services restarted."
}

pull_images() {
    section "Pulling latest images"
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" pull
    success "Images updated."
}

show_status() {
    section "OpenShip Services Status"

    if ! command_exists docker; then
        error "Docker is not installed."
        return
    fi

    docker ps -a --filter "name=openship-" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo
    log "Network: openship-network"
    docker network inspect openship-network --format '{{range .Containers}}{{.Name}} ({{.IPv4Address}}){{"\n"}}{{end}}' 2>/dev/null || true

    echo
    log "Volumes:"
    docker volume ls --filter "name=openship_"
}

follow_logs() {
    docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" logs -f
}

# ------------------------------------------------------------------------------
# Summary and Connection Details
# ------------------------------------------------------------------------------

print_summary() {
    section "Deployment Complete — Connection Details"

    local server_ip
    server_ip="$(get_server_ip)"

    echo -e "${BOLD}1. Local Connection (Containers on the SAME worker node):${NC}"
    echo -e "   Connect containers to Docker network: ${CYAN}openship-network${NC}"
    echo "   MariaDB Host:     mariadb"
    echo "   MariaDB Port:     3306"
    echo "   Redis Host:       redis"
    echo "   Redis Port:       6379"
    echo
    echo -e "${BOLD}2. Remote Connection (Applications on OTHER servers):${NC}"
    echo "   MariaDB Host:     ${server_ip}"
    echo "   MariaDB Port:     ${MARIADB_PORT}"
    echo "   Redis Host:       ${server_ip}"
    echo "   Redis Port:       ${REDIS_PORT}"
    echo
    echo -e "${BOLD}3. Credentials:${NC}"
    echo "   MariaDB Root:     root / ${MARIADB_ROOT_PASSWORD}"
    echo "   Redis Password:   ${REDIS_PASSWORD}"
    echo
    echo -e "${BOLD}4. Example Laravel .env configuration:${NC}"
    echo "------------------------------------------------------------"
    cat <<EOF
DB_CONNECTION=mysql
DB_HOST=${server_ip}
DB_PORT=${MARIADB_PORT}
DB_DATABASE=your_app_db
DB_USERNAME=root
DB_PASSWORD=${MARIADB_ROOT_PASSWORD}

REDIS_CLIENT=phpredis
REDIS_HOST=${server_ip}
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_PORT=${REDIS_PORT}
EOF
    echo "------------------------------------------------------------"
    echo
    echo -e "${YELLOW}Credentials and settings are saved in:${NC} ${ENV_FILE}"
    echo -e "${YELLOW}Manage with:${NC}"
    echo "  ${SCRIPT_DIR}/deploy.sh --status"
    echo "  ${SCRIPT_DIR}/deploy.sh --logs"
    echo "  ${SCRIPT_DIR}/deploy.sh --restart"
    echo "  ${SCRIPT_DIR}/backup.sh"
    echo
}

# ------------------------------------------------------------------------------
# Usage / Help
# ------------------------------------------------------------------------------

show_help() {
    cat <<EOF
OpenShip Worker Services Deployer (MariaDB + Redis)

Usage:
  sudo ./deploy.sh [OPTIONS]

Options:
  --status        Display current status and health of containers
  --restart       Restart MariaDB and Redis containers
  --stop          Stop and remove containers (data volumes preserved)
  --logs          Follow container logs in real time
  --pull          Pull updated Docker images and recreate containers
  --skip-tuning   Skip server optimization (swap, sysctl, THP, ulimits)
  --prepare-host  Tune host only (swap, sysctl, THP, network) without starting containers
  --help, -h      Display this help message

Environment variables:
  MARIADB_ROOT_PASSWORD   Root password for MariaDB
  REDIS_PASSWORD          Password for Redis authentication
  MARIADB_PORT            Host port for MariaDB (default: 3306)
  REDIS_PORT              Host port for Redis (default: 6379)
  UFW_ALLOW_IPS           Allowed IP list or "any" for firewall
  SKIP_TUNING             Set to 1 or true to skip server optimization
  NON_INTERACTIVE         Set to 1 or true for non-interactive execution
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

    # Command line argument handling
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --status)
                show_status
                exit 0
                ;;
            --stop|--down)
                stop_services
                exit 0
                ;;
            --restart)
                restart_services
                exit 0
                ;;
            --logs)
                follow_logs
                exit 0
                ;;
            --pull)
                pull_images
                start_services
                exit 0
                ;;
            --skip-tuning)
                export SKIP_TUNING=true
                shift
                ;;
            --prepare-host|--tune-only)
                exec > >(tee -a "$LOG_FILE") 2>&1
                section "Preparing Host for OpenShip Control Panel Deployment"
                check_and_install_docker
                ensure_docker_running
                ensure_docker_network
                configure_swap
                optimize_system
                configure_thp
                success "Host optimization complete. Ready for OpenShip UI stack deployment."
                exit 0
                ;;
            *)
                error "Unknown argument: $1"
                echo
                show_help
                exit 1
                ;;
        esac
    done

    # Default flow: Full setup / deploy
    exec > >(tee -a "$LOG_FILE") 2>&1

    section "OpenShip Worker Services — MariaDB + Redis Deployer"

    check_and_install_docker
    ensure_docker_running
    ensure_docker_network

    configure_environment
    configure_firewall

    configure_swap
    optimize_system
    configure_thp

    start_services
    print_summary
}

main "$@"
