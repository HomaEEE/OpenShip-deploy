#!/usr/bin/env bash
set -Eeuo pipefail

readonly LOG_FILE="/var/log/openship-doctor.log"
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
OPENSHIP_ROLE="control"
OPENSHIP_DOMAIN_KIND="none"
OPENSHIP_EDGE_ENABLED="false"
OPENSHIP_HOST=""

echo
echo "============================================================"
echo " OpenShip Diagnostic Doctor"
echo "============================================================"
echo

log "Host"
echo "  Hostname: $(hostname)"
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo "  OS:       ${PRETTY_NAME:-Linux}"
fi
echo "  Kernel:   $(uname -r)"
echo "  Arch:     $(dpkg --print-architecture 2>/dev/null || uname -m)"
echo "  CPU:      $(nproc) cores"
echo "  RAM:      $(free -h | awk '/^Mem:/ {print $2}')"
echo "  Disk:     $(df -h / | awk 'NR==2 {print $4 " free / " $2}')"
echo

if [[ -f "$STATE_FILE" ]]; then
    ok "Installer state exists: $STATE_FILE"
    # shellcheck disable=SC1090
    source "$STATE_FILE"
    echo "  Mode:         ${INSTALL_MODE:-unknown}"
    echo "  Role:         ${OPENSHIP_ROLE:-control}"
    echo "  SSH port:     ${SSH_PORT:-22}"
    echo "  Admin user:   ${ADMIN_USER:-unknown}"
    echo "  Domain:       ${OPENSHIP_HOST:-none} (${OPENSHIP_DOMAIN_KIND:-none})"
    echo "  Edge:         ${OPENSHIP_EDGE_ENABLED:-false}"
fi

# Control Plane checks (if installed or state file exists)
if [[ -f "$STATE_FILE" ]] || command -v openship >/dev/null 2>&1; then
    echo
    log "OpenShip Control Plane CLI"

    if command -v openship >/dev/null 2>&1; then
        ok "openship command found: $(command -v openship) ($(openship --version 2>/dev/null || true))"
    else
        fail "openship command not found"
        FAILED=1
    fi

    echo
    log "OpenShip Control Plane Service"

    if [[ "${INSTALL_MODE:-}" == "bare" ]]; then
        if systemctl is-active --quiet openship 2>/dev/null; then
            ok "OpenShip systemd unit (openship.service) is active"
        else
            fail "OpenShip systemd unit (openship.service) is NOT active"
            FAILED=1
        fi
    fi

    if command -v openship >/dev/null 2>&1; then
        if openship status; then
            ok "OpenShip status/API health"
        else
            fail "OpenShip status/API health"
            FAILED=1
        fi

        echo
        log "OpenShip internal doctor"

        if openship doctor; then
            ok "OpenShip doctor check passed"
        else
            fail "OpenShip doctor reported issues"
            FAILED=1
        fi
    fi
fi

# Caddy Reverse Proxy checks
if command -v caddy >/dev/null 2>&1; then
    echo
    log "Caddy Reverse Proxy"
    if systemctl is-active --quiet caddy; then
        ok "Caddy service is active"
    else
        fail "Caddy service is installed but NOT active"
        FAILED=1
    fi
    if [[ -f /etc/caddy/Caddyfile ]]; then
        if grep -q "127.0.0.1:3001" /etc/caddy/Caddyfile; then
            ok "Caddyfile proxies Dashboard to 127.0.0.1:3001"
        fi
        if grep -q "127.0.0.1:4000" /etc/caddy/Caddyfile; then
            ok "Caddyfile proxies API to 127.0.0.1:4000"
        else
            warn "Caddyfile does NOT proxy API to 127.0.0.1:4000 (terminal WebSockets / API may fail)"
        fi
        if grep -qE "^[a-zA-Z0-9.-]+ \{" /etc/caddy/Caddyfile && ! grep -qE "^http://" /etc/caddy/Caddyfile; then
            echo "  ℹ Cloudflare SSL tip: if 'Too Many Redirects', switch Cloudflare SSL to 'Full' or prefix domain with 'http://' in /etc/caddy/Caddyfile."
        fi
    fi
fi

# Docker & Edge checks
echo
log "Docker Daemon & Edge Services"

