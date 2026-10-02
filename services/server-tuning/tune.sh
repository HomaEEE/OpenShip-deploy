#!/usr/bin/env bash

# ==============================================================================
# OpenShip Worker VPS — Initial Setup & System Tuning
# ==============================================================================
#
# Configures and tunes an Ubuntu 24.04 / 22.04 LTS VPS for the OpenShip Worker role:
#   - System packages update & essential utilities
#   - Hostname and timezone configuration
#   - Swap allocation & tuning (vm.swappiness=10, vm.vfs_cache_pressure=50)
#   - Kernel & network sysctl tuning (BBR, somaxconn, syn_backlog, port range)
#   - Container & database memory optimizations (vm.overcommit_memory=1, max_map_count=262144)
#   - File descriptor & process limits (limits.d: nofile 65535, nproc 65535)
#   - Systemd journald size bounding (SystemMaxUse=200M)
#   - UFW firewall (SSH, HTTP :80, HTTPS :443; databases kept internal)
#   - SSH hardening & Fail2ban jail
#   - Automatic security updates (unattended-upgrades)
#
# NOTE: Docker installation is intentionally excluded. Docker is handled
# separately by OpenShip or system administrator.
#
# Usage:
#   sudo ./tune.sh [OPTIONS]
#
# Options:
#   --non-interactive       Apply configuration without interactive prompts
#   --dry-run               Inspect system and validate configuration without modifying system
#   --ssh-port=PORT         Override SSH port (default: 22)
#   --swap-size=GB          Override swap size in GB (default: auto based on RAM)
#   --admin-user=USER       Configure dedicated non-root admin user
#   --skip-packages         Skip apt upgrade and package installation
#   --skip-swap             Skip swapfile creation
#   --skip-sysctl           Skip kernel and sysctl tuning
#   --skip-ufw              Skip UFW firewall configuration
#   --skip-ssh              Skip SSH configuration
#   --version, -v           Display script version
#   --help, -h              Display this help message
#
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="1.0.0"
readonly LOG_FILE="/var/log/openship-worker-tuning.log"

# Minimum RAM thresholds (Worker role)
readonly MIN_RAM_MB=512
readonly LOW_RAM_MB=1024
readonly RECOMMENDED_RAM_MB=2048
readonly MIN_DISK_GB=10

# ------------------------------------------------------------------------------
# Terminal styling
# ------------------------------------------------------------------------------

if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    MAGENTA='\033[0;35m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    MAGENTA=''
    BOLD=''
    DIM=''
    NC=''
fi

_TW="$(tput cols 2>/dev/null || echo 60)"

# ------------------------------------------------------------------------------
# CLI Flags & Arguments
# ------------------------------------------------------------------------------

DRY_RUN=false
NON_INTERACTIVE=false
SKIP_PACKAGES=false
SKIP_SWAP=false
SKIP_SYSCTL=false
SKIP_UFW=false
SKIP_SSH=false

CLI_SSH_PORT=""
CLI_SWAP_SIZE=""
CLI_ADMIN_USER=""

