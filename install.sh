#!/usr/bin/env bash

# ==============================================================================
# OpenShip Control Plane Installer
# ==============================================================================
#
# Supported:
#   Ubuntu 24.04 LTS
#
# Installation modes:
#   BARE      - OpenShip Control Plane (lightweight Node process, embedded DB)
#               Optionally with OpenShip Edge (:80/:443 via Docker)
#   STANDARD  - Full OpenShip Docker Compose stack
#
# The installer automatically detects RAM and recommends the appropriate mode.
#
# Usage:
#   sudo ./install.sh
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.4.0"
readonly OPENSHIP_INSTALL_URL="https://get.openship.io"

readonly LOG_FILE="/var/log/openship-control-install.log"
readonly STATE_DIR="/etc/openship-control"
readonly STATE_FILE="${STATE_DIR}/install.conf"

# Resource thresholds
# Bare mode is intentionally allowed on small VPS instances.
# 768 MiB is the hard minimum; 2 GiB is recommended for Standard/Docker.
readonly MIN_RAM_MB=768
readonly LOW_RAM_MB=1024
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
        read -r -p "$prompt [Y/n]: " answer </dev/tty
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N]: " answer </dev/tty
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

    read -r -p "$prompt [$default]: " value </dev/tty

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

    echo "RAM:         ${RAM_MB} MB"
    echo "Minimum:     ${MIN_RAM_MB} MB (Bare Control Plane)"
    echo "Recommended: ${RECOMMENDED_RAM_MB} MB (Standard Docker Stack)"
    echo "CPU cores:   ${CPU_COUNT}"
    echo "Disk:        ${DISK_GB} GB free"
    echo

    if (( RAM_MB < MIN_RAM_MB )); then
        die "At least ${MIN_RAM_MB} MiB RAM is required. Detected: ${RAM_MB} MB."
    elif (( RAM_MB < LOW_RAM_MB )); then
        warn "Low-memory VPS detected: ${RAM_MB} MB RAM (supported with warning)."
        warn "Bare mode is required. Standard Docker mode is not recommended."
    elif (( RAM_MB < RECOMMENDED_RAM_MB )); then
        success "RAM: ${RAM_MB} MB (supported for Bare Control Plane)."
    else
        success "RAM is sufficient for Standard mode (${RAM_MB} MB)."
    fi

    if (( DISK_GB < MIN_DISK_GB )); then
        die "At least ${MIN_DISK_GB} GB free disk space is required."
    fi

    success "Resource check passed."
}

# ------------------------------------------------------------------------------
# Installation mode selection
# ------------------------------------------------------------------------------

select_installation_mode() {
    section "OpenShip installation mode"

    echo "Detected resources:"
    echo "  RAM:  ${RAM_MB} MB"
    echo "  CPU:  ${CPU_COUNT}"
    echo "  Disk: ${DISK_GB} GB"
    echo

    if (( RAM_MB < RECOMMENDED_RAM_MB )); then

        echo -e "${BOLD}${YELLOW}"
        echo "RECOMMENDATION FOR LOW-MEMORY VPS (< 2 GB RAM)"
        echo "----------------------------------------------------------------"
        echo "This server will act as an OpenShip Control Plane."
        echo "Bare mode runs OpenShip as a lightweight native service with"
        echo "an embedded database (avoiding Postgres & Redis containers)."
        echo "OpenShip Edge (:80/:443) will be used to route control plane traffic."
        echo -e "${NC}"

        echo "Choose installation mode:"
        echo
        echo "  1) Bare (Recommended)"
        echo "     Lightweight Control Plane (Node process + embedded DB)."
        echo "     Optionally with Edge on :80/:443."
        echo
        echo "  2) Standard"
        echo "     Full OpenShip Docker Compose stack (Postgres + Redis)."
        echo "     Requires more RAM."
        echo
        echo "  3) Cancel"
        echo

        while true; do
            read -r -p "Select [1]: " choice </dev/tty
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
        echo "     Full OpenShip Docker Compose stack."
        echo "     Recommended for 2+ GB RAM."
        echo
        echo "  2) Bare"
        echo "     Lightweight Control Plane (Node process + embedded DB)."
        echo
        echo "  3) Cancel"
        echo

        while true; do
            read -r -p "Select [1]: " choice </dev/tty
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
        success "Selected mode: BARE Control Plane"
        log "OpenShip daemon will run as a native service with embedded database."
    else
        success "Selected mode: STANDARD Docker Stack"
        log "OpenShip will run using Docker Compose."
    fi
}

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------

