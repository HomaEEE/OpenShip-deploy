#!/usr/bin/env bash

# ==============================================================================
# OpenShip Control Plane Installer
# ==============================================================================
#
# Supported:
#   Ubuntu 24.04 LTS
#
# Installation modes:
#   BARE      - OpenShip without Docker
#   STANDARD  - OpenShip using Docker
#
# The installer automatically detects RAM and recommends the appropriate mode.
#
# Usage:
#   sudo ./install.sh
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.0.1"
readonly OPENSHIP_INSTALL_URL="https://get.openship.io"

readonly LOG_FILE="/var/log/openship-control-install.log"
readonly STATE_DIR="/etc/openship-control"
readonly STATE_FILE="${STATE_DIR}/install.conf"

# Resource thresholds
# Bare mode is intentionally allowed on small VPS instances.
# 768 MiB is the hard minimum; 2 GiB is recommended for Standard/Docker.
readonly MIN_RAM_MB=768
readonly RECOMMENDED_RAM_MB=2048
readonly MIN_DISK_GB=10

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

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

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
    error "Installation log: ${LOG_FILE}"
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
    error "Installation failed."
    error "Line: ${line_no}"
    error "Exit code: ${exit_code}"
    error "Log: ${LOG_FILE}"
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

ask_yes_no() {
    local prompt="$1"
    local default="${2:-Y}"
    local answer

    if [[ "$default" == "Y" ]]; then
        read -r -p "$prompt [Y/n]: " answer
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N]: " answer
        answer="${answer:-N}"
    fi

    case "${answer,,}" in
        y|yes)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

ask_default() {
    local prompt="$1"
    local default="$2"
    local value

    read -r -p "$prompt [$default]: " value

    echo "${value:-$default}"
}

valid_hostname() {
    [[ "$1" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]
}

valid_ssh_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
        (( "$1" >= 1 && "$1" <= 65535 ))
}

# ------------------------------------------------------------------------------
# Root
# ------------------------------------------------------------------------------

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "Run this installer as root or with sudo."
    fi
}

# ------------------------------------------------------------------------------
# OS
# ------------------------------------------------------------------------------

check_os() {
    section "Operating system"

    [[ -f /etc/os-release ]] ||
        die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Ubuntu is required. Detected: ${ID:-unknown}"
    fi

    if [[ "${VERSION_ID:-}" != "24.04" ]]; then
        warn "This installer is designed for Ubuntu 24.04 LTS."
        warn "Detected: Ubuntu ${VERSION_ID:-unknown}"

        if ! ask_yes_no "Continue anyway?" "N"; then
            die "Installation cancelled."
        fi
    fi

    success "Ubuntu ${VERSION_ID:-unknown}"
}

# ------------------------------------------------------------------------------
# Architecture
# ------------------------------------------------------------------------------

check_architecture() {
    section "Architecture"

    local arch
    arch="$(dpkg --print-architecture)"

    case "$arch" in
        amd64|arm64)
            success "Architecture: ${arch}"
            ;;
        *)
            die "Unsupported architecture: ${arch}"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Resources
# ------------------------------------------------------------------------------

detect_resources() {
    RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
    DISK_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"
    CPU_COUNT="$(nproc)"
}

check_resources() {
    section "System resources"

    detect_resources

    echo "RAM:     ${RAM_MB} MB"
    echo "Minimum: ${MIN_RAM_MB} MB (Bare)"
    echo "Recommended: ${RECOMMENDED_RAM_MB} MB (Standard)"
    echo "CPU:     ${CPU_COUNT}"
    echo "Disk:    ${DISK_GB} GB"
    echo

    if (( RAM_MB < MIN_RAM_MB )); then
        die "At least 768 MiB RAM is required for Bare mode."
    elif (( RAM_MB < RECOMMENDED_RAM_MB )); then
        warn "Low-memory VPS detected: ${RAM_MB} MB RAM."
        warn "Bare mode is recommended for this server."
        warn "Standard/Docker mode may be unstable or use swap heavily."
    else
        success "RAM is sufficient for Standard mode."
    fi

    if (( DISK_GB < MIN_DISK_GB )); then
        die "At least ${MIN_DISK_GB} GB free disk space is required."
    fi

    if (( RAM_MB < RECOMMENDED_RAM_MB )); then
        warn "RAM is below the recommended 2 GB."
        warn "This server is suitable for a lightweight Bare installation."
    else
        success "RAM is sufficient for Standard mode."
    fi

    success "Resource check passed."
}