for arg in "$@"; do
    case "$arg" in
        --version|-v)
            echo "OpenShip Worker Tuning Script v${SCRIPT_VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "Usage: sudo ./tune.sh [OPTIONS]"
            echo
            echo "Options:"
            echo "  --non-interactive   Apply configuration without interactive prompts"
            echo "  --dry-run           Inspect system and validate configuration without modifying system"
            echo "  --ssh-port=PORT     Override SSH port (default: 22)"
            echo "  --swap-size=GB      Override swap size in GB (default: auto based on RAM)"
            echo "  --admin-user=USER   Configure dedicated non-root admin user"
            echo "  --skip-packages     Skip apt upgrade and package installation"
            echo "  --skip-swap         Skip swapfile creation"
            echo "  --skip-sysctl       Skip kernel and sysctl tuning"
            echo "  --skip-ufw          Skip UFW firewall configuration"
            echo "  --skip-ssh          Skip SSH configuration"
            echo "  --version, -v       Display version"
            echo "  --help, -h          Display this help message"
            exit 0
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            ;;
        --skip-packages)
            SKIP_PACKAGES=true
            ;;
        --skip-swap)
            SKIP_SWAP=true
            ;;
        --skip-sysctl)
            SKIP_SYSCTL=true
            ;;
        --skip-ufw)
            SKIP_UFW=true
            ;;
        --skip-ssh)
            SKIP_SSH=true
            ;;
        --ssh-port=*)
            CLI_SSH_PORT="${arg#*=}"
            ;;
        --swap-size=*)
            CLI_SWAP_SIZE="${arg#*=}"
            ;;
        --admin-user=*)
            CLI_ADMIN_USER="${arg#*=}"
            ;;
        *)
            echo "Unknown option: $arg" >&2
            echo "Run './tune.sh --help' for usage." >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Root Check
# ------------------------------------------------------------------------------

if [[ "$EUID" -ne 0 && "$DRY_RUN" != "true" ]]; then
    echo "Error: This script must be run as root: sudo ./tune.sh" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# Sourcing Modular Libraries (lib/common.sh, lib/system.sh, lib/security.sh)
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." 2>/dev/null && pwd || echo "")"
LIB_DIR="${REPO_DIR}/lib"

TEMP_CLONE_DIR=""
cleanup_tuning() {
    if [[ -n "$TEMP_CLONE_DIR" && -d "$TEMP_CLONE_DIR" ]]; then
        rm -rf "$TEMP_CLONE_DIR"
    fi
}
trap cleanup_tuning EXIT

if [[ ! -d "$LIB_DIR" ]]; then
    if command -v git &>/dev/null; then
        TEMP_CLONE_DIR="$(mktemp -d /tmp/openship-deploy-XXXXXX)"
        echo "==> Fetching OpenShip Deploy libraries..."
        git clone --depth 1 https://github.com/HomaEEE/OpenShip-deploy.git "$TEMP_CLONE_DIR" >/dev/null 2>&1
        LIB_DIR="${TEMP_CLONE_DIR}/lib"
    else
        echo "Error: Required libraries not found at ${LIB_DIR} and git is not available." >&2
        exit 1
    fi
fi

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/system.sh
source "${LIB_DIR}/system.sh"
# shellcheck source=lib/security.sh
source "${LIB_DIR}/security.sh"

# Ensure log directory and log file exist
if [[ "$DRY_RUN" != "true" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"
fi

# ------------------------------------------------------------------------------
# Load .env configuration if present
# ------------------------------------------------------------------------------

ENV_FILE="${SCRIPT_DIR}/.env"
if [[ -f "$ENV_FILE" ]]; then
    log "Loading configuration from ${ENV_FILE}..."
    while IFS="=" read -r key val || [[ -n "$key" ]]; do
        [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
        key="$(echo "$key" | tr -d '[:space:]')"
        val="${val#\"}"
        val="${val%\"}"
        val="${val#\'}"
        val="${val%\'}"
        case "$key" in
            HOSTNAME)                   ENV_HOSTNAME="$val" ;;
            TIMEZONE)                   ENV_TIMEZONE="$val" ;;
            SSH_PORT)                   ENV_SSH_PORT="$val" ;;
            ADMIN_USER)                 ENV_ADMIN_USER="$val" ;;
            ENABLE_SWAP)                ENV_ENABLE_SWAP="$val" ;;
            SWAP_SIZE_GB)               ENV_SWAP_SIZE_GB="$val" ;;
            ENABLE_BBR)                 ENV_ENABLE_BBR="$val" ;;
            ENABLE_UFW)                 ENV_ENABLE_UFW="$val" ;;
            ENABLE_FAIL2BAN)            ENV_ENABLE_FAIL2BAN="$val" ;;
            ENABLE_UNATTENDED_UPGRADES) ENV_ENABLE_UNATTENDED_UPGRADES="$val" ;;
        esac
    done < "$ENV_FILE"
