#!/usr/bin/env bash
# ==============================================================================
# OpenShip Installer — Caddy Reverse Proxy & Cloudflare SSL
# ==============================================================================

collect_cloudflare_origin_credentials() {
    local domain="$1"
    local cert_file="/etc/caddy/certs/${domain}.crt"
    local key_file="/etc/caddy/certs/${domain}.key"

    mkdir -p /etc/caddy/certs
    chmod 755 /etc/caddy/certs

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
                if [[ "$line" == *"END "* && "$line" == *"KEY-----"* ]]; then
                    break
                fi
            done
            chmod 640 "$key_file"

            if grep -q "BEGIN" "$key_file" && grep -q "END" "$key_file" && grep -q "KEY" "$key_file"; then
                success "Private key captured."
                break
            fi
            warn "Invalid private key: missing 'BEGIN' or 'END' markers. Try again."
        done
    fi

    CADDY_ORIGIN_CERT_PATH="$cert_file"
    CADDY_ORIGIN_KEY_PATH="$key_file"
    success "Cloudflare Origin CA certificate and key configured."
}


install_caddy_package() {
    rm -f /etc/apt/sources.list.d/caddy*.sources /etc/apt/sources.list.d/caddy*.list /etc/apt/trusted.gpg.d/caddy*.gpg /usr/share/keyrings/caddy*.gpg

    local arch
    arch="$(dpkg --print-architecture 2>/dev/null || uname -m)"
    [[ "$arch" == "x86_64" ]] && arch="amd64"
    [[ "$arch" == "aarch64" ]] && arch="arm64"

    local tag ver deb_url
    tag="$(basename "$(curl -sIL -o /dev/null -w '%{url_effective}' https://github.com/caddyserver/caddy/releases/latest 2>/dev/null)")"
    ver="${tag#v}"
    if [[ -n "$ver" && "$ver" =~ ^[0-9]+\.[0-9]+ ]]; then
        deb_url="https://github.com/caddyserver/caddy/releases/download/${tag}/caddy_${ver}_linux_${arch}.deb"
    else
        deb_url="https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_${arch}.deb"
    fi

    if ! curl -fsSL "$deb_url" -o /tmp/caddy.deb || [[ ! -s /tmp/caddy.deb ]]; then
        curl -fsSL "https://github.com/caddyserver/caddy/releases/download/v2.8.4/caddy_2.8.4_linux_${arch}.deb" -o /tmp/caddy.deb
    fi

    dpkg -i /tmp/caddy.deb || (apt-get install -f -y -qq && dpkg -i /tmp/caddy.deb)
    rm -f /tmp/caddy.deb

    command -v caddy >/dev/null 2>&1
}

configure_caddy() {
    if [[ "${OPENSHIP_PROXY_MODE:-none}" != "caddy" ]]; then
        return
    fi

    section "Caddy Reverse Proxy"

    if ! command_exists caddy; then
        run_task "Installing Caddy web server" install_caddy_package
    else
        success "Caddy is already installed."
    fi

    local site_address="${OPENSHIP_HOST}"
    local tls_directive=""
    local proto_header="        header_up X-Forwarded-Proto https"

    if [[ -z "${OPENSHIP_HOST}" || "${CADDY_SSL_MODE:-auto}" == "http_ip" ]]; then
        site_address=":80"
        proto_header=""
    elif [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_flexible" ]]; then
        site_address="http://${OPENSHIP_HOST}"
    elif [[ "${CADDY_SSL_MODE:-auto}" == "cloudflare_origin" && -n "${CADDY_ORIGIN_CERT_PATH:-}" && -f "${CADDY_ORIGIN_CERT_PATH:-}" && -n "${CADDY_ORIGIN_KEY_PATH:-}" && -f "${CADDY_ORIGIN_KEY_PATH:-}" ]]; then
        tls_directive="    tls ${CADDY_ORIGIN_CERT_PATH} ${CADDY_ORIGIN_KEY_PATH}"
        chown -R caddy:caddy /etc/caddy/certs 2>/dev/null || true
        chmod 755 /etc/caddy/certs 2>/dev/null || true
        chmod 644 /etc/caddy/certs/*.crt 2>/dev/null || true
        chmod 640 /etc/caddy/certs/*.key 2>/dev/null || true
    fi

    write_caddyfile() {
        mkdir -p /etc/caddy
        cat > /etc/caddy/Caddyfile <<EOF
${site_address} {
${tls_directive}
    # OpenShip API (port 4000) for frontend same-origin proxy (including terminal WebSockets)
    handle_path /api/proxy/* {
        reverse_proxy 127.0.0.1:4000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
${proto_header}
        }
    }

    # OpenShip API (port 4000) for direct API requests
    handle /api/* {
        reverse_proxy 127.0.0.1:4000 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
${proto_header}
        }
    }

    # OpenShip Dashboard UI (port 3001) for all other web requests
    handle {
        reverse_proxy 127.0.0.1:3001 {
            header_up Host {host}
            header_up X-Real-IP {remote_host}
${proto_header}
        }
    }
}
EOF
        chmod 644 /etc/caddy/Caddyfile
        systemctl enable caddy
        systemctl restart caddy
    }

    run_task "Configuring Caddyfile (${site_address} -> :3001, :4000)" write_caddyfile

    verify_caddy_service() {
        for i in {1..5}; do
            if systemctl is-active --quiet caddy; then
                return 0
            fi
            sleep 1
        done
        journalctl -u caddy --no-pager -n 20
        return 1
    }

    run_task "Verifying Caddy service health" verify_caddy_service

    success "Caddy configured and running for ${OPENSHIP_PUBLIC_URL}"
}

# ------------------------------------------------------------------------------
# Post-install
# ------------------------------------------------------------------------------