collect_bare_openship_credentials() {
    section "OpenShip Control Plane Credentials & Domain"

    echo "Configure administrator credentials and reachability for OpenShip:"
    echo

    OPENSHIP_ADMIN_NAME_INPUT="$(ask_default "OpenShip administrator name" "$ADMIN_USER_INPUT")"

    while true; do
        OPENSHIP_ADMIN_EMAIL_INPUT="$(ask_default "OpenShip administrator email" "")"
        if [[ "$OPENSHIP_ADMIN_EMAIL_INPUT" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
            break
        fi
        warn "Enter a valid email address."
    done

    while true; do
        read -r -s -p "OpenShip administrator password: " OPENSHIP_ADMIN_PASSWORD_INPUT </dev/tty
        echo
        read -r -s -p "Repeat OpenShip administrator password: " OPENSHIP_ADMIN_PASSWORD_CONFIRM </dev/tty
        echo

        if [[ -z "$OPENSHIP_ADMIN_PASSWORD_INPUT" ]]; then
            warn "Password cannot be empty."
            continue
        fi

        if (( ${#OPENSHIP_ADMIN_PASSWORD_INPUT} < 8 )); then
            warn "Password must contain at least 8 characters."
            continue
        fi

        if [[ "$OPENSHIP_ADMIN_PASSWORD_INPUT" != "$OPENSHIP_ADMIN_PASSWORD_CONFIRM" ]]; then
            warn "Passwords do not match."
            continue
        fi

        break
    done

    unset OPENSHIP_ADMIN_PASSWORD_CONFIRM

    OPENSHIP_DOMAIN_KIND="none"
    OPENSHIP_PUBLIC_URL=""
    OPENSHIP_HOST=""
    OPENSHIP_EDGE_ENABLED="false"

    echo
    echo "OpenShip instance reachability:"
    echo
    echo "  1) Public HTTPS domain (Recommended)"
    echo "     Use OpenShip Edge (:80/:443) to route your domain (e.g. os.example.com)"
    echo "     directly to the OpenShip dashboard."
    echo
    echo "  2) Local / private"
    echo "     Dashboard stays on internal port 3001 without public ingress."
    echo "     Cloudflare Tunnel or custom VPN can be configured later."
    echo
    echo "  3) Cancel"
    echo

    while true; do
        read -r -p "Select [1]: " reachability </dev/tty
        reachability="${reachability:-1}"
        case "$reachability" in
            1)
                OPENSHIP_DOMAIN_KIND="byo"
                OPENSHIP_EDGE_ENABLED="true"
                while true; do
                    OPENSHIP_HOST="$(ask_default "OpenShip domain (e.g. os.example.com)" "")"
                    if [[ "$OPENSHIP_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
                        break
                    fi
                    warn "Enter a valid DNS hostname, for example os.example.com."
                done
                OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"
                break
                ;;
            2)
                OPENSHIP_DOMAIN_KIND="none"
                OPENSHIP_EDGE_ENABLED="false"
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

    echo

    # ------------------------------------------------------------------
    # Host control mode
    # ------------------------------------------------------------------
    echo -e "${BOLD}OpenShip Host Control Mode${NC}"
    echo
    echo "OpenShip can optionally manage the Control VPS itself as a server."
    echo "This affects whether the built-in terminal (in the dashboard) can"
    echo "connect to this VPS and whether OpenShip lists it in the server view."
    echo
    echo "  1) Full control (Recommended for most setups)"
    echo "     OpenShip registers this VPS as a managed server."
    echo "     Dashboard terminal → Control VPS works."
    echo "     OpenShip may perform host-level operations (SSH key, process mgmt)."
    echo "     This is how version 2.1.2 worked (last known-good version)."
    echo
    echo "  2) Strict isolation (--no-host-control)"
    echo "     OpenShip does NOT register this VPS as a server."
    echo "     Dashboard terminal → Control VPS is BLOCKED."
    echo "     No host-level SSH keys or daemons are created."
    echo "     Use if this VPS must be invisible to the OpenShip server list."
    echo

    OPENSHIP_NO_HOST_CONTROL="false"

    while true; do
        read -r -p "Select [1]: " hc_choice </dev/tty
        hc_choice="${hc_choice:-1}"
        case "$hc_choice" in
            1)
                OPENSHIP_NO_HOST_CONTROL="false"
                success "Host control: ENABLED — terminal to Control VPS will work."
                break
                ;;
            2)
                OPENSHIP_NO_HOST_CONTROL="true"
                warn "Host control: DISABLED — dashboard terminal to this VPS will not work."
                break
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    done

    echo
    success "OpenShip Control Plane parameters collected."
}

collect_configuration() {
    section "Control Plane host configuration"

    # ------------------------------------------------------------------
    # Resume from previous installation state
    # ------------------------------------------------------------------
    if [[ -f "$STATE_FILE" ]]; then
        echo
        echo -e "${YELLOW}A previous installation state was found at:${NC}"
        echo "  ${STATE_FILE}"
        echo

        if ask_yes_no "Resume using previously entered values?" "Y"; then
            # shellcheck disable=SC1090
            source "$STATE_FILE"

            # Map state file keys back to input variables
            HOSTNAME_INPUT="${HOSTNAME:-openship-control}"
            TIMEZONE_INPUT="${TIMEZONE:-UTC}"
            SSH_PORT_INPUT="${SSH_PORT:-22}"
            ADMIN_USER_INPUT="${ADMIN_USER:-openship}"
            ENABLE_UFW="${ENABLE_UFW:-true}"
            ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
            ENABLE_SWAP="${ENABLE_SWAP:-true}"
            SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
            OPENSHIP_ADMIN_NAME_INPUT="${OPENSHIP_ADMIN_NAME:-}"
            OPENSHIP_ADMIN_EMAIL_INPUT="${OPENSHIP_ADMIN_EMAIL:-}"
            OPENSHIP_DOMAIN_KIND="${OPENSHIP_DOMAIN_KIND:-none}"
            OPENSHIP_HOST="${OPENSHIP_HOST:-}"
            OPENSHIP_PUBLIC_URL="${OPENSHIP_PUBLIC_URL:-}"
            OPENSHIP_EDGE_ENABLED="${OPENSHIP_EDGE_ENABLED:-false}"
            OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-false}"

            echo
            echo "Loaded values:"
            echo "  Hostname:   ${HOSTNAME_INPUT}"
            echo "  Timezone:   ${TIMEZONE_INPUT}"
            echo "  SSH port:   ${SSH_PORT_INPUT}"
            echo "  Admin user: ${ADMIN_USER_INPUT}"
            echo "  Mode:       ${INSTALL_MODE}"
            echo "  Domain:     ${OPENSHIP_HOST:-none}"
            echo

            # Password must always be re-entered (never stored)
            if [[ "$INSTALL_MODE" == "bare" ]]; then
                echo -e "${YELLOW}Admin password must be entered again (never stored).${NC}"
                echo

                while true; do
                    read -r -s -p "OpenShip administrator password: " OPENSHIP_ADMIN_PASSWORD_INPUT </dev/tty
                    echo
                    read -r -s -p "Repeat password: " OPENSHIP_ADMIN_PASSWORD_CONFIRM </dev/tty
                    echo

                    if [[ -z "$OPENSHIP_ADMIN_PASSWORD_INPUT" ]]; then
                        warn "Password cannot be empty."
                        continue
                    fi
                    if (( ${#OPENSHIP_ADMIN_PASSWORD_INPUT} < 8 )); then
                        warn "Password must be at least 8 characters."
                        continue
                    fi
                    if [[ "$OPENSHIP_ADMIN_PASSWORD_INPUT" != "$OPENSHIP_ADMIN_PASSWORD_CONFIRM" ]]; then
                        warn "Passwords do not match."
                        continue
                    fi
                    break
                done

                unset OPENSHIP_ADMIN_PASSWORD_CONFIRM
            fi

            success "Configuration loaded from state file."
            return
        fi

        echo
    fi

    echo "This VPS will act as the OpenShip Control Plane."
    echo "Production applications (Laravel/CRM) should NOT be deployed here."
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

    # ------------------------------------------------------------------
    # Timezone — interactive region/city selector
    # ------------------------------------------------------------------
    _select_timezone() {
        local auto_tz
        auto_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"

        # Alias legacy names
        case "${auto_tz}" in
            "Europe/Kiev") auto_tz="Europe/Kyiv" ;;
        esac

        local default_tz="${auto_tz:-UTC}"

        echo
        echo "Timezone selection:"
        echo "  Detected system timezone: ${default_tz}"
        echo
        echo "  1) Use detected timezone (${default_tz})"
        echo "  2) Select from list by region"
        echo "  3) Enter manually"
        echo

        local tz_choice
        read -r -p "Select [1]: " tz_choice </dev/tty
        tz_choice="${tz_choice:-1}"

        case "$tz_choice" in
            1)
                TIMEZONE_INPUT="$default_tz"
                ;;
            2)
                # Show unique regions
                local regions
                regions="$(timedatectl list-timezones 2>/dev/null | cut -d/ -f1 | sort -u)"
                echo
                echo "Available regions:"
                echo "$regions" | nl -w3 -s') '
                echo
                local region_choice
                read -r -p "Region number: " region_choice </dev/tty
                local region
                region="$(echo "$regions" | sed -n "${region_choice}p")"

                if [[ -z "$region" ]]; then
                    warn "Invalid region. Using ${default_tz}."
                    TIMEZONE_INPUT="$default_tz"
                else
                    # Show cities in chosen region
                    local cities
                    cities="$(timedatectl list-timezones 2>/dev/null | grep "^${region}/" | sed "s|^${region}/||")"
                    echo
                    echo "Cities in ${region}:"
                    echo "$cities" | nl -w3 -s') '
                    echo
                    local city_choice
                    read -r -p "City number: " city_choice </dev/tty
                    local city
                    city="$(echo "$cities" | sed -n "${city_choice}p")"

                    if [[ -z "$city" ]]; then
                        warn "Invalid city. Using ${default_tz}."
                        TIMEZONE_INPUT="$default_tz"
                    else
                        TIMEZONE_INPUT="${region}/${city}"
                    fi
                fi
                ;;
            3)
                local manual_tz
                manual_tz="$(ask_default "Enter timezone (e.g. Europe/Kyiv)" "$default_tz")"
                # Alias legacy names
                case "$manual_tz" in
                    "Europe/Kiev") manual_tz="Europe/Kyiv" ;;
                    "Asia/Calcutta") manual_tz="Asia/Kolkata" ;;
                esac
                TIMEZONE_INPUT="$manual_tz"
                ;;
            *)
                TIMEZONE_INPUT="$default_tz"
                ;;
        esac

        # Validate
        if ! timedatectl list-timezones 2>/dev/null | grep -Fxq "$TIMEZONE_INPUT"; then
            warn "Timezone '${TIMEZONE_INPUT}' not recognised. Falling back to UTC."
            TIMEZONE_INPUT="UTC"
        fi
    }
    _select_timezone

    while true; do
        SSH_PORT_INPUT="$(ask_default "SSH port" "22")"

        if valid_ssh_port "$SSH_PORT_INPUT"; then
            break
        fi

        warn "Invalid SSH port."
    done

    ADMIN_USER_INPUT="$(ask_default "Linux administrator" "openship")"

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

    local rec_swap=2
    if (( RAM_MB > 2048 )); then
        rec_swap=4
    fi

    echo
    echo "SWAP configuration:"
    echo "  Recommended swap for ${RAM_MB} MB RAM: ${rec_swap} GB"
    echo

    if ask_yes_no "Configure ${rec_swap} GB swap?" "Y"; then
        ENABLE_SWAP="true"
        SWAP_SIZE_GB="$rec_swap"
    else
        ENABLE_SWAP="false"
        SWAP_SIZE_GB=0
    fi

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        collect_bare_openship_credentials
    fi

    save_configuration
}

