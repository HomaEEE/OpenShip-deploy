#!/usr/bin/env bash

# ==============================================================================
# OpenShip Interactive Installer
# ==============================================================================
#
# Supported:
#   Ubuntu 24.04 LTS (amd64 / arm64)
#
# Workflow:
#   1. Automated server pre-hardening & tuning (swap, sysctl, journald, limits).
#   2. Automated firewall (UFW) & security (Fail2ban, unattended upgrades).
#   3. Docker Engine & Compose plugin installation.
#   4. Downloads and installs official OpenShip CLI from openship.io.
#   5. Hands over 100% interactive control to the official OpenShip setup wizard.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install-interactive.sh | sudo bash
#   or:
#   sudo ./install-interactive.sh
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly OPENSHIP_INSTALL_URL="https://get.openship.io"
readonly LOG_FILE="/var/log/openship-interactive-install.log"

readonly MIN_RAM_MB=768
readonly RECOMMENDED_RAM_MB=2048
readonly MIN_DISK_GB=10

# ------------------------------------------------------------------------------
# Colors & Dimensions
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    BOLD=''
    DIM=''
    NC=''
fi

_TW="$(tput cols 2>/dev/null || echo 60)"

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

exec > >(tee -a "$LOG_FILE") 2>&1

log() {
    echo -e "  ${BLUE}·${NC} $*"
}

success() {
    echo -e "  ${GREEN}✓${NC} $*"
}

warn() {
    echo -e "  ${YELLOW}⚠${NC}  $*"
}

error() {
    echo -e "  ${RED}✗${NC} $*" >&2
}

die() {
    echo
    error "$*"
    echo -e "  ${DIM}Log: ${LOG_FILE}${NC}"
    echo
    exit 1
}

section() {
    local title=" $* "
    local width=$(( _TW < 72 ? _TW : 72 ))
    local pad=$(( (width - ${#title} - 2) / 2 ))
    local line
    printf -v line '%*s' "$width" ''
    line="${line// /─}"
    local prefix="${line:0:$pad}"
    local suffix="${line:0:$(( width - pad - ${#title} ))}"
    echo
    echo -e "${BOLD}${CYAN}${prefix}${title}${suffix}${NC}"
    echo
}

run_task() {
    local msg="$1"
    shift
    local pid i=0
    local frames=(
        "[■         ]"
        "[■■        ]"
        "[■■■       ]"
        "[ ■■■      ]"
        "[  ■■■     ]"
        "[   ■■■    ]"
        "[    ■■■   ]"
        "[     ■■■  ]"
        "[      ■■■ ]"
        "[       ■■■]"
        "[        ■■]"
        "[         ■]"
    )

    ("$@") >> "$LOG_FILE" 2>&1 &
    pid=$!

    if [[ -e /dev/tty && -w /dev/tty ]]; then
        while kill -0 "$pid" 2>/dev/null; do
            printf "\r  ${CYAN}%s${NC} %s..." "${frames[i]}" "$msg" >/dev/tty 2>/dev/null || break
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
        wait "$pid"
        local status=$?
        if (( status == 0 )); then
            printf "\r\033[K  ${GREEN}✔${NC} %s\n" "$msg" >/dev/tty 2>/dev/null || success "$msg"
        else
            printf "\r\033[K  ${RED}✖${NC} %s (failed, exit %d)\n" "$msg" "$status" >/dev/tty 2>/dev/null || error "$msg failed"
            return "$status"
        fi
    else
        log "${msg}..."
        wait "$pid"
        local status=$?
        if (( status == 0 )); then
            success "$msg"
        else
            error "$msg (failed, exit $status)"
            return "$status"
        fi
    fi
}

# ------------------------------------------------------------------------------
# Error Handling
# ------------------------------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_no=$1

    echo
    error "Pre-configuration failed."
    error "Line: ${line_no}"
    error "Exit code: ${exit_code}"
    error "Log: ${LOG_FILE}"
    echo

    exit "$exit_code"
}

trap 'on_error ${LINENO}' ERR

# ------------------------------------------------------------------------------
# Helpers & Checks
# ------------------------------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_root() {
    if [[ "$EUID" -ne 0 ]]; then
        die "Run this installer as root or with sudo."
    fi
}

check_os() {
    section "Operating system"

    [[ -f /etc/os-release ]] ||
        die "/etc/os-release not found."

    # shellcheck disable=SC1091
    source /etc/os-release

    if [[ "${ID:-}" != "ubuntu" ]]; then
        die "Ubuntu is required. Detected: ${ID:-unknown}"
    fi

    local major_ver="${VERSION_ID%%.*}"
    if ! [[ "$major_ver" =~ ^[0-9]+$ ]] || (( major_ver < 22 )); then
        die "Ubuntu 22+ or 24 LTS required (detected: Ubuntu ${VERSION_ID:-unknown})."
    fi

    success "Ubuntu ${VERSION_ID:-unknown} verified."
}

check_architecture() {
    section "Architecture"

    local arch
    arch="$(dpkg --print-architecture)"

    case "$arch" in
        amd64|arm64)
            success "Architecture: ${arch}"
            ;;
        *)
            die "Unsupported architecture: ${arch}. OpenShip requires amd64 or arm64."
            ;;
    esac
}

