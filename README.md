<div align="center">

# ⚓ OpenShip Deploy

**Production-ready provisioning toolkit for [OpenShip](https://openship.io/) Control Plane**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#requirements)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](#license)

[🇷🇺 Русский](docs/README.ru.md) · [🇺🇦 Українська](docs/README.ua.md)

</div>

---

## Overview

**OpenShip Deploy** prepares a clean Ubuntu 24.04 LTS VPS as a dedicated **OpenShip Control Plane** — the lightweight management layer that orchestrates your production servers without ever serving application traffic itself.

The installer detects system resources, recommends the appropriate OpenShip runtime, hardens the host, and launches the official OpenShip setup. It deliberately separates OS provisioning from OpenShip itself: the script prepares the server; OpenShip manages its own application, domain, Edge, and deployment configuration.

---

## Architecture

```text
                    Internet
                       │
                   Cloudflare
                       │
       ┌───────────────┴───────────────┐
       │                               │
 os.example.com                   app.example.com
       │                               │
  Control VPS                      Prod VPS
 Ubuntu 24.04, 1–2 GB           Ubuntu 24.04, 4–8 GB
       │                               │
 OpenShip Edge :80/:443         OpenShip Edge :80/:443
       │                               │
 OpenShip Bare :3001            Laravel / CRM
  (Control Plane daemon)        MariaDB + Redis
       │
       └────── SSH management ─────────►
```

> [!IMPORTANT]
> **Key invariant**: The Control VPS is **never in the HTTP request path** of production applications.
> If the Control VPS goes down, all production apps continue running without interruption.

---

## Runtime Modes

| Mode | OpenShip Runtime | Proxy (:80/:443) | Docker | Min RAM | Best for |
|---|---|---|---|---|---|
| **Bare** | Native process + embedded DB | Edge container | Edge only | 1 GB | Dedicated Control Plane |
| **Standard** | Docker Compose | Edge container | Full stack | 2 GB | Full Docker environment |

On 1–2 GB VPS instances **Bare mode is recommended**: OpenShip runs as a lightweight native systemd service with an embedded database. Docker is used exclusively for the Edge container routing the control plane domain.

---

## Installation

### Option A — One-liner (recommended for a fresh VPS)

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

The installer is **fully interactive** — no command-line parameters required.

---

## What the Installer Does

1. Validates Ubuntu 24.04 LTS and architecture (amd64 / arm64)
2. Checks CPU, RAM, disk — recommends Bare on &lt; 2 GB RAM
3. Selects installation mode (Bare / Standard)
4. Collects hostname, timezone, SSH port, admin user
5. Configures OpenShip domain and Edge TLS (Let's Encrypt HTTP-01)
6. Sets **host control mode** — whether the dashboard terminal can reach this VPS
7. Installs base packages and applies system tuning (swap, journald, file limits)
8. Creates a dedicated Linux admin account and hardens SSH
9. Configures UFW firewall and Fail2ban
10. Enables automatic security updates
11. Installs Docker (Edge only in Bare, full stack in Standard)
12. Installs the official OpenShip CLI from [get.openship.io](https://get.openship.io)
13. Runs OpenShip first-time setup (`--bare --non-interactive`)
14. Polls API health-check; rolls back automatically on failure
15. Prints a post-install verification summary

---

## Host Control Mode

During installation you choose whether OpenShip should manage this VPS as a server:

| Option | Dashboard terminal | Server in OpenShip | Notes |
|---|---|---|---|
| **Full control** *(default)* | ✅ Works | ✅ Visible | Same as v2.1.2 — recommended |
| **Strict isolation** (`--no-host-control`) | ❌ Blocked | ❌ Hidden | Maximum isolation |

> [!NOTE]
> The default is **Full control**. Choose Strict isolation only if the Control VPS must be invisible to the OpenShip server list.

---

## Domain Configuration

| Option | How it works |
|---|---|
| **Public HTTPS domain** | OpenShip Edge (:80/:443) handles TLS via Let's Encrypt (HTTP-01 challenge). Point DNS/Cloudflare A-record to this VPS IP. |
| **Private / local** | Dashboard stays on internal port 3001. Only SSH is exposed in UFW. Configure Cloudflare Tunnel or VPN later. |

> [!NOTE]
> Application domains (Laravel, CRM, etc.) are **not configured here**. They belong to the OpenShip deployment layer and are set per-project after adding production servers.

---

## Worker Database Services (MariaDB + Redis)

For production/worker VPS nodes this repository provides an isolated **MariaDB 11.4 + Redis 7.4** Docker stack.

```bash
# On the worker node
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
sudo ./deploy-services.sh
```

Or deploy `services/mariadb-redis/docker-compose.yml` directly from the OpenShip web UI as a Git stack.

### Project network

Attach your application container to the shared `openship-network`:

```yaml
# project docker-compose.yml
networks:
  default:
    name: openship-network
    external: true
```

### Environment variables

```env
DB_HOST=mariadb
DB_PORT=3306
DB_CONNECTION=mysql
DB_DATABASE=your_project_db
DB_USERNAME=root
DB_PASSWORD=your_mariadb_root_password

REDIS_HOST=redis
REDIS_PORT=6379
REDIS_CLIENT=phpredis
REDIS_PASSWORD=your_redis_password
```

### Stack management

```bash
sudo ./deploy-services.sh --status    # Health check
sudo ./deploy-services.sh --logs      # Live logs
sudo ./deploy-services.sh --restart   # Restart containers
sudo ./deploy-services.sh --pull      # Pull latest images
sudo ./deploy-services.sh --stop      # Stop (volumes preserved)
```

### Backups

```bash
cd services/mariadb-redis
sudo ./backup.sh          # Run backup now
sudo ./backup.sh --list   # List existing backups
sudo ./backup.sh --cron   # Install daily cron at 03:00 UTC
```

---

## Updating OpenShip

```bash
sudo ./update.sh --check   # Check for available update
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

> [!NOTE]
> The OpenShip administrator password is **never stored** in the installer state file.

---

## Project Structure

```text
OpenShip-deploy/
├── install.sh                  # Control Plane provisioner
├── update.sh                   # OpenShip update helper
├── doctor.sh                   # System & service diagnostics
├── deploy-services.sh          # Worker database stack runner
├── config/
│   └── defaults.env.example    # Environment variable reference
├── docs/
│   ├── README.ru.md            # Документация на русском
│   └── README.ua.md            # Документація українською
├── services/
│   └── mariadb-redis/
│       ├── docker-compose.yml
│       ├── .env.example
│       ├── deploy.sh
│       └── backup.sh
└── README.md                   # This file (EN)
```

---

## Requirements

- **OS**: Ubuntu 24.04 LTS
- **Access**: root or sudo
- **RAM**: 768 MiB minimum (Bare) · 2 GB+ recommended (Standard)
- **Disk**: 10 GB free minimum
- **Arch**: amd64 or arm64

---

## Security Notes

- SSH access is preserved throughout provisioning.
- Password authentication is disabled only when an admin SSH key is detected.
- UFW opens `:80/:443` exclusively when OpenShip Edge is enabled.
- Dashboard `:3001` and API `:4000` are never exposed directly by UFW.
- Fail2ban: 5 attempts / 10 min / 1 hour ban.
- Secrets are passed via environment and are not written to the state file.
- Health-check failure triggers automatic rollback — service is stopped and logs are printed.

---

## Official Documentation

[openship.io/docs](https://openship.io/docs/)

---

## License

MIT


> Production-ready interactive installer for an OpenShip Control Plane on Ubuntu 24.04 LTS.