save_configuration() {
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"

    cat > "$STATE_FILE" <<EOF
INSTALL_MODE=${INSTALL_MODE}
OPENSHIP_ROLE=control
OPENSHIP_HOST_CONTROL=false
HOSTNAME=${HOSTNAME_INPUT}
TIMEZONE=${TIMEZONE_INPUT}
SSH_PORT=${SSH_PORT_INPUT}
ADMIN_USER=${ADMIN_USER_INPUT}
ENABLE_UFW=${ENABLE_UFW}
ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN}
ENABLE_SWAP=${ENABLE_SWAP}
SWAP_SIZE_GB=${SWAP_SIZE_GB:-2}
OPENSHIP_ADMIN_NAME=${OPENSHIP_ADMIN_NAME_INPUT:-}
OPENSHIP_ADMIN_EMAIL=${OPENSHIP_ADMIN_EMAIL_INPUT:-}
OPENSHIP_DOMAIN_KIND=${OPENSHIP_DOMAIN_KIND:-none}
OPENSHIP_HOST=${OPENSHIP_HOST:-}
OPENSHIP_PUBLIC_URL=${OPENSHIP_PUBLIC_URL:-}
OPENSHIP_EDGE_ENABLED=${OPENSHIP_EDGE_ENABLED:-false}
OPENSHIP_NO_HOST_CONTROL=${OPENSHIP_NO_HOST_CONTROL:-false}
EOF

    chmod 600 "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# Hostname & Timezone
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

