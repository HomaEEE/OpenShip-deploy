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

# Caddy reverse proxy variables
CADDY_SSL_MODE="auto"
CADDY_ORIGIN_CERT_PATH=""
CADDY_ORIGIN_KEY_PATH=""

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

# Terminal width (default 60 if unknown)
_TW="$(tput cols 2>/dev/null || echo 60)"

# ------------------------------------------------------------------------------
# Fast CLI flags (--help, --version)
# ------------------------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --version|-v)
            echo "OpenShip Installer v${SCRIPT_VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo
            echo "Options:"
            echo "  --dry-run           Validate system and configuration without modifying system"
            echo "  --non-interactive   Use default / saved environment values without interactive prompts"
            echo "  --version, -v       Display version"
            echo "  --help, -h          Display this help message"
            exit 0
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

if [[ $EUID -eq 0 ]] || mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null; then
    touch "$LOG_FILE" 2>/dev/null || true
    exec > >(tee -a "$LOG_FILE") 2>&1
fi


# ------------------------------------------------------------------------------
# Module Loading & Self-Extraction
# ------------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "")"
LIB_DIR="${SCRIPT_DIR}/lib"

TEMP_CLONE_DIR=""
cleanup_installer() {
    if [[ -n "$TEMP_CLONE_DIR" && -d "$TEMP_CLONE_DIR" ]]; then
        rm -rf "$TEMP_CLONE_DIR"
    fi
}
trap cleanup_installer EXIT

if [[ ! -d "$LIB_DIR" ]]; then
    if command -v git &>/dev/null; then
        TEMP_CLONE_DIR="$(mktemp -d /tmp/openship-deploy-XXXXXX)"
        echo "==> Fetching OpenShip Deploy modules..."
        git clone --depth 1 https://github.com/HomaEEE/OpenShip-deploy.git "$TEMP_CLONE_DIR" >/dev/null 2>&1
        LIB_DIR="${TEMP_CLONE_DIR}/lib"
    else
        echo "Error: Required installer libraries not found at ${LIB_DIR} and git is not installed." >&2
        exit 1
    fi
fi

# Source modular libraries
# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/system.sh
source "${LIB_DIR}/system.sh"
# shellcheck source=lib/security.sh
source "${LIB_DIR}/security.sh"
# shellcheck source=lib/docker.sh
source "${LIB_DIR}/docker.sh"
# shellcheck source=lib/openship.sh
source "${LIB_DIR}/openship.sh"
# shellcheck source=lib/proxy.sh
source "${LIB_DIR}/proxy.sh"

# ------------------------------------------------------------------------------
# CLI Options
# ------------------------------------------------------------------------------

DRY_RUN=false
NON_INTERACTIVE=false

for arg in "$@"; do
    case "$arg" in
        --dry-run)
            DRY_RUN=true
            ;;
        --non-interactive)
            NON_INTERACTIVE=true
            ;;
        --version|-v)
            echo "OpenShip Installer v${SCRIPT_VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "Usage: sudo ./install.sh [OPTIONS]"
            echo
            echo "Options:"
            echo "  --dry-run           Validate system and configuration without modifying system"
            echo "  --non-interactive   Use default / saved environment values without interactive prompts"
            echo "  --version, -v       Display version"
            echo "  --help, -h          Display this help message"
            exit 0
            ;;
    esac
done

