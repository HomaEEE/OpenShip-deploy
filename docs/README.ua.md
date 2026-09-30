<div align="center">

# ⚓ OpenShip Deploy

**Автоматизований інструментарій для розгортання Control Plane та сервісів [OpenShip](https://openship.io/) на Ubuntu 24.04 LTS**

[![Ubuntu 24.04](https://img.shields.io/badge/Ubuntu-24.04_LTS-E95420?logo=ubuntu&logoColor=white)](https://ubuntu.com/)
[![Bash](https://img.shields.io/badge/Shell-Bash-4EAA25?logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![amd64 · arm64](https://img.shields.io/badge/arch-amd64%20·%20arm64-blue)](#вимоги)
[![License MIT](https://img.shields.io/badge/license-MIT-green)](#ліцензія)

| [🇬🇧 English](../README.md) | [🇷🇺 Русский](README.ru.md) | 🇺🇦 **Українська** |
| :---: | :---: | :---: |

</div>

---

## Швидкий старт

### 1. Встановлення Control Plane
Повна підготовка чистого VPS на Ubuntu 24.04 LTS (безпека, swap, UFW, Caddy, OpenShip):

```bash
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/install.sh | sudo bash
```

Або через клонування репозиторію:
```bash
git clone https://github.com/HomaEEE/OpenShip-deploy.git
cd OpenShip-deploy && chmod +x *.sh
sudo ./install.sh
```

### 2. Діагностика системи та OpenShip (`doctor.sh`)
Швидка перевірка стану Control Plane, реверс-проксі Caddy, внутрішніх портів та файрвола:

```bash
# Прямий запуск через curl (без клонування)
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/doctor.sh | sudo bash

# Або локально з папки репозиторію
sudo ./doctor.sh
```

---

## Архітектура

```text
                    Інтернет
                       │
                   Cloudflare
                       │
       ┌───────────────┴───────────────┐
       │                               │
 os.example.com                   apps.example.com
       │                               │
  Control VPS                      Worker VPS
 Ubuntu 24.04 (1–2 ГБ)            Ubuntu 24.04 (4–8 ГБ)
       │                               │
  Caddy :80/:443                  OpenShip Edge :80/:443
   ├── :3001 (UI Дашборда)             │
   └── :4000 (API та WebSockets)   Laravel (FrankenPHP)
       │                               │ (openship-openship-deploy)
       │                        ┌──────┴──────┐
       │                        │             │
       │                   MariaDB:3306  Redis:6379
       │
       └────── SSH управління ─────────►
```

> [!IMPORTANT]
> **Головний інваріант**: Control VPS **ніколи не бере участі в обробці користувацького HTTP-трафіку** додатків. Якщо Control VPS тимчасово недоступний, усі прод-додатки продовжують працювати без перерв.

---

## Режими Control Plane

| Режим | Стек OpenShip | Проксі | Мін. RAM | Рекомендація |
|---|---|---|---|---|
| **Bare** *(Рекомендовано)* | Нативний процес + вбудована БД | Caddy reverse proxy | 1 ГБ | Виділений Control VPS (швидко, легко) |
| **Standard** | Docker Compose стек | OpenShip Edge контейнер | 2 ГБ | Повна ізоляція в Docker |

### Реверс-проксі Caddy (в режимі Bare)
Caddy приймає зовнішній трафік і безпечно проксіює його локально:
- `handle_path /api/proxy/*` → `127.0.0.1:4000` (API OpenShip та WebSockets термінала)
- `handle /api/*` → `127.0.0.1:4000` (прямі виклики API)
- `handle` → `127.0.0.1:3001` (UI дашборда)
- Порти `3001` та `4000` закриті в UFW від прямого зовнішнього доступу.

---

## Діагностика (`doctor.sh`)

Скрипт [`doctor.sh`](../doctor.sh) проводить повну діагностику стану хоста та компонентів OpenShip.

### Запуск

```bash
# Однією командою через curl
curl -fsSL https://raw.githubusercontent.com/HomaEEE/OpenShip-deploy/main/doctor.sh | sudo bash

# Локально
sudo ./doctor.sh
```

### Що перевіряє скрипт

| Категорія | Що перевіряється |
|---|---|
| **Ресурси хоста** | Версія OS, ядро, ядра CPU, оперативна пам'ять, Swap, вільний диск |
| **Control Plane** | Наявність CLI, версія, активність systemd-юніта (`openship.service`) |
| **Caddy Проксі** | Статус сервісу Caddy, маршрутизація Caddyfile (`:3001` та `:4000`) |
| **Порти** | Стан `ss -lntp` для SSH, дашборда (`:3001`) та API (`:4000`) |
| **Docker і сокет** | Демон Docker, доступність `/var/run/docker.sock` для керування хостом |
| **Файрвол (UFW)** | Відкриті `:80`, `:443`, SSH; порти `:3001` та `:4000` надійно закриті |
| **Безпека** | Активність Fail2ban та джейла SSH |

*Логи перевірки автоматично зберігаються у `/var/log/openship-doctor.log`.*

---

## Бази даних Worker (MariaDB + Redis)

Для серверів із робочими додатками:

### Деплой через інтерфейс OpenShip
Додайте цей репозиторій у дашборд OpenShip. Файл `docker-compose.yml` у корені запустить **MariaDB 11.4 LTS + Redis 7.4 Alpine** у мережу `openship-openship-deploy`. Порти назовні не публікуються.

### Керування через CLI
```bash
sudo ./deploy-services.sh             # Запуск стека
sudo ./deploy-services.sh --status    # Статус контейнерів
sudo ./deploy-services.sh --logs      # Перегляд логів
sudo ./deploy-services.sh --restart   # Перезапуск стека
sudo ./deploy-services.sh --stop      # Зупинка (дані зберігаються)
```

### Автоматичний бекап
```bash
sudo ./backup.sh                      # Миттєвий бекап MariaDB у gzip
# Щоденний бекап о 03:00 UTC (зберігання 7 днів у /var/backups/mariadb/):
(crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/mariadb-backup.sh >> /var/log/mariadb-backup.log 2>&1") | crontab -
```

---

## Шаблони додатків

У директорії [`templates/laravel-frankenphp/`](../templates/laravel-frankenphp/) доступний готовий шаблон для Laravel:
- Сервер FrankenPHP на Caddy з підтримкою HTTP/3 та worker-режиму.
- Автовиявлення MariaDB та Redis у внутрішній мережі Docker.
- Автоматичне створення бази даних і користувача при першому запуску.
- Автоматичний запуск міграцій (`migrate --force`) та кешування конфігурації.

---

## Оновлення OpenShip

```bash
sudo ./update.sh --check   # Перевірити наявність оновлень
sudo ./update.sh           # Застосувати оновлення
```

---

## Структура репозиторію

```text
OpenShip-deploy/
├── install.sh                  # Автоматичний інсталятор Control Plane
├── doctor.sh                   # Діагностика системи та сервісів OpenShip
├── update.sh                   # Скрипт оновлення OpenShip
├── deploy-services.sh          # Керування стеком MariaDB + Redis
├── backup.sh                   # Скрипт резервного копіювання баз даних
├── docker-compose.yml          # Compose-файл баз даних для деплою з OpenShip
├── openship.json               # Маніфест OpenShip
├── templates/
│   └── laravel-frankenphp/     # Шаблон для деплою Laravel + FrankenPHP
└── docs/
    ├── README.ru.md            # Документація російською
    └── README.ua.md            # Документація українською
```

---

## Вимоги

- **ОС**: Ubuntu 24.04 LTS (amd64 / arm64)
- **Права**: root або sudo
- **Control VPS**: від 1 ГБ RAM (у режимі Bare), 10 ГБ диску
- **Worker VPS**: від 2–8 ГБ RAM (під навантаження додатків)

---

## Ліцензія

MIT