# ------------------------------------------------------------------------------
# Installation mode selection
# ------------------------------------------------------------------------------

select_installation_mode() {
    section "OpenShip installation mode"

    echo "Detected resources:"
    echo
    echo "  RAM:  ${RAM_MB} MB"
    echo "  CPU:  ${CPU_COUNT}"
    echo "  Disk: ${DISK_GB} GB"
    echo

    if (( RAM_MB < RECOMMENDED_RAM_MB )); then

        echo -e "${BOLD}${YELLOW}"
        echo "WARNING"
        echo "----------------------------------------------------------------"
        echo "This server has less than 2 GB of RAM."
        echo
        echo "Standard Docker mode will run:"
        echo "  - Docker"
        echo "  - PostgreSQL"
        echo "  - Redis"
        echo "  - OpenShip API"
        echo "  - OpenShip Dashboard"
        echo "  - OpenShip Edge"
        echo
        echo "On a 1 GB VPS this can create significant memory pressure."
        echo
        echo "For 1–2 GB VPS servers, Bare mode is recommended."
        echo
        echo "Hard minimum for Bare mode: 768 MiB RAM."
        echo -e "${NC}"

        echo
        echo "Choose installation mode:"
        echo
        echo "  1) Bare"
        echo "     OpenShip without Docker."
        echo "     Recommended for this server."
        echo
        echo "  2) Standard"
        echo "     OpenShip using Docker."
        echo "     Requires more RAM."
        echo
        echo "  3) Cancel"
        echo

        while true; do
            read -r -p "Select [1]: " choice
            choice="${choice:-1}"

            case "$choice" in
                1)
                    INSTALL_MODE="bare"
                    break
                    ;;
                2)
                    echo
                    warn "You selected Standard Docker mode on a low-memory VPS."
                    warn "The system may use swap heavily or become unstable."
                    echo

                    if ask_yes_no "Are you sure you want Standard mode?" "N"; then
                        INSTALL_MODE="standard"
                        break
                    fi
                    ;;
                3)
                    die "Installation cancelled."
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done

    else

        echo "Choose installation mode:"
        echo
        echo "  1) Standard"
        echo "     OpenShip using Docker."
        echo "     Recommended."
        echo
        echo "  2) Bare"
        echo "     OpenShip without Docker."
        echo
        echo "  3) Cancel"
        echo

        while true; do
            read -r -p "Select [1]: " choice
            choice="${choice:-1}"

            case "$choice" in
                1)
                    INSTALL_MODE="standard"
                    break
                    ;;
                2)
                    INSTALL_MODE="bare"
                    break
                    ;;
                3)
                    die "Installation cancelled."
                    ;;
                *)
                    echo "Invalid choice."
                    ;;
            esac
        done

    fi

    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        success "Selected mode: BARE"
        warn "Docker will NOT be installed."
    else
        success "Selected mode: STANDARD"
        log "OpenShip will run using Docker."
    fi
}

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