select_installation_mode() {
    section "OpenShip installation mode"

    if (( RAM_MB < RECOMMENDED_RAM_MB )); then

        echo -e "${BOLD}${YELLOW}"
        echo "RECOMMENDATION FOR LOW-MEMORY VPS (< 2 GB RAM)"
        echo "----------------------------------------------------------------"
        echo "This server will act as an OpenShip Control Plane."
        echo "Bare mode runs OpenShip as a lightweight native service with"
        echo "an embedded database (avoiding Postgres & Redis containers)."
        echo "Web traffic can be routed via Caddy or OpenShip Edge (:80/:443)."
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
            choice="${choice//[$'\r\n\t ']/}"
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
            choice="${choice//[$'\r\n\t ']/}"
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
            # Safely parse state file without sourcing to prevent syntax errors with spaces
            while IFS="=" read -r key val || [[ -n "$key" ]]; do
                [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
                key="$(echo "$key" | tr -d '[:space:]')"
                val="${val#\"}"
                val="${val%\"}"
                val="${val#\'}"
                val="${val%\'}"
                case "$key" in
                    INSTALL_MODE)             INSTALL_MODE="$val" ;;
                    HOSTNAME)                 HOSTNAME_INPUT="$val" ;;
                    TIMEZONE)                 TIMEZONE_INPUT="$val" ;;
                    SSH_PORT)                 SSH_PORT_INPUT="$val" ;;
                    ADMIN_USER)               ADMIN_USER_INPUT="$val" ;;
                    ENABLE_UFW)               ENABLE_UFW="$val" ;;
                    ENABLE_FAIL2BAN)          ENABLE_FAIL2BAN="$val" ;;
                    ENABLE_SWAP)              ENABLE_SWAP="$val" ;;
                    SWAP_SIZE_GB)             SWAP_SIZE_GB="$val" ;;
                    OPENSHIP_ADMIN_NAME)      OPENSHIP_ADMIN_NAME_INPUT="$val" ;;
                    OPENSHIP_ADMIN_EMAIL)     OPENSHIP_ADMIN_EMAIL_INPUT="$val" ;;
                    OPENSHIP_DOMAIN_KIND)     OPENSHIP_DOMAIN_KIND="$val" ;;
                    OPENSHIP_HOST)            OPENSHIP_HOST="$val" ;;
                    OPENSHIP_PUBLIC_URL)      OPENSHIP_PUBLIC_URL="$val" ;;
                    OPENSHIP_EDGE_ENABLED)    OPENSHIP_EDGE_ENABLED="$val" ;;
                    OPENSHIP_PROXY_MODE)      OPENSHIP_PROXY_MODE="$val" ;;
                    OPENSHIP_NO_HOST_CONTROL) OPENSHIP_NO_HOST_CONTROL="$val" ;;
                    CADDY_SSL_MODE)           CADDY_SSL_MODE="$val" ;;
                    CADDY_ORIGIN_CERT_PATH)   CADDY_ORIGIN_CERT_PATH="$val" ;;
                    CADDY_ORIGIN_KEY_PATH)    CADDY_ORIGIN_KEY_PATH="$val" ;;
                esac
            done < "$STATE_FILE"

            # Apply sensible defaults if not set in state file
            HOSTNAME_INPUT="${HOSTNAME_INPUT:-openship-control}"
            TIMEZONE_INPUT="${TIMEZONE_INPUT:-UTC}"
            SSH_PORT_INPUT="${SSH_PORT_INPUT:-22}"
            ADMIN_USER_INPUT="${ADMIN_USER_INPUT:-openship}"
            ENABLE_UFW="${ENABLE_UFW:-true}"
            ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-true}"
            ENABLE_SWAP="${ENABLE_SWAP:-true}"
            SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
            OPENSHIP_DOMAIN_KIND="${OPENSHIP_DOMAIN_KIND:-none}"
            OPENSHIP_EDGE_ENABLED="${OPENSHIP_EDGE_ENABLED:-false}"
            OPENSHIP_PROXY_MODE="${OPENSHIP_PROXY_MODE:-none}"
            OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-false}"
            CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"

            # Auto-infer proxy mode if loading an older state file
            if [[ "$OPENSHIP_PROXY_MODE" == "none" ]]; then
                if [[ "$OPENSHIP_EDGE_ENABLED" == "true" ]]; then
                    OPENSHIP_PROXY_MODE="edge"
                    OPENSHIP_DOMAIN_KIND="custom"
                elif [[ "$OPENSHIP_DOMAIN_KIND" == "byo" && -n "$OPENSHIP_HOST" ]]; then
                    OPENSHIP_PROXY_MODE="caddy"
                fi
            elif [[ "$OPENSHIP_PROXY_MODE" == "edge" ]]; then
                OPENSHIP_EDGE_ENABLED="true"
                OPENSHIP_DOMAIN_KIND="custom"
            elif [[ "$OPENSHIP_PROXY_MODE" == "caddy" ]]; then
                OPENSHIP_EDGE_ENABLED="false"
                OPENSHIP_DOMAIN_KIND="byo"
            fi

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
                    OPENSHIP_ADMIN_PASSWORD_INPUT="$(ask_password "OpenShip administrator password: ")"

                    if [[ -z "$OPENSHIP_ADMIN_PASSWORD_INPUT" ]]; then
                        warn "Password cannot be empty."
                        continue
                    fi
                    if (( ${#OPENSHIP_ADMIN_PASSWORD_INPUT} < 8 )); then
                        warn "Password must be at least 8 characters (entered: ${#OPENSHIP_ADMIN_PASSWORD_INPUT})."
                        continue
                    fi
                    success "Password accepted (${#OPENSHIP_ADMIN_PASSWORD_INPUT} characters)."
                    break
                done
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
    # Timezone — auto-detect → region → city
    # ------------------------------------------------------------------
    _select_timezone() {
        local auto_tz=""
        local ssh_raw="${SSH_CLIENT:-${SSH_CONNECTION:-}}"
        local client_ip="${ssh_raw%% *}"

        # Try client timezone via SSH IP
        if [[ -n "$client_ip" && ! "$client_ip" =~ ^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.) ]]; then
            auto_tz="$(curl -fsSL --max-time 2 "http://ip-api.com/line/${client_ip}?fields=timezone" 2>/dev/null || true)"
            if [[ ! "$auto_tz" =~ ^[A-Za-z0-9_+-]+/[A-Za-z0-9_+-]+$ ]]; then
                auto_tz=""
            fi
        fi

        # Fallback to server system timezone
        if [[ -z "$auto_tz" ]]; then
            auto_tz="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"
        fi

        # Alias legacy names
        case "${auto_tz}" in
            "Europe/Kiev")     auto_tz="Europe/Kyiv" ;;
            "Asia/Calcutta")   auto_tz="Asia/Kolkata" ;;
        esac

        local default_tz="${auto_tz:-UTC}"

        echo
        log "Detected timezone: ${BOLD}${default_tz}${NC}"

        if ask_yes_no "Use ${default_tz}?" "Y"; then
            TIMEZONE_INPUT="$default_tz"
        else
            # Step 1: Region
            local regions
            regions="$(timedatectl list-timezones 2>/dev/null | cut -d/ -f1 | sort -u)"
            local region_count
            region_count="$(echo "$regions" | wc -l)"

            echo
            echo -e "  ${BOLD}Regions:${NC}"
            echo "$regions" | nl -w3 -s') ' | column -c 60
            echo

            local region_num region
            while true; do
                read -r -p "  Region [1-${region_count}]: " region_num </dev/tty
                region_num="${region_num//[$'\r\n\t ']/}"
                region="$(echo "$regions" | sed -n "${region_num}p")"
                [[ -n "$region" ]] && break
                warn "Invalid number, try again."
            done

            # Step 2: City
            local cities
            cities="$(timedatectl list-timezones 2>/dev/null | grep "^${region}/" | sed "s|^${region}/||")"
            local city_count
            city_count="$(echo "$cities" | wc -l)"

            echo
            echo -e "  ${BOLD}Cities in ${region}:${NC}"
            echo "$cities" | nl -w3 -s') ' | column -c 60
            echo

            local city_num city
            while true; do
                read -r -p "  City [1-${city_count}]: " city_num </dev/tty
                city_num="${city_num//[$'\r\n\t ']/}"
                city="$(echo "$cities" | sed -n "${city_num}p")"
                [[ -n "$city" ]] && break
                warn "Invalid number, try again."
            done

            TIMEZONE_INPUT="${region}/${city}"
        fi

        # Validate
        if ! timedatectl list-timezones 2>/dev/null | grep -Fxq "$TIMEZONE_INPUT"; then
            warn "Timezone '${TIMEZONE_INPUT}' not recognised. Falling back to UTC."
            TIMEZONE_INPUT="UTC"
        fi

        success "Timezone: ${TIMEZONE_INPUT}"
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
INSTALL_MODE="${INSTALL_MODE}"
OPENSHIP_ROLE="control"
OPENSHIP_HOST_CONTROL="false"
HOSTNAME="${HOSTNAME_INPUT}"
TIMEZONE="${TIMEZONE_INPUT}"
SSH_PORT="${SSH_PORT_INPUT}"
ADMIN_USER="${ADMIN_USER_INPUT}"
ENABLE_UFW="${ENABLE_UFW}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN}"
ENABLE_SWAP="${ENABLE_SWAP}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-2}"
OPENSHIP_ADMIN_NAME="${OPENSHIP_ADMIN_NAME_INPUT:-}"
OPENSHIP_ADMIN_EMAIL="${OPENSHIP_ADMIN_EMAIL_INPUT:-}"
OPENSHIP_DOMAIN_KIND="${OPENSHIP_DOMAIN_KIND:-none}"
OPENSHIP_HOST="${OPENSHIP_HOST:-}"
OPENSHIP_PUBLIC_URL="${OPENSHIP_PUBLIC_URL:-}"
OPENSHIP_EDGE_ENABLED="${OPENSHIP_EDGE_ENABLED:-false}"
OPENSHIP_PROXY_MODE="${OPENSHIP_PROXY_MODE:-none}"
OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-false}"
CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"
CADDY_ORIGIN_CERT_PATH="${CADDY_ORIGIN_CERT_PATH:-}"
CADDY_ORIGIN_KEY_PATH="${CADDY_ORIGIN_KEY_PATH:-}"
EOF

    chmod 600 "$STATE_FILE"
}