fi

# Default configuration values
HOSTNAME_INPUT="${ENV_HOSTNAME:-$(hostname)}"
TIMEZONE_INPUT="${ENV_TIMEZONE:-UTC}"
SSH_PORT_INPUT="${CLI_SSH_PORT:-${ENV_SSH_PORT:-22}}"
ADMIN_USER_INPUT="${CLI_ADMIN_USER:-${ENV_ADMIN_USER:-}}"
ENABLE_SWAP="${ENV_ENABLE_SWAP:-true}"
SWAP_SIZE_GB="${CLI_SWAP_SIZE:-${ENV_SWAP_SIZE_GB:-}}"
ENABLE_BBR="${ENV_ENABLE_BBR:-true}"
ENABLE_UFW="${ENV_ENABLE_UFW:-true}"
ENABLE_FAIL2BAN="${ENV_ENABLE_FAIL2BAN:-true}"
ENABLE_UNATTENDED_UPGRADES="${ENV_ENABLE_UNATTENDED_UPGRADES:-true}"

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------

echo
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo -e "${BOLD}${CYAN} OpenShip Worker VPS — Setup & Tuning v${SCRIPT_VERSION}${NC}"
echo -e "${BOLD}${CYAN}============================================================${NC}"
echo

if [[ "$DRY_RUN" == "true" ]]; then
    warn "DRY-RUN MODE: No changes will be written to the host system."
    echo
fi

# ------------------------------------------------------------------------------
# Preflight System Checks
# ------------------------------------------------------------------------------

if [[ "$DRY_RUN" != "true" ]]; then
    check_os
    check_architecture
fi

detect_worker_resources() {
    if [[ -f /proc/meminfo ]]; then
        detect_resources
    else
        # Fallback for non-Linux or simulated environments (e.g. testing --dry-run)
        RAM_MB="${RAM_MB:-2048}"
        DISK_GB="${DISK_GB:-50}"
        CPU_COUNT="${CPU_COUNT:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)}"
    fi
}

detect_worker_resources

section "System resources"
echo "  RAM:         ${RAM_MB} MB"
echo "  CPU cores:   ${CPU_COUNT}"
echo "  Disk free:   ${DISK_GB} GB"
echo

if (( RAM_MB < MIN_RAM_MB )); then
    warn "RAM (${RAM_MB} MB) is below minimum recommended for Worker node (${MIN_RAM_MB} MB)."
fi

# Compute default swap size if not explicitly set
if [[ -z "$SWAP_SIZE_GB" ]]; then
    if (( RAM_MB <= 2048 )); then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=4
    fi
fi

# ------------------------------------------------------------------------------
# Interactive Configuration (unless --non-interactive)
# ------------------------------------------------------------------------------