configure_timezone() {
    section "Timezone"

    if timedatectl set-timezone "$TIMEZONE_INPUT" 2>/dev/null; then
        success "Timezone: ${TIMEZONE_INPUT}"
    else
        warn "Failed to set timezone '${TIMEZONE_INPUT}'. Falling back to UTC."
        TIMEZONE_INPUT="UTC"
        timedatectl set-timezone UTC || true
        warn "Timezone set to UTC."
    fi
}

# ------------------------------------------------------------------------------
# Base packages
# ------------------------------------------------------------------------------

install_base_packages() {
    section "Base packages"

    export DEBIAN_FRONTEND=noninteractive

    log "Updating package lists..."
    apt-get update -qq >> "$LOG_FILE" 2>&1

    log "Installing base packages..."
    apt-get install -y -qq \
        ca-certificates \
        curl \
        gnupg \
        git \
        jq \
        unzip \
        rsync \
        btop \
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
        unattended-upgrades \
        systemd-timesyncd >> "$LOG_FILE" 2>&1

    apt-get autoremove -y -qq >> "$LOG_FILE" 2>&1

    success "Base packages installed."
}

# ------------------------------------------------------------------------------
# System update
# ------------------------------------------------------------------------------

update_system() {
    section "System update"

    log "Updating package lists..."
    apt-get update -qq >> "$LOG_FILE" 2>&1

    log "Upgrading system packages (this may take a few minutes)..."
    DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" >> "$LOG_FILE" 2>&1

    apt-get autoremove -y -qq >> "$LOG_FILE" 2>&1
    apt-get clean -qq >> "$LOG_FILE" 2>&1

    if [[ -f /var/run/reboot-required ]]; then
        warn "A system restart is recommended after kernel/library updates."
        warn "You can complete the OpenShip installation now and reboot afterward."
    fi

    success "System packages updated."
}