# ------------------------------------------------------------------------------
# Hostname & Timezone
# ------------------------------------------------------------------------------


post_install_checks() {
    # Detailed system diagnostic output is written exclusively to the log file
    {
        echo "=== Post-install verification ==="
        echo "OpenShip status:"
        openship status || true

        if command_exists docker; then
            echo "Docker containers:"
            docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
        fi

        echo "Memory:"
        free -h

        echo "Disk:"
        df -h /

        echo "Swap:"
        swapon --show || true

        echo "Listening ports:"
        ss -lntp || true

        echo "Firewall:"
        ufw status verbose || true

        echo "Fail2ban:"
        fail2ban-client status sshd 2>/dev/null || true
    } >> "$LOG_FILE" 2>&1
}

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------


print_summary() {
    clear 2>/dev/null || true

    section "Installation complete"

    local mode_label="${INSTALL_MODE^^}"
    local proxy_label="none"
    if [[ "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        if [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_flexible" ]]; then
            proxy_label="Caddy (Cloudflare Flexible / HTTP :80)"
        elif [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_origin" ]]; then
            proxy_label="Caddy (Cloudflare Origin CA)"
        else
            proxy_label="Caddy (Let's Encrypt HTTPS)"
        fi
    elif [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
        proxy_label="OpenShip Edge (Docker)"
    fi

    local hc_label="enabled"
    if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
        hc_label="disabled"
    fi

    local domain_label="${OPENSHIP_HOST:-none}"
    if [[ -z "$domain_label" || "$domain_label" == "none" ]]; then
        domain_label="none (private / port 3001)"
    fi

    echo -e "  ${BOLD}${CYAN}OpenShip Control Plane${NC}"
    echo
    printf "  ${DIM}%-18s${NC}  %s\n" "Mode"          "$mode_label"
    printf "  ${DIM}%-18s${NC}  %s\n" "Host control"  "$hc_label"
    printf "  ${DIM}%-18s${NC}  %s\n" "Hostname"      "${HOSTNAME_INPUT}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Timezone"      "${TIMEZONE_INPUT}"
    printf "  ${DIM}%-18s${NC}  %s:%s\n" "SSH"        "${ADMIN_USER_INPUT}" "${SSH_PORT_INPUT}"
    printf "  ${DIM}%-18s${NC}  %s\n" "UFW"           "${ENABLE_UFW}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Fail2ban"      "${ENABLE_FAIL2BAN}"
    printf "  ${DIM}%-18s${NC}  %s GB\n" "Swap"        "${SWAP_SIZE_GB:-2}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Domain"        "$domain_label"
    printf "  ${DIM}%-18s${NC}  %s\n" "Proxy"         "$proxy_label"
    echo
    printf "  ${DIM}%-18s${NC}  %s\n" "State file"    "${STATE_FILE}"
    printf "  ${DIM}%-18s${NC}  %s\n" "Install log"   "${LOG_FILE}"
    echo

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if [[ -n "${OPENSHIP_PUBLIC_URL:-}" ]]; then
            success "OpenShip Bare  →  ${OPENSHIP_PUBLIC_URL} (${proxy_label})"
        else
            success "OpenShip Bare  →  http://localhost:3001  (private)"
        fi
    else
        success "OpenShip Standard (Docker Compose)"
    fi

    if [[ "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        echo
        echo -e "  ${YELLOW}Cloudflare setup:${NC}"
        echo -e "  ${DIM}1. In Cloudflare DNS, set ${OPENSHIP_HOST} to 'Proxied' (orange cloud).${NC}"
        echo -e "  ${DIM}2. Under SSL/TLS, ensure encryption mode is set to 'Full (strict)'.${NC}"
    fi

    echo
    echo -e "  ${DIM}This VPS is strictly a Control Plane. Remote deployment servers${NC}"
    echo -e "  ${DIM}are added via 'openship server add'. Never deploy apps here.${NC}"
    echo
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------



main() {

    clear || true

    echo
    echo -e ""
    echo   "  ╔══════════════════════════════════════════════════════╗"
    echo   "  ║                                                      ║"
    printf "  ║   ⚓  %-46s  ║
" "OpenShip Control Plane Installer"
    printf "  ║   %-48s  ║
" "Version   ·  Ubuntu 24.04 LTS"
    echo   "  ║                                                      ║"
    echo   "  ╚══════════════════════════════════════════════════════╝"
    echo -e ""

    require_root

    check_os
    check_architecture
    check_resources

    select_installation_mode

    if [[ "" == "true" ]]; then
        echo
        success "Dry-run validation successful. System is compatible and ready for OpenShip installation."
        exit 0
    fi

    collect_configuration

    configure_hostname
    configure_timezone

    install_and_update_packages
    optimize_system

    configure_swap
    configure_admin_user
    configure_ssh

    configure_ufw
    configure_fail2ban
    configure_unattended_upgrades

    install_docker
    configure_docker
    ensure_openship_docker_network

    prepare_runtime_for_openship

    install_openship_cli
    preflight_openship

    run_openship_setup

    post_install_checks
    print_summary
}

main ""
