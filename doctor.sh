#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOG_FILE="/var/log/openship-control-doctor.log"
readonly STATE_FILE="/etc/openship-control/install.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log() { echo -e "$CYAN[INFO]$NC $*"; }
ok() { echo -e "$GREEN[ OK ]$NC $*"; }
warn() { echo -e "$YELLOW[WARN]$NC $*"; }
fail() { echo -e "$RED[FAIL]$NC $*"; }

if [[ "$EUID" -ne 0 ]]; then
    echo "Run as root: sudo ./doctor.sh" >&2
    exit 1
fi

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

FAILED=0
INSTALL_MODE=""
SSH_PORT=""
ADMIN_USER=""

echo
echo "============================================================"
echo " OpenShip Control Plane — Doctor"
echo "============================================================"
echo

log "Host"
echo "  Hostname: $(hostname)"
. /etc/os-release
echo "  OS:       $PRETTY_NAME"
echo "  Kernel:   $(uname -r)"
echo "  Arch:     $(dpkg --print-architecture)"
echo "  CPU:      $(nproc)"
echo "  RAM:      $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Disk:     $(df -h / | awk 'NR==2 {print $4 " free / " $2}')"
echo

if [[ -f "$STATE_FILE" ]]; then
    ok "Installer state exists: $STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo "  Mode:     $INSTALL_MODE"
    echo "  SSH port: $SSH_PORT"
    echo "  Admin:    $ADMIN_USER"
else
    warn "Installer state not found: $STATE_FILE"
fi

echo
log "OpenShip CLI"

if command -v openship >/dev/null 2>&1; then
    ok "openship command found: $(command -v openship)"
    openship --version || true
else
    fail "openship command not found"
    FAILED=1
fi

echo
log "OpenShip service"

if command -v openship >/dev/null 2>&1; then
    if openship status; then
        ok "OpenShip status/API health"
    else
        fail "OpenShip status/API health"
        FAILED=1
    fi

    echo
    log "OpenShip doctor"

    if openship doctor; then
        ok "OpenShip doctor"
    else
        fail "OpenShip doctor"
        FAILED=1
    fi
fi

echo
log "Runtime"

if command -v node >/dev/null 2>&1; then
    echo "  Node: $(node --version)"
else
    warn "Node is not installed system-wide (OpenShip may use its bundled runtime)."
fi

if command -v bun >/dev/null 2>&1; then
    echo "  Bun:  $(bun --version)"
else
    log "Bun: not installed system-wide"
fi

echo
log "Docker"

if command -v docker >/dev/null 2>&1; then
    echo "  $(docker --version)"
    if systemctl is-active --quiet docker; then
        ok "Docker daemon is running"
    else
        fail "Docker daemon is not running"
        FAILED=1
    fi
else
    log "Docker is not installed (expected for Bare mode)."
fi

echo
log "Network"
ss -lntp | sed -n '1p;/LISTEN/p' || true

if [[ -n "$SSH_PORT" ]]; then
    if ss -lnt "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
        ok "SSH listens on port $SSH_PORT"
    else
        warn "Configured SSH port $SSH_PORT is not detected by ss."
    fi
fi

echo
log "Firewall"

if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
else
    warn "UFW is not installed."
fi

echo
log "Fail2ban"

if command -v fail2ban-client >/dev/null 2>&1; then
    fail2ban-client status sshd 2>/dev/null || true
else
    warn "Fail2ban is not installed."
fi

echo
log "Swap"
swapon --show || true

echo
log "Disk"
df -h /

echo
log "Memory"
free -h

echo
if (( FAILED == 0 )); then
    ok "Doctor finished: no critical failures detected."
else
    fail "Doctor finished with critical failures."
fi

echo
echo "Log: $LOG_FILE"

exit "$FAILED"
