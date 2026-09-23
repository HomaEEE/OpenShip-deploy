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
        answer="${answer//[$'\r\n\t ']/}"
        answer="${answer:-Y}"
    else
        read -r -p "$prompt [y/N]: " answer </dev/tty
        answer="${answer//[$'\r\n\t ']/}"
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
    value="${value//[$'\r\n']/}"

    echo "${value:-$default}"
}

ask_password() {
    local prompt="$1"
    local password=""
    local char=""

    if [[ ! -e /dev/tty || ! -r /dev/tty ]]; then
        read -r -s -p "$prompt" password
        echo
        echo "${password//[$'\r\n']/}"
        return
    fi

    printf "%s" "$prompt" >/dev/tty

    while IFS= read -r -s -n 1 char </dev/tty; do
        if [[ -z "$char" || "$char" == $'\r' || "$char" == $'\n' ]]; then
            printf "\n" >/dev/tty
            break
        fi

        # Backspace / Delete (127 or \b)
        if [[ "$char" == $'\177' || "$char" == $'\b' ]]; then
            if (( ${#password} > 0 )); then
                password="${password%?}"
                printf "\b \b" >/dev/tty
            fi
        else
            password+="$char"
            printf "*" >/dev/tty
        fi
    done

    echo "${password//[$'\r\n']/}"
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

collect_cloudflare_origin_credentials() {
    local domain="$1"
    local cert_file="/etc/caddy/certs/${domain}.crt"
    local key_file="/etc/caddy/certs/${domain}.key"

    mkdir -p /etc/caddy/certs
    chmod 700 /etc/caddy/certs

    echo
    echo "Provide Cloudflare Origin Certificate & Private Key for ${domain}:"
    echo "  1) Paste PEM content directly in terminal"
    echo "  2) Specify paths to existing files on this server"
    echo

    local method_choice
    read -r -p "Select [1]: " method_choice </dev/tty
    method_choice="${method_choice//[$'\r\n\t ']/}"
    method_choice="${method_choice:-1}"

    if [[ "$method_choice" == "2" ]]; then
        while true; do
            local input_cert
            input_cert="$(ask_default "Path to Origin Certificate (.crt/.pem)" "")"
            if [[ -f "$input_cert" ]]; then
                cp -f "$input_cert" "$cert_file"
                chmod 644 "$cert_file"
                break
            fi
            warn "File not found: ${input_cert}"
        done

        while true; do
            local input_key
            input_key="$(ask_default "Path to Private Key (.key)" "")"
            if [[ -f "$input_key" ]]; then
                cp -f "$input_key" "$key_file"
                chmod 600 "$key_file"
                break
            fi
            warn "File not found: ${input_key}"
        done
    else
        while true; do
            echo
            echo -e "  ${BOLD}Paste Cloudflare Origin Certificate (.pem/.crt):${NC}"
            echo -e "  ${DIM}(Starts with '-----BEGIN CERTIFICATE-----', automatically ends after '-----END CERTIFICATE-----')${NC}"
            : > "$cert_file"
            while IFS= read -r line </dev/tty; do
                echo "$line" >> "$cert_file"
                if [[ "$line" == *"END CERTIFICATE"* ]]; then
                    break
                fi
            done
            chmod 644 "$cert_file"

            if grep -q "BEGIN CERTIFICATE" "$cert_file" && grep -q "END CERTIFICATE" "$cert_file"; then
                success "Certificate captured."
                break
            fi
            warn "Invalid certificate: missing 'BEGIN CERTIFICATE' or 'END CERTIFICATE' markers. Try again."
        done

        while true; do
            echo
            echo -e "  ${BOLD}Paste Cloudflare Private Key (.key):${NC}"
            echo -e "  ${DIM}(Starts with '-----BEGIN ... KEY-----', automatically ends after '-----END ... KEY-----')${NC}"
            : > "$key_file"
            while IFS= read -r line </dev/tty; do
                echo "$line" >> "$key_file"
                if [[ "$line" == *"KEY-----"* ]]; then
                    break
                fi
            done
            chmod 600 "$key_file"

            if grep -q "BEGIN" "$key_file" && grep -q "KEY" "$key_file"; then
                success "Private key captured."
                break
            fi
            warn "Invalid private key: missing 'BEGIN' or 'KEY' markers. Try again."
        done
    fi

    CADDY_ORIGIN_CERT_PATH="$cert_file"
    CADDY_ORIGIN_KEY_PATH="$key_file"
    success "Cloudflare Origin CA certificate and key configured."
}

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
        OPENSHIP_ADMIN_PASSWORD_INPUT="$(ask_password "OpenShip administrator password: ")"

        if [[ -z "$OPENSHIP_ADMIN_PASSWORD_INPUT" ]]; then
            warn "Password cannot be empty."
            continue
        fi

        if (( ${#OPENSHIP_ADMIN_PASSWORD_INPUT} < 8 )); then
            warn "Password must contain at least 8 characters (entered: ${#OPENSHIP_ADMIN_PASSWORD_INPUT})."
            continue
        fi

        success "Password accepted (${#OPENSHIP_ADMIN_PASSWORD_INPUT} characters)."
        break
    done

    OPENSHIP_DOMAIN_KIND="none"
    OPENSHIP_PUBLIC_URL=""
    OPENSHIP_HOST=""
    OPENSHIP_EDGE_ENABLED="false"
    OPENSHIP_PROXY_MODE="none"
    CADDY_SSL_MODE="auto"
    CADDY_ORIGIN_CERT_PATH=""
    CADDY_ORIGIN_KEY_PATH=""

    echo
    echo "OpenShip instance reachability:"
    echo
    echo "  1) Public HTTPS via OpenShip Edge (Docker required)"
    echo "     Use OpenShip containerized Edge (:80/:443) with Let's Encrypt."
    echo
    echo "  2) Local / private"
    echo "     Dashboard stays on internal port 3001 without public ingress."
    echo "     Cloudflare Tunnel or custom VPN can be configured later."
    echo
    echo "  3) Public HTTPS via Caddy (Native, no Docker — Recommended for Bare)"
    echo "     Installs Caddy, auto-issues SSL certificate, and reverse-proxies"
    echo "     :80/:443 directly to OpenShip (:3001). Ultra-lightweight."
    echo
    echo "  4) Cancel"
    echo

    while true; do
        read -r -p "Select [3]: " reachability </dev/tty
        reachability="${reachability//[$'\r\n\t ']/}"
        reachability="${reachability:-3}"
        case "$reachability" in
            1)
                OPENSHIP_DOMAIN_KIND="custom"
                OPENSHIP_EDGE_ENABLED="true"
                OPENSHIP_PROXY_MODE="edge"
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
                OPENSHIP_PROXY_MODE="none"
                break
                ;;
            3)
                OPENSHIP_DOMAIN_KIND="byo"
                OPENSHIP_EDGE_ENABLED="false"
                OPENSHIP_PROXY_MODE="caddy"
                while true; do
                    OPENSHIP_HOST="$(ask_default "OpenShip domain (e.g. os.example.com)" "")"
                    if [[ "$OPENSHIP_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
                        break
                    fi
                    warn "Enter a valid DNS hostname, for example os.example.com."
                done
                OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"

                echo
                echo "Caddy SSL certificate mode for ${OPENSHIP_HOST}:"
                echo
                echo "  1) Automatic Let's Encrypt / ZeroSSL (Standard Caddy auto-TLS)"
                echo "     Caddy requests and renews certificates via ACME HTTP-01."
                echo "     Works with Cloudflare if proxy is bypassed or HTTP-01 is allowed."
                echo
                echo "  2) Cloudflare Origin CA certificate (Recommended for Cloudflare Full / Full strict)"
                echo "     Paste your 15-year Origin Certificate from Cloudflare Dashboard."
                echo "     Immune to ACME challenges, rate limits, and redirect loops."
                echo

                while true; do
                    read -r -p "Select SSL mode [1]: " ssl_choice </dev/tty
                    ssl_choice="${ssl_choice//[$'\r\n\t ']/}"
                    ssl_choice="${ssl_choice:-1}"
                    case "$ssl_choice" in
                        1)
                            CADDY_SSL_MODE="auto"
                            success "Caddy SSL: Automatic Let's Encrypt."
                            echo
                            echo -e "  ${YELLOW}Notice for Cloudflare users:${NC}"
                            echo -e "  ${DIM}If ${OPENSHIP_HOST} is on Cloudflare, ensure its DNS record is${NC}"
                            echo -e "  ${DIM}temporarily set to 'DNS only' (gray cloud) so Let's Encrypt can verify.${NC}"
                            echo -e "  ${DIM}You can switch back to 'Proxied' + Full (strict) immediately after install.${NC}"
                            echo
                            break
                            ;;
                        2)
                            CADDY_SSL_MODE="cloudflare_origin"
                            collect_cloudflare_origin_credentials "$OPENSHIP_HOST"
                            break
                            ;;
                        *)
                            echo "Invalid choice."
                            ;;
                    esac
                done
                break
                ;;
            4)
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
        hc_choice="${hc_choice//[$'\r\n\t ']/}"
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
            OPENSHIP_PROXY_MODE="${OPENSHIP_PROXY_MODE:-none}"
            OPENSHIP_NO_HOST_CONTROL="${OPENSHIP_NO_HOST_CONTROL:-false}"
            CADDY_SSL_MODE="${CADDY_SSL_MODE:-auto}"
            CADDY_ORIGIN_CERT_PATH="${CADDY_ORIGIN_CERT_PATH:-}"
            CADDY_ORIGIN_KEY_PATH="${CADDY_ORIGIN_KEY_PATH:-}"

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
OPENSHIP_PROXY_MODE=${OPENSHIP_PROXY_MODE:-none}
OPENSHIP_NO_HOST_CONTROL=${OPENSHIP_NO_HOST_CONTROL:-false}
CADDY_SSL_MODE=${CADDY_SSL_MODE:-auto}
CADDY_ORIGIN_CERT_PATH=${CADDY_ORIGIN_CERT_PATH:-}
CADDY_ORIGIN_KEY_PATH=${CADDY_ORIGIN_KEY_PATH:-}
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

    run_task "Updating package lists" apt-get update -qq

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
        systemd-timesyncd

    run_task "Cleaning up unused packages" apt-get autoremove -y -qq
}

# ------------------------------------------------------------------------------
# System update
# ------------------------------------------------------------------------------

update_system() {
    section "System update"

    run_task "Updating package lists" apt-get update -qq

    run_task "Upgrading system packages" env DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    run_task "Cleaning up package cache" bash -c "apt-get autoremove -y -qq && apt-get clean -qq"

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

    # Web ports (:80/:443) — only when Edge or Caddy is enabled.
    # In Private mode (no proxy), only SSH is exposed.
    if [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" || "${OPENSHIP_PROXY_MODE:-none}" == "caddy" ]]; then
        ufw allow 80/tcp \
            comment "Web HTTP (ACME + proxy)"

        ufw allow 443/tcp \
            comment "Web HTTPS"

        log "UFW: opened :80 (ACME challenge) and :443 (TLS) for web traffic."
    else
        log "UFW: Private mode — :80/:443 NOT opened (no public proxy)."
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
        success "OpenShip CLI already installed: $(openship --version 2>/dev/null || true)"
        return
    fi

    run_task "Downloading and installing OpenShip CLI" bash -c "curl -fsSL '$OPENSHIP_INSTALL_URL' | sh"

    export PATH="/root/.openship/bin:/usr/local/bin:/usr/bin:/bin:${PATH}"

    if ! command_exists openship && [[ -x "/root/.openship/bin/openship" ]]; then
        ln -sf \
            "/root/.openship/bin/openship" \
            "/usr/local/bin/openship"
    fi

    command_exists openship ||
        die "OpenShip CLI was not found after installation."

    success "OpenShip CLI ready: $(openship --version 2>/dev/null || true)"

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

    if [[ "$OPENSHIP_DOMAIN_KIND" == "custom" ]]; then
        # OpenShip Edge (:80/:443 via OpenResty Docker container + Let's Encrypt TLS)
        args+=(
            --hostname "$OPENSHIP_HOST"
            --public-url "$OPENSHIP_PUBLIC_URL"
            --edge takeover
            --acme-email "$OPENSHIP_ADMIN_EMAIL_INPUT"
        )
    elif [[ "$OPENSHIP_DOMAIN_KIND" == "byo" ]]; then
        # byo = Bring Your Own ingress (external reverse proxy handles TLS)
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
        configure_caddy
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
# Caddy Reverse Proxy
# ------------------------------------------------------------------------------

configure_caddy() {
    if [[ "${OPENSHIP_PROXY_MODE:-none}" != "caddy" ]]; then
        return
    fi

    section "Caddy Reverse Proxy"

    if ! command_exists caddy; then
        run_task "Adding Caddy repository" bash -c "
            apt-get update -qq
            apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl gnupg
            rm -f /etc/apt/sources.list.d/caddy-stable.sources
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg --yes 2>/dev/null || true
            curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
            apt-get update -qq
        "

        run_task "Installing Caddy web server" apt-get install -y -qq caddy
    else
        success "Caddy is already installed."
    fi

    local tls_directive=""
    if [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_origin" && -n "${CADDY_ORIGIN_CERT_PATH:-}" && -f "${CADDY_ORIGIN_CERT_PATH:-}" && -n "${CADDY_ORIGIN_KEY_PATH:-}" && -f "${CADDY_ORIGIN_KEY_PATH:-}" ]]; then
        tls_directive="    tls ${CADDY_ORIGIN_CERT_PATH} ${CADDY_ORIGIN_KEY_PATH}"
    fi

    run_task "Configuring Caddyfile (${OPENSHIP_HOST} -> :3001)" bash -c "
        mkdir -p /etc/caddy
        cat > /etc/caddy/Caddyfile <<EOF
${OPENSHIP_HOST} {
${tls_directive}
    reverse_proxy 127.0.0.1:3001 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
    }
}
EOF
        systemctl enable caddy
        systemctl restart caddy
    "

    success "Caddy configured and running for https://${OPENSHIP_HOST}"
}

# ------------------------------------------------------------------------------
# Post-install
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
        if [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_origin" ]]; then
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
    echo -e "${BOLD}${CYAN}"
    echo   "  ╔══════════════════════════════════════════════════════╗"
    echo   "  ║                                                      ║"
    printf "  ║   ⚓  %-46s  ║\n" "OpenShip Control Plane Installer"
    printf "  ║   %-48s  ║\n" "Version ${SCRIPT_VERSION}  ·  Ubuntu 24.04 LTS"
    echo   "  ║                                                      ║"
    echo   "  ╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

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