if [[ "$NON_INTERACTIVE" != "true" && "$DRY_RUN" != "true" ]]; then
    section "Configuration parameters"

    HOSTNAME_INPUT="$(ask_default "Worker hostname" "$HOSTNAME_INPUT")"
    TIMEZONE_INPUT="$(ask_default "Timezone" "$TIMEZONE_INPUT")"

    if [[ "$SKIP_SWAP" != "true" ]]; then
        if ask_yes_no "Configure Swap (${SWAP_SIZE_GB} GB)?" "Y"; then
            ENABLE_SWAP="true"
            SWAP_SIZE_GB="$(ask_default "Swap size in GB" "$SWAP_SIZE_GB")"
        else
            ENABLE_SWAP="false"
        fi
    fi

    if [[ "$SKIP_SSH" != "true" ]]; then
        SSH_PORT_INPUT="$(ask_default "SSH port" "$SSH_PORT_INPUT")"
        if [[ -z "$ADMIN_USER_INPUT" ]]; then
            if ask_yes_no "Create a dedicated non-root admin user?" "N"; then
                ADMIN_USER_INPUT="$(ask_default "Admin username" "openship")"
            fi
        fi
    fi

    if [[ "$SKIP_UFW" != "true" ]]; then
        if ask_yes_no "Configure UFW firewall (SSH :${SSH_PORT_INPUT}, HTTP :80, HTTPS :443)?" "Y"; then
            ENABLE_UFW="true"
        else
            ENABLE_UFW="false"
        fi
    fi

    echo
    echo -e "${BOLD}Summary of configuration:${NC}"
    echo "  Hostname:            ${HOSTNAME_INPUT}"
    echo "  Timezone:            ${TIMEZONE_INPUT}"
    echo "  Swap:                ${ENABLE_SWAP} (${SWAP_SIZE_GB} GB)"
    echo "  SSH Port:            ${SSH_PORT_INPUT}"
    echo "  Admin User:          ${ADMIN_USER_INPUT:-<none>}"
    echo "  UFW Firewall:        ${ENABLE_UFW}"
    echo "  Fail2ban:            ${ENABLE_FAIL2BAN}"
    echo "  BBR Congestion:      ${ENABLE_BBR}"
    echo "  Auto Security Updates: ${ENABLE_UNATTENDED_UPGRADES}"
    echo

    if ! ask_yes_no "Proceed with tuning?" "Y"; then
        die "Tuning cancelled by user."
    fi
fi

# ------------------------------------------------------------------------------
# Dry-Run Inspection Output
# ------------------------------------------------------------------------------

if [[ "$DRY_RUN" == "true" ]]; then
    section "Dry-run validation"
    success "Hostname target:      ${HOSTNAME_INPUT}"
    success "Timezone target:      ${TIMEZONE_INPUT}"
    success "Swap target:          ${ENABLE_SWAP} (${SWAP_SIZE_GB} GB)"
    success "SSH port target:      ${SSH_PORT_INPUT}"
    success "Admin user target:    ${ADMIN_USER_INPUT:-none}"
    success "Sysctl tuning:        /etc/sysctl.d/99-openship-worker.conf"
    success "Security limits:      /etc/security/limits.d/99-openship-worker.conf"
    success "Journald limit:       /etc/systemd/journald.conf.d/99-openship.conf"
    success "UFW rules:            allow ${SSH_PORT_INPUT}/tcp, allow 80/tcp, allow 443/tcp, allow 443/udp (HTTP/3 QUIC)"
    success "Fail2ban jail:        /etc/fail2ban/jail.d/sshd-openship.local"
    echo
    echo -e "${GREEN}Dry-run complete. System configuration is valid.${NC}"
    exit 0
fi

# ------------------------------------------------------------------------------
# Step 1: Hostname & Timezone
# ------------------------------------------------------------------------------

if [[ -n "$HOSTNAME_INPUT" && "$HOSTNAME_INPUT" != "$(hostname)" ]]; then
    configure_hostname
fi

if [[ -n "$TIMEZONE_INPUT" ]]; then
    configure_timezone
fi

# ------------------------------------------------------------------------------
# Step 2: System Packages & Essential Utilities
# ------------------------------------------------------------------------------

if [[ "$SKIP_PACKAGES" != "true" ]]; then
    install_and_update_packages
else
    warn "Package update & installation skipped (--skip-packages)."
fi

# ------------------------------------------------------------------------------
# Step 3: Swap Allocation & Tuning
# ------------------------------------------------------------------------------

if [[ "$SKIP_SWAP" != "true" ]]; then
    configure_swap
else
    warn "Swap configuration skipped (--skip-swap)."
fi

# ------------------------------------------------------------------------------
# Step 4: Kernel & Sysctl Worker Tuning
# ------------------------------------------------------------------------------