collect_configuration() {
    section "Control Plane configuration"

    echo "This VPS will act as the OpenShip Control Plane."
    echo
    echo "It will manage remote deployment servers."
    echo "Laravel / Filament applications should NOT be deployed here."
    echo

    while true; do
        HOSTNAME_INPUT="$(ask_default \
            "Control Plane hostname" \
            "openship-control")"

        if valid_hostname "$HOSTNAME_INPUT"; then
            break
        fi

        warn "Invalid hostname."
    done

    TIMEZONE_INPUT="$(ask_default "Timezone" "UTC")"

    if ! timedatectl list-timezones 2>/dev/null |
        grep -Fxq "$TIMEZONE_INPUT"; then

        warn "Timezone '${TIMEZONE_INPUT}' not found."
        warn "Using UTC."

        TIMEZONE_INPUT="UTC"
    fi

    while true; do
        SSH_PORT_INPUT="$(ask_default "SSH port" "22")"

        if valid_ssh_port "$SSH_PORT_INPUT"; then
            break
        fi

        warn "Invalid SSH port."
    done

    ADMIN_USER_INPUT="$(ask_default "Linux administrator" "deploy")"

    if ! [[ "$ADMIN_USER_INPUT" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        die "Invalid Linux username: ${ADMIN_USER_INPUT}"
    fi

    echo

    if ask_yes_no "Enable UFW firewall?" "Y"; then
        ENABLE_UFW="true"
    else
        ENABLE_UFW="false"
    fi

    if ask_yes_no "Enable Fail2ban for SSH?" "Y"; then
        ENABLE_FAIL2BAN="true"
    else
        ENABLE_FAIL2BAN="false"
    fi

    if ask_yes_no "Ensure 2 GB swap?" "Y"; then
        ENABLE_SWAP="true"
    else
        ENABLE_SWAP="false"
    fi

    save_configuration
}

save_configuration() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    cat > "$STATE_FILE" <<EOF
INSTALL_MODE=${INSTALL_MODE}
HOSTNAME=${HOSTNAME_INPUT}
TIMEZONE=${TIMEZONE_INPUT}
SSH_PORT=${SSH_PORT_INPUT}
ADMIN_USER=${ADMIN_USER_INPUT}
ENABLE_UFW=${ENABLE_UFW}
ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN}
ENABLE_SWAP=${ENABLE_SWAP}
EOF

    chmod 600 "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# Hostname
# ------------------------------------------------------------------------------

configure_hostname() {
    section "Hostname"

    hostnamectl set-hostname "$HOSTNAME_INPUT"

    if grep -qE '^127\.0\.1\.1[[:space:]]+' /etc/hosts; then
        sed -i \
            "s/^127\.0\.1\.1.*/127.0.1.1 ${HOSTNAME_INPUT}/" \
            /etc/hosts
    else
        echo "127.0.1.1 ${HOSTNAME_INPUT}" >> /etc/hosts
    fi

    success "Hostname: ${HOSTNAME_INPUT}"
}

# ------------------------------------------------------------------------------
# Timezone
# ------------------------------------------------------------------------------

configure_timezone() {
    section "Timezone"

    timedatectl set-timezone "$TIMEZONE_INPUT"

    success "Timezone: ${TIMEZONE_INPUT}"
}

# ------------------------------------------------------------------------------
# Base packages
# ------------------------------------------------------------------------------

install_base_packages() {
    section "Base packages"

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        gnupg \
        git \
        jq \
        unzip \
        rsync \
        htop \
        nano \
        vim \
        ncdu \
        lsof \
        procps \
        net-tools \
        dnsutils \
        openssl \
        ufw \
        fail2ban \
        unattended-upgrades

    apt-get autoremove -y

    success "Base packages installed."
}

# ------------------------------------------------------------------------------
# Swap
# ------------------------------------------------------------------------------

configure_swap() {
    section "Swap"

    if swapon --show | grep -q .; then
        success "Swap is already enabled."
        swapon --show
        return
    fi

    if [[ "$ENABLE_SWAP" != "true" ]]; then
        warn "Swap disabled by configuration."
        return
    fi

    log "Creating 2 GB swap..."

    if [[ ! -f /swapfile ]]; then
        fallocate -l 2G /swapfile
        chmod 600 /swapfile
        mkswap /swapfile
    fi

    swapon /swapfile

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    cat > /etc/sysctl.d/99-openship-control.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

    sysctl --system >/dev/null

    success "2 GB swap configured."
}

# ------------------------------------------------------------------------------
# Admin user
# ------------------------------------------------------------------------------

configure_admin_user() {
    section "Administrator user"

    if id "$ADMIN_USER_INPUT" >/dev/null 2>&1; then
        log "User '${ADMIN_USER_INPUT}' already exists."
    else
        adduser \
            --disabled-password \
            --gecos "" \
            "$ADMIN_USER_INPUT"
    fi

    usermod -aG sudo "$ADMIN_USER_INPUT"

    if [[ -f /root/.ssh/authorized_keys ]]; then

        mkdir -p "/home/${ADMIN_USER_INPUT}/.ssh"

        cp /root/.ssh/authorized_keys \
            "/home/${ADMIN_USER_INPUT}/.ssh/authorized_keys"

        chown -R \
            "${ADMIN_USER_INPUT}:${ADMIN_USER_INPUT}" \
            "/home/${ADMIN_USER_INPUT}/.ssh"

        chmod 700 \
            "/home/${ADMIN_USER_INPUT}/.ssh"

        chmod 600 \
            "/home/${ADMIN_USER_INPUT}/.ssh/authorized_keys"

        success "SSH key copied to ${ADMIN_USER_INPUT}."
    else
        warn "No /root/.ssh/authorized_keys found."
        warn "Root SSH access will not be disabled automatically."
    fi
}

# ------------------------------------------------------------------------------
# SSH
# ------------------------------------------------------------------------------

configure_ssh() {
    section "SSH hardening"

    local config="/etc/ssh/sshd_config.d/99-openship-control.conf"

    {
        echo "# OpenShip Control Plane"
        echo
        echo "Port ${SSH_PORT_INPUT}"
        echo
        echo "PubkeyAuthentication yes"
        echo "KbdInteractiveAuthentication no"
        echo
        echo "X11Forwarding no"
        echo "AllowAgentForwarding no"
    } > "$config"

    if [[ -f "/home/${ADMIN_USER_INPUT}/.ssh/authorized_keys" ]]; then
        cat >> "$config" <<'EOF'

PasswordAuthentication no
PermitRootLogin prohibit-password
EOF
        success "SSH password authentication disabled."
    else
        cat >> "$config" <<'EOF'

# Password authentication remains enabled because no administrator SSH key
# was found during installation.
EOF
        warn "No administrator SSH key was detected."
        warn "Password authentication remains enabled to prevent lockout."
        warn "Add an SSH key to the administrator account, then disable passwords manually."
    fi

    sshd -t

    systemctl reload ssh

    success "SSH configuration validated."
}

# ------------------------------------------------------------------------------
# UFW
# ------------------------------------------------------------------------------

configure_ufw() {
    section "Firewall"

    if [[ "$ENABLE_UFW" != "true" ]]; then
        warn "UFW disabled."
        return
    fi

    ufw default deny incoming
    ufw default allow outgoing

    ufw allow "${SSH_PORT_INPUT}/tcp" \
        comment "SSH"

    # OpenShip Edge
    ufw allow 80/tcp \
        comment "OpenShip HTTP"

    ufw allow 443/tcp \
        comment "OpenShip HTTPS"

    # IMPORTANT:
    # Dashboard :3001 and API :4000 are intentionally NOT exposed.

    ufw --force enable

    success "UFW enabled."
}

# ------------------------------------------------------------------------------
# Fail2ban
# ------------------------------------------------------------------------------

configure_fail2ban() {
    section "Fail2ban"

    if [[ "$ENABLE_FAIL2BAN" != "true" ]]; then
        warn "Fail2ban disabled."
        return
    fi

    mkdir -p /etc/fail2ban/jail.d

    cat > /etc/fail2ban/jail.d/sshd-openship.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT_INPUT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable fail2ban
    systemctl restart fail2ban

    success "Fail2ban enabled."
}

# ------------------------------------------------------------------------------
# Automatic security updates
# ------------------------------------------------------------------------------

configure_unattended_upgrades() {
    section "Automatic security updates"

    systemctl enable --now unattended-upgrades

    success "Unattended upgrades enabled."
}

# ------------------------------------------------------------------------------
# Docker
# ------------------------------------------------------------------------------

install_docker() {
    if [[ "$INSTALL_MODE" != "standard" ]]; then
        section "Docker"

        log "Bare mode selected."
        log "Docker installation skipped."

        return
    fi

    section "Docker"

    if command_exists docker; then
        success "Docker already installed."
        docker --version
        return
    fi

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL \
        https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    # shellcheck disable=SC1091
    source /etc/os-release

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-${VERSION_CODENAME}} stable
EOF

    apt-get update

    apt-get install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    docker --version
    docker compose version

    success "Docker installed."
}

