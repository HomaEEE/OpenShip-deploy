<div align="center">

# ⚓ OpenShip Deploy

**Production-ready provisioning toolkit for [OpenShip](https://openship.io/) Control Plane & Worker Infrastructure**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#requirements)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](#license)

| 🇬🇧 **English** | [🇷🇺 Русский](docs/README.ru.md) | [🇺🇦 Українська](docs/README.ua.md) |
| :---: | :---: | :---: |

</div>

---

## Quick Start

### 1. Control Plane Provisioning
Set up a clean Ubuntu 24.04 LTS VPS with security hardening, swap, UFW, Caddy, and OpenShip:

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
```

Or clone and inspect before running:
```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy && chmod +x *.sh
sudo ./install.sh
```

### 2. System & OpenShip Diagnostics (`doctor.sh`)
Validate your Control Plane status, Caddy reverse-proxy routing, ports, and firewall rules in one command:

```bash
# Run directly via curl (no clone needed)
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/doctor.sh | sudo bash

# Or locally if cloned
sudo ./doctor.sh
```

---

## Architecture

```text
                    Internet
                       │
                   Cloudflare
                       │
       ┌───────────────┴───────────────┐
       │                               │
 os.example.com                   apps.example.com
       │                               │
  Control VPS                      Worker VPS
 Ubuntu 24.04 (1–2 GB)            Ubuntu 24.04 (4–8 GB)
       │                               │
  Caddy :80/:443                  OpenShip Edge :80/:443
   ├── :3001 (Dashboard UI)            │
   └── :4000 (API & WebSockets)    Laravel (FrankenPHP)
       │                               │ (openship)
       │                        ┌──────┴──────┐
       │                        │             │
       │                   MariaDB:3306  Redis:6379
       │
       └────── SSH management ─────────►
```

> [!IMPORTANT]
> **Key Invariant**: The Control VPS is **never in the HTTP request path** of production apps. If the Control VPS goes down, all production apps continue running uninterrupted.

---

## Control Plane Setup

### Runtime Modes

| Mode | Runtime | Proxy | Min RAM | Use Case |
|---|---|---|---|---|
| **Bare** *(Recommended)* | Native process + embedded DB | Caddy reverse proxy | 1 GB | Dedicated Control VPS (efficient, fast) |
| **Standard** | Docker Compose stack | OpenShip Edge container | 2 GB | Full Docker-based setup |

### Caddy Reverse Proxy (Bare Mode)
In Bare mode, Caddy handles public ingress and routes traffic internally:
- `handle_path /api/proxy/*` → `127.0.0.1:4000` (OpenShip API & terminal WebSockets)
- `handle /api/*` → `127.0.0.1:4000` (Direct API endpoints)
- `handle` → `127.0.0.1:3001` (Dashboard UI)
- Ports `3001` and `4000` are strictly blocked from external access via UFW.

---

## Diagnostics (`doctor.sh`)

[`doctor.sh`](doctor.sh) is a comprehensive diagnostic utility for the OpenShip Control Plane.

### Running Diagnostics

```bash
# Direct run
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/doctor.sh | sudo bash

# Local run
sudo ./doctor.sh
```

### What `doctor.sh` Validates

| Check | What is Verified |
|---|---|
| **Host Resources** | OS version, Kernel, CPU cores, RAM, Swap, Free disk space |
| **Control Plane** | CLI installation, version, systemd service state (`openship.service`) |
| **Caddy Proxy** | Caddy active status, Caddyfile routing (`:3001` UI and `:4000` API/WS) |
| **Listening Ports** | `ss -lntp` validation for SSH, `:3001` (Dashboard), `:4000` (API) |
| **Docker & Sockets** | Daemon health, `/var/run/docker.sock` accessibility for Host Control |
| **Firewall (UFW)** | Ports `:80`, `:443`, SSH allowed; `:3001` and `:4000` closed to public |
| **Security** | Fail2ban service and SSH jail activity |

*Diagnostics automatically log to `/var/log/openship-doctor.log`.*

---

## Worker Databases (MariaDB + Redis)

For production application nodes:

### Direct OpenShip Deploy
Add this repo as an OpenShip project. The root `docker-compose.yml` launches **MariaDB 11.4 LTS + Redis 7.4 Alpine** into `openship`. Ports are not exposed to the internet.

### CLI Deploy & Management
```bash
sudo ./deploy-services.sh             # Start stack
sudo ./deploy-services.sh --status    # Check container health
sudo ./deploy-services.sh --logs      # Stream logs
sudo ./deploy-services.sh --restart   # Restart stack
sudo ./deploy-services.sh --stop      # Stop stack (data preserved)
```

### Automated Backups
```bash
sudo ./backup.sh
sudo ./restore.sh                      # Instant compressed MariaDB backup
# Cron daily backup at 03:00 UTC (7-day retention in /var/backups/mariadb/):
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/mariadb-backup.sh >> /var/log/mariadb-backup.log 2>&1") | crontab -
```

---

## Application Templates

[`templates/laravel-frankenphp/`](templates/laravel-frankenphp/) provides a zero-downtime, production-ready Laravel 11/12 template:
- FrankenPHP Caddy-based server on port 80 with HTTP/3 and worker mode.
- Auto-discovers MariaDB and Redis on the internal network.
- Automatically provisions database and user via PDO on first boot.
- Runs `artisan migrate --force` and caches configuration/routes/views.

---

## Maintenance & Updates

```bash
sudo ./update.sh --check   # Check for OpenShip updates
sudo ./update.sh           # Apply update
```

---

## Project Structure

```text
OpenShip-deploy/
├── install.sh                  # Control Plane automated installer
├── doctor.sh                   # System & OpenShip diagnostic tool
├── update.sh                   # OpenShip update helper
├── deploy-services.sh          # Worker MariaDB + Redis stack manager
├── backup.sh                   # Automated MariaDB backup script
├── docker-compose.yml          # Root MariaDB + Redis compose for OpenShip Git deploy
├── openship.json               # OpenShip descriptor
├── templates/
│   └── laravel-frankenphp/     # Production Laravel + FrankenPHP deploy template
└── docs/
    ├── README.ru.md            # Документация на русском
    └── README.ua.md            # Документація українською
```

---

## Requirements

- **OS**: Ubuntu 24.04 LTS (amd64 / arm64)
- **Privileges**: root or sudo
- **Control VPS**: 1 GB+ RAM (Bare mode), 10 GB disk
- **Worker VPS**: 2–8 GB+ RAM (depending on workload)

---

## License

MIT