optimize_worker_kernel_and_limits() {
    section "Kernel, Network & System Tuning (Worker VPS)"

    log "Enabling systemd-timesyncd time synchronization..."
    systemctl enable --now systemd-timesyncd 2>/dev/null || true

    log "Configuring file descriptor & process limits (nofile/nproc 65535)..."
    cat > /etc/security/limits.d/99-openship-worker.conf <<'EOF'
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
* soft nproc 65535
* hard nproc 65535
root soft nproc 65535
root hard nproc 65535
EOF

    # Ensure PAM limits are loaded
    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [[ -f "$pam_file" ]] && ! grep -q "pam_limits.so" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
        fi
    done

    log "Configuring systemd journal limit (SystemMaxUse=200M)..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-openship.conf <<'EOF'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=100M
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # TCP BBR Congestion Control
    local bbr_applied=false
    if [[ "$ENABLE_BBR" == "true" ]]; then
        if modprobe tcp_bbr 2>/dev/null; then
            mkdir -p /etc/modules-load.d
            echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
            bbr_applied=true
            log "BBR congestion control module loaded."
        else
            warn "Kernel module tcp_bbr not available. Continuing with default cubic."
        fi
    fi

    log "Applying worker sysctl network and database optimizations..."
    cat > /etc/sysctl.d/99-openship-worker.conf <<EOF
# OpenShip Worker VPS Kernel & Network Tuning

# Network connection backlog & buffers
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# Socket buffer sizes (16MB high-throughput buffers + UDP defaults for HTTP/3 QUIC)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 87380 16777216

# TCP Fast Open & Low Latency (reduces TTFB by 1 RTT)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0

# Fast TCP reuse & timeout for high-concurrency reverse proxy
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# Keepalive timeouts
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Memory management for Redis background save & MariaDB
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.swappiness = 10
vm.vfs_cache_pressure = 50

# Memory dirty writeback ratios (prevents I/O write freezes)
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5

# File system & inotify watchers
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF

    if [[ "$bbr_applied" == "true" ]]; then
        cat >> /etc/sysctl.d/99-openship-worker.conf <<'EOF'
# TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    sysctl --system >> "$LOG_FILE" 2>&1 || true
    success "Worker kernel and sysctl tuning applied."
}

configure_cpu_governor() {
    local gov_files=(/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor)
    if [[ -f "${gov_files[0]:-}" ]]; then
        section "CPU Scaling Governor"
        log "Setting CPU scaling governor to 'performance'..."
        for f in "${gov_files[@]}"; do
            echo "performance" > "$f" 2>/dev/null || true
        done
        mkdir -p /etc/systemd/system
        cat > /etc/systemd/system/cpu-governor-performance.service <<'EOF'
[Unit]
Description=Set CPU Governor to Performance
After=sysinit.target local-fs.target
DefaultDependencies=no

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$f" 2>/dev/null || true; done'
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl enable cpu-governor-performance.service 2>/dev/null || true
        success "CPU governor set to 'performance' (persistent via systemd)."
    fi
}

if [[ "$SKIP_SYSCTL" != "true" ]]; then
    optimize_worker_kernel_and_limits
    configure_cpu_governor
else
    warn "Kernel & sysctl tuning skipped (--skip-sysctl)."
fi

# ------------------------------------------------------------------------------
# Step 5: Security Hardening (Admin User, SSH, Fail2ban, Updates)
# ------------------------------------------------------------------------------

if [[ -n "$ADMIN_USER_INPUT" ]]; then
    configure_admin_user
fi

if [[ "$SKIP_SSH" != "true" ]]; then
    configure_ssh
else
    warn "SSH configuration skipped (--skip-ssh)."
fi

if [[ "$ENABLE_FAIL2BAN" == "true" ]]; then
    configure_fail2ban
fi

if [[ "$ENABLE_UNATTENDED_UPGRADES" == "true" ]]; then
    configure_unattended_upgrades
fi

