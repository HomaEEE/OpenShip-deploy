#!/usr/bin/env bash
# ==============================================================================
# OpenShip Installer — Security, SSH, UFW, Fail2ban
# ==============================================================================

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

    systemctl reload ssh 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true

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

        ufw allow 443/udp \
            comment "Web HTTPS (HTTP/3 QUIC)"

        log "UFW: opened :80 (ACME challenge), :443/tcp (TLS), and :443/udp (HTTP/3 QUIC) for web traffic."
    else
        log "UFW: Private mode — :80/:443 NOT opened (no public proxy)."
    fi

    # Ensure Docker container bridge forwarding is permitted by UFW
    if [[ -f /etc/default/ufw ]]; then
        sed -i -E 's/^DEFAULT_FORWARD_POLICY=.*/DEFAULT_FORWARD_POLICY="ACCEPT"/' /etc/default/ufw 2>/dev/null || true
    fi

    # Repair any corrupted single quotes in UFW rule files
    for f in /etc/ufw/user.rules /etc/ufw/user6.rules; do
        if [[ -f "$f" ]]; then
            sed -i "s/Let's Encrypt/Lets Encrypt/g" "$f" 2>/dev/null || true
            sed -i "s/'s /s /g" "$f" 2>/dev/null || true
        fi
    done

    # Ensure ports 3001 and 4000 are closed externally (Caddy reverse-proxies :80/:443 to localhost)
    ufw delete allow 3001/tcp >/dev/null 2>&1 || true
    ufw delete allow 3001 >/dev/null 2>&1 || true
    ufw delete allow 4000/tcp >/dev/null 2>&1 || true
    ufw delete allow 4000 >/dev/null 2>&1 || true

    ufw --force enable

    success "UFW enabled (ports 3001/4000 secured, Docker bridge forwarding enabled)."
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