# ------------------------------------------------------------------------------
# Docker daemon
# ------------------------------------------------------------------------------

configure_docker() {
    if [[ "$INSTALL_MODE" != "standard" ]]; then
        return
    fi

    section "Docker configuration"

    mkdir -p /etc/docker

    cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
EOF

    systemctl restart docker

    docker info >/dev/null

    success "Docker daemon configured."
}

# ------------------------------------------------------------------------------
# Runtime mode enforcement
# ------------------------------------------------------------------------------

prepare_runtime_for_openship() {
    section "OpenShip runtime"

    if [[ "$INSTALL_MODE" != "bare" ]]; then
        log "Standard mode selected. Docker is available for OpenShip Compose."
        return
    fi

    # OpenShip's guided wizard automatically selects Compose on Linux when
    # Docker + Compose are available. For a true Bare installation Docker
    # must not be present, otherwise the wizard will silently choose Compose.
    if ! command_exists docker; then
        success "Bare mode: Docker is not installed."
        return
    fi

    warn "Docker is already installed on this VPS."
    warn "OpenShip's guided wizard detects Docker and will select Compose mode."
    warn "To enforce Bare mode, Docker packages must be removed before setup."
    echo

    if ! ask_yes_no "Remove Docker packages now and continue with Bare mode?" "Y"; then
        die "Bare mode cannot be guaranteed while Docker is installed."
    fi

    systemctl stop docker docker.socket containerd 2>/dev/null || true
    systemctl disable docker docker.socket containerd 2>/dev/null || true

    apt-get remove -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin \
        docker-ce-rootless-extras 2>/dev/null || true

    # Remove Docker's apt source/key installed by this installer. Do not delete
    # /var/lib/docker automatically: existing Docker data should never be
    # destroyed implicitly.
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/keyrings/docker.asc

    hash -r 2>/dev/null || true

    if command_exists docker; then
        die "Docker is still available after removal. Refusing to continue Bare setup."
    fi

    success "Docker removed. OpenShip will now use Bare mode."
}

