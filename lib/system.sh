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
        systemd-timesyncd \
        zram-tools

    run_task "Cleaning up unused packages" bash -c "apt-get autoremove -y -qq && apt-get clean -qq"

    if [[ -f /var/run/reboot-required ]]; then
        warn "A system restart is recommended after kernel/library updates."
        warn "You can complete the OpenShip installation now and reboot afterward."
    fi
}

# ------------------------------------------------------------------------------
# System tuning
# ------------------------------------------------------------------------------

disable_unused_services() {
    section "Freeing memory (unused services)"
    local services=(
        snapd.service
        snapd.socket
        snapd.seeded.service
        multipathd.service
        multipathd.socket
        ModemManager.service
        packagekit.service
        whoopsie.service
        apport.service
    )
    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            log "Disabling unused service: ${svc}..."
            systemctl stop "$svc" 2>/dev/null || true
            systemctl disable "$svc" 2>/dev/null || true
            systemctl mask "$svc" 2>/dev/null || true
        fi
    done

    # Disable cloud-init after install to prevent memory usage & background checks
    if command_exists cloud-init || [[ -d /etc/cloud ]]; then
        mkdir -p /etc/cloud
        touch /etc/cloud/cloud-init.disabled
        for ci_svc in cloud-init.service cloud-config.service cloud-final.service cloud-init-local.service; do
            systemctl disable "$ci_svc" 2>/dev/null || true
            systemctl mask "$ci_svc" 2>/dev/null || true
        done
        log "cloud-init disabled for post-install boots."
    fi

    # Reschedule apt-daily timers to night hours (03:30) to avoid daytime CPU spikes on 1-core VPS
    if systemctl list-unit-files apt-daily.timer &>/dev/null; then
        mkdir -p /etc/systemd/system/apt-daily.timer.d /etc/systemd/system/apt-daily-upgrade.timer.d
        cat > /etc/systemd/system/apt-daily.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 03:30:00
RandomizedDelaySec=30m
Persistent=true
EOF
        cat > /etc/systemd/system/apt-daily-upgrade.timer.d/override.conf <<'EOF'
[Timer]
OnCalendar=
OnCalendar=*-*-* 04:15:00
RandomizedDelaySec=30m
Persistent=true
EOF
        systemctl daemon-reload 2>/dev/null || true
        systemctl restart apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
        log "apt-daily background maintenance rescheduled to off-peak night hours (03:30-04:45)."
    fi

    success "Unused background services disabled (freed ~100-150MB RAM)."
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

configure_thp() {
    section "Transparent HugePages (THP)"
    log "Disabling Transparent HugePages (never) to eliminate memory bloat & latency spikes..."
    echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
    echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true

    mkdir -p /etc/systemd/system
    cat > /etc/systemd/system/disable-thp.service <<'EOF'
[Unit]
Description=Disable Transparent HugePages
DefaultDependencies=no
After=sysinit.target local-fs.target
Before=basic.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true; echo never > /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null || true'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable disable-thp.service 2>/dev/null || true
    success "Transparent HugePages disabled (persistent via systemd)."
}

configure_disk_io() {
    section "Disk I/O & Filesystem Tuning"

    # 1. Enable noatime for root mount in /etc/fstab to eliminate disk write overhead on file reads
    log "Configuring 'noatime' mount option for root filesystem..."
    mount -o remount,noatime / 2>/dev/null || true
    if [[ -f /etc/fstab ]]; then
        if grep -E '\s+/\s+' /etc/fstab | grep -q 'relatime'; then
            sed -i -E '/\s+\/\s+/ s/relatime/noatime/' /etc/fstab
            log "Updated /etc/fstab: replaced relatime with noatime on /."
        elif grep -E '\s+/\s+' /etc/fstab | grep -q 'defaults'; then
            sed -i -E '/\s+\/\s+/ s/defaults/defaults,noatime/' /etc/fstab
            log "Updated /etc/fstab: added noatime to defaults on /."
        fi
    fi

    # 2. Set I/O scheduler to mq-deadline or none for NVMe/SSD
    log "Configuring I/O scheduler (mq-deadline/none) for NVMe/SSD block devices..."
    mkdir -p /etc/udev/rules.d
    cat > /etc/udev/rules.d/60-io-schedulers.rules <<'EOF'
# OpenShip: Low-latency I/O scheduler for SSD / NVMe
ACTION=="add|change", KERNEL=="nvme[0-9]*|sd[a-z]|vd[a-z]", ATTR{queue/rotational}=="0", ATTR{queue/scheduler}="none mq-deadline"
EOF
    udevadm control --reload 2>/dev/null || true
    udevadm trigger --subsystem-match=block 2>/dev/null || true

    success "Disk I/O tuning (noatime + SSD queue scheduler) applied."
}

optimize_system() {
    section "System tuning & resource optimization"

    # 1. Stop bloat daemons to free up 100-150MB of RAM
    disable_unused_services

    # 2. Time sync & weekly SSD TRIM
    log "Enabling systemd-timesyncd time synchronization & fstrim..."
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
    systemctl enable --now fstrim.timer 2>/dev/null || true

    # 3. Dynamic resource thresholds
    local sock_buf_max=16777216
    local dirty_ratio=15
    local dirty_bg_ratio=5
    local journal_max="150M"
    local journal_runtime="75M"
    local min_free_kb=65536

    if (( RAM_MB < 2048 )); then
        sock_buf_max=4194304
        dirty_ratio=10
        dirty_bg_ratio=3
        journal_max="50M"
        journal_runtime="25M"
        min_free_kb=32768
        log "Low-memory profile active (< 2GB RAM): conservative socket buffers (4MB) and journald (50MB)."
    fi

    # 4. File descriptor & process limits
    log "Configuring file descriptor & process limits (nofile 65535, nproc 65535)..."
    cat > /etc/security/limits.d/99-openship.conf <<'EOF'
* soft nofile 65535
* hard nofile 131072
root soft nofile 65535
root hard nofile 131072
* soft nproc 65535
* hard nproc 65535
root soft nproc 65535
root hard nproc 65535
EOF

    for pam_file in /etc/pam.d/common-session /etc/pam.d/common-session-noninteractive; do
        if [[ -f "$pam_file" ]] && ! grep -q "pam_limits.so" "$pam_file"; then
            echo "session required pam_limits.so" >> "$pam_file"
        fi
    done

    # 5. Journald size limit
    log "Configuring systemd journal limit (SystemMaxUse=${journal_max})..."
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/99-openship.conf <<EOF
[Journal]
SystemMaxUse=${journal_max}
RuntimeMaxUse=${journal_runtime}
EOF
    systemctl restart systemd-journald 2>/dev/null || true

    # 6. TCP BBR Congestion Control
    local bbr_applied=false
    if modprobe tcp_bbr 2>/dev/null; then
        mkdir -p /etc/modules-load.d
        echo "tcp_bbr" > /etc/modules-load.d/bbr.conf
        bbr_applied=true
        log "BBR congestion control module loaded."
    fi

    # 7. Sysctl low-latency & memory tuning
    modprobe br_netfilter 2>/dev/null || true
    log "Applying kernel network, low-latency, and memory optimizations..."
    cat > /etc/sysctl.d/99-openship-control.conf <<EOF
# OpenShip Kernel & Network Tuning

# Network connection backlog & buffers
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.core.netdev_max_backlog = 65535

# Socket buffer sizes (Dynamic based on RAM)
net.core.rmem_max = ${sock_buf_max}
net.core.wmem_max = ${sock_buf_max}
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.ipv4.tcp_rmem = 4096 87380 ${sock_buf_max}
net.ipv4.tcp_wmem = 4096 87380 ${sock_buf_max}

# Low-latency TCP (reduces TTFB)
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.ip_local_port_range = 1024 65535

# Keepalive timeouts
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5

# Memory management & swapping
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.min_free_kbytes = ${min_free_kb}
vm.panic_on_oom = 0
vm.oom_kill_allocating_task = 0
vm.swappiness = 20
vm.vfs_cache_pressure = 50
vm.dirty_ratio = ${dirty_ratio}
vm.dirty_background_ratio = ${dirty_bg_ratio}

# Docker Bridge & IP Forwarding
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1

# Connection tracking & Container NAT
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15

# ARP neighbor table limits for container veth interfaces
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 2048
net.ipv4.neigh.default.gc_thresh3 = 4096

# File system & inotify watchers
fs.file-max = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 1024
EOF

    if [[ "$bbr_applied" == "true" ]]; then
        cat >> /etc/sysctl.d/99-openship-control.conf <<'EOF'
# TCP BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi

    sysctl --system >> "$LOG_FILE" 2>&1 || true

    # 8. CPU scaling governor
    configure_cpu_governor

    # 9. Transparent HugePages (THP = never)
    configure_thp

    # 10. Disk I/O & noatime
    configure_disk_io

    success "System tuning applied successfully."
}

# ------------------------------------------------------------------------------
# Swap (Hybrid zRAM + Swapfile)
# ------------------------------------------------------------------------------

configure_swap() {
    section "Memory Compression (zRAM) & Swap"

    # 1. Setup zRAM (in-memory compressed swap)
    if command_exists zramctl || [[ -f /etc/default/zramswap ]] || modprobe zram 2>/dev/null; then
        log "Configuring zRAM compressed memory (lz4, 50% RAM, priority 100)..."
        mkdir -p /etc/default
        cat > /etc/default/zramswap <<'EOF'
ALGO=lz4
PERCENT=50
PRIORITY=100
EOF
        systemctl enable --now zramswap 2>/dev/null || true
        success "zRAM compressed memory configured."
    fi

    # 2. Check disk swap
    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        success "Swapfile is already active:"
        swapon --show 2>/dev/null || true
        return
    fi

    if [[ "$ENABLE_SWAP" != "true" || "${SWAP_SIZE_GB:-0}" -le 0 ]]; then
        warn "Disk swap disabled by configuration."
        return
    fi

    local swap_gb="${SWAP_SIZE_GB:-2}"
    log "Creating ${swap_gb} GB disk swapfile (backup priority 10)..."

    if [[ ! -f /swapfile ]]; then
        if ! fallocate -l "${swap_gb}G" /swapfile 2>/dev/null; then
            warn "fallocate failed, creating swapfile with dd..."
            dd if=/dev/zero of=/swapfile bs=1M count="$((swap_gb * 1024))" status=progress 2>/dev/null
        fi
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
    fi

    if ! swapon --priority 10 /swapfile 2>/dev/null && ! swapon /swapfile 2>/dev/null; then
        warn "swapon failed (possibly running inside container or unsupported filesystem)."
        warn "Continuing without disk swap."
        return
    fi

    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw,pri=10 0 0' >> /etc/fstab
    fi

    success "${swap_gb} GB disk swap configured (hybrid zRAM + swapfile active)."
}

# ------------------------------------------------------------------------------
# Administrator user
# ------------------------------------------------------------------------------

