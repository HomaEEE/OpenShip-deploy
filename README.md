# OpenShip Deploy

> Production-ready interactive installer for an OpenShip Control Plane on Ubuntu 24.04 LTS.

[English](#english) · [Русский](#русский) · [Українська](#українська)

---

## English

### Overview

**OpenShip Deploy** is a lightweight provisioning toolkit for preparing a clean Ubuntu 24.04 LTS VPS as an [OpenShip](https://openship.io/) Control Plane.

The installer is designed for both small and standard VPS instances. It detects system resources, recommends the appropriate OpenShip runtime, configures the host, and starts the official OpenShip installation flow.

The project intentionally keeps infrastructure configuration separate from OpenShip itself: the installer prepares the operating system, while OpenShip remains responsible for its own application, dashboard, domain and deployment configuration.

### Features

- Ubuntu 24.04 LTS support
- x86_64/amd64 and ARM64 support
- Automatic CPU, RAM and disk detection
- Interactive **Bare / Standard** runtime selection
- Automatic warning and Bare recommendation on VPS instances below 2 GB RAM
- **Bare mode** using OpenShip's official `--bare` runtime
- **Standard mode** using Docker Compose
- Optional 2 GB swap configuration
- Dedicated Linux administrator account
- SSH configuration and hardening
- Optional UFW firewall
- Optional Fail2ban protection for SSH
- Automatic security updates
- Docker installation only when Standard mode is selected
- OpenShip CLI installation from the official installer
- OpenShip administrator bootstrap in Bare mode
- Optional OpenShip custom domain during installation
- Persistent installer configuration
- Installation and update logs
- Post-installation diagnostics
- Separate update and doctor scripts

### Runtime modes

| Mode | Docker | Recommended RAM | Use case |
|---|---:|---:|---|
| **Bare** | No | 1–2 GB | Lightweight Control Plane |
| **Standard** | Yes | 2+ GB | Full Docker-based installation |

On a small VPS, Bare mode avoids the additional Docker/Compose stack and uses OpenShip's embedded database/runtime.

### Installation

Run on a clean Ubuntu 24.04 VPS:

```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
chmod +x *.sh
sudo ./install.sh
```

The installer is intentionally interactive. **No command-line parameters are required.**

### Installation flow

The installer performs:

1. Operating system validation
2. Architecture detection
3. Resource detection
4. Runtime selection
5. Hostname/timezone configuration
6. Base package installation
7. Swap configuration
8. Administrator account setup
9. SSH configuration
10. Firewall configuration
11. Fail2ban configuration
12. Automatic security update configuration
13. Docker installation when required
14. OpenShip CLI installation
15. OpenShip pre-flight checks
16. OpenShip first-run setup
17. Post-install verification

### OpenShip domain

The installer only asks about the **Control Plane domain**.

You can choose:

- **This machine only** — configure OpenShip without a public domain.
- **Custom domain** — provide a hostname such as `ops.example.com`.

Application domains are deliberately not configured by this installer. They belong to the OpenShip deployment/Edge layer and are configured later for individual projects.

This keeps the installer small and avoids duplicating OpenShip's own networking configuration.

### Files

```text
OpenShip-deploy/
├── install.sh                  # Initial Control Plane provisioning
├── update.sh                   # OpenShip update wrapper
├── doctor.sh                   # Host, OpenShip, and database diagnostics
├── deploy-services.sh          # Worker database services launcher
├── config/
│   └── defaults.env.example    # Configuration environment examples
├── services/
│   └── mariadb-redis/          # MariaDB + Redis stack for worker nodes
│       ├── docker-compose.yml
│       ├── .env.example
│       ├── deploy.sh
│       └── backup.sh
└── README.md                   # Documentation
```

### Logs and state

Installer log:

```text
/var/log/openship-control-install.log
```

Installer state:

```text
/etc/openship-control/install.conf
```

Update log:

```text
/var/log/openship-control-update.log
```

Diagnostic log:

```text
/var/log/openship-control-doctor.log
```

The OpenShip administrator password is **not stored** in the installer state file.

### Updating OpenShip

Check for an available update:

```bash
sudo ./update.sh --check
```

Run the update:

```bash
sudo ./update.sh
```

### Diagnostics

Run the diagnostic script:

```bash
sudo ./doctor.sh
```

It checks, among other things:

- OS and architecture
- CPU/RAM/disk
- swap
- installer state
- OpenShip CLI
- OpenShip status
- OpenShip doctor
- Node/Bun
- Docker when installed
- listening ports
- SSH configuration
- UFW
- Fail2ban

### Recommended architecture

The intended deployment model is:

```text
                    ┌─────────────────────────┐
                    │   OpenShip Control Plane │
                    │       Bare / Standard    │
                    └────────────┬────────────┘
                                 │
                         manages nodes
                                 │
              ┌──────────────────┴──────────────────┐
              │                                     │
       Deployment Node 1                     Deployment Node 2
              │                                     │
             Edge                                  Edge
              │                                     │
        ┌─────┼─────┐                         ┌─────┼─────┐
        │     │     │                         │     │     │
       App   App   App                       CRM   Site  Bot
```

The Control Plane should remain dedicated to management. Laravel/Filament applications should be deployed to separate deployment nodes.

### Worker Database Services (MariaDB + Redis)

For child deployment servers (worker nodes), this repository provides an isolated **MariaDB 11.4** + **Redis 7.4** Docker stack.

#### Deployment options:

1. **Via CLI script (recommended on the worker node):**
   ```bash
   git clone https://github.com/HomaEEE/OpenShip-deploy.git
   cd OpenShip-deploy
   sudo ./deploy-services.sh
   ```
   *The script checks/installs Docker, configures the `openship-network`, prompts or auto-generates 32-char passwords, optionally restricts firewall access via UFW, and starts the containers.*

2. **Via OpenShip Web UI / Stack:**
   Deploy `services/mariadb-redis/docker-compose.yml` directly from OpenShip as a Git repository stack, and set the environment variables (`MARIADB_ROOT_PASSWORD`, `REDIS_PASSWORD`, etc.) in the OpenShip UI.

#### Connecting projects deployed via Dockerfile:

When deploying a new application (via Dockerfile or OpenShip Application):

1. **Docker Network:**
   The project container must be attached to `openship-network`:
   ```bash
   # CLI docker run:
   docker run -d \
     --name my-project \
     --network openship-network \
     my-project-image
   ```
   Or in project `docker-compose.yml` using Dockerfile:
   ```yaml
   services:
     web:
       build: .
       networks:
         - default

   networks:
     default:
       name: openship-network
       external: true
   ```

2. **Project Environment Variables (.env):**
   ```env
   # MariaDB
   DB_CONNECTION=mysql
   DB_HOST=mariadb
   DB_PORT=3306
   DB_DATABASE=your_project_db
   DB_USERNAME=root
   DB_PASSWORD=your_mariadb_root_password

   # Redis
   REDIS_CLIENT=phpredis
   REDIS_HOST=redis
   REDIS_PORT=6379
   REDIS_PASSWORD=your_redis_password   # leave empty if no password configured
   ```

3. **Database creation for a new project:**
   ```bash
   docker exec -i openship-mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
     CREATE DATABASE IF NOT EXISTS your_project_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
     CREATE USER IF NOT EXISTS 'project_user'@'%' IDENTIFIED BY 'project_secure_password';
     GRANT ALL PRIVILEGES ON your_project_db.* TO 'project_user'@'%';
     FLUSH PRIVILEGES;
   "
   ```

#### Management commands:
```bash
sudo ./deploy-services.sh --status    # Check containers health
sudo ./deploy-services.sh --logs      # Follow logs in real time
sudo ./deploy-services.sh --restart   # Restart services
sudo ./deploy-services.sh --pull      # Pull latest images and restart
sudo ./deploy-services.sh --stop      # Stop containers (volumes preserved)
```

#### Backups (`backup.sh`):
```bash
cd services/mariadb-redis
sudo ./backup.sh          # Run backup now
sudo ./backup.sh --list   # List existing backups
sudo ./backup.sh --cron   # Install automated daily cron job at 03:00 UTC
```

### Security notes

The installer follows a conservative default approach:

- SSH access is preserved during provisioning.
- Password authentication is disabled automatically only when an administrator SSH key is available.
- UFW exposes SSH plus HTTP/HTTPS when enabled.
- OpenShip dashboard/API ports are not opened directly in UFW.
- Fail2ban protects SSH when enabled.
- Secrets supplied to the Bare installer are passed through the OpenShip environment and are not written to the installer state file.

Review the generated configuration before exposing a Control Plane to the public Internet.

### Requirements

- Ubuntu 24.04 LTS
- Root/sudo access
- Minimum 768 MiB RAM for Bare mode
- Minimum 10 GB free disk space
- amd64 or arm64

**Recommended:** 2 GB+ RAM for Standard mode.

### License

Add your preferred project license here.

---

## Русский

### О проекте

**OpenShip Deploy** — интерактивный установщик для подготовки чистого VPS на Ubuntu 24.04 LTS под **OpenShip Control Plane**.

Установщик рассчитан как на небольшие VPS с 1–2 GB RAM, так и на стандартные серверы. Он определяет ресурсы сервера, предлагает подходящий режим OpenShip, выполняет базовую настройку Ubuntu и запускает официальный процесс установки OpenShip.

Установщик намеренно не дублирует функциональность самого OpenShip: он подготавливает ОС и сервер, а OpenShip отвечает за собственный Control Plane, домены, Edge и дальнейшие deployment-задачи.

### Возможности

- Ubuntu 24.04 LTS
- amd64 и ARM64
- автоматическое определение RAM/CPU/диска
- выбор **Bare / Standard**
- автоматическое предупреждение на VPS менее 2 GB RAM
- рекомендация Bare для небольших VPS
- Bare без Docker через официальный `--bare`
- Standard на Docker Compose
- автоматическая настройка swap 2 GB
- отдельный Linux administrator
- настройка и hardening SSH
- опциональный UFW
- опциональный Fail2ban для SSH
- unattended security updates
- Docker устанавливается только для Standard
- установка OpenShip CLI
- создание OpenShip administrator в Bare mode
- настройка домена Control Plane
- сохранение конфигурации установки
- отдельные логи
- post-install проверки
- отдельные update/doctor скрипты

### Режимы

| Режим | Docker | RAM | Назначение |
|---|---:|---:|---|
| **Bare** | Нет | 1–2 GB | Лёгкий Control Plane |
| **Standard** | Да | 2+ GB | Docker-based установка |

Для небольшого VPS рекомендуется Bare: он не создаёт дополнительный Docker/Compose stack и использует штатный лёгкий runtime OpenShip.

### Установка

```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
chmod +x *.sh
sudo ./install.sh
```

Параметры командной строки не требуются — установщик работает интерактивно.

### Что делает установщик

1. Проверяет Ubuntu
2. Определяет архитектуру
3. Проверяет ресурсы
4. Предлагает режим OpenShip
5. Настраивает hostname/timezone
6. Устанавливает системные пакеты
7. Настраивает swap
8. Создаёт администратора
9. Настраивает SSH
10. Настраивает UFW
11. Настраивает Fail2ban
12. Включает автоматические security updates
13. Устанавливает Docker только для Standard
14. Устанавливает OpenShip CLI
15. Выполняет pre-flight проверки
16. Запускает первый setup OpenShip
17. Проверяет результат установки

### Домен

Установщик настраивает только **домен Control Plane**.

Варианты:

- **This machine only** — OpenShip без публичного домена.
- **Custom domain** — например `ops.example.com`.

Домены Laravel/Filament-приложений здесь не настраиваются. Они относятся к deployment/Edge-уровню OpenShip и задаются для конкретных проектов после подключения deployment node.

### Обновление

Проверка:

```bash
sudo ./update.sh --check
```

Обновление:

```bash
sudo ./update.sh
```

### Диагностика

```bash
sudo ./doctor.sh
```

Скрипт проверяет состояние VPS, OpenShip, Docker, Node/Bun, SSH, UFW, Fail2ban, swap, диска, памяти и сетевых портов.

### Логи

```text
/var/log/openship-control-install.log
/var/log/openship-control-update.log
/var/log/openship-control-doctor.log
```

Состояние установщика:

```text
/etc/openship-control/install.conf
```

Пароль OpenShip administrator в state-файл не сохраняется.

### Архитектура

Control Plane рекомендуется держать отдельно от приложений:

```text
OpenShip Control Plane
        │
        ├── Deployment Node 1 (Apps)
        │       ├── Laravel / Filament
        │       └── Other web apps
        │
        └── Deployment Node 2 (Databases & Cache)
                ├── MariaDB 11.4 (Docker)
                └── Redis 7.4 (Docker)
```

### Службы баз данных для Worker-серверов (MariaDB + Redis)

В каталоге `services/mariadb-redis/` находится готовый стек для развертывания MariaDB и Redis на дочерних серверах:

#### 1. Установка через скрипт на дочернем сервере:
```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
sudo ./deploy-services.sh
```
Скрипт автоматически:
- Проверяет наличие и при необходимости устанавливает Docker и Compose.
- Создает общую Docker-сеть `openship-network`.
- Генерирует надежные пароли или читает их из переменных окружения.
- Настраивает правила фаервола UFW (с возможностью ограничения доступа по IP).
- Запускает контейнеры и дожидается успешного прохождения healthcheck.

#### 2. Деплой через панель OpenShip:
Подключите репозиторий в OpenShip, укажите путь к файлу `services/mariadb-redis/docker-compose.yml` и задайте переменные окружения (`MARIADB_ROOT_PASSWORD`, `REDIS_PASSWORD` и т.д.) в настройках проекта.

#### 3. Подключение проектов (развертывание через Dockerfile):

При развертывании нового проекта через Dockerfile или панель OpenShip:

1. **Сетевое подключение:**
   Контейнер проекта должен быть подключен к Docker-сети `openship-network`:
   ```bash
   # Запуск контейнера через Docker CLI:
   docker run -d \
     --name my-project \
     --network openship-network \
     my-project-image
   ```
   Или в `docker-compose.yml` проекта со сборкой из Dockerfile:
   ```yaml
   services:
     web:
       build: .
       networks:
         - default

   networks:
     default:
       name: openship-network
       external: true
   ```

2. **Переменные окружения проекта (.env):**
   ```env
   # MariaDB
   DB_CONNECTION=mysql
   DB_HOST=mariadb
   DB_PORT=3306
   DB_DATABASE=your_project_db
   DB_USERNAME=root
   DB_PASSWORD=ваш_mariadb_root_password

   # Redis
   REDIS_CLIENT=phpredis
   REDIS_HOST=redis
   REDIS_PORT=6379
   REDIS_PASSWORD=ваш_redis_password   # оставить пустым, если пароль не задан
   ```

3. **Создание базы данных для нового проекта:**
   ```bash
   docker exec -i openship-mariadb mariadb -u root -p"$MARIADB_ROOT_PASSWORD" -e "
     CREATE DATABASE IF NOT EXISTS your_project_db CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
     CREATE USER IF NOT EXISTS 'project_user'@'%' IDENTIFIED BY 'project_secure_password';
     GRANT ALL PRIVILEGES ON your_project_db.* TO 'project_user'@'%';
     FLUSH PRIVILEGES;
   "
   ```

#### 4. Управление стеком:
```bash
sudo ./deploy-services.sh --status   # Статус и healthcheck
sudo ./deploy-services.sh --logs     # Просмотр логов
sudo ./deploy-services.sh --restart  # Перезапуск контейнеров
sudo ./deploy-services.sh --pull     # Обновление образов
sudo ./deploy-services.sh --stop     # Остановка
```

#### 4. Резервное копирование (`backup.sh`):
```bash
cd services/mariadb-redis
sudo ./backup.sh         # Создать бэкап MariaDB (gzip) и Redis (RDB)
sudo ./backup.sh --list  # Список существующих бэкапов
sudo ./backup.sh --cron  # Установить ежедневный запуск в cron (03:00 UTC)
```

---

## Українська

### Проєкт

**OpenShip Deploy** — інтерактивний інсталятор для підготовки чистого VPS на Ubuntu 24.04 LTS під **OpenShip Control Plane**.

Інсталятор підтримує як невеликі VPS із 1–2 GB RAM, так і стандартні сервери. Він визначає ресурси системи, пропонує відповідний режим OpenShip, налаштовує Ubuntu та запускає офіційний процес встановлення OpenShip.

Інсталятор не дублює функціональність OpenShip: він відповідає за підготовку ОС і сервера, а OpenShip — за Control Plane, домени, Edge та подальший deployment.

### Можливості

- Ubuntu 24.04 LTS
- amd64 та ARM64
- автоматичне визначення RAM/CPU/диска
- вибір **Bare / Standard**
- попередження для VPS із RAM менше 2 GB
- рекомендація Bare для невеликих VPS
- Bare без Docker через офіційний `--bare`
- Standard на Docker Compose
- автоматичне налаштування swap 2 GB
- окремий Linux administrator
- налаштування SSH
- опціональний UFW
- опціональний Fail2ban для SSH
- автоматичні security updates
- Docker встановлюється лише у Standard
- встановлення OpenShip CLI
- створення OpenShip administrator у Bare mode
- налаштування домену Control Plane
- збереження конфігурації
- логи встановлення
- post-install діагностика
- окремі update/doctor скрипти

### Режими встановлення

| Режим | Docker | RAM | Призначення |
|---|---:|---:|---|
| **Bare** | Ні | 1–2 GB | Легкий Control Plane |
| **Standard** | Так | 2+ GB | Повна Docker-інсталяція |

Для невеликих VPS рекомендується Bare.

### Встановлення

```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy
chmod +x *.sh
sudo ./install.sh
```

Командні параметри не потрібні — інсталятор працює в інтерактивному режимі.

### Що робить інсталятор

1. Перевіряє Ubuntu
2. Визначає архітектуру
3. Перевіряє ресурси
4. Пропонує режим OpenShip
5. Налаштовує hostname/timezone
6. Встановлює системні пакети
7. Налаштовує swap
8. Створює адміністратора
9. Налаштовує SSH
10. Налаштовує UFW
11. Налаштовує Fail2ban
12. Вмикає автоматичні security updates
13. Встановлює Docker лише для Standard
14. Встановлює OpenShip CLI
15. Виконує pre-flight перевірки
16. Запускає перше налаштування OpenShip
17. Перевіряє результат

### Домен

Інсталятор налаштовує лише **домен Control Plane**:

- **This machine only**
- **Custom domain**, наприклад `ops.example.com`

Домени Laravel/Filament застосунків не налаштовуються цим скриптом. Вони належать до deployment/Edge-рівня OpenShip та налаштовуються для конкретних проєктів після підключення deployment node.

### Оновлення

```bash
sudo ./update.sh --check
sudo ./update.sh
```

### Діагностика

```bash
sudo ./doctor.sh
```

Перевіряються OpenShip, Docker, Node/Bun, SSH, UFW, Fail2ban, swap, RAM, диск та мережеві порти.

### Логи

```text
/var/log/openship-control-install.log
/var/log/openship-control-update.log
/var/log/openship-control-doctor.log
```

Конфігурація інсталятора:

```text
/etc/openship-control/install.conf
```

Пароль адміністратора OpenShip не зберігається у state-файлі.

---

## Project structure

```text
OpenShip-deploy/
├── install.sh                  # Control Plane installer
├── update.sh                   # OpenShip update tool
├── doctor.sh                   # System & services doctor
├── deploy-services.sh          # Worker database services runner
├── config/
│   └── defaults.env.example    # Configuration example
├── services/
│   └── mariadb-redis/          # MariaDB + Redis stack
│       ├── docker-compose.yml
│       ├── .env.example
│       ├── deploy.sh
│       └── backup.sh
└── README.md                   # Documentation
```

## Requirements

- Ubuntu 24.04 LTS
- root/sudo
- минимум 768 MiB RAM для Bare
- минимум 10 GB свободного места
- amd64 или arm64

Для Standard рекомендуется **2 GB RAM и более**.

## Official OpenShip documentation

[OpenShip Documentation](https://openship.io/docs/)

---

## Status

This project is intended as a practical provisioning layer around the official OpenShip installation process.

OpenShip itself remains the source of truth for supported runtime, CLI options and deployment behavior.