# ------------------------------------------------------------------------------
# OpenShip CLI
# ------------------------------------------------------------------------------

install_openship_cli() {
    section "OpenShip CLI"

    if command_exists openship; then
        success "OpenShip CLI already installed."
        openship --version || true
        return
    fi

    log "Installing official OpenShip CLI..."

    curl -fsSL "$OPENSHIP_INSTALL_URL" | sh

    # The official installer installs the CLI under ~/.openship/bin.
    export PATH="/root/.openship/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

    if ! command_exists openship && [[ -x "/root/.openship/bin/openship" ]]; then
        ln -sf \
            "/root/.openship/bin/openship" \
            "/usr/local/bin/openship"
    fi

    command_exists openship ||
        die "OpenShip CLI was not found after installation."

    openship --version || true

    success "OpenShip CLI installed."
}

# ------------------------------------------------------------------------------
# OpenShip preflight
# ------------------------------------------------------------------------------

preflight_openship() {
    section "OpenShip pre-flight"

    command_exists openship ||
        die "OpenShip CLI is not available."

    if [[ "$INSTALL_MODE" == "standard" ]]; then

        command_exists docker ||
            die "Docker is required for Standard mode."

        docker info >/dev/null ||
            die "Docker daemon is not running."

    fi

    if ss -lntp 2>/dev/null |
        grep -Eq ':(80|443)[[:space:]]'; then

        warn "Port 80 or 443 is already in use."

        ss -lntp 2>/dev/null |
            grep -E ':(80|443)[[:space:]]' || true

        if ! ask_yes_no "Continue anyway?" "N"; then
            die "Installation cancelled."
        fi
    fi

    success "Pre-flight checks passed."
}

