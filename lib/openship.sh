#!/usr/bin/env bash
# ==============================================================================
# OpenShip Installer — OpenShip CLI, Runtime & Service Setup
# ==============================================================================

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
    local default_host="${OPENSHIP_HOST:-}"
    if [[ -z "$default_host" && "$HOSTNAME_INPUT" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
        default_host="$HOSTNAME_INPUT"
    fi
    OPENSHIP_HOST="$default_host"
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
    if [[ -n "$default_host" ]]; then
        echo -e "  ${DIM}Pre-filled domain from hostname: ${BOLD}${default_host}${NC}"
        echo
    fi

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
                    OPENSHIP_HOST="$(ask_default "OpenShip domain" "${default_host:-os.example.com}")"
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
                if [[ -n "$default_host" ]]; then
                    OPENSHIP_HOST="$(ask_default "OpenShip domain" "$default_host")"
                else
                    OPENSHIP_HOST="$(ask_default "OpenShip domain (or press Enter for direct IP on :80)" "")"
                fi
                if [[ -n "$OPENSHIP_HOST" ]]; then
                    while true; do
                        if [[ "$OPENSHIP_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z]{2,}$ ]]; then
                            break
                        fi
                        warn "Enter a valid DNS hostname, for example os.example.com."
                        OPENSHIP_HOST="$(ask_default "OpenShip domain" "$default_host")"
                    done
                    OPENSHIP_PUBLIC_URL="https://$OPENSHIP_HOST"

                    echo
                    echo "Caddy proxy / SSL mode for ${OPENSHIP_HOST}:"
                    echo
                    echo "  1) Cloudflare Flexible mode (Recommended if Cloudflare is in Flexible)"
                    echo "     Caddy listens on HTTP (:80), no SSL certificates needed on server."
                    echo "     Cloudflare handles HTTPS for clients. Zero maintenance, no redirect loops."
                    echo
                    echo "  2) Cloudflare Origin CA certificate (For Cloudflare Full / Full strict)"
                    echo "     Paste your 15-year Origin Certificate from Cloudflare Dashboard."
                    echo "     Immune to ACME challenges and rate limits."
                    echo
                    echo "  3) Automatic Let's Encrypt / ZeroSSL (Standard Caddy auto-TLS)"
                    echo "     Caddy requests and renews certificates via ACME HTTP-01."
                    echo

                    while true; do
                        read -r -p "Select SSL mode [1]: " ssl_choice </dev/tty
                        ssl_choice="${ssl_choice//[$'\r\n\t ']/}"
                        ssl_choice="${ssl_choice:-1}"
                        case "$ssl_choice" in
                            1)
                                CADDY_SSL_MODE="cloudflare_flexible"
                                success "Caddy mode: Cloudflare Flexible (HTTP :80, no local SSL)."
                                break
                                ;;
                            2)
                                CADDY_SSL_MODE="cloudflare_origin"
                                collect_cloudflare_origin_credentials "$OPENSHIP_HOST"
                                break
                                ;;
                            3)
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
                            *)
                                echo "Invalid choice."
                                ;;
                        esac
                    done
                else
                    SERVER_IP="$(curl -4s --max-time 3 ifconfig.me 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')"
                    OPENSHIP_PUBLIC_URL="http://${SERVER_IP:-localhost}"
                    CADDY_SSL_MODE="http_ip"
                    success "Caddy mode: direct IP HTTP on port :80 (${OPENSHIP_PUBLIC_URL})."
                fi
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
        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
            echo "OpenShip will use the explicit --bare runtime mode with --no-host-control."
        else
            echo "OpenShip will use the explicit --bare runtime mode with host control enabled."
        fi
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