# ------------------------------------------------------------------------------
# System tuning
# ------------------------------------------------------------------------------

optimize_system() {
    section "System tuning"

    log "Enabling systemd-timesyncd time synchronization..."
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

    if [[ "$ENABLE_SWAP" != "true" || "${SWAP_SIZE_GB:-0}" -le 0 ]]; then
        warn "Swap disabled by configuration."
        return
    fi

    local swap_gb="${SWAP_SIZE_GB:-2}"
    log "Creating ${swap_gb} GB swapfile..."

    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${swap_gb}G" /swapfile 2>/dev/null; then
            warn "fallocate failed, creating swapfile with dd..."
            dd if=/dev/zero of=/swapfile bs=1M count="$((swap_gb * 1024))" status=progress
        fi
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

    success "${swap_gb} GB swap configured and enabled."
}

# ------------------------------------------------------------------------------
# Administrator user
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

    # OpenShip Edge (:80/:443) — only when Edge container is enabled.
    # In Private mode (no Edge), only SSH is exposed.
    if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        ufw allow 80/tcp \
            comment "OpenShip Edge HTTP (ACME + proxy)"

        ufw allow 443/tcp \
            comment "OpenShip Edge HTTPS"

        log "UFW: opened :80 (ACME challenge) and :443 (Edge TLS) for OpenShip Edge."
    else
        log "UFW: Private mode — :80/:443 NOT opened (no Edge container)."
    fi

    # IMPORTANT:
    # Dashboard :3001 and API :4000 are intentionally NOT exposed externally.
    # OpenShip Edge proxies directly to localhost:3001.

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
    section "Docker Engine"

    if [[ "$INSTALL_MODE" == "bare" && "${OPENSHIP_EDGE_ENABLED:-false}" != "true" ]]; then
        log "Private Bare mode selected without OpenShip Edge."
        log "Docker installation skipped."
        return
    fi

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        log "OpenShip Edge (:80/:443) container requires Docker Engine."
        log "Docker will run solely the openship-edge container (no production apps)."
    fi

    if command_exists docker; then
        success "Docker already installed: $(docker --version)"
        return
    fi

    log "Installing official Docker Engine..."
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

    apt-get update -qq >> "$LOG_FILE" 2>&1

    log "Installing Docker CE..."
    apt-get install -y -qq \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin >> "$LOG_FILE" 2>&1

    systemctl enable --now docker >> "$LOG_FILE" 2>&1

    docker --version
    docker compose version

    success "Docker Engine installed."
}