if command -v docker >/dev/null 2>&1; then
    if systemctl is-active --quiet docker; then
        ok "Docker daemon is running: $(docker --version)"
    else
        if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" || "${INSTALL_MODE:-}" == "standard" ]]; then
            fail "Docker daemon is not running"
            FAILED=1
        else
            warn "Docker daemon is installed but not running"
        fi
    fi

    # Check OpenShip Edge container if enabled
    if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^openship-edge$'; then
            ok "OpenShip Edge container is running on :80/:443"
        elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^openship-edge$'; then
            fail "OpenShip Edge container exists but is STOPPED"
            FAILED=1
        else
            warn "OpenShip Edge container not found (may still be provisioning)"
        fi
    fi

    # Check Worker Database Services (only if explicitly deployed on this host)
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE '^openship-(mariadb|redis)$'; then
        echo
        log "OpenShip Worker Services (MariaDB + Redis)"

        for service in openship-mariadb openship-redis; do
            if docker ps --format '{{.Names}}' | grep -q "^${service}$"; then
                health="$(docker inspect --format='{{json .State.Health.Status}}' "$service" 2>/dev/null || echo '"running"')"
                ok "${service} is running (health: ${health//\"/})"
            elif docker ps -a --format '{{.Names}}' | grep -q "^${service}$"; then
                warn "${service} exists but is STOPPED"
            fi
        done

        local net="${OPENSHIP_NETWORK:-openship-openship-deploy}"
        if docker network inspect "$net" >/dev/null 2>&1; then
            ok "Docker network '${net}' is active"
        fi
    else
        if [[ "${OPENSHIP_ROLE:-control}" == "control" ]]; then
            echo "  ○ Worker databases (MariaDB/Redis): not required on Control Plane"
            echo "  ○ Production applications: not required on Control Plane"
        fi
    fi
else
    if [[ "${OPENSHIP_ROLE:-control}" == "control" && "${OPENSHIP_EDGE_ENABLED:-false}" != "true" ]]; then
        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" != "true" ]]; then
            fail "Docker daemon is NOT running! OpenShip reports 'connect ENOENT /var/run/docker.sock' because Host Control is enabled. Start Docker: 'systemctl enable --now docker'."
            FAILED=1
        else
            ok "Docker daemon: not required (strict isolation --no-host-control active)"
        fi
    elif [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        fail "Docker is required for OpenShip Edge (:80/:443)"
        FAILED=1
    fi
fi

echo
log "Network & Listening Ports"
ss -lntp | sed -n '1p;/LISTEN/p' || true

if [[ -n "$SSH_PORT" ]]; then
    if ss -lnt "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
        ok "SSH listens on port $SSH_PORT"
    else
        warn "Configured SSH port $SSH_PORT is not detected by ss."
    fi
fi

if [[ "${INSTALL_MODE:-}" == "bare" ]]; then
    if ss -lnt "sport = :3001" 2>/dev/null | grep -q LISTEN; then
        ok "OpenShip Dashboard listens internally on port 3001"
    else
        warn "OpenShip Dashboard port 3001 not detected in LISTEN state."
    fi

    if ss -lnt "sport = :4000" 2>/dev/null | grep -q LISTEN; then
        ok "OpenShip API listens internally on port 4000"
    else
        warn "OpenShip API port 4000 not detected in LISTEN state."
    fi
fi

if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
    if ss -lnt "sport = :80" 2>/dev/null | grep -q LISTEN; then
        ok "Edge HTTP listens on port 80"
    else
        warn "Edge HTTP port 80 not detected in LISTEN state."
    fi

    if ss -lnt "sport = :443" 2>/dev/null | grep -q LISTEN; then
        ok "Edge HTTPS listens on port 443"
    else
        warn "Edge HTTPS port 443 not detected in LISTEN state."
    fi
fi

echo
log "Firewall (UFW)"
if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
    if ufw status 2>/dev/null | grep -qE "(3001|3001/tcp).*ALLOW"; then
        warn "Port 3001 is open in UFW! Direct public access to 3001 bypasses Caddy reverse proxy. Run: 'ufw delete allow 3001/tcp'."
    else
        ok "Port 3001 is not exposed in UFW (safe behind Caddy / internal)."
    fi
    if ufw status 2>/dev/null | grep -qE "(4000|4000/tcp).*ALLOW"; then
        warn "Port 4000 is open in UFW! Direct public access to 4000 bypasses Caddy reverse proxy. Run: 'ufw delete allow 4000/tcp'."
    else
        ok "Port 4000 is not exposed in UFW (safe behind Caddy / internal)."
    fi
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
    ok "Doctor finished: no critical failures detected for Control Plane."
else
    fail "Doctor finished with critical failures."
fi

echo
echo "Log: $LOG_FILE"

exit "$FAILED"
