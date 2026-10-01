#!/usr/bin/env bash
# ==============================================================================
# OpenShip Installer — Docker Engine, Compose & Network
# ==============================================================================

install_docker() {
    section "Docker Engine"

    if [[ "$INSTALL_MODE" == "bare" && "${OPENSHIP_EDGE_ENABLED:-false}" != "true" && "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
        log "Bare mode with strict isolation (--no-host-control) and without Edge."
        log "Docker installation skipped."
        return
    fi

    if [[ "$INSTALL_MODE" == "bare" ]]; then
        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" != "true" ]]; then
            log "Host control is ENABLED: Docker Engine is required for OpenShip to monitor This Server."
        elif [[ "${OPENSHIP_EDGE_ENABLED:-false}" == "true" ]]; then
            log "OpenShip Edge (:80/:443) container requires Docker Engine."
        fi
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

        if [[ "${OPENSHIP_NO_HOST_CONTROL:-false}" == "true" ]]; then
            success "Bare runtime selected: OpenShip will start with --bare --no-host-control."
        else
            success "Bare runtime selected: OpenShip will start with --bare (host control enabled)."
        fi
        return
    fi

    command_exists docker ||
        die "Standard mode requires Docker."

    success "Standard runtime selected: OpenShip will use Docker Compose."
}

# ------------------------------------------------------------------------------
# OpenShip CLI
# ------------------------------------------------------------------------------


ensure_openship_docker_network() {
    local net_name="openship"
    if command_exists docker && docker info >/dev/null 2>&1; then
        if ! docker network inspect "" >/dev/null 2>&1; then
            run_task "Creating shared Docker network ''"                 docker network create --driver bridge --opt "com.docker.network.bridge.enable_icc=true" ""
        else
            ok "Docker network '' already exists"
        fi
    fi
}