# ------------------------------------------------------------------------------
# Docker daemon
# ------------------------------------------------------------------------------

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

    systemctl restart docker

    docker info >/dev/null

    success "Docker daemon configured."
}

# ------------------------------------------------------------------------------
# Runtime mode enforcement
# ------------------------------------------------------------------------------

prepare_runtime_for_openship() {
    section "OpenShip runtime"

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if command_exists docker; then
            log "Docker is available for the OpenShip Edge container (:80/:443)."
            log "OpenShip Control Plane will run as a lightweight Bare process."
        fi

        success "Bare runtime selected: OpenShip will start with --bare --no-host-control."
        return
    fi

    command_exists docker ||
        die "Standard mode requires Docker."

    success "Standard runtime selected: OpenShip will use Docker Compose."
}

# ------------------------------------------------------------------------------
# OpenShip CLI
# ------------------------------------------------------------------------------

install_openship_cli() {
    section "OpenShip CLI"

    if command_exists openship; then
        success "OpenShip CLI already installed: $(openship --version || true)"
        return
    fi

    log "Installing official OpenShip CLI..."

    curl -fsSL "$OPENSHIP_INSTALL_URL" | sh

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

    success "Pre-flight checks passed."
}

# ------------------------------------------------------------------------------
# OpenShip setup
# ------------------------------------------------------------------------------

run_bare_openship_setup() {
    echo
    echo "Preparing OpenShip Bare service..."
    echo

    # Stop any existing or orphaned OpenShip instances and free ports
    if systemctl is-active --quiet openship 2>/dev/null; then
        log "Stopping active OpenShip systemd service..."
        systemctl stop openship 2>/dev/null || true
    fi
    if command_exists openship; then
        openship stop 2>/dev/null || true
    fi

    # Kill any processes locking the default and fallback OpenShip ports
    fuser -k 4000/tcp 3001/tcp 4001/tcp 3002/tcp 2>/dev/null || true

    # Reset stored ports cache so OpenShip always binds standard 4000/3001
    rm -f /root/.openship/ports.json

    export OPENSHIP_ADMIN_PASSWORD="$OPENSHIP_ADMIN_PASSWORD_INPUT"

    local -a args
    args=(
        up
        --bare
        --non-interactive
        --admin-email "$OPENSHIP_ADMIN_EMAIL_INPUT"
        --admin-name "$OPENSHIP_ADMIN_NAME_INPUT"
        --domain-kind "$OPENSHIP_DOMAIN_KIND"
    )

    # --no-host-control: prevents OpenShip from registering this VPS as a
    # managed server. Blocks dashboard terminal to Control VPS.
    # User chose this during configuration.
    if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
        args+=( --no-host-control )
        log "--no-host-control is ENABLED: Control VPS will not appear as a server."
    else
        log "--no-host-control is DISABLED: Control VPS terminal will be accessible."
    fi

    if [[ "$OPENSHIP_DOMAIN_KIND" == "byo" ]]; then
        # byo = Bring Your Own ingress (Cloudflare / reverse proxy handles TLS).
        # OpenShip seeds the domain with externalIngress=true, sslStatus=external.
        # Do NOT pass --edge takeover — that triggers Docker edge container routines.
        args+=(
            --hostname "$OPENSHIP_HOST"
            --public-url "$OPENSHIP_PUBLIC_URL"
        )
    fi

    log "Starting OpenShip Bare service with arguments:"
    echo "  openship ${args[*]}"
    echo

    openship "${args[@]}"

    unset OPENSHIP_ADMIN_PASSWORD
    unset OPENSHIP_ADMIN_PASSWORD_INPUT

    success "OpenShip Bare setup completed."
}

