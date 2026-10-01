#!/usr/bin/env bash
# ==============================================================================
# OpenShip Installer — System Checks & Configuration
# ==============================================================================

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
    if ! [[ "$major_ver" =~ ^[0-9]+$ ]] || (( major_ver < 24 )); then
        warn "This installer is designed for Ubuntu 24+ (detected: Ubuntu ${VERSION_ID:-unknown})."

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
# System packages & update
# ------------------------------------------------------------------------------

install_and_update_packages() {
    section "System packages & update"

    export DEBIAN_FRONTEND=noninteractive

    # Clean up broken/expired Caddy Cloudsmith repos from previous runs before apt-get update
    rm -f /etc/apt/sources.list.d/caddy-stable.list /etc/apt/sources.list.d/caddy-stable.sources /usr/share/keyrings/caddy-stable-archive-keyring.gpg

    run_task "Updating package lists" apt-get update -qq

    run_task "Upgrading system packages" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    run_task "Installing base packages" apt-get install -y -qq \
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

    if [[ -f /var/run/reboot-required ]]; then
        warn "A system restart is recommended after kernel/library updates."
        warn "You can complete the OpenShip installation now and reboot afterward."
    fi
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

    if ! swapon /swapfile 2>/dev/null; then
        warn "swapon failed (possibly running inside container or unsupported filesystem)."
        warn "Continuing without swap."
        return
    fi

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