# ------------------------------------------------------------------------------
# OpenShip setup
# ------------------------------------------------------------------------------

run_openship_setup() {
    section "OpenShip first-run setup"

    echo
    echo -e "${BOLD}Selected mode: ${INSTALL_MODE^^}${NC}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        echo "OpenShip will be started in Bare mode."
        echo
        echo "No Docker containers will be created by this installer."
    else
        echo "OpenShip will be started using Docker."
    fi

    echo
    echo "The official OpenShip setup will ask for:"
    echo
    echo "  - Administrator name"
    echo "  - Administrator email"
    echo "  - Administrator password"
    echo "  - Instance visibility"
    echo "  - Domain / HTTPS configuration"
    echo

    echo -e "${YELLOW}Do not close this terminal during setup.${NC}"
    echo

    read -r -p "Press ENTER to start OpenShip..."

    # Always use the guided wizard so OpenShip creates the admin account
    # and prints the login URL. Bare vs. Compose is determined by whether
    # Docker was installed on this control-plane host.
    openship
}

# ------------------------------------------------------------------------------
# Post-install
# ------------------------------------------------------------------------------

post_install_checks() {
    section "Post-install verification"

    echo
    log "OpenShip status:"
    openship status || true

    echo

    if [[ "$INSTALL_MODE" == "standard" ]]; then
        log "Docker containers:"
        docker ps --format \
            'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
    fi

    echo
    log "Memory:"
    free -h

    echo
    log "Disk:"
    df -h /

    echo
    log "Swap:"
    swapon --show || true

    echo
    log "Listening ports:"
    ss -lntp || true

    echo
    log "Firewall:"
    ufw status verbose || true

    echo
    log "Fail2ban:"
    fail2ban-client status sshd 2>/dev/null || true
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------

print_summary() {
    section "Installation complete"

    echo
    echo -e "${BOLD}OpenShip Control Plane${NC}"
    echo
    echo "Installation mode:"
    echo "  ${INSTALL_MODE}"
    echo
    echo "Hostname:"
    echo "  ${HOSTNAME_INPUT}"
    echo
    echo "Timezone:"
    echo "  ${TIMEZONE_INPUT}"
    echo
    echo "SSH:"
    echo "  Port: ${SSH_PORT_INPUT}"
    echo "  User: ${ADMIN_USER_INPUT}"
    echo
    echo "Firewall:"
    echo "  UFW: ${ENABLE_UFW}"
    echo
    echo "Fail2ban:"
    echo "  SSH: ${ENABLE_FAIL2BAN}"
    echo
    echo "Swap:"
    echo "  2 GB: ${ENABLE_SWAP}"
    echo
    echo "Installer state:"
    echo "  ${STATE_FILE}"
    echo
    echo "Installer log:"
    echo "  ${LOG_FILE}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        echo -e "${GREEN}OpenShip is configured in BARE mode.${NC}"
    else
        echo -e "${GREEN}OpenShip is configured in STANDARD Docker mode.${NC}"
    fi

    echo
    echo "Next step:"
    echo "  Add the first deployment server from OpenShip."
    echo
    echo "This VPS should remain a Control Plane."
    echo "Do not deploy Laravel/Filament applications here."
    echo
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {

    clear || true

    echo
    echo -e "${BOLD}${CYAN}"
    echo "============================================================"
    echo "        OpenShip Control Plane Installer"
    echo "        Version ${SCRIPT_VERSION}"
    echo "============================================================"
    echo -e "${NC}"

    echo
    echo "Supported OS: Ubuntu 24.04 LTS"
    echo

    require_root

    check_os
    check_architecture
    check_resources

    select_installation_mode

    collect_configuration

    configure_hostname
    configure_timezone

    install_base_packages

    configure_swap
    configure_admin_user
    configure_ssh

    configure_ufw
    configure_fail2ban
    configure_unattended_upgrades

    install_docker
    configure_docker

    prepare_runtime_for_openship

    install_openship_cli
    preflight_openship

    run_openship_setup

    post_install_checks
    print_summary
}

main "$@"