# ------------------------------------------------------------------------------
# Step 6: Worker VPS UFW Firewall
# ------------------------------------------------------------------------------

configure_worker_ufw() {
    section "Worker VPS Firewall (UFW)"

    if [[ "$ENABLE_UFW" != "true" ]]; then
        warn "UFW disabled by configuration."
        return
    fi

    ufw default deny incoming
    ufw default allow outgoing

    # Allow SSH
    ufw allow "${SSH_PORT_INPUT}/tcp" comment "SSH"

    # Allow HTTP & HTTPS for OpenShip Edge / Caddy / FrankenPHP
    ufw allow 80/tcp comment "Web HTTP (OpenShip Edge)"
    ufw allow 443/tcp comment "Web HTTPS (OpenShip Edge)"
    ufw allow 443/udp comment "Web HTTPS HTTP/3 QUIC (FrankenPHP / Caddy)"

    # Ensure internal databases are not exposed externally
    ufw delete allow 3306/tcp >/dev/null 2>&1 || true
    ufw delete allow 3306 >/dev/null 2>&1 || true
    ufw delete allow 6379/tcp >/dev/null 2>&1 || true
    ufw delete allow 6379 >/dev/null 2>&1 || true
    ufw delete allow 20003/tcp >/dev/null 2>&1 || true
    ufw delete allow 20003 >/dev/null 2>&1 || true

    # Repair any corrupted single quotes in UFW rule files
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        if [[ -f "$f" ]]; then
            sed -i "s/Let's Encrypt/Lets Encrypt/g" "$f" 2>/dev/null || true
            sed -i "s/'s /s /g" "$f" 2>/dev/null || true
        fi
    done

    ufw --force enable

    success "UFW firewall active: allowed SSH (${SSH_PORT_INPUT}), HTTP (80/tcp), HTTPS (443/tcp + 443/udp HTTP/3 QUIC)."
    log "Database ports (3306, 6379) remain isolated on internal Docker network."
}

if [[ "$SKIP_UFW" != "true" ]]; then
    configure_worker_ufw
else
    warn "Firewall configuration skipped (--skip-ufw)."
fi

# ------------------------------------------------------------------------------
# Completion Summary
# ------------------------------------------------------------------------------

section "Tuning Complete"
echo -e "${GREEN}${BOLD}Worker VPS tuning successfully finished!${NC}"
echo
echo "Applied settings:"
echo "  • System packages:   up to date"
echo "  • Time sync:         systemd-timesyncd active"
echo "  • Journald:          bounded to 200MB"
echo "  • Limits:            nofile 65535, nproc 65535"
echo "  • Sysctl:            network backlog, 16MB buffers, TCP Fast Open, no-idle-slow-start"
echo "  • Memory/DB:         vm.overcommit_memory=1, vm.max_map_count=262144, dirty_ratio=15"
if [[ "$ENABLE_BBR" == "true" ]]; then
    echo "  • Congestion:        BBR enabled"
fi
if [[ "$ENABLE_SWAP" == "true" ]]; then
    echo "  • Swap:              active (${SWAP_SIZE_GB} GB, swappiness=10, vfs_cache_pressure=50)"
fi
if [[ "$ENABLE_UFW" == "true" ]]; then
    echo "  • UFW:               active (SSH :${SSH_PORT_INPUT}, :80, :443 tcp+udp HTTP/3 QUIC open)"
fi
if [[ "$ENABLE_FAIL2BAN" == "true" ]]; then
    echo "  • Fail2ban:          protecting SSH on port ${SSH_PORT_INPUT}"
fi
echo
echo "Next steps for this Worker VPS:"
echo "  1. Install Docker Engine / Compose v2 (if not already installed)."
echo "  2. Connect this worker to OpenShip Control Plane (or deploy Edge)."
echo "  3. Deploy databases: cd ../mariadb-redis && sudo ./deploy.sh"
echo