detect_resources() {
    RAM_MB="$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)"
    DISK_GB="$(df -BG / | awk 'NR==2 {gsub("G","",$4); print $4}')"
    CPU_COUNT="$(nproc)"
}

check_resources() {
    section "System resources"

    detect_resources

    echo "RAM:         ${RAM_MB} MB"
    echo "Minimum:     ${MIN_RAM_MB} MB"
    echo "Recommended: ${RECOMMENDED_RAM_MB} MB"
    echo "CPU cores:   ${CPU_COUNT}"
    echo "Disk:        ${DISK_GB} GB free"
    echo

    if (( RAM_MB < MIN_RAM_MB )); then
        die "At least ${MIN_RAM_MB} MiB RAM is required. Detected: ${RAM_MB} MB."
    fi

    if (( DISK_GB < MIN_DISK_GB )); then
        die "At least ${MIN_DISK_GB} GB free disk space is required."
    fi

    success "Resource check passed."
}

detect_ssh_port() {
    local port=""

    if command_exists sshd; then
        port="$(sshd -T 2>/dev/null | grep -i '^port ' | awk '{print $2}' | head -n1 || true)"
    fi

    if [[ -z "$port" && -n "${SSH_CLIENT:-${SSH_CONNECTION:-}}" ]]; then
        local raw="${SSH_CLIENT:-${SSH_CONNECTION:-}}"
        port="$(echo "$raw" | awk '{print $3}')"
    fi

    if [[ -z "$port" && -f /etc/ssh/sshd_config ]]; then
        port="$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config | awk '{print $2}' | tail -n1 || true)"
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] || (( port < 1 || port > 65535 )); then
        port="22"
    fi

    echo "$port"
}

# ------------------------------------------------------------------------------
# System Packages & Updates
# ------------------------------------------------------------------------------

install_and_update_packages() {
    section "System packages & update"

    export DEBIAN_FRONTEND=noninteractive

    run_task "Updating package lists" apt-get update -qq

    run_task "Upgrading system packages" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    run_task "Installing base dependencies" apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        git \
        jq \
        unzip \
        rsync \
        btop \
        nano \
        lsof \
        procps \
        dnsutils \
        openssl \
        ufw \
        fail2ban \
        unattended-upgrades \
        systemd-timesyncd

    run_task "Cleaning up unused packages" bash -c "apt-get autoremove -y -qq && apt-get clean -qq"
}

# ------------------------------------------------------------------------------
# System Tuning
# ------------------------------------------------------------------------------

optimize_system() {
    section "System tuning"

    log "Enabling systemd-timesyncd..."
    systemctl enable --now systemd-timesyncd 2>/dev/null || true

    log "Configuring file descriptor limits (nofile 65535)..."
    cat > /etc/security/limits.d/99-openship.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

    log "Configuring systemd journal limit (SystemMaxUse=200M)..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-openship.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
    systemctl restart systemd-journald 2>/dev/null || true
    sysctl --system >> "$LOG_FILE" 2>&1 || true

    success "System tuning applied."
}

# ------------------------------------------------------------------------------
# Swap
# ------------------------------------------------------------------------------

configure_swap() {
    section "Swap"

    if swapon --show | grep -q .; then
        success "Swap is already active:"
        swapon --show
        return
    fi

    local swap_gb=2
    if (( RAM_MB > 2048 )); then
        swap_gb=4
    fi

    log "Configuring ${swap_gb} GB swapfile automatically..."

    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${swap_gb}G" /swapfile 2>/dev/null; then
            warn "fallocate failed, creating swapfile with dd..."
            dd if=/dev/zero of=/swapfile bs=1M count="$((swap_gb * 1024))" status=none
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
    fi

    if ! swapon /swapfile 2>/dev/null; then
        warn "swapon failed (possibly container environment). Continuing without swap."
        return
    fi

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    cat > /etc/sysctl.d/99-openship-control.conf <<'EOF'
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF

    sysctl --system >/dev/null 2>&1 || true

    success "${swap_gb} GB swap configured and enabled."
}

# ------------------------------------------------------------------------------
# Firewall & Security
# ------------------------------------------------------------------------------

