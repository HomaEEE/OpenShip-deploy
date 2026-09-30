<div align="center">

# ⚓ OpenShip Deploy

**Production-ready provisioning toolkit for [OpenShip](https://openship.io/) Control Plane & Worker Infrastructure**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#requirements)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](#license)

[🇷🇺 Русский](docs/README.ru.md) · [🇺🇦 Українська](docs/README.ua.md)

</div>

---

## Overview

**OpenShip Deploy** is an automated, production-ready toolkit designed for:
1. **Control Plane Provisioning**: Prepares a clean Ubuntu 24.04 LTS VPS as a dedicated OpenShip Control Plane with security hardening, automated updates, and diagnostics.
2. **Worker Database Services**: Provides an isolated, pre-tuned **MariaDB 11.4 LTS + Redis 7.4 Alpine** stack accessible exclusively via the internal Docker network (`openship-openship-deploy`, configurable via `OPENSHIP_NETWORK`).
3. **Application Templates**: Includes a production-ready **Laravel + FrankenPHP** template with auto-provisioning databases, zero-config migrations, and OpenShip domain routing.

---

## Architecture

```text
                    Internet
                       │
                   Cloudflare
                       │
       ┌───────────────┴───────────────┐
       │                               │
 os.example.com                   noire.od.ua (apps)
       │                               │
  Control VPS                      Prod VPS
 Ubuntu 24.04, 1–2 GB           Ubuntu 24.04, 4–8 GB
       │                               │
 OpenShip Edge :80/:443         OpenShip Edge :80/:443
       │                               │
 OpenShip Bare :3001            Laravel (FrankenPHP)
  (Control Plane daemon)               │ (openship-openship-deploy)
       │                        ┌──────┴──────┐
       │                        │             │
       │                   MariaDB:3306  Redis:6379
       │
       └────── SSH management ─────────►
```

> [!IMPORTANT]
> **Key Invariant**: The Control VPS is **never in the HTTP request path** of production applications.
> If the Control VPS goes down, all production apps continue running without interruption.

---

## Control Plane Installation

### Runtime Modes

| Mode | OpenShip Runtime | Proxy (:80/:443) | Docker | Min RAM | Best for |
|---|---|---|---|---|---|
| **Bare** *(recommended)* | Native process + embedded DB | Edge container | Edge only | 1 GB | Dedicated Control Plane |
| **Standard** | Docker Compose | Edge container | Full stack | 2 GB | Full Docker environment |

On 1–2 GB VPS instances **Bare mode is recommended**: OpenShip runs as a lightweight native systemd service with an embedded database. Docker is used exclusively for the Edge container routing the control plane domain.

### Option A — One-liner (recommended for fresh VPS)

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
```

### Option B — Clone and run

```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
chmod +x *.sh
sudo ./install.sh
```

### Option C — Pre-hardening + Upstream Wizard (`install-interactive.sh`)

Automatically configures server security & environment (swap, sysctl, journald, UFW, Fail2ban, Docker), downloads the official OpenShip CLI from `openship.io`, and hands over full interactive control directly to OpenShip's setup wizard:

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install-interactive.sh | sudo bash
```

Or via clone:
```bash
sudo ./install-interactive.sh
```

### What `install.sh` does

1. Validates OS (Ubuntu 24.04 LTS), root/sudo privileges, architecture (`amd64`/`arm64`).
2. Checks available RAM and automatically configures swap if needed.
3. Hardens SSH (preserves key access, disables root password login if keys exist).
4. Configures UFW firewall (SSH, and Edge ports `:80/:443` when public domain is configured).
5. Configures Fail2ban for brute-force protection.
6. Installs official Docker Engine and Compose plugin.
7. Installs Node.js / Bun runtime for OpenShip daemon.
8. Launches OpenShip first-time setup (`--bare --non-interactive`).
9. Polls API health-check; rolls back automatically on failure.
10. Prints post-install verification summary and login URL.

---

## Host Control Mode

During installation you choose whether OpenShip should manage the Control VPS as an execution server:

| Option | Dashboard terminal | Server in OpenShip | Notes |
|---|---|---|---|
| **Full control** *(default)* | ✅ Works | ✅ Visible | Recommended |
| **Strict isolation** (`--no-host-control`) | ❌ Blocked | ❌ Hidden | Maximum isolation |

---

## Domain Configuration

| Option | How it works |
|---|---|
| **Public HTTPS domain** | OpenShip Edge (:80/:443) handles TLS via Let's Encrypt (HTTP-01 challenge). Point DNS/Cloudflare A-record to this VPS IP. |
| **Private / local** | Dashboard stays on internal port 3001. Only SSH is exposed in UFW. Configure Cloudflare Tunnel or VPN later. |

---

## Shared Database Services (MariaDB + Redis)

For production/worker nodes, this repository provides a dedicated **MariaDB 11.4 LTS + Redis 7.4 Alpine** stack.

### 1. Direct OpenShip Deployment (Recommended)
This repository contains a root `docker-compose.yml` and `openship.json`. You can add this repository as a project in your OpenShip dashboard and deploy it directly with zero configuration:

- **Network**: Registers in `openship-openship-deploy` (or `OPENSHIP_NETWORK`) under aliases `mariadb` and `redis`.
- **Security**: Ports `3306` and `6379` are **not exposed to the host or internet**. Accessible only to containers on `openship-openship-deploy`.

### 2. Manual CLI Deployment
```bash
# On the worker node
cd OpenShip-deploy
sudo ./deploy-services.sh
```

Management commands:
```bash
sudo ./deploy-services.sh --status    # Check container health
sudo ./deploy-services.sh --logs      # View live logs
sudo ./deploy-services.sh --restart   # Restart services
sudo ./deploy-services.sh --stop      # Stop (volumes preserved)
```

### 3. Automated Backups
The included [`backup.sh`](backup.sh) script creates compressed daily database dumps with automatic 7-day retention:

```bash
# Run backup immediately
sudo ./backup.sh

# Install daily cron job (runs at 03:00 UTC)
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/mariadb-backup.sh >> /var/log/mariadb-backup.log 2>&1") | crontab -
```
Backups are stored in `/var/backups/mariadb/`.

---

## Deploying Laravel Applications

Use the ready-to-go universal template in [`templates/laravel-frankenphp/`](templates/laravel-frankenphp/):

1. Copy `deploy/`, `openship.json`, and `.github/workflows/deploy.yml` into your Laravel project root.
2. In OpenShip project settings, configure:
   - `DB_DATABASE=your_app`
   - `DB_USERNAME=your_app`
   - `DB_PASSWORD=your_secure_password`
   - `DB_ROOT_PASSWORD=openship_root_secret` (only needed during first deploy; wiped from memory after creation)
   - `APP_KEY=base64:...`
3. On first startup, `entrypoint.sh`:
   - Auto-discovers MariaDB and Redis in `openship-openship-deploy`.
   - Creates the database and user automatically via PHP PDO.
   - Runs migrations (`php artisan migrate --force`).
   - Caches configs, routes, views, icons.
   - Starts FrankenPHP on port 80 with Cloudflare/OpenShip trusted proxy support.

---

## Updating OpenShip

```bash
sudo ./update.sh --check   # Check for available updates
sudo ./update.sh           # Apply update
```

---

## Diagnostics

```bash
sudo ./doctor.sh
```

Checks: OS · architecture · CPU/RAM/disk · swap · installer state · OpenShip CLI · OpenShip status · Node/Bun · Docker · listening ports · SSH · UFW · Fail2ban

---

## Logs & State

| File | Contents |
|---|---|
| `/var/log/openship-control-install.log` | Installation log |
| `/var/log/openship-control-update.log` | Update log |
| `/var/log/openship-control-doctor.log` | Diagnostic log |
| `/etc/openship-control/install.conf` | Installer state |

---

## Project Structure

```text
OpenShip-deploy/
├── install.sh                  # Control Plane provisioner
├── update.sh                   # OpenShip update helper
├── doctor.sh                   # System & service diagnostics
├── deploy-services.sh          # Worker database stack runner
├── backup.sh                   # Automated MariaDB backup script
├── docker-compose.yml          # Root MariaDB + Redis compose (for OpenShip Git deploy)
├── openship.json               # OpenShip descriptor
├── .env.example                # Environment variables reference
├── config/
│   └── defaults.env.example    # Installer defaults
├── docs/
│   ├── README.ru.md            # Документация на русском
│   └── README.ua.md            # Документація українською
├── services/
│   └── mariadb-redis/          # Shared database stack source
└── templates/
    └── laravel-frankenphp/     # Universal Laravel + FrankenPHP deploy template
        ├── deploy/
        │   ├── Caddyfile
        │   ├── Dockerfile
        │   ├── docker-compose.yml
        │   ├── entrypoint.sh
        │   └── php.ini
        ├── openship.json
        ├── .github/workflows/deploy.yml
        └── README.md
```

---

## Requirements

- **OS**: Ubuntu 24.04 LTS
- **Access**: root or sudo
- **RAM**: 1 GB minimum (Bare) · 2 GB+ recommended (Standard)
- **Disk**: 10 GB free minimum
- **Arch**: amd64 or arm64

---

## Official Documentation

- [openship.io/docs](https://openship.io/docs/)
- [Laravel Documentation](https://laravel.com/docs)
- [FrankenPHP Documentation](https://frankenphp.dev/)

---

## License

MIT