run_openship_setup() {
    section "OpenShip first-run setup"

    echo -e "${BOLD}Selected mode: ${INSTALL_MODE^^}${NC}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        echo "OpenShip will use the explicit --bare runtime mode with --no-host-control."
        echo "The interactive guided wizard will NOT be used."
        echo
        run_bare_openship_setup
        wait_for_api_healthy
        return
    fi

    echo "OpenShip will be started using Docker Compose."
    echo
    echo -e "${YELLOW}Do not close this terminal during setup.${NC}"
    echo

    read -r -p "Press ENTER to start OpenShip..." </dev/tty

    [[ -e /dev/tty ]] ||
        die "Interactive terminal /dev/tty is not available for OpenShip setup."

    echo
    log "Starting OpenShip interactive setup with direct TTY I/O..."
    echo

    openship </dev/tty >/dev/tty 2>/dev/tty
}

# ------------------------------------------------------------------------------
# API health-check & rollback
# ------------------------------------------------------------------------------

rollback_bare_openship() {
    echo
    warn "Rolling back OpenShip Bare service..."

    systemctl stop openship 2>/dev/null || true
    openship stop 2>/dev/null || true

    echo
    warn "Last 50 lines from openship logs:"
    echo "--------------------------------------"
    openship logs --tail 50 2>/dev/null || journalctl -u openship -n 50 --no-pager 2>/dev/null || true
    echo "--------------------------------------"
    echo

    die "OpenShip API did not become healthy. See logs above and ${LOG_FILE}."
}

wait_for_api_healthy() {
    if [[ "$INSTALL_MODE" != "bare" ]]; then
        return
    fi

    section "OpenShip API health-check"

    local api_port=4000
    local retries=30
    local interval=10
    local attempt=0

    log "Polling /api/health — up to $((retries * interval / 60)) minutes..."
    printf "      "

    while (( attempt < retries )); do
        attempt=$(( attempt + 1 ))

        if curl -fsS --max-time 5 "http://localhost:${api_port}/api/health" >/dev/null 2>&1; then
            echo  # newline after dots
            success "OpenShip API is healthy (attempt ${attempt}/${retries})."
            return
        fi

        printf "."
        sleep "$interval"
    done

    echo  # newline after dots

    rollback_bare_openship
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
    if command_exists docker; then
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
    echo "  ${SWAP_SIZE_GB:-2} GB: ${ENABLE_SWAP}"
    echo
    echo "Installer state:"
    echo "  ${STATE_FILE}"
    echo
    echo "Installer log:"
    echo "  ${LOG_FILE}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        echo -e "${GREEN}OpenShip is configured in BARE mode with --no-host-control.${NC}"
        if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
            echo -e "OpenShip Edge (:80/:443) routes: ${BOLD}${OPENSHIP_PUBLIC_URL}${NC}"
        fi
    else
        echo -e "${GREEN}OpenShip is configured in STANDARD Docker mode.${NC}"
    fi

    echo
    echo -e "${BOLD}${CYAN}Architecture Notice:${NC}"
    echo "  This VPS is strictly a Control Plane. Remote deployment servers"
    echo "  (e.g. for Laravel/CRM) must be added via 'openship server add'."
    echo "  This server is NEVER in the HTTP path of production applications."
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
    update_system
    optimize_system

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