configure_ufw() {
    section "Firewall (UFW)"

    SSH_PORT="$(detect_ssh_port)"
    log "Active SSH port detected: ${SSH_PORT}"

    # Repair corrupted single quotes in UFW rule files left by prior failed attempts
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        if [[ -f "$f" ]]; then
            sed -i "s/Let's Encrypt/Lets Encrypt/g" "$f" 2>/dev/null || true
            sed -i "s/'s /s /g" "$f" 2>/dev/null || true
        fi
    done

    ufw default deny incoming >/dev/null 2>&1 || true
    ufw default allow outgoing >/dev/null 2>&1 || true

    ufw allow "${SSH_PORT}/tcp" comment "SSH" >/dev/null 2>&1 || \
        ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1 || \
        warn "Could not add SSH port ${SSH_PORT} to UFW."

    ufw allow 80/tcp comment "HTTP" >/dev/null 2>&1 || \
        ufw allow 80/tcp >/dev/null 2>&1 || \
        warn "Could not add 80/tcp to UFW."

    ufw allow 443/tcp comment "HTTPS" >/dev/null 2>&1 || \
        ufw allow 443/tcp >/dev/null 2>&1 || \
        warn "Could not add 443/tcp to UFW."

    if ufw --force enable >/dev/null 2>&1; then
        success "UFW enabled (ports: ${SSH_PORT}/tcp, 80/tcp, 443/tcp allowed)."
    else
        warn "Could not enable UFW (possibly container or missing kernel modules). Continuing."
    fi
}

configure_fail2ban() {
    section "Fail2ban"

    local ssh_port="${SSH_PORT:-22}"

    mkdir -p /etc/fail2ban/jail.d

    cat > /etc/fail2ban/jail.d/sshd-openship.local <<EOF
[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    success "Fail2ban enabled for SSH (port ${ssh_port})."
}

configure_unattended_upgrades() {
    section "Automatic security updates"

    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

    success "Unattended upgrades enabled."
}

# ------------------------------------------------------------------------------
# Docker Engine
# ------------------------------------------------------------------------------

install_docker() {
    section "Docker Engine"

    if command_exists docker; then
        success "Docker already installed: $(docker --version)"
        return
    fi

    run_task "Adding Docker repository" bash -c '
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        # shellcheck disable=SC1091
        source /etc/os-release
        cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-${VERSION_CODENAME}} stable
EOF
        apt-get update -qq
    '

    run_task "Installing Docker CE Engine" apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    run_task "Starting Docker daemon" systemctl enable --now docker
}

configure_docker() {
    if ! command_exists docker; then
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

    systemctl restart docker >/dev/null 2>&1 || true

    docker info >/dev/null 2>&1 || true

    success "Docker daemon configured with log rotation."
}

# ------------------------------------------------------------------------------
# OpenShip CLI & Handover
# ------------------------------------------------------------------------------

install_openship_cli() {
    section "OpenShip CLI"

    run_task "Downloading and installing OpenShip CLI from openship.io" bash -c "curl -fsSL '$OPENSHIP_INSTALL_URL' | sh"

    export PATH="/root/.openship/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

    if [[ -x "/root/.openship/bin/openship" ]]; then
        ln -sf "/root/.openship/bin/openship" "/usr/local/bin/openship"
    fi

    command_exists openship ||
        die "OpenShip CLI was not found after installation."

    success "OpenShip CLI installed: $(openship --version 2>/dev/null || true)"
}

handover_to_openship() {
    section "Handing over to OpenShip setup"

    echo
    echo -e "  ${BOLD}${GREEN}✔ Server pre-configuration and hardening complete!${NC}"
    echo
    echo -e "  ${CYAN}Starting official OpenShip setup wizard with full interactive control...${NC}"
    echo -e "  ${DIM}(Press Ctrl+C at any time if you wish to exit)${NC}"
    echo
    sleep 2

    # Reconnect standard descriptors directly to /dev/tty for full TUI control
    if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]]; then
        exec </dev/tty >/dev/tty 2>/dev/tty
    fi

    exec openship
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------

main() {
    clear || true

    echo
    echo -e "${BOLD}${CYAN}"
    echo   "  ╔══════════════════════════════════════════════════════╗"
    echo   "  ║                                                      ║"
    printf "  ║   ⚓  %-46s  ║\n" "OpenShip Interactive Installer"
    printf "  ║   %-48s  ║\n" "Server Prep + Upstream Wizard  ·  v${SCRIPT_VERSION}"
    echo   "  ║                                                      ║"
    echo   "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    require_root

    check_os
    check_architecture
    check_resources

    install_and_update_packages
    optimize_system

    configure_swap
    configure_ufw
    configure_fail2ban
    configure_unattended_upgrades

    install_docker
    configure_docker

    install_openship_cli

    handover_to_openship
}

main "$@"
